import SwiftUI
import SwiftData

/// The Wallet: one place holding every scannable card, whatever created it
/// (#398).
///
/// Three things it does, in order of how often they matter:
///  1. **Shows** every card as a stacked deck: each card collapses to a coloured
///     band carrying its title and date, cards overlap so the group reads as a
///     wallet rather than a list, and tapping one unfolds the full ticket while
///     the rest stay closed. Colour comes from the card's kind, so a stay, a
///     boarding pass and an event ticket are told apart at a glance. Grouped into
///     Upcoming (soonest first, so the next thing you need is the card that
///     opens) and Past (most recent first).
///  2. **Presents to scan** on tap: straight into `TicketScanView` (max
///     brightness, idle timer held) on iPhone, which is the whole point of a
///     wallet at a gate. A card with nothing scannable opens its detail sheet
///     instead of a screen with an empty barcode panel.
///  3. **Adds** a card with no trip involved: camera, Photos, PDF, or by hand.
///     Uploads run the #222 pipeline (persist → decode barcode → BCBP parse →
///     one Claude call) via `TicketExtraction.runForWallet`.
///
/// The list is a VIEW over existing data (see `WalletEntry`), so a trip's
/// boarding pass appears here and on the trip timeline with one record behind
/// both. Cards it does not own are read-only here and route back to the surface
/// that does own them.
struct WalletView: View {
    @Environment(\.modelContext) private var modelContext

    @Bindable var router: AppRouter

    @Query(sort: \LocalWalletCard.dayDate, order: .reverse)
    private var cards: [LocalWalletCard]

    /// Every itinerary item, filtered down to the ticketed ones in
    /// `WalletEntry.build`. `hasTicket` is computed (it reads two string
    /// properties), so it cannot be expressed as a `#Predicate` and the filter
    /// has to happen in memory. Personal scale, so a full fetch is fine — the
    /// same call the trip timeline already makes per trip.
    @Query private var itineraryItems: [LocalItineraryItem]

    /// Only used to label a borrowed card with its trip name.
    @Query private var trips: [LocalTrip]

    /// Tickets attached to tasks (#399), filtered down to the ones that are
    /// actually a pass in `WalletEntry.build` — same in-memory arrangement as the
    /// itinerary above, and for the same reason: `belongsInWallet` reads a JSON
    /// blob, so no `#Predicate` can express it.
    @Query private var taskTickets: [LocalTaskTicket]

    /// Only used to label a task ticket with its task's title, which is also the
    /// card's fallback name when the extractor read no event name.
    @Query private var todos: [LocalTodo]

    // MARK: Add / edit state

    @State private var editorTarget: WalletCardEditorTarget?
    @State private var detailTarget: WalletDetailTarget?

    /// Blocks the FAB and shows the "Reading ticket…" overlay while an upload is
    /// being persisted, decoded and extracted. Mirrors `TripDetailView`.
    @State private var isProcessingTicket = false
    @State private var ticketError: String?

    @State private var showingCamera = false
    @State private var showingPhotoLibrary = false
    @State private var showingPDFPicker = false

    /// Which card is open. One at a time: a deck with several cards unfolded is
    /// just a list again, and the point of the stack is that the rest stay as
    /// readable bands. Seeded to the first Upcoming card so the wallet opens on
    /// the thing you most likely came for.
    @State private var expandedID: String?
    /// Guards the seeding so it happens once, not on every re-render.
    @State private var didSeedExpansion = false

    /// Card queued for deletion, driving the confirmation dialog. Holds the SOURCE
    /// rather than the model so a re-render can't hand the dialog a deleted row —
    /// and rather than a bare UUID, because what deleting removes and what the
    /// confirmation has to promise both depend on which surface made the card
    /// (#503).
    @State private var pendingDelete: WalletEntry.Source?

    /// Ticket queued for re-reading (#485). Confirmed rather than immediate: a
    /// re-read re-derives the whole card from the document, so it can overwrite a
    /// detail someone typed by hand.
    @State private var pendingRereadID: UUID?

