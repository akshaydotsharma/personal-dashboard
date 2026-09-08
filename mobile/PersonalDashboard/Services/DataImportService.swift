import Foundation
import SwiftData

/// Reads a `.zip` exported by `DataExportService` and merges it into the
/// local store by `clientUUID`. Existing UUIDs are skipped, new UUIDs
/// inserted. Receipt files for new expenses get restored to
/// `Documents/receipts/<uuid>.<ext>`. Re-importing the same archive is a
/// clean no-op.
///
/// Use it in two steps:
///   1. `preview(url:)` parses + counts so the UI can show the user what
///      will change before they commit.
///   2. `commit(preview:)` writes the new rows + receipt files.
///
/// Splitting the two avoids surprise mutations from a malformed archive
/// and lets the preview screen render counts without holding any locks.
@MainActor
final class DataImportService {

    enum ImportError: LocalizedError {
        case unreadable(Error)
        case zipFailure(MiniZip.ReadError)
        case manifestMissing
        case manifestUnparseable(Error)
        case unsupportedSchemaVersion(found: Int, supported: Int)
        /// #319: the manifest's declared row counts or model list disagree with
        /// the payload. Raised during preview, before anything is written.
        case manifestClaimsMismatch(details: [String])
        case commitFailed(Error)

        var errorDescription: String? {
            switch self {
            case .unreadable(let e):
                return "Couldn't read the file: \(e.localizedDescription)"
            case .zipFailure(let e):
                return e.errorDescription ?? "Couldn't read the ZIP archive."
            case .manifestMissing:
                return "The archive is missing manifest.json. It doesn't look like a Dexter export."
            case .manifestUnparseable(let e):
                return "The manifest couldn't be parsed: \(e.localizedDescription)"
            case .unsupportedSchemaVersion(let found, let supported):
                return "This archive uses schema version \(found), but this app supports version \(supported). Update the app to import it."
            case .manifestClaimsMismatch(let details):
                return "This archive looks incomplete or damaged, so nothing was imported. \(details.joined(separator: "; "))."
            case .commitFailed(let e):
                return "Couldn't save imported data: \(e.localizedDescription)"
            }
        }
    }

    /// Per-entity counts shown on the preview screen.
    ///
    /// `new` + `repaired` + `skipped` always equals `total`. Which of `repaired`
    /// and `skipped` an already-present record lands in depends entirely on the
    /// `Mode` the counts were computed for: insert-only skips it, repair
    /// overwrites it. Keeping both fields (rather than a single "will be
    /// written" number) is what lets the preview screen say which of the two is
    /// about to happen, since that is the whole distinction the user is
    /// choosing between.
    struct EntityCounts: Equatable {
        var total: Int
        var new: Int
        var repaired: Int
        var skipped: Int

        /// Records this mode will actually write.
        var written: Int { new + repaired }

        static let zero = EntityCounts(total: 0, new: 0, repaired: 0, skipped: 0)
    }

    /// Snapshot of what an import would change. Hand back to `commit(...)`
    /// to actually mutate the store.
    /// How an incoming record that already exists locally is treated.
    ///
    /// ⚠️ `.skipExisting` is the DEFAULT restore behaviour and must not change.
    /// Restore merges an archive into a live store and has always promised never
    /// to overwrite anything already present; #349 verified the recovery path
    /// with exactly these semantics, and that verification is what phase 2's
    /// safety argument rests on. Sync opts into `.replaceMatching` explicitly.
    ///
    /// #366 added a second explicit opt-in: the restore screen can now request
    /// `.replaceMatching` too, behind an off-by-default switch. That is a
    /// deliberate user choice on a per-import basis, not a change to the
    /// default, so the guarantee above is intact. It exists because insert-only
    /// merge has no way to heal a record that was inserted from a LOSSY archive
    /// (the pre-#335 exports, which dropped `tripUUID`, the per-surface hide
    /// flags, splits and the statement metadata). Those rows are present, so
    /// merge skips them forever, and the only other route back to correct data
    /// is wiping the store — which throws away anything the device holds that
    /// the archive does not.
    enum Mode {
        /// Insert only what is absent. Never touches an existing record.
        case skipExisting
        /// Delete the local record and re-insert from the incoming DTO.
        ///
        /// Delete-then-insert rather than field-by-field assignment, deliberately.
        /// Assigning fields one at a time means a field added to a model later,
        /// and forgotten here, is silently dropped on every apply — the exact class
        /// of bug #319 existed to fix, and the worst possible failure mode for
        /// sync because the data simply appears never to have been there. Reusing
        /// the same constructor call the insert path already uses makes it
        /// structurally impossible to miss a field.
        ///
        /// Safe here only because the schema has ZERO `@Relationship` edges, so
        /// deleting a row cannot cascade. Revisit if a relationship is ever added.
        case replaceMatching
    }

    /// What to do with a row that names an attachment whose bytes are neither on
    /// this device nor in the archive being imported.
    ///
    /// The two callers genuinely want different answers, so this is a parameter
    /// rather than a rule.
    enum UnresolvedAssetPolicy {
        /// Archive restore. The row ends up with no path, so it never claims bytes
        /// that exist nowhere. This is the behaviour #319 and #399 chose and #411
        /// keeps.
        case dropPath
        /// Sync apply (#471). The reference is KEPT, because the bytes travel
        /// separately now and a row with no path has nothing left for them to
        /// attach to. The card renders an arriving state until the blob lands.
        case keepPath
    }

    /// What an asset restorer did.
    ///
    /// `alreadyPresent` and `written` are deliberately distinct: the callers
    /// register restored paths for rollback, and only a file this import actually
    /// wrote may be deleted if the commit fails. See `restoreAsset` below.
    enum RestoredAsset {
        /// The bytes are already on this device. The row keeps pointing at them.
        case alreadyPresent(String)
        /// This import wrote the bytes out of the archive.
        case written(String)
        /// A path was declared but the bytes are nowhere. `UnresolvedAssetPolicy`
        /// decides whether the row keeps the reference.
        case unresolved(String)
        /// The row names no attachment at all.
        case noPath

        /// Registered for rollback. Nil for everything this import did not write.
        var writtenPath: String? {
            if case .written(let path) = self { return path }
            return nil
        }

        func path(unresolved policy: UnresolvedAssetPolicy) -> String? {
            switch self {
            case .alreadyPresent(let path), .written(let path):
                return path
            case .unresolved(let path):
                return policy == .keepPath ? path : nil
            case .noPath:
                return nil
            }
        }
    }

    struct Preview {
        let manifest: DataArchive.Manifest
        let archiveURL: URL
        let entries: [String: Data]      // path -> bytes (for receipts)

        /// Counts under `.skipExisting`, the default restore.
        let counts: [Entity: EntityCounts]
        /// Counts under `.replaceMatching`, the opt-in repair (#366).
        ///
        /// Held alongside rather than recomputed on demand: the preview is built
        /// once when the file is picked, but the mode toggle lives on the preview
        /// screen and flips afterwards. Recomputing would mean re-fetching the
        /// whole store on every tap of a switch.
        let repairCounts: [Entity: EntityCounts]

        init(
            manifest: DataArchive.Manifest,
            archiveURL: URL,
            entries: [String: Data],
            counts: [Entity: EntityCounts],
            repairCounts: [Entity: EntityCounts]? = nil
        ) {
            self.manifest = manifest
            self.archiveURL = archiveURL
            self.entries = entries
            self.counts = counts
            self.repairCounts = repairCounts ?? counts
        }

