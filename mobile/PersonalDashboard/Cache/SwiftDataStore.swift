import Foundation
import SwiftData
#if canImport(AppKit)
import AppKit
#endif

/// SwiftData container singleton.
///
/// The store backs the iOS local-first data layer (#14). It holds
/// `LocalTodo`, `LocalNote`, `LocalList`, `LocalNoteFolder`, `LocalKeyword`,
/// `LocalTrip`, and `LocalItineraryItem`.
/// SwiftData persists to the app's Application Support directory by default,
/// which survives cache eviction unlike the legacy JSON cache.
///
/// Access the shared `ModelContext` via `SwiftDataStore.shared.context`.
/// Services and view models inject this context; tests can substitute an
/// in-memory container via `SwiftDataStore.makeInMemory()`.
/// Single debug-only seam for every launch hook that redirects or drives the
/// data layer (#318, #319 verification).
///
/// One place on purpose. Scattering `ProcessInfo` reads into views is what #316
/// exists to clean up, and the `LAUNCH_SECTION` parse is already duplicated, so
/// this gains a third tenant rather than the codebase gaining a third scattered
/// read. When #316 consolidates scaffolding it should relocate this whole enum
/// to its own file; it lives here for now only because a new file needs a
/// `project.yml` entry, which is MacUI's to add, and that would put the round
/// trip behind a cross-branch dependency.
///
/// Every hook follows the same discipline:
///   • `#if DEBUG` only, so release builds cannot be driven from the outside.
///   • Environment-only, never a persisted setting, so nothing stale outlives
///     the run that set it.
///   • Three-way resolution: absent is fine, usable proceeds, and **present but
///     unusable refuses to launch** rather than falling back. Falling back is
///     what made an unexpanded `${DEXTER_STORE_PATH}` silently target the user's
///     real store.
enum DebugLaunchHooks {
    #if DEBUG
    /// Resolve a path-valued hook three ways. Returns nil when the variable is
    /// genuinely absent; traps when it is set to something unusable.
    ///
    /// Reuses `AppConfig.resolved` for placeholder DETECTION only. Its nil is
    /// deliberately ambiguous between "missing" and "junk" because for an API key
    /// both mean "not configured"; for a path they mean opposite things, so the
    /// presence check happens here, before the helper is consulted.
    static func path(for variable: String) -> String? {
        guard let present = ProcessInfo.processInfo.environment[variable] else { return nil }
        guard let usable = AppConfig.resolved(present) else {
            fatalError(
                """
                \(variable) is set but carries no usable value (got "\(present)": \
                empty, whitespace-only, or an unexpanded $(...) / ${...} \
                placeholder). Refusing to launch rather than guessing.
                """
            )
        }
        return (usable as NSString).expandingTildeInPath
    }

    /// Run the export / import hooks once the container exists.
    ///
    /// Called from `SwiftDataStore`'s bootstrap rather than from the SwiftUI
    /// shell: `DexterMacApp.swift` is MacUI's file and currently carries the
    /// #293 router rework, so editing it concurrently is the worst available
    /// merge conflict.
    ///
    /// Export exits the process on completion so a script can rely on the exit
    /// code. Import deliberately does NOT exit, because the whole point of
    /// importing is to then inspect the restored data in the UI — checking a
    /// restored boarding pass opens is the one assertion that catches a dangling
    /// `attachmentPath`, and a count check cannot.
    @MainActor
    static func runDataHooks(context: ModelContext) async {
        if let target = path(for: "DEXTER_EXPORT_TO") {
            await runExport(to: target, context: context)
        }
        if let source = path(for: "DEXTER_IMPORT_FROM") {
            runImport(from: source, context: context)
        }
        #if os(macOS)
        // Apple Notes import (#396). The picker is a list of tap rows, and macOS
        // SwiftUI ignores synthetic clicks on those, so without this the whole
        // import path — AppleScript read, HTML conversion, image compression,
        // SwiftData write, dedup — cannot be exercised end to end by an agent.
        // Takes a folder NAME, imports every note in it, and leaves the app
        // running so the result can be inspected in the UI.
        if let folderName = ProcessInfo.processInfo.environment["DEXTER_IMPORT_APPLE_NOTES"],
           !folderName.trimmingCharacters(in: .whitespaces).isEmpty {
            await runAppleNotesImport(folderName: folderName, context: context)
        }
        #endif
    }