    #if os(iOS)
    /// Full-screen present-to-scan target (iOS only — the surface depends on
    /// `UIScreen.brightness` and the idle timer).
    @State private var scanTarget: WalletScanTarget?
    #endif

    private var entries: [WalletEntry] {
        WalletEntry.build(
            cards: cards,
            itineraryItems: itineraryItems,
            trips: trips,
            // Soft-deleted rows stay in the store until a sweep; the wallet must
            // not resurrect a ticket the user deleted from its task.
            taskTickets: taskTickets.filter { $0.deletedAt == nil },
            todos: todos
        )
    }

    private var groups: WalletGroups {
        // A card's `validThrough` is a UTC-anchored day (#506), so "today" is
        // anchored the same way before the Upcoming / Past split compares them.
        WalletEntry.grouped(entries, today: WallClock.todayAnchor())
    }

    var body: some View {
        ZStack {
            Tokens.paper.canvasIgnoresSafeArea()

            VStack(spacing: 0) {
                // iOS in-view top bar; macOS uses the native window toolbar.
                #if os(iOS)
                TopBar(
                    title: "Wallet",
                    onMenu: { withAnimation(.easeOut(duration: 0.2)) { router.drawerOpen = true } }
                )
                #endif
                content
                    .macSectionChrome("Wallet")
                    #if os(macOS)
                    .focusedSceneValue(\.newItemAction, NewItemAction(title: "New Card") {
                        editorTarget = .new
                    })
                    #endif
            }

            addMenu

            if isProcessingTicket {
                processingOverlay
            }
        }
        .activeSection(.wallet)
        .onAppear(perform: seedExpansionIfNeeded)
        .onChange(of: groups.upcoming.first?.id) { _, _ in
            // The first card can change under us — a new upload, or midnight
            // moving one to Past. Re-seed only while nothing is open, so this
            // never yanks a card shut while the user is looking at it.
            guard expandedID == nil else { return }
            didSeedExpansion = false
            seedExpansionIfNeeded()
        }
        .sheet(item: $editorTarget) { target in
            WalletCardEditorSheet(target: target)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        // Card detail: the tinted card plus its actions. iOS presents it
        // full-screen to match TicketScanView; macOS has no `.fullScreenCover`,
        // so it presents the same view as a sheet (same treatment as
        // `StayBookingDetailSheet`, issue #281).
        #if os(iOS)
        .fullScreenCover(item: $detailTarget) { target in
            detailSheet(for: target)
        }
        .fullScreenCover(item: $scanTarget) { target in
            TicketScanView(pass: ScannablePass(card: target.card))
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraPicker { data in
                showingCamera = false
                handleTicketData(data, isPDF: false)
            }
            .ignoresSafeArea()
        }
        #else
        .sheet(item: $detailTarget) { target in
            detailSheet(for: target)
        }
        #endif
        .photoLibraryPicker(isPresented: $showingPhotoLibrary) { data in
            handleTicketData(data, isPDF: false)
        }
        .pdfPicker(isPresented: $showingPDFPicker) { data, _ in
            handleTicketData(data, isPDF: true)
        }
        .confirmationDialog(
            pendingDelete?.deletionTitle ?? "Delete this card?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(pendingDelete?.deletionConfirmLabel ?? "Delete", role: .destructive) {
                if let source = pendingDelete { delete(source) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(pendingDelete?.deletionMessage ?? "")
        }
        .confirmationDialog(
            "Read this ticket again?",
            isPresented: Binding(
                get: { pendingRereadID != nil },
                set: { if !$0 { pendingRereadID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Read again") {
                if let id = pendingRereadID { reread(ticketID: id) }
                pendingRereadID = nil
            }
            Button("Cancel", role: .cancel) { pendingRereadID = nil }
        } message: {
            Text("The stored file is read again and the card's details are replaced with what it says. Anything you typed by hand is overwritten. The file and its code are untouched.")
        }
        .alert(
            "Couldn't save the ticket",
            isPresented: Binding(
                get: { ticketError != nil },
                set: { if !$0 { ticketError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { ticketError = nil }
        } message: {
            Text(ticketError ?? "")
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        let grouped = groups
        if grouped.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: Space.xl) {
                        cardStack(
                            title: "Upcoming",
                            entries: grouped.upcoming,
                            accent: Tokens.accent(for: .wallet),
                            soft: Tokens.paper2,
                            isPast: false
                        )
                        cardStack(
                            title: "Past",
                            entries: grouped.past,
                            accent: Tokens.muted,
                            soft: Tokens.paper2,
                            isPast: true
                        )

                        // Bumper so the last card clears the floating tab bar + FAB.
                        Color.clear.frame(height: 96)
                    }
                    .padding(.horizontal, Space.lg)
                    .padding(.top, Space.sm)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: expandedID) { _, newValue in
                    // Bring a newly opened card fully into view: it grows
                    // downward from a strip to a full ticket, so opening one near
                    // the bottom would otherwise unfold mostly off-screen.
                    guard let newValue else { return }
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(newValue, anchor: .top)
                    }
                }
            }
        }
    }

    /// One group rendered as a stack of overlapping cards.
    ///
    /// The overlap is what makes this a wallet rather than a list: collapsed
    /// cards are pulled up under the one before them so only their coloured band
    /// shows, and the whole group reads as a deck you flick through. An open card
    /// gets real space on both sides so it stops looking stacked and starts
    /// looking like the ticket it is.
    @ViewBuilder
    private func cardStack(
        title: String,
        entries: [WalletEntry],
        accent: Color,
        soft: Color,
        isPast: Bool
    ) -> some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: Space.md) {
                groupHeader(title: title, count: entries.count, accent: accent, soft: soft)

                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        // Edit / delete go over only for a card the wallet owns,
                        // open-source only for a borrowed one. The card renders
                        // whichever closures it was handed.
                        let ownID = walletCardID(of: entry)
                        WalletDeckCard(
                            entry: entry,
                            isExpanded: expandedID == entry.id,
                            isPast: isPast,
                            onToggle: { toggle(entry) },
                            onPresent: { present(entry) },
                            onEdit: ownID.map { id in { editorTarget = .existing(id) } },
                            // Delete is offered for EVERY card, whatever made it
                            // (#503). Edit still is not: a record has one editor.
                            onDelete: { pendingDelete = entry.source },
                            onOpenSource: ownID == nil ? { openSource(of: entry) } : nil,
                            onReread: rereadableTicketID(of: entry).map { id in
                                { pendingRereadID = id }
                            }
                        )
                        .id(entry.id)
                        .padding(.top, topInset(at: index, in: entries))
                        // Later cards draw over earlier ones, so each band
                        // overlaps the bottom edge of the card above it — the
                        // stacking order a real wallet has.
                        .zIndex(Double(index))
                    }
                }
            }
        }
    }

    /// Gap above the card at `index`: negative between two closed cards so they
    /// overlap into a deck, positive whenever either neighbour is open.
    private func topInset(at index: Int, in entries: [WalletEntry]) -> CGFloat {
        guard index > 0 else { return 0 }
        let thisOpen = expandedID == entries[index].id
        let prevOpen = expandedID == entries[index - 1].id
        return (thisOpen || prevOpen) ? Space.md : -Self.deckOverlap
    }

    /// How far each closed card slides under the one before it. Tuned against
    /// the band's own height: enough that the stack reads as stacked, little
    /// enough that every title stays fully readable.
    private static let deckOverlap: CGFloat = 12

    /// Same shape as the Trips / Tasks section headers: accent title plus a
    /// count capsule, left-aligned on paper.
    private func groupHeader(title: String, count: Int, accent: Color, soft: Color) -> some View {
        HStack(spacing: Space.sm) {
            Text(title)
                .font(.edHeading)
                .foregroundStyle(accent)
            Text("\(count)")
                .font(.edCaption)
                .foregroundStyle(accent)
                .padding(.horizontal, Space.sm)
                .padding(.vertical, 2)
                .background(soft, in: Capsule())
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(spacing: Space.md) {
            Spacer()
            Image(systemName: "wallet.pass")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Tokens.muted)
            Text("Nothing to scan yet")
                .font(.edHeading)
                .foregroundStyle(Tokens.ink)
                .multilineTextAlignment(.center)
            Text("Add a boarding pass, an event ticket, or any pass with a barcode. Photograph it or drop in the PDF and the details are read for you. Tickets already attached to a trip show up here on their own.")
                .font(.edSubheadline)
                .foregroundStyle(Tokens.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Space.xl)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Space.lg)
    }

    // MARK: - Add menu (FAB)

    private var addMenu: some View {
        Menu {
            // Camera capture is iOS-only (UIImagePickerController +
            // `.fullScreenCover`), matching the trip ticket menu.
            #if os(iOS)
            Button {
                Haptics.light()
                showingCamera = true
            } label: {
                Label("Scan a ticket", systemImage: "camera")
            }
            #endif
            Button {
                showingPhotoLibrary = true
            } label: {
                Label("Ticket from Photos", systemImage: "photo")
            }
            Button {
                showingPDFPicker = true
            } label: {
                Label("Ticket from PDF", systemImage: "doc.text")
            }
            Divider()
            Button {
                editorTarget = .new
            } label: {
                Label("Add manually", systemImage: "square.and.pencil")
            }
        } label: {
            Image(systemName: "plus")
        }
        .buttonStyle(EdIconCircleButtonStyle(kind: .primary))
        .disabled(isProcessingTicket)
        .padding(.trailing, 22)
        .padding(.bottom, BottomTabBarMetrics.fabBottomInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .accessibilityLabel("Add a card")
    }

    private var processingOverlay: some View {
        ZStack {
            Tokens.paper.opacity(0.72).ignoresSafeArea()
            VStack(spacing: Space.md) {
                ProgressView()
                Text("Reading ticket…")
                    .font(.edSubheadline)
                    .foregroundStyle(Tokens.inkSoft)
            }
            .padding(Space.xl)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
            .paperBorder(Tokens.border, radius: Radius.lg)
        }
        .transition(.opacity)
    }

    // MARK: - Detail

    @ViewBuilder
    private func detailSheet(for target: WalletDetailTarget) -> some View {
        WalletCardDetailSheet(
            entry: target.entry,
            onEdit: walletCardID(of: target.entry).map { id in
                {
                    detailTarget = nil
                    editorTarget = .existing(id)
                }
            },
            onOpenSource: target.entry.source.isEditableInWallet
                ? nil
                : {
                    let entry = target.entry
                    detailTarget = nil
                    openSource(of: entry)
                }
        )
    }

    // MARK: - Actions

    /// Open the tapped card and close whatever was open, or close it if it was
    /// already the open one.
    private func toggle(_ entry: WalletEntry) {
        Haptics.light()
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            expandedID = (expandedID == entry.id) ? nil : entry.id
        }
    }

    private func seedExpansionIfNeeded() {
        guard !didSeedExpansion else { return }
        didSeedExpansion = true
        let grouped = groups
        // Fall back to the most recent past card when there is nothing upcoming,
        // so the wallet never opens looking empty when it holds cards.
        expandedID = grouped.upcoming.first?.id ?? grouped.past.first?.id
    }

    /// Straight to the high-contrast barcode: max brightness, idle timer held.
    /// The fast path for someone already standing at the gate. A card with
    /// nothing scannable falls back to its detail rather than presenting an
    /// empty barcode panel, and macOS has no scan surface at all.
    private func present(_ entry: WalletEntry) {
        Haptics.light()
        #if os(iOS)
        if entry.card.hasBarcode {
            scanTarget = WalletScanTarget(id: entry.id, card: entry.card)
        } else {
            detailTarget = WalletDetailTarget(entry: entry)
        }
        #else
        detailTarget = WalletDetailTarget(entry: entry)
        #endif
    }

    /// Jump to the surface that owns a borrowed card. Uses the same
    /// `router.focus` deep-link the Activity timeline uses, so the trip opens on
    /// its detail rather than the trip list.
    ///
    /// Reached only from the card's context menu and the detail sheet since #483.
    /// It is the one thing the Wallet does that changes section, so it needs a
    /// deliberate action behind it rather than a tap on the card.
    private func openSource(of entry: WalletEntry) {
        switch entry.source {
        case .wallet:
            break
        case .trip(_, let tripID, _), .tripDocument(_, _, let tripID, _):
            router.focus = ActivityFocus(section: .itineraries, id: tripID)
            router.go(to: .itineraries)
        case .task(_, let todoID, _):
            router.focus = ActivityFocus(section: .tasks, id: todoID)
            router.go(to: .tasks)
        }
    }

    /// The `LocalTaskTicket.clientUUID` behind an entry, when that card can be read
    /// again (#484).
    ///
    /// Only the extracted cards qualify. A `.pkpass` was never guessed at, and a
    /// standalone wallet card or a trip's inline ticket is edited directly, so
    /// neither has an extraction to re-run.
    private func rereadableTicketID(of entry: WalletEntry) -> UUID? {
        let ticketID: UUID
        switch entry.source {
        case .task(let id, _, _):               ticketID = id
        case .tripDocument(let id, _, _, _):    ticketID = id
        case .wallet, .trip:                    return nil
        }
        let path = entry.card.attachmentPath
        guard !path.trimmingCharacters(in: .whitespaces).isEmpty,
              !TicketStorage.isPass(path) else { return nil }
        return ticketID
    }

    /// Read a stored ticket again against the current extractor.
    ///
    /// The card's face and back are only ever as good as the prompt that was running
    /// the day the file was uploaded. When that prompt gets better — English labels,
    /// or no longer keeping the issuer's fiscal codes — this is how a card already in
    /// the wallet catches up, without re-uploading a file that dedupe would refuse.
    private func reread(ticketID: UUID) {
        Task {
            withAnimation(.easeInOut(duration: 0.15)) { isProcessingTicket = true }
            defer { withAnimation(.easeInOut(duration: 0.15)) { isProcessingTicket = false } }
            do {
                try await TaskTicketExtraction().reread(ticketUUID: ticketID, context: modelContext)
                Haptics.light()
            } catch {
                ticketError = (error as? LocalizedError)?.errorDescription
                    ?? "We couldn't read that ticket again. Please try again."
            }
        }
    }

    /// The `LocalWalletCard.clientUUID` behind an entry, or `nil` for a borrowed
    /// card that has no wallet row of its own.
    private func walletCardID(of entry: WalletEntry) -> UUID? {
        switch entry.source {
        case .wallet(let cardID):            return cardID
        case .trip, .task, .tripDocument:    return nil
        }
    }

    // MARK: - Upload

    private func handleTicketData(_ data: Data?, isPDF: Bool) {
        guard let data else { return }
        Task { await processTicket(data: data, isPDF: isPDF) }
    }

    /// Run the upload through the shared ticket pipeline and open the card it
    /// created. A degraded extraction still produced a card (the file is never
    /// lost), so it opens the editor to be filled in rather than showing an
    /// error.
    private func processTicket(data: Data, isPDF: Bool) async {
        withAnimation(.easeInOut(duration: 0.15)) { isProcessingTicket = true }
        defer { withAnimation(.easeInOut(duration: 0.15)) { isProcessingTicket = false } }

        do {
            let result = try await TicketExtraction().runForWallet(
                data: data,
                isPDF: isPDF,
                context: modelContext
            )
            Haptics.light()
            if result.degraded {
                editorTarget = .existing(result.itemUUID)
            } else if fetchCard(result.itemUUID) != nil {
                // Straight to the card that was just added, so the upload ends on
                // something the user can see, check and scan.
                //
                // Fetched from the context rather than read off `cards`: the
                // `@Query` has not necessarily republished in the same run-loop
                // turn as the insert, so reading it here can miss the brand new
                // row and silently skip this step.
                editorTarget = .existing(result.itemUUID)
            }
        } catch {
            ticketError = (error as? LocalizedError)?.errorDescription
                ?? "We couldn't save that ticket. Please try again."
        }
    }

    /// Read one card straight from the store, bypassing the `@Query` snapshot.
    private func fetchCard(_ id: UUID) -> LocalWalletCard? {
        let descriptor = FetchDescriptor<LocalWalletCard>(
            predicate: #Predicate { $0.clientUUID == id }
        )
        return try? modelContext.fetch(descriptor).first
    }

    /// Delete a standalone card and its stored file. The file goes first: a
    /// failed row delete would otherwise leave an orphan the user can never
    /// reach, whereas a deleted file with a surviving row degrades to a card
    /// that reports no ticket.
    /// Delete whatever this card actually is (#503).
    ///
    /// `WalletEntry.Source.deletion` decides what that means; this only carries it
    /// out. A card the Wallet owns and a document attached elsewhere both have a row
    /// to remove; a stop's inline ticket has fields to clear and a stop to leave
    /// standing.
    private func delete(_ source: WalletEntry.Source) {
        switch source.deletion {
        case .walletCard(let cardID):
            delete(cardID: cardID)
        case .document(let ticketID):
            deleteDocument(ticketID: ticketID)
        case .stopTicket(let itemID):
            clearStopTicket(itemID: itemID)
        }
    }

    private func delete(cardID: UUID) {
        guard let card = fetchCard(cardID) else { return }
        if !card.attachmentPath.isEmpty {
            try? TicketStorage.shared.delete(relativePath: card.attachmentPath)
        }
        modelContext.delete(card)
        try? modelContext.save()
        Haptics.destructive()
    }

    /// Detach a document attached to a task or a trip stop.
    ///
    /// Through `TaskTicketService` rather than by touching the row here, because the
    /// service tombstones instead of hard-deleting (so the removal reaches the other
    /// device), removes the file, and announces to the owning surface so the task or
    /// the stop stops showing an attachment that is gone.
    private func deleteDocument(ticketID: UUID) {
        let descriptor = FetchDescriptor<LocalTaskTicket>(
            predicate: #Predicate { $0.clientUUID == ticketID && $0.deletedAt == nil }
        )
        guard let row = try? modelContext.fetch(descriptor).first else { return }
        do {
            try TaskTicketService().delete(row.toDTO())
            Haptics.destructive()
        } catch {
            ticketError = "We couldn't remove that card. Please try again."
        }
    }

    /// Clear the pass off a trip stop, keeping the stop.
    ///
    /// The field clearing lives on the model (`clearTicketFields`) so this and the
    /// trip editor's own Remove ticket action cannot drift apart.
    private func clearStopTicket(itemID: UUID) {
        let descriptor = FetchDescriptor<LocalItineraryItem>(
            predicate: #Predicate { $0.clientUUID == itemID }
        )
        guard let item = try? modelContext.fetch(descriptor).first else { return }
        let path = item.attachmentPath
        item.clearTicketFields()
        try? modelContext.save()
        if !path.trimmingCharacters(in: .whitespaces).isEmpty {
            try? TicketStorage.shared.delete(relativePath: path)
        }
        Haptics.destructive()
    }
}

// MARK: - Presentation targets

/// `.sheet(item:)` payload for the card detail surface.
struct WalletDetailTarget: Identifiable {
    let entry: WalletEntry
    var id: String { entry.id }
}

#if os(iOS)
/// `.fullScreenCover(item:)` payload for present-to-scan. Carries the projected
/// card rather than a model id: the scan surface is display-only, and passing the
/// value means it cannot be handed a row that has since been deleted.
struct WalletScanTarget: Identifiable {
    let id: String
    let card: TicketCardData
}
#endif