        func counts(for mode: Mode) -> [Entity: EntityCounts] {
            mode == .replaceMatching ? repairCounts : counts
        }

        /// Records the given mode will write: inserts plus, in repair mode,
        /// overwrites. This is what gates the commit button, so it MUST be
        /// mode-aware. Keying it to inserts alone is exactly the bug in #366: an
        /// archive whose every UUID is already present reported nothing to do
        /// and disabled the button, at precisely the moment a repair was needed.
        func totalWrites(for mode: Mode) -> Int {
            let table = counts(for: mode)
            return Entity.allCases.reduce(0) { $0 + (table[$1]?.written ?? 0) }
        }

        func totalNew(for mode: Mode) -> Int {
            let table = counts(for: mode)
            return Entity.allCases.reduce(0) { $0 + (table[$1]?.new ?? 0) }
        }

        func totalRepaired(for mode: Mode) -> Int {
            let table = counts(for: mode)
            return Entity.allCases.reduce(0) { $0 + (table[$1]?.repaired ?? 0) }
        }

        func hasAnythingToImport(for mode: Mode) -> Bool { totalWrites(for: mode) > 0 }
    }

    /// Display-order entities for the preview. Matches the order the
    /// user sees in the side drawer.
    /// Everything the preview screen reports on.
    ///
    /// The last five were added in #366. They were already being WRITTEN by
    /// `commit` (they joined the archive in #319) but were absent here, so they
    /// contributed nothing to the counts and nothing to the commit gate. An
    /// archive carrying only side models therefore reported "nothing to import"
    /// and refused to restore them. This list must stay in step with what
    /// `commit` inserts.
    enum Entity: String, CaseIterable, Hashable, Identifiable {
        case tasks
        /// #399. Present here and not only in `commit` for the reason the comment
        /// above gives: an entity that `commit` writes but this list omits
        /// contributes nothing to the gate, so an archive carrying only tickets
        /// would report "nothing to import" and refuse to restore them.
        case taskTickets
        case notes
        case noteImages
        case noteFolders
        case lists
        case itineraries
        case itineraryDays
        case expenses
        case vocab
        case persons
        case events
        case statementImports
        case recurringExpenses
        case processedEmails
        case walletCards
        /// #449. The board joins the archive here as well as in `commit`, or an
        /// archive carrying only blocks would report "nothing to import".
        case visionBlocks

        var id: String { rawValue }

        var label: String {
            switch self {
            case .tasks:             return "Tasks"
            case .taskTickets:       return "Task tickets"
            case .notes:             return "Notes"
            case .noteImages:        return "Note images"
            case .noteFolders:       return "Note folders"
            case .lists:             return "Lists"
            case .itineraries:       return "Itineraries"
            case .itineraryDays:     return "Itinerary items"
            case .expenses:          return "Expenses"
            case .vocab:             return "Vocabulary"
            case .persons:           return "People"
            case .events:            return "Events"
            case .statementImports:  return "Statement imports"
            case .recurringExpenses: return "Recurring expenses"
            case .processedEmails:   return "Processed emails"
            case .walletCards:       return "Wallet cards"
            case .visionBlocks:      return "Vision blocks"
            }
        }

        var icon: String {
            switch self {
            case .tasks:             return "checkmark.square"
            case .taskTickets:       return "ticket"
            case .notes:             return "doc.text"
            case .noteImages:        return "photo"
            case .noteFolders:       return "folder"
            case .lists:             return "list.bullet"
            case .itineraries:       return "airplane"
            case .itineraryDays:     return "mappin.and.ellipse"
            case .expenses:          return "dollarsign.circle"
            case .vocab:             return "character.book.closed"
            case .persons:           return "person.2"
            case .events:            return "calendar"
            case .statementImports:  return "doc.text.magnifyingglass"
            case .recurringExpenses: return "arrow.clockwise.circle"
            case .processedEmails:   return "envelope"
            case .walletCards:       return "wallet.pass"
            case .visionBlocks:      return "square.grid.2x2"
            }
        }
    }

    private let modelContext: ModelContext
    private let receiptStorage: ReceiptStorage
    /// #319: ticket files (`tickets/<uuid>.<ext>`) travel in the archive
    /// alongside receipts. Same shape and same API as `receiptStorage`.
    private let ticketStorage: TicketStorage
    /// #395: note image attachments. Same shape and same API again.
    private let noteImageStorage: ReceiptStorage
    /// #399: task ticket files, read out of the archive into
    /// `Documents/task-tickets/`.
    private let taskTicketStorage: TicketStorage
    /// #428: trip cover photographs, read out of the archive into
    /// `Documents/trip-covers/`.
    private let tripCoverStorage: ReceiptStorage

    init(
        modelContext: ModelContext,
        receiptStorage: ReceiptStorage = .shared,
        ticketStorage: TicketStorage = .shared,
        noteImageStorage: ReceiptStorage = .noteImages,
        taskTicketStorage: TicketStorage = .taskTickets,
        tripCoverStorage: ReceiptStorage = .tripCovers
    ) {
        self.modelContext = modelContext
        self.receiptStorage = receiptStorage
        self.ticketStorage = ticketStorage
        self.noteImageStorage = noteImageStorage
        self.taskTicketStorage = taskTicketStorage
        self.tripCoverStorage = tripCoverStorage
    }

    // MARK: - Preview

    func preview(url: URL) throws -> Preview {
        // Security-scoped resources: iOS hands the document picker a URL
        // outside the app sandbox; without start/stop access the read
        // fails silently. The export-side path lives in our own temp dir
        // and won't need this — but `startAccessingSecurityScopedResource`
        // is safe to call either way (returns false on non-scoped URLs).
        let didStartScope = url.startAccessingSecurityScopedResource()
        defer { if didStartScope { url.stopAccessingSecurityScopedResource() } }

        let entries: [MiniZip.Entry]
        do {
            entries = try MiniZip.read(from: url)
        } catch let error as MiniZip.ReadError {
            throw ImportError.zipFailure(error)
        } catch {
            throw ImportError.unreadable(error)
        }

        var byPath: [String: Data] = [:]
        for entry in entries { byPath[entry.name] = entry.data }

        guard let manifestData = byPath["manifest.json"] else {
            throw ImportError.manifestMissing
        }

        let manifest: DataArchive.Manifest
        do {
            manifest = try DataArchive.makeDecoder().decode(DataArchive.Manifest.self, from: manifestData)
        } catch {
            throw ImportError.manifestUnparseable(error)
        }

        // #319: was an exact-equality check, which made any future
        // `currentSchemaVersion` bump reject every archive already in the wild.
        // That is why this ticket does NOT bump the version: the guard shipped
        // to the phone is the strict one, so a newer archive would be refused by
        // code we cannot patch retroactively. Accepting anything up to the
        // current version means the next legitimate bump degrades instead of
        // breaking. A NEWER archive is still refused, since we genuinely cannot
        // know what it contains.
        guard manifest.schemaVersion <= DataArchive.currentSchemaVersion else {
            throw ImportError.unsupportedSchemaVersion(
                found: manifest.schemaVersion,
                supported: DataArchive.currentSchemaVersion
            )
        }

        // Self-verification (#319). Runs here, during preview, so a mismatch is
        // refused BEFORE any write. Counts absent means a pre-#319 archive:
        // proceed and warn rather than treating the absence as expected-zero,
        // which would reject every backup the user already holds as corrupt.
        try verifyManifestClaims(manifest)

        let (skipCounts, repairCounts) = try computeCounts(payload: manifest.data)
        return Preview(
            manifest: manifest,
            archiveURL: url,
            entries: byPath,
            counts: skipCounts,
            repairCounts: repairCounts
        )
    }