    #if os(macOS)
    /// Headless Apple Notes import of one folder, for verification.
    @MainActor
    private static func runAppleNotesImport(folderName: String, context: ModelContext) async {
        // Same gate as `runImport`: this writes real notes, so it is only allowed
        // against a disposable store.
        guard SwiftDataStore.isUsingOverrideStore else {
            NSLog("DEXTER_IMPORT_APPLE_NOTES: refusing without DEXTER_STORE_PATH set — will not write to the real store")
            exit(1)
        }
        do {
            let folders = try await AppleNotesReader.library()
            guard let folder = folders.first(where: {
                $0.name.caseInsensitiveCompare(folderName) == .orderedSame
            }) else {
                NSLog("DEXTER_IMPORT_APPLE_NOTES: no folder named %@ (have %d folders)",
                      folderName, folders.count)
                exit(1)
            }
            let service = AppleNotesImportService(store: SwiftDataStore.shared)
            let plan = try service.plan(
                folders: [folder], selectedNoteIDs: Set(folder.notes.map(\.id))
            )
            NSLog("DEXTER_IMPORT_APPLE_NOTES: %@ — %d to import, %d already there",
                  folder.name, plan.pending.count, plan.alreadyImported)
            let outcome = await service.run(plan: plan)
            NSLog("DEXTER_IMPORT_APPLE_NOTES: imported=%d images=%d skipped=%d failed=%d nonImageAttachments=%d",
                  outcome.imported, outcome.imagesImported, outcome.skipped,
                  outcome.failed, outcome.nonImageAttachmentsSkipped)
        } catch {
            NSLog("DEXTER_IMPORT_APPLE_NOTES: failed: %@", String(describing: error))
            exit(1)
        }
    }
    #endif

    @MainActor
    private static func runExport(to target: String, context: ModelContext) async {
        let url = URL(fileURLWithPath: target)
        let parent = url.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path) else {
            NSLog("DEXTER_EXPORT_TO: parent directory does not exist: %@", parent.path)
            exit(1)
        }
        do {
            let produced = try await DataExportService(modelContext: context).export()
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: produced, to: url)
            NSLog("DEXTER_EXPORT_TO: wrote archive to %@", url.path)
            exit(0)
        } catch {
            NSLog("DEXTER_EXPORT_TO: export failed: %@", String(describing: error))
            exit(1)
        }
    }

    @MainActor
    private static func runImport(from source: String, context: ModelContext) {
        // Import is the one operation that destroys data by design, so it is
        // gated on the store already being disposable. Without this, a careless
        // script could restore an archive straight over the user's real
        // financial data, and a fresh backup would only convert that into a
        // restore that depends on the code under test.
        guard SwiftDataStore.isUsingOverrideStore else {
            NSLog("DEXTER_IMPORT_FROM: refusing to import without DEXTER_STORE_PATH set — will not write to the real store")
            exit(1)
        }
        let url = URL(fileURLWithPath: source)
        guard FileManager.default.fileExists(atPath: url.path) else {
            NSLog("DEXTER_IMPORT_FROM: no archive at %@", url.path)
            exit(1)
        }
        do {
            let service = DataImportService(modelContext: context)
            let preview = try service.preview(url: url)
            try service.commit(preview: preview)
            NSLog("DEXTER_IMPORT_FROM: imported %@ — app left running for UI inspection", url.path)
        } catch {
            // Surfaced rather than swallowed: this is how a manifestClaimsMismatch
            // refusal becomes observable, which is otherwise unverifiable.
            NSLog("DEXTER_IMPORT_FROM: import failed: %@", String(describing: error))
            exit(1)
        }
    }
    #endif
}

@MainActor
final class SwiftDataStore {
    static let shared = SwiftDataStore()

    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    /// True when `DEXTER_STORE_PATH` redirected this process away from the
    /// user's real store (#318). Surfaces so the UI can say so out loud: a
    /// disposable store looks exactly like a wiped one, and a tester who
    /// forgets the override is active will read an empty app as data loss.
    /// Always false in release builds, where the override is inert.
    private(set) static var isUsingOverrideStore = false