    /// Counts for BOTH modes off a single pass over the store.
    ///
    /// The two tables differ only in where an already-present record is filed
    /// (`skipped` vs `repaired`), so fetching twice would be pure waste — and on
    /// a store with 1500+ expenses the fetch is the expensive part.
    private func computeCounts(
        payload: DataArchive.Payload
    ) throws -> (skip: [Entity: EntityCounts], repair: [Entity: EntityCounts]) {
        let existingTodoUUIDs       = try existingUUIDs(LocalTodo.self,           keyPath: \.clientUUID)
        let existingNoteUUIDs       = try existingUUIDs(LocalNote.self,           keyPath: \.clientUUID)
        let existingFolderUUIDs     = try existingUUIDs(LocalNoteFolder.self,     keyPath: \.clientUUID)
        let existingListUUIDs       = try existingUUIDs(LocalList.self,           keyPath: \.clientUUID)
        let existingTripUUIDs       = try existingUUIDs(LocalTrip.self,           keyPath: \.clientUUID)
        let existingItineraryUUIDs  = try existingUUIDs(LocalItineraryItem.self,  keyPath: \.clientUUID)
        let existingExpenseUUIDs    = try existingStringUUIDs(LocalExpense.self,  keyPath: \.clientUUID)
        let existingVocabUUIDs      = try existingUUIDs(LocalKeyword.self,        keyPath: \.clientUUID)
        let existingTaskTicketUUIDs = try existingUUIDs(LocalTaskTicket.self,     keyPath: \.clientUUID)

        // Side models (#319 archive additions, counted here since #366).
        let existingPersonUUIDs    = try existingUUIDs(LocalPerson.self,            keyPath: \.clientUUID)
        let existingEventUUIDs     = try existingUUIDs(LocalEvent.self,             keyPath: \.clientUUID)
        let existingStatementUUIDs = try existingUUIDs(LocalStatementImport.self,   keyPath: \.clientUUID)
        let existingRecurringUUIDs = try existingStringUUIDs(RecurringExpense.self, keyPath: \.clientUUID)
        let existingMessageKeys    = try existingStringUUIDs(LocalProcessedEmail.self, keyPath: \.messageKey)
        let existingNoteImageUUIDs = try existingUUIDs(LocalNoteImage.self,          keyPath: \.clientUUID)
        let existingWalletCardIDs  = try existingUUIDs(LocalWalletCard.self,        keyPath: \.clientUUID)
        let existingVisionBlockIDs = try existingUUIDs(LocalVisionBlock.self,       keyPath: \.clientUUID)

        var skip: [Entity: EntityCounts] = [:]
        var repair: [Entity: EntityCounts] = [:]

        func record<ID: Hashable>(_ entity: Entity, _ incoming: [ID], existing: Set<ID>) {
            let total = incoming.count
            var new = 0
            for id in incoming where !existing.contains(id) { new += 1 }
            let present = total - new
            skip[entity]   = EntityCounts(total: total, new: new, repaired: 0,       skipped: present)
            repair[entity] = EntityCounts(total: total, new: new, repaired: present, skipped: 0)
        }

        record(.tasks,             payload.tasks.map(\.clientUUID),                    existing: existingTodoUUIDs)
        record(.taskTickets,       (payload.taskTickets ?? []).map(\.clientUUID),      existing: existingTaskTicketUUIDs)
        record(.notes,             payload.notes.map(\.clientUUID),                    existing: existingNoteUUIDs)
        record(.noteImages,        (payload.noteImages ?? []).map(\.clientUUID),       existing: existingNoteImageUUIDs)
        record(.noteFolders,       payload.noteFolders.map(\.clientUUID),              existing: existingFolderUUIDs)
        record(.lists,             payload.lists.map(\.clientUUID),                    existing: existingListUUIDs)
        record(.itineraries,       payload.itineraries.map(\.clientUUID),              existing: existingTripUUIDs)
        record(.itineraryDays,     payload.itineraryDays.map(\.clientUUID),            existing: existingItineraryUUIDs)
        record(.expenses,          payload.expenses.map(\.clientUUID),                 existing: existingExpenseUUIDs)
        record(.vocab,             payload.vocab.map(\.clientUUID),                    existing: existingVocabUUIDs)
        record(.persons,           (payload.persons ?? []).map(\.clientUUID),          existing: existingPersonUUIDs)
        record(.events,            (payload.events ?? []).map(\.clientUUID),           existing: existingEventUUIDs)
        record(.statementImports,  (payload.statementImports ?? []).map(\.clientUUID), existing: existingStatementUUIDs)
        record(.recurringExpenses, (payload.recurringExpenses ?? []).map(\.clientUUID), existing: existingRecurringUUIDs)
        record(.processedEmails,   (payload.processedEmails ?? []).map(\.messageKey),  existing: existingMessageKeys)
        record(.walletCards,       (payload.walletCards ?? []).map(\.clientUUID),      existing: existingWalletCardIDs)
        record(.visionBlocks,      (payload.visionBlocks ?? []).map(\.clientUUID),     existing: existingVisionBlockIDs)

        return (skip, repair)
    }

    private func existingUUIDs<M: PersistentModel>(_ model: M.Type, keyPath: KeyPath<M, UUID>) throws -> Set<UUID> {
        let rows = try modelContext.fetch(FetchDescriptor<M>())
        return Set(rows.map { $0[keyPath: keyPath] })
    }

    private func existingStringUUIDs<M: PersistentModel>(_ model: M.Type, keyPath: KeyPath<M, String>) throws -> Set<String> {
        let rows = try modelContext.fetch(FetchDescriptor<M>())
        return Set(rows.map { $0[keyPath: keyPath] })
    }

    // MARK: - Commit

    /// Applies the preview's changes. Receipt files get written to disk
    /// inside the same transaction window; if the SwiftData save fails,
    /// the receipts written so far are rolled back so re-running the
    /// import after the error is still a clean no-op for the rows that
    /// did succeed.
    func commit(
        preview: Preview,
        mode: Mode = .skipExisting,
        unresolvedAssets: UnresolvedAssetPolicy = .dropPath
    ) throws {
        let payload = preview.manifest.data

        // In replace mode the matching rows are removed FIRST and saved, so the
        // insert loops below then run against a store where nothing collides.
        // That is what lets the identical loops serve both modes: the only
        // difference is whether the "already here" sets are populated.
        //
        // A separate save is required between the delete and the inserts. The
        // unique constraint on `clientUUID` is enforced per save, so deleting and
        // re-inserting the same key inside one transaction trips it.
        if mode == .replaceMatching {
            try deleteMatching(payload: payload)
            try modelContext.save()
        }

        // Resolve existing UUIDs once up front. A second `fetch` after we
        // start `insert`ing would include the new rows.
        let existingTodoUUIDs       = mode == .replaceMatching ? [] : try existingUUIDs(LocalTodo.self,           keyPath: \.clientUUID)
        let existingNoteUUIDs       = mode == .replaceMatching ? [] : try existingUUIDs(LocalNote.self,           keyPath: \.clientUUID)
        let existingFolderUUIDs     = mode == .replaceMatching ? [] : try existingUUIDs(LocalNoteFolder.self,     keyPath: \.clientUUID)
        let existingListUUIDs       = mode == .replaceMatching ? [] : try existingUUIDs(LocalList.self,           keyPath: \.clientUUID)
        let existingTripUUIDs       = mode == .replaceMatching ? [] : try existingUUIDs(LocalTrip.self,           keyPath: \.clientUUID)
        let existingItineraryUUIDs  = mode == .replaceMatching ? [] : try existingUUIDs(LocalItineraryItem.self,  keyPath: \.clientUUID)
        let existingExpenseUUIDs    = mode == .replaceMatching ? [] : try existingStringUUIDs(LocalExpense.self,  keyPath: \.clientUUID)
        let existingVocabUUIDs      = mode == .replaceMatching ? [] : try existingUUIDs(LocalKeyword.self,        keyPath: \.clientUUID)
        let existingNoteImageUUIDs  = mode == .replaceMatching ? [] : try existingUUIDs(LocalNoteImage.self,      keyPath: \.clientUUID)
        let existingTaskTicketUUIDs = mode == .replaceMatching ? [] : try existingUUIDs(LocalTaskTicket.self,     keyPath: \.clientUUID)
        let existingWalletCardUUIDs = mode == .replaceMatching ? [] : try existingUUIDs(LocalWalletCard.self,     keyPath: \.clientUUID)
        let existingVisionBlockUUIDs = mode == .replaceMatching ? [] : try existingUUIDs(LocalVisionBlock.self,   keyPath: \.clientUUID)
        var writtenReceiptPaths: [String] = []
        // #319: tracked alongside receipts so a rollback removes restored ticket
        // files too, rather than leaving orphans behind after a failed import.
        var writtenTicketPaths: [String] = []
        /// #395: and note image files, for the same rollback reason.
        var writtenNoteImagePaths: [String] = []
        // #399: same, for task ticket files.
        var writtenTaskTicketPaths: [String] = []
        // #428: same, for trip cover photographs.
        var writtenTripCoverPaths: [String] = []

        do {
            for dto in payload.noteFolders where !existingFolderUUIDs.contains(dto.clientUUID) {
                modelContext.insert(LocalNoteFolder(
                    clientUUID: dto.clientUUID,
                    name: dto.name,
                    position: dto.position,
                    createdAt: dto.createdAt,
                    updatedAt: dto.updatedAt,
                    deletedAt: dto.deletedAt,
                    // Restore the archive state (#393). Nil for archives written
                    // before folders could be archived, which correctly restores
                    // those folders as active.
                    archivedAt: dto.archivedAt,
                    needsSync: false
                ))
            }

            for dto in payload.tasks where !existingTodoUUIDs.contains(dto.clientUUID) {
                modelContext.insert(LocalTodo(
                    clientUUID: dto.clientUUID,
                    title: dto.title,
                    todoDescription: dto.description,
                    completed: dto.completed,
                    dueDate: dto.dueDate,
                    tag: dto.tag,
                    position: dto.position,
                    address: dto.address ?? "",
                    googleMapsLink: dto.googleMapsLink ?? "",
                    priority: dto.priority ?? 0,
                    remindMe: dto.remindMe ?? false,
                    reminderClearedAt: dto.reminderClearedAt,
                    createdAt: dto.createdAt,
                    updatedAt: dto.updatedAt,
                    deletedAt: dto.deletedAt,
                    needsSync: false
                ))
            }

            // #399. Restore the ticket's file first and only set `attachmentPath`
            // when a file actually landed, so a row never points at bytes that
            // aren't there. A row whose file the archive didn't carry is KEPT
            // rather than dropped: it still holds the barcode and the details,
            // which is the whole card minus its original scan, and dropping it
            // would silently lose those.
            for dto in payload.taskTickets ?? []
            where !existingTaskTicketUUIDs.contains(dto.clientUUID) {
                let restored = try restoreTaskTicket(for: dto, archiveEntries: preview.entries)
                if let written = restored.writtenPath { writtenTaskTicketPaths.append(written) }
                modelContext.insert(LocalTaskTicket(
                    clientUUID: dto.clientUUID,
                    todoClientUUID: dto.todoClientUUID,
                    itineraryItemUUID: dto.itineraryItemUUID,
                    attachmentPath: restored.path(unresolved: unresolvedAssets) ?? "",
                    barcodePayload: dto.barcodePayload,
                    barcodeSymbology: dto.barcodeSymbology,
                    eventTitle: dto.eventTitle,
                    eventDate: dto.eventDate,
                    startTimeText: dto.startTimeText,
                    venue: dto.venue,
                    seat: dto.seat,
                    gate: dto.gate,
                    reference: dto.reference,
                    ticketMetaJSON: dto.ticketMetaJSON,
                    position: dto.position,
                    createdAt: dto.createdAt,
                    updatedAt: dto.updatedAt,
                    deletedAt: dto.deletedAt,
                    needsSync: false
                ))
            }

            for dto in payload.notes where !existingNoteUUIDs.contains(dto.clientUUID) {
                modelContext.insert(LocalNote(
                    clientUUID: dto.clientUUID,
                    folderClientUUID: dto.folderClientUUID,
                    title: dto.title,
                    content: dto.content,
                    position: dto.position,
                    createdAt: dto.createdAt,
                    updatedAt: dto.updatedAt,
                    deletedAt: dto.deletedAt,
                    // Restore the archive state (#374). Nil for archives written
                    // before the field existed, which correctly restores those
                    // notes as active.
                    archivedAt: dto.archivedAt,
                    // And whether it was archived by its folder (#393), so a
                    // restored folder unarchives the same set it took away.
                    archivedWithFolderAt: dto.archivedWithFolderAt,
                    needsSync: false
                ))
            }

            // Lists: re-attach list items by `listClientUUID` and preserve
            // order via `position`. We only attach items for lists that
            // are being newly inserted; lists that already exist keep
            // their on-device items as-is (skip semantics).
            let itemsByList: [UUID: [DataArchive.ListItemDTO]] = Dictionary(grouping: payload.listItems, by: \.listClientUUID)
            for dto in payload.lists where !existingListUUIDs.contains(dto.clientUUID) {
                let rawItems = (itemsByList[dto.clientUUID] ?? []).sorted { $0.position < $1.position }
                let items = rawItems.map {
                    ChecklistItem(text: $0.text, checked: $0.checked, url: $0.url ?? "")
                }
                modelContext.insert(LocalList(
                    clientUUID: dto.clientUUID,
                    title: dto.title,
                    items: items,
                    position: dto.position,
                    iconName: dto.iconName,
                    colorHex: dto.colorHex,
                    createdAt: dto.createdAt,
                    updatedAt: dto.updatedAt,
                    deletedAt: dto.deletedAt,
                    // Restore the archive state (#374).
                    archivedAt: dto.archivedAt,
                    needsSync: false
                ))
            }

            for dto in payload.itineraries where !existingTripUUIDs.contains(dto.clientUUID) {
                let trip = LocalTrip(
                    clientUUID: dto.clientUUID,
                    name: dto.name,
                    // Day fields are anchored on the way in (#506). A peer or
                    // archive written by an older build carries device-local
                    // midnights, and letting those land would re-introduce the
                    // day shift the launch migration just repaired. The repair
                    // is idempotent, so an already-anchored value passes through.
                    startDate: WallClock.repairedDayAnchor(dto.startDate),
                    endDate: WallClock.repairedDayAnchor(dto.endDate),
                    notes: dto.notes,
                    createdAt: dto.createdAt,
                    updatedAt: dto.updatedAt
                )
                // Participants (#258) are carried as the raw blob and assigned
                // after init, so the round trip is byte-for-byte and we don't
                // decode/re-encode a structure the model already guards.
                trip.participantsData = dto.participantsData
                // Cover photography (#428). The portable fields always travel;
                // `coverImagePath` is set ONLY when the file was actually restored
                // from the archive, exactly like `attachmentPath` below. A path
                // pointing at a file that is not on disk would make the row claim
                // a cover it cannot draw.
                //
                // Leaving the path nil is not a loss and needs no repair flag: the
                // launch sweep treats `resolved`-with-no-file as un-generated and
                // re-derives the art from the trip's name. That is the same branch the
                // sync path relies on, where there is no byte channel at all. Cover art
                // is always re-derivable, so this can never be data loss.
                trip.coverImageState          = dto.coverImageState
                trip.coverArtPromptVersion    = dto.coverArtPromptVersion
                // Dead fields, restored verbatim rather than dropped: an archive from
                // build 1102 carries values in them, and a DTO that silently discarded
                // fields is the lossy-restore shape #366 had to add a repair path for.
                trip.coverImageSourceURL      = dto.coverImageSourceURL
                trip.coverImageAttribution    = dto.coverImageAttribution
                trip.coverImageAttributionURL = dto.coverImageAttributionURL
                let restoredCover = try restoreTripCover(
                    relativePath: dto.coverImagePath,
                    archiveEntries: preview.entries
                )
                if let written = restoredCover.writtenPath { writtenTripCoverPaths.append(written) }
                if let coverPath = restoredCover.path(unresolved: unresolvedAssets) {
                    trip.coverImagePath = coverPath
                }
                modelContext.insert(trip)
            }

            for dto in payload.itineraryDays where !existingItineraryUUIDs.contains(dto.clientUUID) {
                let kind = ItineraryKind(rawValue: dto.kind) ?? .activity
                let transportMode = (dto.transportMode?.isEmpty ?? true)
                    ? nil
                    : TransportMode(rawValue: dto.transportMode!)
                let item = LocalItineraryItem(
                    clientUUID: dto.clientUUID,
                    tripUUID: dto.tripClientUUID,
                    // Anchored on the way in — see the trip loop above (#506).
                    dayDate: WallClock.repairedDayAnchor(dto.dayDate),
                    kind: kind,
                    transportMode: transportMode,
                    title: dto.title,
                    notes: dto.notes,
                    startTime: dto.startTime,
                    endDate: dto.endDate.map(WallClock.repairedDayAnchor),
                    endTime: dto.endTime,
                    sortOrder: dto.sortOrder,
                    googleMapsLink: dto.googleMapsLink ?? "",
                    createdAt: dto.createdAt,
                    updatedAt: dto.updatedAt
                )
                // Ticket / wallet fields (#222) and the ingest dedupe fields
                // (#143), all previously dropped so a restore lost every
                // boarding pass. Assigned after init to keep the change additive
                // rather than widening the model's initializer.
                item.arrivalTime        = dto.arrivalTime
                item.address            = dto.address ?? ""
                item.dedupeKey          = dto.dedupeKey ?? ""
                item.sourceConfirmation = dto.sourceConfirmation ?? ""
                item.barcodePayload     = dto.barcodePayload ?? ""
                item.barcodeSymbology   = dto.barcodeSymbology ?? ""
                item.seat               = dto.seat ?? ""
                item.gate               = dto.gate ?? ""
                item.venue              = dto.venue ?? ""
                item.ticketMetaJSON     = dto.ticketMetaJSON ?? ""
                // `attachmentPath` is set ONLY when the referenced file was
                // actually restored from the archive. Setting it otherwise makes
                // `hasTicket` true against a file that isn't on disk, which is
                // worse than reporting no ticket.
                let restoredTicket = try restoreTicket(
                    relativePath: dto.attachmentPath,
                    archiveEntries: preview.entries
                )
                if let written = restoredTicket.writtenPath { writtenTicketPaths.append(written) }
                if let ticketPath = restoredTicket.path(unresolved: unresolvedAssets) {
                    item.attachmentPath = ticketPath
                }
                modelContext.insert(item)
            }

            // #398: standalone wallet cards. Same shape as the itinerary loop
            // above, including the "only set `attachmentPath` when the file was
            // actually restored" rule.
            for dto in payload.walletCards ?? [] where !existingWalletCardUUIDs.contains(dto.clientUUID) {
                let card = LocalWalletCard(
                    clientUUID: dto.clientUUID,
                    kind: WalletCardKind(rawValue: dto.kind) ?? .pass,
                    title: dto.title,
                    // Anchored on the way in — see the trip loop above (#506).
                    dayDate: WallClock.repairedDayAnchor(dto.dayDate),
                    startTime: dto.startTime,
                    arrivalTime: dto.arrivalTime,
                    endDate: dto.endDate.map(WallClock.repairedDayAnchor),
                    endTime: dto.endTime,
                    notes: dto.notes,
                    venue: dto.venue,
                    address: dto.address,
                    googleMapsLink: dto.googleMapsLink,
                    seat: dto.seat,
                    gate: dto.gate,
                    sourceConfirmation: dto.sourceConfirmation,
                    barcodePayload: dto.barcodePayload,
                    barcodeSymbology: dto.barcodeSymbology,
                    ticketMetaJSON: dto.ticketMetaJSON,
                    createdAt: dto.createdAt,
                    updatedAt: dto.updatedAt
                )
                let restoredCardFile = try restoreTicket(
                    relativePath: dto.attachmentPath,
                    archiveEntries: preview.entries
                )
                if let written = restoredCardFile.writtenPath { writtenTicketPaths.append(written) }
                if let cardPath = restoredCardFile.path(unresolved: unresolvedAssets) {
                    card.attachmentPath = cardPath
                }
                modelContext.insert(card)
            }

            // #449: vision board blocks. No files to restore — a block is rows
            // only. The two blobs are assigned after construction because the
            // initialiser takes decoded arrays, and going through them would
            // re-encode: a member id or a `VisionItem` field this build does not
            // know would be dropped by the round trip, which is precisely the
            // lossy-restore shape #366 had to add a repair path for.
            for dto in payload.visionBlocks ?? [] where !existingVisionBlockUUIDs.contains(dto.clientUUID) {
                let block = LocalVisionBlock(
                    clientUUID: dto.clientUUID,
                    title: dto.title,
                    intent: dto.intent,
                    col: dto.col,
                    row: dto.row,
                    w: dto.w,
                    h: dto.h,
                    gridVersion: dto.gridVersion,
                    state: BlockState(rawValue: dto.state) ?? .default,
                    position: dto.position,
                    createdAt: dto.createdAt,
                    updatedAt: dto.updatedAt,
                    deletedAt: dto.deletedAt,
                    archivedAt: dto.archivedAt
                )
                block.membersData = dto.membersData
                block.notesData = dto.notesData
                modelContext.insert(block)
            }

            for dto in payload.expenses where !existingExpenseUUIDs.contains(dto.clientUUID) {
                let restoredPath = try restoreReceipt(for: dto, archiveEntries: preview.entries)
                if let written = restoredPath.writtenPath { writtenReceiptPaths.append(written) }
                // `.keepPath` regardless of the caller's policy, because receipts
                // have ALWAYS kept their reference — the old code fell back to
                // `dto.receiptImagePath` here. #411 does not change that; it only
                // brings task tickets, itinerary tickets and wallet cards into line
                // on the sync path.
                let receiptPath = restoredPath.path(unresolved: .keepPath)

                let expense = LocalExpense(
                    clientUUID: dto.clientUUID,
                    date: dto.date,
                    category: dto.category,
                    merchant: dto.merchant,
                    expenseDescription: dto.expenseDescription,
                    originalAmount: dto.originalAmount,
                    originalCurrency: dto.originalCurrency,
                    sgdAmount: dto.sgdAmount,
                    fxRate: dto.fxRate,
                    paymentMethod: dto.paymentMethod,
                    receiptImagePath: receiptPath ?? dto.receiptImagePath,
                    source: dto.source,
                    createdAt: dto.createdAt,
                    isRefund: dto.isRefund ?? false,
                    dedupeDescriptor: dto.dedupeDescriptor ?? "",
                    needsSync: false,
                    version: 0
                )
                // Trip linkage, person/event tagging (#183), shares (#188) and
                // group settle-up (#258-#261), plus the per-surface visibility
                // flags (#264). All previously dropped, which is why a restored
                // trip expense came back as a loose Finance row with its splits
                // gone and `myShareSGD` reporting the full amount.
                expense.tripUUID          = dto.tripUUID
                expense.sourceReference   = dto.sourceReference ?? ""
                expense.statementLabel    = dto.statementLabel ?? ""
                expense.statementFileName = dto.statementFileName ?? ""
                expense.personUUID        = dto.personUUID
                expense.personName        = dto.personName
                expense.eventUUID         = dto.eventUUID
                expense.eventName         = dto.eventName
                expense.numberOfShares    = dto.numberOfShares ?? 1
                expense.paidByPersonUUID  = dto.paidByPersonUUID
                expense.splitsData        = dto.splitsData
                // Restores the user's per-surface deletions. Without these a
                // restore resurrects rows they had already hidden.
                expense.hiddenFromFinance = dto.hiddenFromFinance ?? false
                expense.hiddenFromTrip    = dto.hiddenFromTrip ?? false
                // Statement dedupe key (#208): without it, re-importing the same
                // statement after a restore re-duplicated every transaction.
                expense.dedupeKey         = dto.dedupeKey ?? ""
                modelContext.insert(expense)
            }

            // MARK: Models added in #319
            //
            // Insertion order relative to expenses is IRRELEVANT here, and it is
            // worth stating so nobody later "preserves" an ordering that carries
            // no meaning. None of these models declares a `@Relationship`:
            // `personUUID`, `eventUUID` and `paidByPersonUUID` are plain `UUID?`
            // fields and `splitsData` is a JSON blob, so SwiftData enforces no
            // referential integrity between them and there is nothing to resolve
            // within the transaction. Everything lands in one save regardless.
            //
            // (An earlier version of this comment claimed people and events were
            // inserted first so references would resolve. That was wrong twice
            // over: they are inserted after expenses, and the ordering would not
            // have mattered even if they were not.)
            let existingPersonUUIDs    = mode == .replaceMatching ? [] : try existingUUIDs(LocalPerson.self,  keyPath: \.clientUUID)
            let existingEventUUIDs     = mode == .replaceMatching ? [] : try existingUUIDs(LocalEvent.self,   keyPath: \.clientUUID)
            for dto in (payload.persons ?? []) where !existingPersonUUIDs.contains(dto.clientUUID) {
                let person = LocalPerson(name: dto.name, colorHex: dto.colorHex)
                person.clientUUID = dto.clientUUID
                person.createdAt = dto.createdAt
                modelContext.insert(person)
            }
            for dto in (payload.events ?? []) where !existingEventUUIDs.contains(dto.clientUUID) {
                let event = LocalEvent(name: dto.name)
                event.clientUUID = dto.clientUUID
                event.startDate = dto.startDate
                event.endDate = dto.endDate
                event.tripUUID = dto.tripUUID
                event.notes = dto.notes
                event.createdAt = dto.createdAt
                event.updatedAt = dto.updatedAt
                modelContext.insert(event)
            }

            let existingRecurringUUIDs = mode == .replaceMatching ? [] : try existingStringUUIDs(RecurringExpense.self, keyPath: \.clientUUID)
            for dto in (payload.recurringExpenses ?? []) where !existingRecurringUUIDs.contains(dto.clientUUID) {
                let template = RecurringExpense(
                    amount: dto.amount,
                    currency: dto.currency,
                    category: dto.category,
                    merchant: dto.merchant,
                    expenseDescription: dto.expenseDescription,
                    paymentMethod: dto.paymentMethod,
                    dayOfMonth: dto.dayOfMonth,
                    isActive: dto.isActive,
                    startDate: dto.startDate,
                    endDate: dto.endDate
                )
                template.clientUUID = dto.clientUUID
                // Carried so a restored template does not re-post a month it has
                // already posted, which would double-charge the current month.
                template.lastPostedMonthKey = dto.lastPostedMonthKey
                template.createdAt = dto.createdAt
                template.updatedAt = dto.updatedAt
                modelContext.insert(template)
            }

            let existingStatementUUIDs = mode == .replaceMatching ? [] : try existingUUIDs(LocalStatementImport.self, keyPath: \.clientUUID)
            for dto in (payload.statementImports ?? []) where !existingStatementUUIDs.contains(dto.clientUUID) {
                let record = LocalStatementImport(
                    clientUUID: dto.clientUUID,
                    fileName: dto.fileName,
                    statementLabel: dto.statementLabel,
                    imported: dto.imported,
                    skippedDuplicates: dto.skippedDuplicates,
                    ignoredNonSpend: dto.ignoredNonSpend,
                    failed: dto.failed,
                    refunds: dto.refunds,
                    possiblyTruncated: dto.possiblyTruncated,
                    deposits: dto.deposits,
                    createdAt: dto.createdAt
                )
                // The initialiser takes `[UUID]` and joins it, but the stored
                // property is the joined string. Assigning it directly keeps the
                // round trip verbatim instead of parse-then-rejoin, which would
                // silently drop any entry that no longer parses as a UUID.
                record.importedExpenseUUIDs = dto.importedExpenseUUIDs
                modelContext.insert(record)
            }

            // Keyed on `messageKey`, not a clientUUID.
            let existingMessageKeys: Set<String> = mode == .replaceMatching ? [] : Set(
                try modelContext.fetch(FetchDescriptor<LocalProcessedEmail>()).map(\.messageKey)
            )
            for dto in (payload.processedEmails ?? []) where !existingMessageKeys.contains(dto.messageKey) {
                let email = LocalProcessedEmail(
                    messageKey: dto.messageKey,
                    uid: dto.uid,
                    uidValidity: dto.uidValidity
                )
                email.processedAt = dto.processedAt
                modelContext.insert(email)
            }

            // #395: note images. Inserted after notes so the rows they point at
            // already exist in this transaction. A row whose file is not in the
            // archive still restores: the strip shows it as "on your other
            // device", which is exactly what it is.
            for dto in (payload.noteImages ?? []) where !existingNoteImageUUIDs.contains(dto.clientUUID) {
                let restoredImage = try restoreNoteImage(for: dto, archiveEntries: preview.entries)
                if let written = restoredImage.writtenPath { writtenNoteImagePaths.append(written) }
                // `.keepPath` for the same reason receipts use it: #395 already
                // decided that an image row with no bytes is a real attachment
                // living on the other device, and kept the DTO's path to say so.
                let imagePath = restoredImage.path(unresolved: .keepPath)
                modelContext.insert(LocalNoteImage(
                    clientUUID: dto.clientUUID,
                    noteClientUUID: dto.noteClientUUID,
                    relativePath: imagePath ?? dto.relativePath,
                    position: dto.position,
                    pixelWidth: dto.pixelWidth,
                    pixelHeight: dto.pixelHeight,
                    createdAt: dto.createdAt,
                    updatedAt: dto.updatedAt,
                    deletedAt: dto.deletedAt,
                    needsSync: false
                ))
            }

            for dto in payload.vocab where !existingVocabUUIDs.contains(dto.clientUUID) {
                modelContext.insert(LocalKeyword(
                    clientUUID: dto.clientUUID,
                    term: dto.term,
                    notes: dto.notes,
                    createdAt: dto.createdAt,
                    updatedAt: dto.updatedAt
                ))
            }

            try modelContext.save()
            Haptics.light()
        } catch {
            modelContext.rollback()
            for path in writtenReceiptPaths {
                try? receiptStorage.delete(relativePath: path)
            }
            for path in writtenTicketPaths {
                try? ticketStorage.delete(relativePath: path)
            }
            for path in writtenNoteImagePaths {
                try? noteImageStorage.delete(relativePath: path)
            }
            for path in writtenTaskTicketPaths {
                try? taskTicketStorage.delete(relativePath: path)
            }
            for path in writtenTripCoverPaths {
                try? tripCoverStorage.delete(relativePath: path)
            }
            throw ImportError.commitFailed(error)
        }
    }