    /// Say out loud, unmissably, that this process is NOT looking at the real
    /// store (#318).
    ///
    /// A disposable store is visually identical to a wiped one, so on this app a
    /// tester who forgets the override is active sees an empty Finance section
    /// and concludes their financial history is gone. An `NSLog` line does
    /// nothing for someone looking at the window, so this is a modal: it cannot
    /// be missed, scrolled past, or hidden behind a window that opened on
    /// another section.
    ///
    /// A modal is proportionate because the whole override is `#if DEBUG` and
    /// dev-only; this is never user-facing chrome. Deliberately implemented here
    /// rather than in the SwiftUI shell, both because `DexterMacApp.swift` is
    /// MacUI's file and because that file currently carries the #293 router
    /// rework, so a concurrent edit there would be a painful merge conflict. A
    /// persistent in-window affordance is a follow-up once the branches
    /// converge, not a substitute for this.
    ///
    /// Deferred to the next run-loop turn: this runs during container bootstrap,
    /// which can precede `NSApplication` being ready to present modally.
    /// Automation opt-out: `DEXTER_STORE_PATH_ACK` (#336).
    ///
    /// `runModal()` blocks the main thread until a human clicks the button. A
    /// script cannot, so under automation it blocks FOREVER, and because it is a
    /// nested modal run loop it also starves every main-actor continuation in the
    /// process. That is the bug #336 describes as "the alert blocks the debug
    /// hooks it exists to protect", and on #348 it presented as a phantom
    /// SwiftData failure: a sync pass completed its file write on a background
    /// task, then never resumed on the main actor to save, so it looked exactly
    /// like `save()` was throwing. Nothing was wrong with the save.
    ///
    /// The safety property survives because the opt-out is EXPLICIT and env-only.
    /// A human who has forgotten the override is active has not set this, so they
    /// still get the unmissable modal that #318 added. Only a caller that states
    /// "I know" is let through, and it still gets the log line.
    private static var overrideModalAcknowledged: Bool {
        ProcessInfo.processInfo.environment["DEXTER_STORE_PATH_ACK"] != nil
    }