    /// Restore a receipt's image bytes from the archive. Returns the
    /// relative path now persisted on disk (e.g. `"receipts/<uuid>.jpg"`)
    /// or `nil` if the archive didn't include the file. We honour the
    /// stored relative path exactly so the round-trip is byte-identical:
    /// the same path that was on `LocalExpense.receiptImagePath` at
    /// export time is what we write back. If a different file already
    /// occupies that path on this device (e.g. user ran the importer
    /// after a partial reset), the existing file wins — receipts are
    /// content-addressed by UUID, collisions on the same UUID mean the
    /// same logical image.
    // MARK: - Replace-mode deletion

    /// Remove every local record the incoming payload also carries, so the
    /// insert loops can then re-create them from the DTOs at full fidelity.
    ///
    /// Only reached in `.replaceMatching`. Restore never calls this.
    ///
    /// Deletion is keyed on the SAME identity each model declares unique, so a
    /// record is matched exactly as the insert loops match it. `LocalExpense` and
    /// `RecurringExpense` key on a String `clientUUID`, and `LocalProcessedEmail`
    /// has no `clientUUID` at all and keys on its IMAP `messageKey`; getting any
    /// of those wrong would silently duplicate rather than replace.
    private func deleteMatching(payload: DataArchive.Payload) throws {
        try deleteMatching(LocalNoteFolder.self,     ids: Set(payload.noteFolders.map(\.clientUUID)),  key: \.clientUUID)
        try deleteMatching(LocalTodo.self,           ids: Set(payload.tasks.map(\.clientUUID)),        key: \.clientUUID)
        try deleteMatching(LocalTaskTicket.self,     ids: Set((payload.taskTickets ?? []).map(\.clientUUID)), key: \.clientUUID)
        try deleteMatching(LocalNote.self,           ids: Set(payload.notes.map(\.clientUUID)),        key: \.clientUUID)
        try deleteMatching(LocalNoteImage.self,      ids: Set((payload.noteImages ?? []).map(\.clientUUID)), key: \.clientUUID)
        try deleteMatching(LocalList.self,           ids: Set(payload.lists.map(\.clientUUID)),        key: \.clientUUID)
        try deleteMatching(LocalTrip.self,           ids: Set(payload.itineraries.map(\.clientUUID)),  key: \.clientUUID)
        try deleteMatching(LocalItineraryItem.self,  ids: Set(payload.itineraryDays.map(\.clientUUID)), key: \.clientUUID)
        try deleteMatching(LocalKeyword.self,        ids: Set(payload.vocab.map(\.clientUUID)),        key: \.clientUUID)
        try deleteMatching(LocalPerson.self,         ids: Set((payload.persons ?? []).map(\.clientUUID)), key: \.clientUUID)
        try deleteMatching(LocalEvent.self,          ids: Set((payload.events ?? []).map(\.clientUUID)),  key: \.clientUUID)
        try deleteMatching(LocalStatementImport.self, ids: Set((payload.statementImports ?? []).map(\.clientUUID)), key: \.clientUUID)
        try deleteMatching(LocalWalletCard.self,      ids: Set((payload.walletCards ?? []).map(\.clientUUID)),     key: \.clientUUID)
        try deleteMatching(LocalVisionBlock.self,     ids: Set((payload.visionBlocks ?? []).map(\.clientUUID)),    key: \.clientUUID)

        // String-keyed models.
        try deleteMatching(LocalExpense.self,   ids: Set(payload.expenses.map(\.clientUUID)), key: \.clientUUID)
        try deleteMatching(RecurringExpense.self, ids: Set((payload.recurringExpenses ?? []).map(\.clientUUID)), key: \.clientUUID)
        try deleteMatching(LocalProcessedEmail.self, ids: Set((payload.processedEmails ?? []).map(\.messageKey)), key: \.messageKey)
    }