    private static func warnIfOverrideStore(_ url: URL) {
        #if DEBUG && canImport(AppKit)
        guard isUsingOverrideStore else { return }
        NSLog("SwiftDataStore: OVERRIDE store active at %@", url.path)
        if overrideModalAcknowledged {
            NSLog("SwiftDataStore: override-store modal suppressed by DEXTER_STORE_PATH_ACK")
            return
        }
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Running against an override store"
            alert.informativeText = """
                DEXTER_STORE_PATH is set, so this launch is NOT using your real \
                Dexter data.

                Store in use:
                \(url.path)

                An empty or unfamiliar app is EXPECTED here and does not mean \
                your data is lost. Your real store is untouched. Quit and unset \
                DEXTER_STORE_PATH to go back to it.
                """
            alert.addButton(withTitle: "Continue with override store")
            alert.runModal()
        }
        #endif
    }

    /// Resolve the SQLite URL, honouring the `DEXTER_STORE_PATH` override.
    ///
    /// The override exists so automated verification (notably the #319 backup
    /// round trip, which by design destroys and rebuilds a store) can run
    /// against a disposable copy instead of the user's real financial data.
    /// Debug-only and env-only: never a persisted setting, so a stale value
    /// cannot outlive the run that set it.
    ///
    /// On any problem this **refuses to launch** rather than falling back to the
    /// default path. That looks harsh but it is the only safe behaviour: a
    /// silent fallback would send a run that asked for a throwaway store
    /// straight at the live one, which is precisely the accident the override
    /// is meant to prevent. Failing to launch touches nobody's data.
    nonisolated private static func resolveStoreURL(default defaultURL: URL) -> URL {
        #if DEBUG
        // Resolved through the shared seam, which does the three-way itself:
        // absent returns nil, present-but-unusable traps. The distinction is
        // load-bearing — collapsing it is what made an unexpanded
        // `${DEXTER_STORE_PATH}` silently target the user's real store.
        guard let raw = DebugLaunchHooks.path(for: "DEXTER_STORE_PATH") else {
            // Genuinely unset. Default path, silently. The only safe fallback.
            return defaultURL
        }
        let url = URL(fileURLWithPath: raw)
        // Require an existing parent directory. Without this check a typo'd
        // path yields a brand-new empty store, the app opens with no data, and
        // the obvious conclusion is that the data is gone.
        let parent = url.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            fatalError(
                """
                DEXTER_STORE_PATH is set to \(url.path) but its parent directory \
                does not exist. Refusing to launch rather than creating an empty \
                store, and refusing to fall back to the real store so this run \
                cannot touch live data. Create the directory or unset the variable.
                """
            )
        }
        guard url.pathExtension.lowercased() == "sqlite" else {
            fatalError(
                """
                DEXTER_STORE_PATH must end in .sqlite (got \(url.lastPathComponent)). \
                SwiftData writes -wal and -shm siblings alongside it, so the \
                extension is load-bearing for copying a store correctly.
                """
            )
        }
        NSLog("SwiftDataStore: using OVERRIDE store at %@ (DEXTER_STORE_PATH)", url.path)
        return url
        #else
        // Release builds ignore the variable entirely.
        return defaultURL
        #endif
    }

    /// Single source of truth for the schema.
    ///
    /// Both the on-disk container and `makeInMemory()` read this list. They used
    /// to carry two hand-maintained copies, which is a standing invitation to
    /// register a new model in one and not the other: the app would work and
    /// only tests or previews would fail, with an error that points at the model
    /// rather than at the missing registration.
    ///
    /// The four `Sync*` types are sidecars added for cross-device sync (#348).
    /// They exist precisely so sync does not have to touch the 15 models above
    /// them. Adding a model type is a safe lightweight migration; altering a
    /// live one is not.
    nonisolated static let schemaModels: [any PersistentModel.Type] = [
        LocalTodo.self,
        // Ticket attachments for a task (#399). A sidecar for the same reason the
        // Sync types below are: adding a model is a safe lightweight migration,
        // widening `LocalTodo` is not.
        LocalTaskTicket.self,
        LocalNoteFolder.self,
        LocalNote.self,
        // Note image attachments (#395). A new model, which is the safe kind of
        // migration — `LocalNote` itself is untouched.
        LocalNoteImage.self,
        LocalList.self,
        LocalKeyword.self,
        LocalTrip.self,
        LocalItineraryItem.self,
        LocalExpense.self,
        RecurringExpense.self,
        LocalPerson.self,
        LocalEvent.self,
        LocalFXRate.self,
        LocalProcessedEmail.self,
        LocalEmailIngestLog.self,
        LocalStatementImport.self,
        // MARK: Apple Notes import provenance (#396)
        // Sidecar, so re-importing a folder cannot duplicate what it already took.
        AppleNotesImportRecord.self,
        // Standalone wallet cards (#398). A new model type, so a lightweight
        // migration that creates one table and touches nothing above it.
        LocalWalletCard.self,
        // Vision board blocks (#446). A new model type, so one new table and no
        // change to anything above it. Membership lives here rather than as a
        // column on `LocalTodo`, which keeps that model untouched too.
        LocalVisionBlock.self,
        // MARK: Sync sidecars (#348)
        SyncDeviceState.self,
        SyncShadow.self,
        SyncTombstone.self,
        SyncPeerCursor.self,
    ]

    /// The default store location. One expression, called from both the
    /// bootstrap below and `storeURLForCurrentProcess()`, so a script asking
    /// which store this build would open cannot be told a different answer from
    /// the one the app uses.
    ///
    /// `create: true` is load-bearing on a fresh simulator, where Application
    /// Support does not exist yet and CoreData logs a noisy stat failure on
    /// first run.
    nonisolated private static func defaultStoreURL() throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask,
                 appropriateFor: nil, create: true)
            .appendingPathComponent("PersonalDashboard.sqlite")
    }

    /// The store this process would open, resolved without touching `shared`.
    ///
    /// Exists for `StoreSchemaGuard`'s check mode (#449), which has to answer
    /// "would this build damage that store" WITHOUT opening a container — since
    /// opening it is the damage.
    nonisolated static func storeURLForCurrentProcess() -> URL {
        guard let defaultURL = try? defaultStoreURL() else {
            fatalError("Cannot resolve the Application Support directory")
        }
        return resolveStoreURL(default: defaultURL)
    }

    private init() {
        do {
            let schema = Schema(Self.schemaModels)
            let defaultURL = try Self.defaultStoreURL()
            let storeURL = Self.resolveStoreURL(default: defaultURL)
            Self.isUsingOverrideStore = (storeURL != defaultURL)
            Self.warnIfOverrideStore(storeURL)
            // ⚠️ BEFORE the container, because after it the damage is done (#449).
            // A build whose schema lacks an entity the store holds drops that
            // entity and every row in it, with no error — the accident that lost
            // the #446 vision blocks. Exits with the entity named rather than
            // proceeding.
            StoreSchemaGuard.refuseIfDestructive(storeURL: storeURL)
            StoreSchemaGuard.reportArchiveCoverageGapInDebug()
            let configuration = ModelConfiguration(
                schema: schema,
                url: storeURL
            )
            self.container = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to bootstrap SwiftData container: \(error)")
        }
        // Runs once at first launch after the UTC-wall-clock change (#168),
        // before any itinerary UI can query. Guarded internally.
        migrateItineraryTimesToUTC()
        // One-time retag of pre-existing transport-shaped activities to the new
        // transport kind (#238). Guarded internally.
        migrateActivitiesToTransport()
        // Re-anchors every stored DAY to UTC midnight so a calendar day stops
        // moving with the device timezone (#506). Must run before any trip or
        // wallet UI can query. Guarded internally.
        migrateDayFieldsToUTCAnchor()
        #if DEBUG
        // Export / import launch hooks (#319 verification). No-op unless
        // DEXTER_EXPORT_TO / DEXTER_IMPORT_FROM are set.
        //
        // ⚠️ THESE FIRE ON FIRST STORE ACCESS, NOT AT LAUNCH. `shared` is a lazy
        // `static let`, so nothing here runs until something first touches the
        // store — which in practice means a window being constructed. A normal
        // launch always makes a window, so this only bites env-var-driven
        // launches, which must execute the inner Mach-O directly (LaunchServices
        // does not inherit the shell environment, so `open` arrives with every
        // DEXTER_* unset and each hook correctly no-ops).
        //
        // ⚠️ ON THIS BRANCH, A WINDOW IS STILL REQUIRED. An earlier version of
        // this comment claimed that `DexterMacApp.init()` touches `shared`
        // unconditionally under DEBUG (commit `0e30805`), so that bootstrap
        // happened at process start and no harness needed to do anything
        // special. That is true of `feat/macos-ux-overhaul` and NOT of this
        // branch — verify before relying on it:
        //
        //   git branch -a --contains 0e30805     # -> feat/macos-ux-overhaul only
        //   git merge-base --is-ancestor 0e30805 HEAD
        //
        // Here, `App/DexterMacApp.swift` has no `init()` at all. `shared` is
        // first touched by `.modelContainer(SwiftDataStore.shared.container)`
        // inside the `WindowGroup` body, so bootstrap happens only when a window
        // is actually constructed. So an env-driven launch with no window never
        // reaches this block, and must force one:
        //   osascript -e 'tell application "System Events" to tell process \
        //     "DexterMac" to click menu item "New Window" of menu 1 of menu bar \
        //     item "File"'
        // (Accessibility MENU clicks are reliable here; row clicks and swipes
        // are not.)
        //
        // Without that you observe no archive and no refusal, and the natural
        // reading is that the hooks are broken. That misreading has now cost
        // real time three times: once here, once on #318's guards (whose
        // comments described intent, "refuses to launch", rather than behaviour,
        // "refuses to bootstrap the store"), and once when this very comment was
        // "corrected" to describe another branch's code — which then presented
        // as a silent 4-minute hang with no output.
        //
        // When `0e30805` does land here, delete the osascript step rather than
        // leaving both claims side by side.
        //
        // Enqueued on the main actor rather than called inline, for two reasons.
        // First, both launch migrations above complete before an export
        // snapshots the store or an import mutates it. Second, and load-bearing:
        // it means the hooks do NOT run during `init`, so the store is never
        // mutated mid-construction. `init` has returned and `shared` is fully
        // assigned by the time this body executes. Nothing in the hook path
        // re-enters `shared` either — `runImport` reads the static
        // `isUsingOverrideStore`, not the singleton — so there is no recursive
        // lazy-init deadlock.
        //
        // A `Task { @MainActor in }` rather than the `DispatchQueue.main.async`
        // this used to be, because `runDataHooks` is now `async`: as of #309 the
        // export hops off the main actor to build the zip. Both forms defer past
        // `init`, so the reasoning above is unchanged.
        //
        // One property that hop introduces, and that matters for a harness
        // reading the archive: the main run loop is no longer blocked for the
        // duration of an export, so a window can come up while the zip is being
        // built. The archive is still a consistent snapshot, because
        // `DataExportService.export` completes every fetch and DTO mapping on
        // the main actor BEFORE it hops. Anything the UI changes afterwards
        // lands in the store but not in this archive.
        let hookContext = container.mainContext
        Task { @MainActor in
            await DebugLaunchHooks.runDataHooks(context: hookContext)
        }
        #endif
    }

    /// One-time backfill (#238): before the `transport` itinerary kind existed,
    /// flights and trains were stored as `.activity`. This pass retags the ones
    /// that carry a transport signal (a decoded boarding pass, a flight number,
    /// or an origin→destination route — i.e. `TicketMeta.isTransport`) to
    /// `.transport` with mode `.flight`.
    ///
    /// Heuristic by design: the `isTransport` signal is flight-shaped (BCBP /
    /// flight number / airport route), so backfilled rows default to `.flight`.
    /// A ticketless car transfer with no route leaves no signal and is left as
    /// an activity; the user can switch it in the editor. New imports classify
    /// correctly at the source, so this only touches legacy rows.
    ///
    /// Gated by a `UserDefaults` flag so it runs exactly once. Wrapped in
    /// do/catch — never crashes launch; a failure leaves the flag unset to retry.
    private func migrateActivitiesToTransport() {
        let flagKey = "activitiesToTransportMigrated_v1"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: flagKey) else { return }

        let ctx = container.mainContext
        do {
            let items = try ctx.fetch(FetchDescriptor<LocalItineraryItem>())
            var didChange = false
            for item in items where item.kindEnum == .activity && (item.ticketMeta?.isTransport ?? false) {
                item.kindEnum = .transport
                if item.transportModeEnum == nil {
                    item.transportModeEnum = .flight
                }
                item.updatedAt = Date()
                didChange = true
            }
            if didChange {
                try ctx.save()
            }
            defaults.set(true, forKey: flagKey)
        } catch {
            // Leave the flag unset so a future launch can retry. Never crash.
            NSLog("SwiftDataStore: activities→transport migration failed: %@", String(describing: error))
        }
    }

    /// One-time migration (#168): convert existing itinerary item times from
    /// the old device-local-wall-clock scheme to the new UTC-wall-clock scheme.
    ///
    /// Before #168, `startTime`/`endTime` stored a Date whose DEVICE-local H:M
    /// equalled the stated booking time. After #168 the app displays times with
    /// a UTC-pinned formatter, so those rows would render shifted. This pass
    /// rebuilds each stored Date so its UTC components equal the old device-local
    /// components (i.e. the stated H:M is preserved under the new anchor).
    ///
    /// Assumption: correct when the device timezone now equals the timezone in
    /// effect when the item was created (the common case — items created and
    /// migrated on the same phone in the same zone). Rare items created while
    /// the phone was in a different timezone can be corrected by re-scan (#165)
    /// or a manual edit, both of which re-anchor to UTC wall-clock directly.
    ///
    /// Gated by a `UserDefaults` flag so it runs exactly once. Wrapped in
    /// do/catch — never crashes launch.
    private func migrateItineraryTimesToUTC() {
        let flagKey = "itineraryTimesUTCMigrated_v1"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: flagKey) else { return }

        let ctx = container.mainContext
        let local = Calendar.current
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!

        // Rebuild `stored` (a device-local wall-clock Date) as a UTC wall-clock
        // Date preserving all components. Returns nil if reconstruction fails.
        func rebased(_ stored: Date) -> Date? {
            let c = local.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: stored
            )
            var out = DateComponents()
            out.year = c.year
            out.month = c.month
            out.day = c.day
            out.hour = c.hour
            out.minute = c.minute
            out.second = c.second
            return utc.date(from: out)
        }

        do {
            let items = try ctx.fetch(FetchDescriptor<LocalItineraryItem>())
            var didChange = false
            for item in items where item.startTime != nil || item.endTime != nil {
                if let start = item.startTime, let r = rebased(start) {
                    item.startTime = r
                    didChange = true
                }
                if let end = item.endTime, let r = rebased(end) {
                    item.endTime = r
                    didChange = true
                }
            }
            if didChange {
                try ctx.save()
            }
            defaults.set(true, forKey: flagKey)
        } catch {
            // Leave the flag unset so a future launch can retry. Never crash.
            NSLog("SwiftDataStore: itinerary UTC time migration failed: %@", String(describing: error))
        }
    }

    /// Re-anchor every stored DAY to UTC midnight, once per device (#506).
    ///
    /// Eight fields name a calendar day but were written as a device-local
    /// `startOfDay`, which is an instant. The day they reported therefore moved
    /// with the device timezone. An Italy itinerary built in Singapore (UTC+8)
    /// and India (UTC+5:30) read one day early once the Mac was on
    /// `Europe/Rome`, while the stops added in Italy read correctly, which split
    /// one day across two headers.
    ///
    /// Unlike ``migrateItineraryTimesToUTC()`` this needs no assumption about
    /// where the row was written. A local midnight is always within 14 hours of
    /// a UTC midnight, so ``WallClock/repairedDayAnchor(_:)`` recovers the
    /// intended day by snapping to the nearest one, from any zone in
    /// (-12, +12). That also makes it idempotent: an already-anchored value is
    /// its own nearest midnight.
    ///
    /// `updatedAt` is deliberately NOT bumped, but not to keep the repair off
    /// the wire — it does go on the wire. `SyncEngine.computeLocalChanges`
    /// diffs by SHA-256 content hash, not by `updatedAt`, so re-anchoring ~105
    /// fields changes ~105 hashes and the next pass emits them as upserts.
    ///
    /// The reason to leave `updatedAt` alone is record-level LWW. A repair is
    /// not a user edit. Bumping the timestamp would make this migration win
    /// every conflict against a genuine concurrent edit on another device, and
    /// silently discard it. Left alone, each record keeps competing on its real
    /// edit time.
    ///
    /// The emitted upserts are harmless and convergent: they carry anchored
    /// values, and `DataImportService` anchors day fields on the way in
    /// regardless — which is also what stops a peer still on an older build
    /// from re-introducing the shift.
    ///
    /// Gated by a `UserDefaults` flag so it runs exactly once. Wrapped in
    /// do/catch — never crashes launch.
    private func migrateDayFieldsToUTCAnchor() {
        let flagKey = "dayFieldsUTCAnchorMigrated_v1"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: flagKey) else { return }

        let ctx = container.mainContext

        /// Repair in place, reporting whether the value actually moved so an
        /// already-anchored store saves nothing.
        func repair(_ current: Date) -> Date? {
            let fixed = WallClock.repairedDayAnchor(current)
            return fixed == current ? nil : fixed
        }

        do {
            var changed = 0

            for item in try ctx.fetch(FetchDescriptor<LocalItineraryItem>()) {
                if let fixed = repair(item.dayDate) { item.dayDate = fixed; changed += 1 }
                if let end = item.endDate, let fixed = repair(end) { item.endDate = fixed; changed += 1 }
            }

            for card in try ctx.fetch(FetchDescriptor<LocalWalletCard>()) {
                if let fixed = repair(card.dayDate) { card.dayDate = fixed; changed += 1 }
                if let end = card.endDate, let fixed = repair(end) { card.endDate = fixed; changed += 1 }
            }

            for trip in try ctx.fetch(FetchDescriptor<LocalTrip>()) {
                if let fixed = repair(trip.startDate) { trip.startDate = fixed; changed += 1 }
                if let fixed = repair(trip.endDate) { trip.endDate = fixed; changed += 1 }
            }

            // `LocalEvent`'s optional range is the same kind of field, written
            // the same way, and it is rendered in Finance — so it drifted too.
            for event in try ctx.fetch(FetchDescriptor<LocalEvent>()) {
                if let start = event.startDate, let fixed = repair(start) {
                    event.startDate = fixed; changed += 1
                }
                if let end = event.endDate, let fixed = repair(end) {
                    event.endDate = fixed; changed += 1
                }
            }

            if changed > 0 {
                try ctx.save()
            }
            NSLog("SwiftDataStore: day-anchor migration re-anchored %d field(s)", changed)
            defaults.set(true, forKey: flagKey)
        } catch {
            // Leave the flag unset so a future launch can retry. Never crash.
            NSLog("SwiftDataStore: day-anchor migration failed: %@", String(describing: error))
        }
    }

    /// Test/preview-only initializer backed by an explicit container (usually
    /// `makeInMemory()`), so isolated tests exercise the real service + dedup
    /// paths against an in-memory store instead of the on-disk singleton. Skips
    /// the launch-time itinerary migration (irrelevant to a fresh store). Never
    /// used by the app, which always goes through `.shared`.
    init(container: ModelContainer) {
        self.container = container
    }

    /// Build an in-memory container for tests or previews.
    static func makeInMemory() -> ModelContainer {
        do {
            let schema = Schema(Self.schemaModels)
            let configuration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true
            )
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to bootstrap in-memory SwiftData container: \(error)")
        }
    }
}