    private func deleteMatching<M: PersistentModel, ID: Hashable>(
        _ type: M.Type,
        ids: Set<ID>,
        key: KeyPath<M, ID>
    ) throws {
        guard !ids.isEmpty else { return }
        // Fetch-all-and-filter rather than a predicate: `#Predicate` cannot
        // capture a Set for a contains check across every one of these key types,
        // and these are personal-scale tables.
        for model in try modelContext.fetch(FetchDescriptor<M>()) where ids.contains(model[keyPath: key]) {
            modelContext.delete(model)
        }
    }

    private func restoreReceipt(
        for expense: DataArchive.ExpenseDTO,
        archiveEntries: [String: Data]
    ) throws -> RestoredAsset {
        try restoreAsset(
            relativePath: expense.receiptImagePath,
            archiveEntries: archiveEntries,
            load: { receiptStorage.load(relativePath: $0) },
            write: { try receiptStorage.write(data: $0, relativePath: $1) }
        )
    }

    /// Verify what the manifest claims against what its payload actually holds
    /// (#319). Deliberately runs during `preview`, before any mutation: a
    /// mismatch found after writing leaves a half-restored store, and on this
    /// app that means the user's financial data in an unknown state. A clean
    /// refusal is strictly better.
    ///
    /// Absent claims mean a pre-#319 archive. Those import normally with a log
    /// line; they are unverifiable, NOT empty. Treating a missing count as an
    /// expected zero would reject every existing backup as corrupt, which is a
    /// worse bug than the one this ticket fixes.
    private func verifyManifestClaims(_ manifest: DataArchive.Manifest) throws {
        guard let claimed = manifest.counts else {
            NSLog("DataImportService: archive predates #319 self-verification; row counts unverifiable")
            return
        }
        let actual = Self.actualCounts(for: manifest.data)
        var mismatches: [String] = []
        for (model, claimedCount) in claimed.sorted(by: { $0.key < $1.key }) {
            let actualCount = actual[model] ?? 0
            if actualCount != claimedCount {
                mismatches.append("\(model): manifest claims \(claimedCount), payload has \(actualCount)")
            }
        }
        // A model named in `models` but absent from `counts` is the omitted-model
        // case a count check alone cannot see.
        if let models = manifest.models {
            for model in models where claimed[model] == nil {
                mismatches.append("\(model): listed as exported but carries no count")
            }
        }
        guard mismatches.isEmpty else {
            throw ImportError.manifestClaimsMismatch(details: mismatches)
        }
    }

    /// Counts derived from the payload itself, compared against the manifest's
    /// claims. Keys match `DataArchive.exportedModels`.
    ///
    /// Not private so `SchemaCoverageTests` can assert that key set against
    /// `exportedModels` (#449). A model added to `exportedModels` but missed
    /// here would be claimed by every manifest and counted by none, which
    /// `verifyManifestClaims` rejects as a corrupt archive — so the omission
    /// would surface as "your backup is broken" on the next restore, long after
    /// the change that caused it.
    static func actualCounts(for payload: DataArchive.Payload) -> [String: Int] {
        [
            "LocalTodo":            payload.tasks.count,
            "LocalTaskTicket":      payload.taskTickets?.count ?? 0,
            "LocalNote":            payload.notes.count,
            "LocalNoteImage":       payload.noteImages?.count ?? 0,
            "LocalNoteFolder":      payload.noteFolders.count,
            "LocalList":            payload.lists.count,
            "LocalTrip":            payload.itineraries.count,
            "LocalItineraryItem":   payload.itineraryDays.count,
            "LocalExpense":         payload.expenses.count,
            "LocalKeyword":         payload.vocab.count,
            "RecurringExpense":     payload.recurringExpenses?.count ?? 0,
            "LocalPerson":          payload.persons?.count ?? 0,
            "LocalEvent":           payload.events?.count ?? 0,
            "LocalStatementImport": payload.statementImports?.count ?? 0,
            "LocalProcessedEmail":  payload.processedEmails?.count ?? 0,
            "LocalWalletCard":      payload.walletCards?.count ?? 0,
            "LocalVisionBlock":     payload.visionBlocks?.count ?? 0,
        ]
    }

    /// #319 counterpart of `restoreReceipt` for ticket attachments.
    ///
    /// Takes the bare relative path (#398) so itinerary items and wallet cards,
    /// which share the `tickets/` directory, restore through one implementation.
    private func restoreTicket(
        relativePath: String?,
        archiveEntries: [String: Data]
    ) throws -> RestoredAsset {
        try restoreAsset(
            relativePath: relativePath,
            archiveEntries: archiveEntries,
            load: { ticketStorage.load(relativePath: $0) },
            write: { try ticketStorage.write(data: $0, relativePath: $1) }
        )
    }

    /// #395 counterpart for note image attachments.
    ///
    /// An unresolved image row does NOT lose its path: an image row with no bytes
    /// is still a real attachment that lives on the user's other device, and the
    /// strip says so. The caller keeps the DTO's original path so a later import
    /// of the Mac's archive, or the asset transfer added by #471, can fill it in.
    private func restoreNoteImage(
        for image: DataArchive.NoteImageDTO,
        archiveEntries: [String: Data]
    ) throws -> RestoredAsset {
        try restoreAsset(
            relativePath: image.relativePath,
            archiveEntries: archiveEntries,
            load: { noteImageStorage.load(relativePath: $0) },
            write: { try noteImageStorage.write(data: $0, relativePath: $1) }
        )
    }

    /// #399 counterpart for task ticket attachments.
    private func restoreTaskTicket(
        for ticket: DataArchive.TaskTicketDTO,
        archiveEntries: [String: Data]
    ) throws -> RestoredAsset {
        try restoreAsset(
            relativePath: ticket.attachmentPath,
            archiveEntries: archiveEntries,
            load: { taskTicketStorage.load(relativePath: $0) },
            write: { try taskTicketStorage.write(data: $0, relativePath: $1) }
        )
    }

    /// #428 counterpart for trip cover photographs. Returns nil when the archive
    /// carries no file for this trip, and the caller then leaves `coverImagePath`
    /// nil rather than pointing at a file that isn't there.
    ///
    /// nil is the ordinary case on the SYNC path, which has no byte channel, and it
    /// is harmless: `coverImageSourceURL` came through, so the launch repair sweep
    /// re-derives the cover. A cover is always re-derivable, so this can never be
    /// data loss — which is why it does not need the overwrite-repair treatment
    /// #366 had to add for lossy expense rows.
    /// The local-file check comes FIRST, and that ordering is the fix for a real data
    /// loss (#428).
    ///
    /// The other three restorers only accept a path whose bytes are in the archive,
    /// which is right for them. Applying that rule here destroyed cover art on every
    /// sync: `SyncApplier` passes `entries: [:]` because attachment bytes do not travel
    /// in the oplog, so `archiveEntries[relativePath]` never matched, the caller left
    /// `coverImagePath` unset, and `.replaceMatching` had already deleted the row — so
    /// the path was gone. Measured on the user's phone: five trips with NULL cover
    /// fields and fifteen orphaned JPEGs on disk.
    ///
    /// Checking disk first is correct for both callers. On the sync path the local file
    /// is already there and its path is exactly what must be kept. On an archive restore
    /// a file already at that UUID-keyed path is the same logical cover, so it wins
    /// rather than being rewritten — which is the rule receipts already follow.
    ///
    /// Returning the path when the file is absent from BOTH disk and archive would be
    /// wrong for the opposite reason: the row would claim art it cannot draw. It stays
    /// nil, and the launch sweep regenerates from the trip's name.
    private func restoreTripCover(
        relativePath: String?,
        archiveEntries: [String: Data]
    ) throws -> RestoredAsset {
        try restoreAsset(
            relativePath: relativePath,
            archiveEntries: archiveEntries,
            load: { tripCoverStorage.load(relativePath: $0) },
            write: { try tripCoverStorage.write(data: $0, relativePath: $1) }
        )
    }

    /// The one implementation behind all five asset restorers above.
    ///
    /// ## The local file is checked FIRST, and that ordering is the whole of #411
    ///
    /// `SyncApplier` replays a peer's winning ops through this importer in
    /// `.replaceMatching` mode with `entries: [:]`, because attachment bytes do not
    /// ride in the oplog. Under the old ordering — archive first, disk second — an
    /// empty archive meant every restorer returned nil, so every sync apply wrote an
    /// empty path over a row whose file was sitting on this device. Measured on the
    /// Mac: four `LocalTaskTicket` rows with a zero-length `ZATTACHMENTPATH` while
    /// `~/Documents/task-tickets/` still held their JPEGs. `restoreTripCover` was
    /// given this ordering by #428 for exactly the same reason; the other four now
    /// share it rather than each rediscovering it.
    ///
    /// ## Why the return type is not `String?`
    ///
    /// The callers register every restored path for rollback, and a failed commit
    /// deletes each one. Once "already on disk" can produce a path, an undifferentiated
    /// `String?` makes a rollback delete a file this import never wrote — the user's
    /// own bytes. Only `.written` is registered.
    private func restoreAsset(
        relativePath: String?,
        archiveEntries: [String: Data],
        load: (String) -> URL?,
        write: (Data, String) throws -> String
    ) rethrows -> RestoredAsset {
        guard let relativePath, !relativePath.isEmpty else { return .noPath }
        if load(relativePath) != nil { return .alreadyPresent(relativePath) }
        guard let archivedData = archiveEntries[relativePath] else {
            return .unresolved(relativePath)
        }
        return .written(try write(archivedData, relativePath))
    }
}
