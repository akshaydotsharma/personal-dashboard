import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

/// Vertical timeline for a single `LocalTrip` (issue #108).
///
/// Items render inside per-day clusters in ascending date order. Within a
/// day, untimed items render first (preserving their `sortOrder`), then
/// timed items sorted ascending by `startTime`. Tapping an item opens
/// `ItineraryItemEditorSheet` for edit. A single global "+" FAB at the
/// bottom-trailing creates a new item, defaulting to today (if today is
/// inside the trip range) or `trip.startDate` otherwise.
///
/// Visual spec lives in issue #108. Layout constants are pinned in
/// `TimelineLayout` below — do not improvise away from these numbers.
struct TripDetailView: View {
    @Environment(\.modelContext) private var modelContext

    let trip: LocalTrip

    @Query private var items: [LocalItineraryItem]

    /// All people, so the trip's participant UUIDs resolve to names + colours
    /// for the expense split context (#258).
    @Query private var allPeople: [LocalPerson]

    /// Every live document row (#432), keyed on its owner in `documentCounts`.
    ///
    /// Not narrowed to this trip: a document row carries the id of the stop it
    /// hangs off and nothing else, and there is no join from here that would reach
    /// that stop's trip. Lookups are by stop id, so a map covering every trip still
    /// answers exactly for this one.
    @Query(filter: #Predicate<LocalTaskTicket> { $0.deletedAt == nil })
    private var allDocuments: [LocalTaskTicket]

    /// Which tab of the trip detail is showing. Defaults to the itinerary so
    /// existing behaviour is unchanged on open (#258).
    @State private var tab: TripDetailTab = .itinerary

    /// Drives the expense editor sheet on the Expenses tab. `.new` for the FAB,
    /// `.existing(uuid)` for a tapped row.
    @State private var expenseEditorTarget: ExpenseEditorTarget?

    /// Drives the item editor. `.new(day:)` carries the pre-filled day;
    /// `.existing(_)` carries the item UUID for edit.
    @State private var editingItem: ItineraryItemEditorTarget?

    // MARK: Ticket upload / scan state (#222)
    @State private var showingTicketCamera: Bool = false
    /// Blocks the FAB and shows a lightweight "Reading ticket…" overlay while
    /// the decode + extraction pipeline runs.
    @State private var isProcessingTicket: Bool = false
    /// Present the full-screen scan surface for a ticket item.
    @State private var scanTarget: TicketScanTarget?
    /// Present the stay booking detail sheet (the card + its actions) for a
    /// booked stay.
    /// Present a stop's documents: its boarding passes, vouchers and receipts (#432).
    @State private var documentsTarget: StopDocumentsTarget?
    /// Hard-failure banner (only when the upload couldn't be saved at all — the
    /// happy and degraded paths always produce a card instead).
    @State private var ticketError: String?

    // MARK: Expense upload / import state (#258)
    /// Camera cover for the Expenses tab, distinct from the ticket camera so
    /// the two capture flows keep separate handlers.
    @State private var showingExpenseCamera: Bool = false
    /// Blocks the expense FAB and shows a lightweight overlay while a receipt /
    /// statement upload extracts + imports in the background.
    @State private var isProcessingExpenseUpload: Bool = false
    /// Summary shown after a statement / multi-expense photo import completes.
    @State private var statementImportSummary: String?
    /// Hard-failure alert when an upload couldn't be processed at all.
    @State private var expenseCaptureError: String?

    // MARK: Shared pickers (#261)
    /// SwiftUI honours only one `.fileImporter` (and one `.photosPicker`) per
    /// view — stacking a second silently breaks presentation — so the ticket
    /// and expense flows share one picker of each kind and dispatch on a
    /// purpose set by the menu button that opened it.
    @State private var showingPDFPicker: Bool = false
    @State private var pdfPickPurpose: PDFPickPurpose = .ticket
    @State private var showingPhotoLibrary: Bool = false
    @State private var photoPickPurpose: PhotoPickPurpose = .ticket

    private enum PDFPickPurpose {
        case ticket
        case expenseReceipt
        case statement
    }

    private enum PhotoPickPurpose {
        case ticket
        case expense
    }

    init(trip: LocalTrip) {
        self.trip = trip
        let tripID = trip.clientUUID
        _items = Query(
            filter: #Predicate<LocalItineraryItem> { $0.tripUUID == tripID },
            sort: [
                SortDescriptor(\.dayDate, order: .forward),
                SortDescriptor(\.sortOrder, order: .forward),
                SortDescriptor(\.createdAt, order: .forward)
            ]
        )
        _allPeople = Query(sort: [SortDescriptor(\LocalPerson.name, order: .forward)])
    }

    /// How many documents each stop is carrying (#432), so the timeline can say so
    /// without loading a byte of any of them.
    ///
    /// Counted off a live `@Query` rather than a service call, because the rows are
    /// written by a surface (the documents sheet) that is not this view: a cached
    /// count would go stale exactly when a document is added, which is the one
    /// moment the number is being looked at.
    private var documentCounts: [UUID: Int] {
        var out: [UUID: Int] = [:]
        for row in allDocuments {
            guard let itemUUID = row.itineraryItemUUID else { continue }
            out[itemUUID, default: 0] += 1
        }
        // The stop's OWN file counts too (#466). It used to be reachable only
        // through the boarding-pass card on the timeline, so with that card gone
        // the tray is the way in and has to know the file is there.
        //
        // Keyed on a non-empty `attachmentPath`, deliberately NOT on `hasTicket`,
        // which is also true for a bare barcode payload with no file behind it.
        // That distinction is issue #298 expressed as data instead of as a
        // platform `#if`: a barcode-only stop has nothing to list, so it adds
        // nothing to the count and grows no tray.
        for item in items where !item.attachmentPath.trimmingCharacters(in: .whitespaces).isEmpty {
            out[item.clientUUID, default: 0] += 1
        }
        return out
    }

    /// The stop's own scanned ticket, as an entry for the shared attachment list
    /// (#466). Empty when there is no file, which is also what keeps a
    /// barcode-only stop out of the list (#298).
    private func ownerAttachments(for item: LocalItineraryItem) -> [OwnerAttachment] {
        let path = item.attachmentPath.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return [] }
        return [
            OwnerAttachment(
                attachmentPath: path,
                title: item.title,
                subtitle: [
                    TaskAttachmentRow.kindWord(for: path),
                    item.hasBarcode ? "Scannable ticket" : "Ticket"
                ].joined(separator: " · ")
            )
        ]
    }

    /// Trip context handed to `AddExpenseSheet` so it stamps `tripUUID` and
    /// shows the settle-up split UI. Participants preserve their stored order.
    private var tripExpenseContext: TripExpenseContext {
        let participants = trip.participantPersonUUIDs.compactMap { id in
            allPeople.first { $0.clientUUID == id }
        }
        return TripExpenseContext(tripUUID: trip.clientUUID, participants: participants)
    }

    /// Imports belonging to THIS trip, owned by `ImportJobCenter` (#498). A
    /// trip import is scoped to the trip rather than to Finance because its
    /// rows are `hiddenFromFinance` by default (#277), so a Finance banner
    /// would point at rows Finance is not counting.
    private var tripJobs: [ImportJob] { ImportJobCenter.shared.jobs(in: .trip(trip.clientUUID)) }

    /// Show a finished import's outcome and clear the row (#498). Removing on
    /// tap rather than on dismiss is deliberate: seen once, then gone.
    private func openFinishedJob(_ job: ImportJob) {
        switch job.outcome {
        case .summary(let text):
            statementImportSummary = text
        case .failure(let text):
            expenseCaptureError = text
        case .none:
            return
        }
        withAnimation(.easeInOut(duration: 0.15)) {
            ImportJobCenter.shared.acknowledge(job.id)
        }
    }

    var body: some View {
        ZStack {
            Tokens.paper.ignoresSafeArea()

            VStack(spacing: 0) {
                tripTabBar

                // Trip statement imports (#498). Shown on both tabs, because
                // the run outlives whichever one the user is looking at, and
                // rendered as a banner rather than the blocking overlay this
                // path used to raise: a statement is read in sequential 3-page
                // chunks, so a long one froze this screen for minutes.
                if !tripJobs.isEmpty {
                    VStack(spacing: Space.xs) {
                        ForEach(tripJobs) { job in
                            FinanceProcessingRow(
                                job: job,
                                onOpen: { openFinishedJob(job) },
                                onCancel: { ImportJobCenter.shared.cancel(job.id) }
                            )
                        }
                    }
                    .padding(.horizontal, Space.lg)
                    .padding(.top, Space.sm)
                }

                switch tab {
                case .itinerary:
                    if grouped.isEmpty {
                        emptyState
                    } else {
                        timelineScroll
                    }
                case .expenses:
                    TripExpensesView(trip: trip) { uuid in
                        expenseEditorTarget = .existing(uuid)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            // FAB sits above the bottom tab bar AND the home indicator. The
            // 96pt bumper at the end of the scroll content guarantees the
            // last card is not hidden by this overlay. Its action is
            // contextual: add a stop on the itinerary tab, add an expense on
            // the expenses tab.
            fabOverlay

            if isProcessingTicket {
                ticketProcessingOverlay
            }

            if isProcessingExpenseUpload {
                expenseProcessingOverlay
            }
        }
        .sheet(item: $expenseEditorTarget) { target in
            AddExpenseSheet(target: target, tripContext: tripExpenseContext)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $editingItem) { target in
            ItineraryItemEditorSheet(trip: trip, target: target)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        // Ticket upload pickers (#222). Camera is a full-screen cover (UIKit's
        // camera UI is itself full-screen); photo/PDF are system pickers.
        // Camera capture is iOS-only: `.fullScreenCover` + UIImagePickerController
        // don't exist on macOS, and the menu item that flips `showingTicketCamera`
        // is likewise gated (issue #281). Photo/PDF import stay cross-platform.
        #if os(iOS)
        .fullScreenCover(isPresented: $showingTicketCamera) {
            CameraPicker { data in
                showingTicketCamera = false
                handleTicketData(data, isPDF: false)
            }
            .ignoresSafeArea()
        }
        #endif
        .photoLibraryPicker(isPresented: $showingPhotoLibrary) { data in
            switch photoPickPurpose {
            case .ticket:  handleTicketData(data, isPDF: false)
            case .expense: handleExpenseCaptureData(data, source: .photoLibrary)
            }
        }
        .pdfPicker(isPresented: $showingPDFPicker) { data, fileName in
            switch pdfPickPurpose {
            case .ticket:         handleTicketData(data, isPDF: true)
            case .expenseReceipt: handleExpenseCaptureData(data, source: .pdf)
            case .statement:      handleStatementData(data, fileName: fileName)
            }
        }
        // Surface for a ticket card tap (or right after a successful upload).
        //
        // iOS gets the present-to-scan surface: a hardware idiom that raises
        // screen brightness and holds the idle timer so a barcode can be
        // scanned at a gate. `TicketScanView` is deliberately absent from the
        // macOS target for exactly that reason.
        //
        // The comment previously here claimed that on macOS "`scanTarget` is
        // never set for scanning and the cover is absent". The second half was
        // true and the first was not: the tap site sets `scanTarget`
        // unconditionally, so on macOS a ticketed flight or event became the
        // target with no presenter to receive it, and clicking one did nothing
        // at all, silently (issue #298).
        //
        // macOS now serves the same intent, "let me look at my ticket", the
        // desktop way: the stored original file in the cross-platform viewer.
        // A barcode-only ticket has no file to show, so the tap site routes
        // those to the editor and they never reach here.
        #if os(iOS)
        .fullScreenCover(item: $scanTarget) { target in
            if let item = items.first(where: { $0.clientUUID == target.id }) {
                TicketScanView(item: item)
            }
        }
        #else
        .sheet(item: $scanTarget) { target in
            if let item = items.first(where: { $0.clientUUID == target.id }) {
                TicketOriginalViewer(attachmentPath: item.attachmentPath)
            }
        }
        #endif
        // Detail surface for a booked stay: the tinted stay card plus its
        // actions (scan / view original / edit). iOS presents it full-screen to
        // match TicketScanView; macOS has no `.fullScreenCover`, so it presents
        // the same content as a `.sheet` instead — the view is presentation-only
        // and its "Done" button closes either form (issue #281). Shown from
        // either the check-in or the check-out row — both resolve to the same
        // item.
        // A stop's documents (#432). A sheet on both platforms: unlike the scan
        // surface this is a place you read and edit in, not something you hold up
        // at a gate, so it has no reason to take the whole screen.
        .sheet(item: $documentsTarget) { target in
            if let item = items.first(where: { $0.clientUUID == target.id }) {
                TaskTicketsSheet(
                    owner: .tripStop(item.clientUUID),
                    context: TaskTicketContext(itineraryItem: item),
                    ownerAttachments: ownerAttachments(for: item)
                )
            }
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
        // Expense camera (#258). Photo / PDF / statement uploads go through the
        // shared pickers above (#261); receipt results flow into the review
        // sheet (which already carries this trip's context), a statement PDF
        // batch-imports every line, linked to the trip.
        #if os(iOS)
        .fullScreenCover(isPresented: $showingExpenseCamera) {
            CameraPicker { data in
                showingExpenseCamera = false
                handleExpenseCaptureData(data, source: .camera)
            }
            .ignoresSafeArea()
        }
        #endif
        .alert(
            "Import complete",
            isPresented: Binding(
                get: { statementImportSummary != nil },
                set: { if !$0 { statementImportSummary = nil } }
            ),
            presenting: statementImportSummary
        ) { _ in
            Button("OK", role: .cancel) { statementImportSummary = nil }
        } message: { summary in
            Text(summary)
        }
        .alert(
            "Couldn't process receipt",
            isPresented: Binding(
                get: { expenseCaptureError != nil },
                set: { if !$0 { expenseCaptureError = nil } }
            ),
            presenting: expenseCaptureError
        ) { _ in
            Button("OK", role: .cancel) { expenseCaptureError = nil }
        } message: { message in
            Text(message)
        }
    }

    // MARK: - Tab bar

    /// Segmented switch between the itinerary timeline and the expense ledger
    /// (#258). Native segmented picker keeps it lightweight and familiar; the
    /// itinerary is the default so opening a trip is unchanged.
    private var tripTabBar: some View {
        Picker("", selection: $tab) {
            Text("Itinerary").tag(TripDetailTab.itinerary)
            Text("Expenses").tag(TripDetailTab.expenses)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, Space.lg)
        .padding(.top, Space.md)
        .padding(.bottom, Space.sm)
    }

    // MARK: - Ticket processing overlay

    private var ticketProcessingOverlay: some View {
        ZStack {
            Color.black.opacity(0.12).ignoresSafeArea()
            VStack(spacing: Space.md) {
                ProgressView()
                    .tint(Tokens.accent(for: .itineraries))
                Text("Reading ticket…")
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.inkSoft)
            }
            .padding(Space.xl)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
            .paperBorder(Tokens.border, radius: Radius.lg)
            .shadowMd()
        }
        .transition(.opacity)
    }

    /// Expense-upload processing overlay (#258). Same treatment as the ticket
    /// overlay but finance-tinted and labelled for receipt / statement reads.
    private var expenseProcessingOverlay: some View {
        ZStack {
            Color.black.opacity(0.12).ignoresSafeArea()
            VStack(spacing: Space.md) {
                ProgressView()
                    .tint(Tokens.accentFinance)
                Text("Reading receipt…")
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.inkSoft)
            }
            .padding(Space.xl)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
            .paperBorder(Tokens.border, radius: Radius.lg)
            .shadowMd()
        }
        .transition(.opacity)
    }

    // MARK: - Timeline

    private var timelineScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(grouped.enumerated()), id: \.element.day) { idx, cluster in
                    TripDayCluster(
                        trip: trip,
                        day: cluster.day,
                        entries: cluster.entries,
                        topPadding: idx == 0 ? Space.xl : Space.xl,
                        documentCounts: documentCounts,
                        onTap: { item in
                            // A booked stay opens its card in a detail sheet (the
                            // hub for scan / view-original / edit). Everything
                            // else opens the editor.
                            //
                            // A ticketed stop used to tap straight through to the
                            // scan surface, which is why it needed a per-platform
                            // special case for a barcode-only row (#298). Since
                            // #466 presenting a pass belongs to the Wallet and the
                            // stop's file is reached through its attachment tray,
                            // so the split is gone and every non-stay row behaves
                            // the same way on both platforms.
                            // Every row, including a booked stay (#468). The stay
                            // used to open its own read-only sheet with an "Edit
                            // details" tile inside, which put a surface in front
                            // of the editor instead of on the way to it.
                            editingItem = .existing(item.clientUUID)
                        },
                        onDocuments: { item in
                            Haptics.light()
                            documentsTarget = StopDocumentsTarget(id: item.clientUUID)
                        },
                        onDelete: { item in
                            Haptics.destructive()
                            delete(item)
                        }
                    )
                }
                Color.clear.frame(height: TimelineLayout.bottomBumper)
            }
            .padding(.horizontal, Space.lg)
            // ONE continuous rail behind the entire timeline content. Each
            // day dot and every item marker publishes its centre via
            // `RailAnchorKey`; the rail spans from the first published anchor
            // (the top day dot) down to the last (the bottom marker), so the
            // line never breaks across single-entry days or day boundaries.
            // Drawn as a background so all dots/markers paint over it.
            .backgroundPreferenceValue(RailAnchorKey.self) { anchors in
                GeometryReader { proxy in
                    if let span = railSpan(from: anchors, in: proxy) {
                        Rectangle()
                            .fill(Tokens.border)
                            .frame(width: TimelineLayout.railWidth, height: span.height)
                            // `railLeading` is measured from the cluster's
                            // leading edge, which sits `Space.lg` inside the
                            // padded content's leading edge. Centre the 1pt
                            // rect on that x.
                            .position(
                                x: Space.lg + TimelineLayout.railLeading,
                                y: span.midY
                            )
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        // Positions every day eyebrow relative to the scroll VIEWPORT, which is
        // what `frozenDayHeader` reads. Must stay paired with the
        // `frame(in: .named(TimelineLayout.scrollSpace))` in the cluster probe.
        .coordinateSpace(.named(TimelineLayout.scrollSpace))
        // The frozen day header. A `LazyVStack(pinnedViews: [.sectionHeaders])`
        // would be the obvious way to do this, but it is already known to break
        // on exactly this shape of content: sections with varying row counts
        // left reserved blank space until a gesture forced a layout pass
        // (issue #63, see the note in `ActivityView`). So the scroll content is
        // left completely alone — plain `VStack`, continuous rail intact — and
        // the header is a fixed overlay driven by the clusters' own geometry.
        .overlayPreferenceValue(DayHeaderFrameKey.self) { frames in
            frozenDayHeader(from: frames)
                // Overlays are not clipped, so without this the outgoing header
                // would slide up over the trip tab bar as it is pushed out.
                .clipped()
                // Never dead-zone the drag: a swipe that starts on the frozen
                // header still scrolls the timeline.
                .allowsHitTesting(false)
        }
    }

    /// The day header frozen at the top of the timeline, so a long day still
    /// says which day it is once its own eyebrow has scrolled away (#426).
    ///
    /// The pinned day is the LAST one whose eyebrow has reached the top inset;
    /// while nothing has reached it (the timeline is scrolled to the top) there
    /// is no frozen header at all, because the real one is already on screen.
    /// As the next day's eyebrow arrives it pushes the frozen copy up and out,
    /// and takes over at the exact offset the outgoing one left, which is what
    /// makes the handover read as one element rather than a swap.
    @ViewBuilder
    private func frozenDayHeader(from frames: [DayHeaderFrame]) -> some View {
        let inset = TimelineLayout.frozenHeaderTopInset
        // Ordered by position rather than by day: a preference's reduce order
        // is not guaranteed to be document order.
        let ordered = frames.sorted { $0.minY < $1.minY }

        if let index = ordered.lastIndex(where: { $0.minY <= inset }) {
            let current = ordered[index]
            let barHeight = inset + current.height + Space.md
            let next = index + 1 < ordered.count ? ordered[index + 1] : nil
            // Ride up with the next eyebrow once it touches the bar's bottom
            // edge. Bounded by construction: `next.minY` is always > `inset`,
            // so the shift never exceeds the bar's own height.
            let shift = next.map { min(0, $0.minY - barHeight) } ?? 0

            VStack(spacing: 0) {
                TripDayEyebrow(trip: trip, day: current.day, isRailNode: false)
                    .padding(.top, inset)
                    .padding(.bottom, Space.md)
                    // Matches the scroll content's own horizontal padding, so
                    // the frozen dot lands on the rail's x-position.
                    .padding(.horizontal, Space.lg)
                    .background(Tokens.paper)
                // Hairline under the bar: the cue that content is passing
                // beneath it rather than being cut off.
                Rectangle()
                    .fill(Tokens.divider)
                    .frame(height: 0.5)
            }
            .offset(y: shift)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    /// Resolve the published rail anchors into a single top-to-bottom span in
    /// the scroll-content coordinate space. Returns the rail's pixel height
    /// and vertical midpoint, or `nil` when there are fewer than two anchors
    /// (a single dot needs no connecting line).
    private func railSpan(
        from anchors: [Anchor<CGPoint>],
        in proxy: GeometryProxy
    ) -> (height: CGFloat, midY: CGFloat)? {
        guard anchors.count > 1 else { return nil }
        let ys = anchors.map { proxy[$0].y }
        guard let top = ys.min(), let bottom = ys.max(), bottom > top else {
            return nil
        }
        return (height: bottom - top, midY: (top + bottom) / 2)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        // True vertical centre of the available area below the trip header.
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 0) {
                Image(systemName: "airplane.departure")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(Tokens.mutedSoft)
                Spacer().frame(height: Space.md)
                Text("Nothing planned yet")
                    .font(.edTitle)
                    .foregroundStyle(Tokens.ink)
                    .multilineTextAlignment(.center)
                Spacer().frame(height: Space.xs)
                Text("Tap + to add your first stop")
                    .font(.edSubheadline)
                    .foregroundStyle(Tokens.muted)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 280)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Space.lg)
    }

    // MARK: - FAB

    private var fabOverlay: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                switch tab {
                case .itinerary: itineraryFab
                case .expenses:  expenseFab
                }
            }
        }
        // 22pt trailing, matching the Tasks / Lists / Notes / Finance FABs so the
        // add control does not shift when you open a trip (#464).
        .padding(.trailing, 22)
        .padding(.bottom, BottomTabBarMetrics.fabBottomInset)
        .allowsHitTesting(true)
    }

    /// Itinerary FAB: the existing add-stop / scan-ticket menu.
    private var itineraryFab: some View {
        Menu {
            Button {
                Haptics.light()
                editingItem = .new(day: defaultDayForNewItem)
            } label: {
                Label("Add a stop", systemImage: "plus")
            }
            Divider()
            // Camera is hidden on hardware without one (simulator), where
            // UIImagePickerController would silently fall back to the
            // library and make two menu items redundant. iOS-only: neither
            // UIImagePickerController nor the camera cover exist on macOS (#281).
            #if os(iOS)
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button {
                    showingTicketCamera = true
                } label: {
                    Label("Scan a ticket", systemImage: "camera")
                }
            }
            #endif
            Button {
                photoPickPurpose = .ticket
                showingPhotoLibrary = true
            } label: {
                Label("Ticket from Photos", systemImage: "photo")
            }
            Button {
                pdfPickPurpose = .ticket
                showingPDFPicker = true
            } label: {
                Label("Ticket from PDF", systemImage: "doc.text")
            }
        } label: {
            Image(systemName: "plus")
        }
        .buttonStyle(EdIconCircleButtonStyle(kind: .primary))
        .disabled(isProcessingTicket)
        .accessibilityLabel("Add to trip")
    }

    /// Expenses FAB: a capture menu scoped to this trip (#258). Mirrors the
    /// Finance capture menu — scan / photo / PDF / statement / manual — but
    /// every path stamps this trip (and its default split) on the result.
    private var expenseFab: some View {
        Menu {
            // Camera is hidden on hardware without one (simulator), where
            // UIImagePickerController would silently fall back to the library.
            // iOS-only (no UIImagePickerController / camera cover on macOS — #281).
            #if os(iOS)
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button {
                    showingExpenseCamera = true
                } label: {
                    Label("Scan receipt", systemImage: "camera")
                }
            }
            #endif
            Button {
                photoPickPurpose = .expense
                showingPhotoLibrary = true
            } label: {
                Label("Photo from library", systemImage: "photo.on.rectangle")
            }
            Button {
                pdfPickPurpose = .expenseReceipt
                showingPDFPicker = true
            } label: {
                Label("PDF from Files", systemImage: "doc.text")
            }
            Button {
                pdfPickPurpose = .statement
                showingPDFPicker = true
            } label: {
                Label("Import statement", systemImage: "doc.text.magnifyingglass")
            }
            Divider()
            Button {
                Haptics.light()
                expenseEditorTarget = .new
            } label: {
                Label("Enter manually", systemImage: "pencil")
            }
        } label: {
            Image(systemName: "plus")
        }
        .buttonStyle(EdIconCircleButtonStyle(kind: .primary))
        .disabled(isProcessingExpenseUpload)
        .accessibilityLabel("Add trip expense")
    }

    // MARK: - Ticket upload

    /// Picker callback: `data == nil` is a user cancel. Otherwise kick off the
    /// on-device decode + extraction pipeline.
    private func handleTicketData(_ data: Data?, isPDF: Bool) {
        guard let data else { return }
        Task { await processTicket(data: data, isPDF: isPDF) }
    }

    /// Persist the upload, decode + extract, and land a wallet-style card on the
    /// timeline. On success we open the scan surface on the new card; on a
    /// degraded read (extraction failed) we open the editor so the user can
    /// complete the details — the attachment is never lost. Only a hard file
    /// save failure surfaces the error banner.
    private func processTicket(data: Data, isPDF: Bool) async {
        withAnimation(.easeInOut(duration: 0.15)) { isProcessingTicket = true }
        defer { withAnimation(.easeInOut(duration: 0.15)) { isProcessingTicket = false } }

        do {
            let result = try await TicketExtraction().run(
                data: data,
                isPDF: isPDF,
                trip: trip,
                context: modelContext
            )
            Haptics.tick()
            if result.degraded {
                // Nothing reliable to scan yet — take the user straight to the
                // editor to fill in the details.
                editingItem = .existing(result.itemUUID)
            } else {
                // A multi-segment booking landed several rows (#475); open the
                // first, which is the outbound leg. The rest are on the timeline.
                scanTarget = TicketScanTarget(id: result.itemUUID)
            }
        } catch {
            ticketError = (error as? LocalizedError)?.errorDescription
                ?? "We couldn't save that ticket. Please try again."
        }
    }

    // MARK: - Expense upload / import (#258)

    /// Picker callback for the receipt/photo/PDF flows. `data == nil` is a
    /// cancel. Otherwise save + extract in the background.
    private func handleExpenseCaptureData(_ data: Data?, source: FinanceCaptureSource) {
        guard let data else { return }
        Task { await processExpenseCapture(data: data, captureSource: source) }
    }

    /// Save the asset, extract it, and route into the trip-scoped review sheet.
    /// Mirrors `FinanceView.processCapturedAsset`, but a single extracted
    /// expense flows into the review sheet (which already carries this trip's
    /// context — tripUUID + default split + payer You) rather than auto-adding,
    /// so the user reviews the split before saving. A photo yielding 2+ lines
    /// batch-imports through the trip-aware statement pipeline.
    private func processExpenseCapture(data: Data, captureSource: FinanceCaptureSource) async {
        let storage = ReceiptStorage.shared
        let client = AnthropicClient()

        withAnimation(.easeInOut(duration: 0.15)) { isProcessingExpenseUpload = true }
        defer { withAnimation(.easeInOut(duration: 0.15)) { isProcessingExpenseUpload = false } }

        // Persist the file. Images compress once (off the main actor) and reuse
        // the JPEG for both the disk save and the Vision call, matching Finance.
        let relativePath: String
        let expenseSource: ExpenseSource
        let visionImageData: Data?
        do {
            switch captureSource {
            case .camera:
                let compressed = try await Task.detached(priority: .userInitiated) {
                    try storage.compress(imageData: data)
                }.value
                relativePath = try storage.saveCompressedJpeg(compressed)
                expenseSource = .receipt
                visionImageData = compressed
            case .photoLibrary:
                let compressed = try await Task.detached(priority: .userInitiated) {
                    try storage.compress(imageData: data)
                }.value
                relativePath = try storage.saveCompressedJpeg(compressed)
                expenseSource = .photo
                visionImageData = compressed
            case .pdf:
                relativePath = try storage.save(pdfData: data)
                expenseSource = .pdf
                visionImageData = nil
            }
        } catch {
            expenseCaptureError = error.localizedDescription
            return
        }

        do {
            switch captureSource {
            case .camera, .photoLibrary:
                let lines = try await client.extractExpenses(
                    imageData: visionImageData ?? data,
                    mediaType: "image/jpeg"
                )
                await handleExtractedTripPhotoLines(
                    lines,
                    receiptImagePath: relativePath,
                    source: expenseSource
                )
            case .pdf:
                let extracted = try await client.extractExpense(pdfData: data)
                let prefill = PrefilledExpense.fromExtraction(
                    extracted,
                    receiptImagePath: relativePath,
                    source: expenseSource
                )
                expenseEditorTarget = .prefilled(prefill)
            }
        } catch {
            // Save the receipt regardless; open the review sheet with a banner.
            let message: String = {
                if let typed = error as? ReceiptExtractionError { return typed.localizedDescription }
                if let typed = error as? StatementExtractionError { return typed.localizedDescription }
                return "We saved your receipt but couldn't read it. Fill in the details below."
            }()
            let prefill = PrefilledExpense.fromFailure(
                receiptImagePath: relativePath,
                source: expenseSource,
                message: message
            )
            expenseEditorTarget = .prefilled(prefill)
        }
    }

    /// Route the expenses extracted from ONE photo, trip-scoped (#258):
    /// 0 → review sheet with a banner; 1 → review sheet prefilled (trip context
    /// seeds the split); 2+ → batch-import through the trip-aware statement
    /// pipeline sharing the one saved receipt image.
    private func handleExtractedTripPhotoLines(
        _ lines: [ExtractedStatementLine],
        receiptImagePath: String,
        source: ExpenseSource
    ) async {
        switch lines.count {
        case 0:
            let prefill = PrefilledExpense.fromFailure(
                receiptImagePath: receiptImagePath,
                source: source,
                message: "We saved your photo but couldn't read any expenses. Fill in the details below."
            )
            expenseEditorTarget = .prefilled(prefill)
        case 1:
            let prefill = PrefilledExpense.from(
                line: lines[0],
                receiptImagePath: receiptImagePath,
                source: source
            )
            expenseEditorTarget = .prefilled(prefill)
        default:
            let result = await StatementImporter.default().insert(
                lines: lines,
                fileName: nil,
                source: source,
                receiptImagePath: receiptImagePath,
                recordsImportHistory: false,
                possiblyTruncated: false,
                trip: trip
            )
            statementImportSummary = tripImportSummary(result.summaryLine)
        }
    }

    /// Statement picker callback. `data == nil` is a cancel.
    private func handleStatementData(_ data: Data?, fileName: String?) {
        guard let data else { return }
        Task { await importTripStatement(pdfData: data, fileName: fileName) }
    }

    /// Batch-import a statement PDF, linked to this trip (#258). Every inserted
    /// row gets the trip FK and — when the trip has participants — the default
    /// equal split. Dedup is unchanged.
    private func importTripStatement(pdfData: Data, fileName: String? = nil) async {
        // No blocking overlay and no `defer` removal (#498): the banner row is
        // cleared by `openFinishedJob` once the user has read the outcome, so
        // leaving the trip mid-import and coming back shows the run as it
        // stands rather than losing it with the view.
        let bannerLabel = fileName
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            .map { "Importing \($0)…" }
        let (jobID, token) = ImportJobCenter.shared.begin(
            kind: .statement,
            scope: .trip(trip.clientUUID),
            overrideLabel: bannerLabel
        )

        do {
            let result = try await StatementImporter.default().importStatement(
                pdfData: pdfData,
                fileName: fileName,
                trip: trip,
                onProgress: { done, total in
                    ImportJobCenter.shared.reportProgress(jobID, completed: done, total: total)
                },
                cancellation: token
            )
            ImportJobCenter.shared.finish(jobID, outcome: .summary(tripImportSummary(result.summaryLine)))
        } catch {
            let message: String = {
                if let typed = error as? StatementExtractionError { return typed.localizedDescription }
                return "We couldn't read this statement. Make sure it's a text-based PDF (not a photo) and try again."
            }()
            ImportJobCenter.shared.finish(jobID, outcome: .failure(message))
        }
    }

    /// Append the trip name to a batch-import summary so it's clear the rows
    /// landed on this trip (#258).
    private func tripImportSummary(_ base: String) -> String {
        "\(base) · Added to \(trip.name)"
    }

    // MARK: - Grouping

    /// `(day, entries)` clusters in ascending date order. Stays expand into
    /// two entries (check-in on dayDate, check-out on endDate) when endDate
    /// is set and differs from dayDate. Within a day: untimed entries render
    /// first (in sortOrder), then timed entries sorted ascending by the
    /// entry's effective time (`startTime` for single/check-in,
    /// `endTime` for check-out).
    private var grouped: [(day: Date, entries: [TimelineEntry])] {
        var buckets: [Date: [TimelineEntry]] = [:]

        for item in items {
            let kind = item.kindEnum
            // Days are UTC-anchored (#506), so the bucket key is read through
            // the UTC calendar. Reading it through `Calendar.current` is what
            // made a day move when the device timezone changed.
            let inDay = WallClock.startOfStoredDay(item.dayDate)

            if kind == .stay, let endDate = item.endDate {
                let outDay = WallClock.startOfStoredDay(endDate)
                buckets[inDay, default: []].append(.stayCheckIn(item: item))
                if outDay != inDay {
                    buckets[outDay, default: []].append(.stayCheckOut(item: item))
                }
            } else {
                buckets[inDay, default: []].append(.single(item: item))
            }
        }

        return buckets.keys.sorted().map { day in
            let raw = buckets[day] ?? []
            let sorted = raw.sorted { lhs, rhs in
                switch (lhs.effectiveTime, rhs.effectiveTime) {
                case (nil, nil):
                    if lhs.item.sortOrder != rhs.item.sortOrder {
                        return lhs.item.sortOrder < rhs.item.sortOrder
                    }
                    return lhs.item.createdAt < rhs.item.createdAt
                case (nil, _):
                    return true   // untimed entries pin to the top of the day
                case (_, nil):
                    return false
                case let (l?, r?):
                    if l != r { return l < r }
                    return lhs.item.sortOrder < rhs.item.sortOrder
                }
            }
            return (day: day, entries: sorted)
        }
    }

    /// Default day to seed the FAB-launched editor. Today if it falls
    /// within the trip's range; else the trip's start date.
    private var defaultDayForNewItem: Date {
        // "Today" is whichever day the device says it is, anchored so it
        // compares against the trip's anchored range (#506).
        let today = WallClock.todayAnchor()
        let start = WallClock.startOfStoredDay(trip.startDate)
        let end = WallClock.startOfStoredDay(trip.endDate)
        if today >= start && today <= end { return today }
        return start
    }

    // MARK: - Persistence

    private func delete(_ item: LocalItineraryItem) {
        ItineraryDocumentCleanup.removeEverything(attachedTo: item)
        modelContext.delete(item)
        try? modelContext.save()
    }
}

// MARK: - Deleting a stop takes its files with it (#432)

/// Removes everything a stop owns on disk before the stop itself goes.
///
/// A `LocalItineraryItem` is hard-deleted, not tombstoned, so nothing downstream
/// ever gets a chance to notice its documents again: the rows would sit there
/// pointing at a stop that does not exist, their JPEGs and PDFs still occupying
/// the container, and the Wallet would skip them silently as orphans. That is the
/// shape a leak hides in — no error, no visible symptom, just disk that never
/// comes back.
///
/// Also clears the stop's own inline ticket file, which has leaked on every stop
/// deletion since #222 for want of these three lines.
enum ItineraryDocumentCleanup {
    /// - Parameter service: the store to clear the documents from. Defaults to the
    ///   shared one, which is the same `mainContext` the views' `@Environment`
    ///   hands out — injectable so a test can assert the cascade against its own
    ///   in-memory store rather than the app's real one.
    ///
    /// `service` is `nil`-defaulted rather than defaulted to a value because a
    /// default argument is evaluated in a nonisolated context and
    /// `TaskTicketService` is `@MainActor` — the same reason
    /// `TaskTicketService.read` takes its extractor that way.
    @MainActor
    static func removeEverything(
        attachedTo item: LocalItineraryItem,
        using service: TaskTicketService? = nil
    ) {
        let service = service ?? TaskTicketService()
        let inline = item.attachmentPath.trimmingCharacters(in: .whitespaces)
        if !inline.isEmpty {
            try? TicketStorage.shared.delete(relativePath: inline)
        }
        try? service.deleteAll(owner: .tripStop(item.clientUUID))
    }
}

// MARK: - Trip detail tabs

/// The two tabs of a trip's detail screen (#258): the itinerary timeline and
/// the expense ledger.
enum TripDetailTab: Hashable {
    case itinerary
    case expenses
}

// MARK: - Layout constants

/// Locked numbers for the trip-detail timeline. Spec lives on issue #108;
/// do not change these values without re-locking the spec there.
enum TimelineLayout {
    /// Distance from the cluster leading edge to the rail centerline. The
    /// day eyebrow's dot, every item marker, and the rail itself all share
    /// this x-position, so they form a clean vertical column.
    static let railLeading: CGFloat = 16
    /// Distance from cluster leading edge to the item card's leading edge.
    /// Equals `railLeading + markerRadius + gutter` (~11pt gutter past the
    /// marker outer edge).
    static let cardLeading: CGFloat = 32
    /// Diameter of each item's marker dot.
    static let markerDiameter: CGFloat = 10
    /// Diameter of the day eyebrow's leading dot.
    static let dayDotDiameter: CGFloat = 6
    /// Thickness of the vertical rail line.
    static let railWidth: CGFloat = 1
    /// Bottom safe-area bumper so the FAB never covers the last card.
    static let bottomBumper: CGFloat = 96
    /// Vertical offset (from row top) at which the marker's centerline
    /// aligns with the first line of the item card's title. Driven by the
    /// 12pt card vertical padding (`Space.md`) plus the title's first-line
    /// half-height for `.edBodyMedium` (≈10pt).
    static let markerCenterFromRowTop: CGFloat = 22
    /// Coordinate space the timeline scroll view registers, so each day
    /// eyebrow can report its position relative to the scroll viewport (not
    /// the screen) for the frozen header. A `frame(in: .named(_:))` against a
    /// name nobody registered silently returns GLOBAL coordinates instead of
    /// failing, so this constant and the `.coordinateSpace` modifier in
    /// `timelineScroll` must stay together.
    static let scrollSpace = "tripTimelineScroll"
    /// Gap above the day header's text once it is frozen at the top of the
    /// timeline. The in-flow eyebrow hands over to the frozen copy at exactly
    /// this offset, which is what makes the swap invisible.
    static let frozenHeaderTopInset: CGFloat = Space.sm
}

// MARK: - Rail anchor preference

/// Collects the centre point of every rail node (each day dot and each item
/// marker) so a single continuous rail can be drawn from the topmost node to
/// the bottommost node. Each node contributes one `Anchor<CGPoint>`; the
/// background reader takes the min/max Y to span the whole timeline.
private struct RailAnchorKey: PreferenceKey {
    static var defaultValue: [Anchor<CGPoint>] { [] }
    static func reduce(value: inout [Anchor<CGPoint>], nextValue: () -> [Anchor<CGPoint>]) {
        value.append(contentsOf: nextValue())
    }
}

// MARK: - Day header frame preference

/// Where one day's eyebrow currently sits inside the timeline's scroll
/// viewport. Published by every day cluster so the timeline can freeze the
/// header of whichever day is filling the screen (#426).
///
/// `minY` / `height` describe the eyebrow's TEXT ROW only, excluding the
/// cluster's own top and bottom padding, so the frozen copy can be laid out at
/// the same y the in-flow row had when it crossed the top edge.
private struct DayHeaderFrame: Equatable {
    let day: Date
    let minY: CGFloat
    let height: CGFloat
}

private struct DayHeaderFrameKey: PreferenceKey {
    static var defaultValue: [DayHeaderFrame] { [] }
    static func reduce(value: inout [DayHeaderFrame], nextValue: () -> [DayHeaderFrame]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// Publishes this view's centre as a rail node for the timeline's
    /// continuous-rail background.
    func railNode() -> some View {
        anchorPreference(key: RailAnchorKey.self, value: .center) { [$0] }
    }
}

// MARK: - Timeline entries (one row on the timeline)

/// A single "event" the timeline renders. A non-stay item produces one
/// `.single` entry on its `dayDate`. A stay with an `endDate` distinct from
/// `dayDate` produces TWO entries: `.stayCheckIn` on `dayDate` and
/// `.stayCheckOut` on `endDate`. A stay without an `endDate` (legacy) or a
/// same-day stay collapses to a single `.stayCheckIn` entry.
enum TimelineEntry: Identifiable {
    case single(item: LocalItineraryItem)
    case stayCheckIn(item: LocalItineraryItem)
    case stayCheckOut(item: LocalItineraryItem)

    var id: String {
        switch self {
        case .single(let item):       return "single-\(item.clientUUID.uuidString)"
        case .stayCheckIn(let item):  return "in-\(item.clientUUID.uuidString)"
        case .stayCheckOut(let item): return "out-\(item.clientUUID.uuidString)"
        }
    }

    var item: LocalItineraryItem {
        switch self {
        case .single(let item), .stayCheckIn(let item), .stayCheckOut(let item):
            return item
        }
    }

    /// The effective time for sort order and marker fill. `startTime` for
    /// single + check-in events; `endTime` for check-out events.
    var effectiveTime: Date? {
        switch self {
        case .single(let item):       return item.startTime
        case .stayCheckIn(let item):  return item.startTime
        case .stayCheckOut(let item): return item.endTime
        }
    }

    /// Locale-aware hour:minute formatter PINNED to UTC. Itinerary
    /// `startTime`/`endTime` are stored as UTC wall-clock (their UTC H:M
    /// equals the booking's stated local time), so rendering in UTC shows the
    /// stated time and never drifts when the device timezone changes. The
    /// "jmm" template keeps the user's 12/24-hour locale preference.
    static let itineraryTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.timeZone = TimeZone(identifier: "UTC")
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f
    }()

    /// The "Anytime / Check-in / Check-out · HH:mm" line shown inside the
    /// card below the kind chip.
    var dateTimeLine: String {
        let timeFormat: (Date) -> String = { TimelineEntry.itineraryTimeFormatter.string(from: $0) }
        switch self {
        case .single(let item):
            if let dep = item.startTime {
                // "10:35 → 15:35" when an arrival is also set; departure alone
                // otherwise. Both render through the UTC-pinned formatter.
                if let arr = item.arrivalTime {
                    return "\(timeFormat(dep)) → \(timeFormat(arr))"
                }
                return timeFormat(dep)
            }
            return "Anytime"
        case .stayCheckIn(let item):
            if let t = item.startTime { return "Check-in · \(timeFormat(t))" }
            return "Check-in"
        case .stayCheckOut(let item):
            if let t = item.endTime { return "Check-out · \(timeFormat(t))" }
            return "Check-out"
        }
    }
}

// MARK: - Editor target

/// Identifiable wrapper used as the `.sheet(item:)` payload for the item
/// editor. `.new(day:)` carries the pre-filled day from the FAB; `.existing(_)`
/// carries the UUID for edit.
enum ItineraryItemEditorTarget: Identifiable {
    case new(day: Date)
    case existing(UUID)

    var id: String {
        switch self {
        case .new(let day):       return "new-\(day.timeIntervalSince1970)"
        case .existing(let uuid): return uuid.uuidString
        }
    }
}

/// Identifiable wrapper for the `.fullScreenCover(item:)` that drives the ticket
/// scan surface. Carries the item's UUID; the view resolves the live item from
/// the trip's `@Query` results so it always reflects the latest edits.
struct TicketScanTarget: Identifiable {
    let id: UUID
}

/// Identifiable wrapper for the `.sheet(item:)` that drives a stop's documents
/// (#432). Carries the stop's UUID and resolves the live row rather than the
/// model itself: a document added in the sheet changes the stop's `updatedAt`,
/// and holding the model here would pin a stale copy.
struct StopDocumentsTarget: Identifiable {
    let id: UUID
}

// MARK: - Day cluster

/// One day's eyebrow + items. The connecting rail is NOT drawn here: it's a
/// single continuous background rail on the whole timeline (see
/// `TripDetailView.timelineScroll`), threaded through every day dot and item
/// marker via the `RailAnchorKey` preference. The day eyebrow's dot is
/// indented to share the marker x-position, so day dot + every marker form a
/// vertical column the rail runs straight down.
private struct TripDayCluster: View {
    let trip: LocalTrip
    let day: Date
    let entries: [TimelineEntry]
    let topPadding: CGFloat
    /// Documents attached per stop, keyed on the stop's `clientUUID` (#432).
    let documentCounts: [UUID: Int]
    let onTap: (LocalItineraryItem) -> Void
    /// Opens the editor. Wired to the context-menu "Edit details" action on
    /// ticket rows (whose tap goes to the scan surface instead of the editor).
    /// Opens the stop's documents: the tray under a stop that has some, and the
    /// context menu on every stop, which is where you go to add the first one.
    let onDocuments: (LocalItineraryItem) -> Void
    let onDelete: (LocalItineraryItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TripDayEyebrow(trip: trip, day: day, isRailNode: true)
                // Report the text row's position so the timeline can freeze
                // this header once it reaches the top edge (#426). Measured
                // INSIDE the paddings so the frozen copy can reproduce the
                // exact y at handover.
                .background(headerFrameProbe)
                .padding(.top, topPadding)
                .padding(.bottom, Space.md)

            itemsStack
        }
    }

    private var headerFrameProbe: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .named(TimelineLayout.scrollSpace))
            Color.clear.preference(
                key: DayHeaderFrameKey.self,
                value: [DayHeaderFrame(day: day, minY: frame.minY, height: frame.height)]
            )
        }
    }

    // MARK: Items + rail

    private var itemsStack: some View {
        // Rows only. The connecting rail is no longer drawn per-day; it's a
        // single continuous background rail on the whole timeline (see
        // `timelineScroll`), anchored to each marker via `railNode()`.
        VStack(alignment: .leading, spacing: Space.md) {
            ForEach(entries) { entry in
                TripTimelineRow(
                    entry: entry,
                    documentCount: documentCounts[entry.item.clientUUID] ?? 0,
                    onDocuments: { onDocuments(entry.item) }
                )
                    .contentShape(Rectangle())
                    .onTapGesture { onTap(entry.item) }
                    .contextMenu {
                        // On every stop, not only ones that already have documents:
                        // this is the way in for the first one, and a boarding pass
                        // turning up the day before a flight is the case the whole
                        // feature exists for (#432).
                        Button {
                            onDocuments(entry.item)
                        } label: {
                            Label("Documents", systemImage: "paperclip")
                        }
                        Button(role: .destructive) {
                            onDelete(entry.item)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
    }
}

// MARK: - Day eyebrow

/// One day's header row: the rail dot plus "Day 3: Wed, 14 May".
///
/// Rendered twice — in flow at the head of its cluster, and again as the copy
/// the timeline freezes at the top while you scroll through that day (#426).
/// The frozen copy passes `isRailNode: false`: only the in-flow dot may thread
/// the continuous rail, or a header parked at the viewport top would drag the
/// rail's span with it.
private struct TripDayEyebrow: View {
    let trip: LocalTrip
    let day: Date
    let isRailNode: Bool

    var body: some View {
        // Every value here is a UTC-anchored day (#506): the range test and the
        // "Day N" count run in the UTC calendar, and the label formats the
        // device-local day naming the same date. Formatting the anchor directly
        // prints the day before, anywhere west of UTC.
        let tripStart = WallClock.startOfStoredDay(trip.startDate)
        let tripEnd = WallClock.startOfStoredDay(trip.endDate)
        let withinTrip = day >= tripStart && day <= tripEnd
        let dayNumber = WallClock.storedDayCount(from: tripStart, to: day) + 1
        // The date is now the section header, so it drops the uppercase/tracked
        // eyebrow treatment for a readable title case (e.g. "Wed, 14 May").
        let weekdayDate = WallClock.deviceDay(from: day)
            .formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))

        return HStack(alignment: .center, spacing: Space.sm) {
            Circle()
                .fill(withinTrip ? Tokens.accent(for: .itineraries) : Tokens.muted)
                .frame(width: TimelineLayout.dayDotDiameter, height: TimelineLayout.dayDotDiameter)
                .modifier(OptionalRailNode(isEnabled: isRailNode))
            // Single-line prominent date header, one consistent size, no line
            // break. The "Day n" prefix is highlighted in the accent colour to
            // set it apart from the ink date (e.g. "Day 1: Wed, 14 May").
            Group {
                if withinTrip {
                    Text("Day \(dayNumber)")
                        .foregroundStyle(Tokens.accent(for: .itineraries))
                    + Text(": \(weekdayDate)")
                        .foregroundStyle(Tokens.ink)
                } else {
                    Text(weekdayDate)
                        .foregroundStyle(Tokens.ink)
                }
            }
            .font(.edHeading)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        // Indent so the dot's centerline sits at `railLeading`, lined up
        // with every item marker below it.
        .padding(.leading, TimelineLayout.railLeading - TimelineLayout.dayDotDiameter / 2)
    }
}

/// Applies `railNode()` only for the in-flow eyebrow, so the frozen copy of a
/// header never contributes an anchor to the continuous rail. Kept as a
/// modifier to leave the dot's declaration in the `HStack` unbranched.
private struct OptionalRailNode: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content.railNode()
        } else {
            content
        }
    }
}

// MARK: - Timeline row

/// One row on the timeline: marker column | card. Uniform structure:
/// title (1 line) → kind chip → date/time line. Tiles are the same height
/// across all kinds so the column feels like a real timeline rather than a
/// jagged list.
private struct TripTimelineRow: View {
    let entry: TimelineEntry
    /// How many documents are attached to this stop (#432). Zero hides the tray.
    var documentCount: Int = 0
    /// Opens this stop's documents.
    var onDocuments: () -> Void = {}
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            markerColumn
            VStack(alignment: .leading, spacing: Space.xs) {
                // Every stop draws the same plain card (#466). A ticketed one used
                // to render a wallet-style pass face here, which put a credential
                // on the timeline instead of on the shelf built for credentials.
                // The pass still exists, in the Wallet; what the timeline shows is
                // the stop.
                card
                // Under the card rather than inside it, so it reads the same way
                // whichever card is above it — and so a flight that already renders
                // as a boarding pass can still say it is carrying two more documents.
                if documentCount > 0 {
                    documentsTray
                }
            }
        }
    }

    /// "2 documents", tappable, under the card. Its own tap target, so the row's
    /// own tap (which goes to the scan surface or the editor) does not swallow it.
    private var documentsTray: some View {
        Button {
            onDocuments()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "paperclip")
                    .font(.system(size: 10, weight: .regular))
                Text(documentCount == 1 ? "1 DOCUMENT" : "\(documentCount) DOCUMENTS")
                    .font(.edEyebrow)
                    .textCase(.uppercase)
                    .tracking(1.4)
            }
            .foregroundStyle(Tokens.accent(for: .itineraries))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Tokens.accent(for: .itineraries).opacity(0.12), in: Capsule(style: .continuous))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            documentCount == 1
                ? "1 document attached to \(entry.item.title)"
                : "\(documentCount) documents attached to \(entry.item.title)"
        )
    }

    /// Fixed-width column whose center sits on `railLeading`. The marker
    /// itself is vertically padded so its centerline aligns with the card
    /// title's first line.
    private var markerColumn: some View {
        Group {
            if entry.effectiveTime != nil {
                Circle()
                    .fill(Tokens.accent(for: .itineraries))
                    .frame(width: TimelineLayout.markerDiameter, height: TimelineLayout.markerDiameter)
            } else {
                Circle()
                    .fill(Tokens.paper)
                    .frame(width: TimelineLayout.markerDiameter, height: TimelineLayout.markerDiameter)
                    .overlay(
                        Circle()
                            .strokeBorder(Tokens.accent(for: .itineraries), lineWidth: 1.5)
                    )
            }
        }
        // Publish this marker's centre as a rail node so the continuous
        // background rail threads through it.
        .railNode()
        .frame(width: TimelineLayout.cardLeading, alignment: .center)
        .padding(.top, TimelineLayout.markerCenterFromRowTop - TimelineLayout.markerDiameter / 2)
    }

    private var card: some View {
        let item = entry.item
        let kind = item.kindEnum
        let isTimed = entry.effectiveTime != nil

        return VStack(alignment: .leading, spacing: Space.xs) {
            // Time reads first: bold, accent-coloured, tabular-digit line at the
            // very top of the tile. An untimed "Anytime" stays the same
            // treatment but softens to muted so timed rows carry the emphasis.
            Text(entry.dateTimeLine)
                .font(.edFootnoteStrong)
                .monospacedDigit()
                .foregroundStyle(isTimed ? Tokens.accent(for: .itineraries) : Tokens.muted)
                .lineLimit(1)
                .truncationMode(.tail)

            Text(item.title)
                .font(.edBodyMedium)
                .foregroundStyle(Tokens.ink)
                .lineLimit(1)
                .truncationMode(.tail)

            HStack(spacing: Space.sm) {
                TripKindChip(kind: kind, transportMode: item.transportModeEnum)
                mapsChip(for: item)
                Spacer(minLength: 0)
            }

            if !item.address.isEmpty {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(Tokens.muted)
                    Text(item.address)
                        .font(.edCaption)
                        .foregroundStyle(Tokens.muted)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .paperBorder(Tokens.border, radius: Radius.md)
    }

    /// Maps affordance on the card: a labeled "MAP" pill sitting right after
    /// the kind chip. Renders ONLY when the item has a saved Google Maps link.
    /// The text label makes the action obvious (vs a lone pin glyph), and its
    /// own tap target stops the card's edit tap from firing.
    @ViewBuilder
    private func mapsChip(for item: LocalItineraryItem) -> some View {
        if let url = item.mapsURL {
            Button {
                openURL(url)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "map.fill")
                        .font(.system(size: 10, weight: .regular))
                    Text("MAP")
                        .font(.edEyebrow)
                        .textCase(.uppercase)
                        .tracking(1.4)
                }
                .foregroundStyle(Tokens.accent(for: .itineraries))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Tokens.accent(for: .itineraries).opacity(0.12), in: Capsule(style: .continuous))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open in Google Maps")
        }
    }
}

// MARK: - Kind chip (timeline variant)

/// Capsule chip for an item's kind. Distinct from the picker chip in the
/// editor sheet (which is selectable / accent-tinted). This one is
/// display-only: surface2 background, accent-tinted icon, soft ink label.
private struct TripKindChip: View {
    let kind: ItineraryKind
    /// Set for `.transport` items so the chip shows the per-mode icon/label
    /// (plane / tram / car …) instead of the generic transport symbol.
    var transportMode: TransportMode? = nil

    /// For a transport item with a known mode, use the mode's icon/label;
    /// otherwise fall back to the kind's own icon/label.
    private var icon: String {
        if kind == .transport, let mode = transportMode { return mode.icon }
        return kind.icon
    }
    private var label: String {
        if kind == .transport, let mode = transportMode { return mode.displayName }
        return kind.displayName
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Tokens.accent(for: .itineraries))
            Text(label.uppercased())
                .font(.edEyebrow)
                .textCase(.uppercase)
                .tracking(1.4)
                .foregroundStyle(Tokens.inkSoft)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Tokens.surface2, in: Capsule(style: .continuous))
    }
}

// MARK: - Item editor sheet

/// Same sheet as before, extended with an optional time picker. Kind /
/// title / day / notes flows are unchanged; the new "Time" section sits
/// between "Day" and "Notes" and gates the time picker behind a toggle.
///
/// Persisted shape: when the toggle is OFF, `LocalItineraryItem.startTime`
/// is `nil`. When ON, `startTime` is `dayDate` combined with the hour and
/// minute from `timeOfDay`. Storing a full `Date` (not a clock-time) means
/// the timeline can sort timed items lexicographically and the day
/// grouping stays driven by `dayDate` alone.
struct ItineraryItemEditorSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let trip: LocalTrip
    let target: ItineraryItemEditorTarget

    @State private var title: String = ""
    @State private var kind: ItineraryKind = .activity
    /// Transport-only: the mode (flight/train/car/…). Only persisted when
    /// `kind == .transport`; ignored otherwise.
    @State private var transportMode: TransportMode = .flight
    /// For non-stay kinds: the item's day (with time when `hasTime` is on).
    /// For stay: the check-in date+time.
    @State private var dayDate: Date = Calendar.current.startOfDay(for: Date())
    @State private var hasTime: Bool = false
    /// Stay only: the check-out date+time. Defaulted to `dayDate + 1 day` when
    /// the kind first switches to stay.
    @State private var endDate: Date = Calendar.current.startOfDay(for: Date())
    @State private var hasEndTime: Bool = false
    /// Activity only: the arrival / landing time. Shares the item's day for its
    /// date component (like `startTime`), so the picker surfaces just the time.
    /// Only settable when a departure (`hasTime`) is present.
    @State private var arrivalTime: Date = Calendar.current.startOfDay(for: Date())
    @State private var hasArrival: Bool = false
    @State private var notes: String = ""
    @State private var address: String = ""
    @State private var googleMapsLink: String = ""
    @State private var isResolvingAddress = false
    @State private var addressResolveTask: Task<Void, Never>?
    @State private var loaded: Bool = false
    @State private var showingDeleteConfirmation: Bool = false
    @FocusState private var titleFocused: Bool
    @Environment(\.openURL) private var openURL

    // Ticket section (#222). Loaded from the existing item; the editor never
    // mutates these on save (ticket fields round-trip untouched) — only the
    // explicit "Remove ticket" action clears them + deletes the file.
    @State private var ticketAttachmentPath: String = ""
    @State private var ticketHasBarcode: Bool = false
    @State private var showingTicketOriginal: Bool = false
    @State private var showingRemoveTicketConfirmation: Bool = false

    // MARK: Documents (#432)
    //
    // The boarding pass, voucher or receipt attached to this stop, which is a
    // separate thing from the ticket block above: that one is the stop's own
    // scanned ticket, minted by the trip FAB at the moment the stop was created,
    // and there is exactly one of it. These arrive afterwards and there can be
    // several — two boarding passes on one flight, a rental voucher and its
    // receipt.
    /// Documents read while composing a stop that does not exist yet, written once
    /// Add is pressed. Cancel discards them, files included.
    @State private var pendingDocuments: [TaskTicket] = []
    /// A document read in flight, which blurs the form and says what it is doing —
    /// the same treatment the task editor gives it (#416).
    @State private var documentsReading: TaskReadingNotice?

    private let titleMaxLength = 96
    private let notesMaxLength = 1000
    private let addressMaxLength = 200

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: Space.lg) {
                        kindField
                        if kind == .transport {
                            modeField
                        }
                        titleField
                        primaryDateField
                        if kind == .stay {
                            endDateField
                        }
                        // Arrival is meaningful for a timed activity or transport
                        // leg (a flight landing, a train arrival) once a departure
                        // time is set — no lone arrival with no start.
                        if (kind == .activity || kind == .transport) && hasTime {
                            arrivalTimeField
                        }
                        notesField
                        addressField
                        googleMapsLinkField
                        if hasTicketData {
                            ticketSection
                        }
                        documentsSection
                        if isEditing {
                            deleteButton
                                .padding(.top, Space.sm)
                        }
                    }
                    .padding(Space.lg)
                }
                .blur(radius: documentsReading == nil ? 0 : 4)

                // Blocks the form while a document is being read, for the reason
                // the task editor does: the read is seconds long and takes you
                // away to Finder or Photos in the middle of it, so coming back to
                // a form with a small spinner somewhere below the fold reads as
                // nothing having happened.
                if let documentsReading {
                    TaskDocumentReadingOverlay(isPDF: documentsReading.isPDF)
                }
            }
            .animation(.easeOut(duration: 0.2), value: documentsReading)
            // A swipe down mid-read cancels it and takes the file back out with it,
            // which is correct but is not what a stray gesture meant. Cancel stays
            // reachable in the toolbar throughout.
            .interactiveDismissDisabled(documentsReading != nil)
            .navigationTitle(isEditing ? "Edit item" : "New item")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        discardPendingDocuments()
                        dismiss()
                    }
                    .foregroundStyle(Tokens.muted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Add") {
                        save()
                        dismiss()
                    }
                    .disabled(trimmedTitle.isEmpty)
                    .foregroundStyle(trimmedTitle.isEmpty ? Tokens.muted : Tokens.ink)
                }
            }
            .alert(
                "Delete this item?",
                isPresented: $showingDeleteConfirmation
            ) {
                Button("Delete", role: .destructive) {
                    deleteItem()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This can't be undone.")
            }
            .alert(
                "Remove this ticket?",
                isPresented: $showingRemoveTicketConfirmation
            ) {
                Button("Remove", role: .destructive) { removeTicket() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The scanned barcode and the saved file will be deleted. The stop stays on your trip.")
            }
            .sheet(isPresented: $showingTicketOriginal) {
                TicketOriginalViewer(attachmentPath: ticketAttachmentPath)
            }
        }
        .onAppear { loadIfNeeded() }
        // The safety net for every way out that is not Cancel: a swipe down, or the
        // sheet being torn off by something else. Save clears the array first, so
        // this only ever fires on an abandoned compose.
        .onDisappear { discardPendingDocuments() }
        .onChange(of: kind) { _, newKind in
            // Switching to stay: make sure check-out is at least the day after
            // check-in. Switching away from stay: reset the end-time flag so
            // the persisted shape matches what's hidden in the UI.
            let cal = Calendar.current
            if newKind == .stay {
                let inDay = cal.startOfDay(for: dayDate)
                let outDay = cal.startOfDay(for: endDate)
                if outDay <= inDay {
                    endDate = cal.date(byAdding: .day, value: 1, to: inDay) ?? inDay
                }
            } else {
                hasEndTime = false
            }
        }
        .onChange(of: dayDate) { _, newValue in
            // Keep check-out >= check-in for stay items.
            guard kind == .stay else { return }
            let cal = Calendar.current
            let inDay = cal.startOfDay(for: newValue)
            let outDay = cal.startOfDay(for: endDate)
            if outDay < inDay {
                endDate = cal.date(byAdding: .day, value: 1, to: inDay) ?? inDay
            }
        }
        .onChange(of: hasTime) { _, newValue in
            // Toggling time on: if the current Date is at midnight, seed a 9 AM
            // default so the picker doesn't open showing 12:00 AM.
            guard newValue else { return }
            dayDate = seededTime(on: dayDate, defaultHour: 9)
        }
        .onChange(of: hasEndTime) { _, newValue in
            guard newValue else { return }
            // Default check-out time: 11 AM (most hotels). Same midnight
            // guard as the check-in time toggle.
            endDate = seededTime(on: endDate, defaultHour: 11)
        }
        .onChange(of: hasArrival) { _, newValue in
            // Toggling arrival on: seed the picker at the departure time so it
            // doesn't open at 12:00 AM; the user then nudges it forward.
            guard newValue else { return }
            let cal = Calendar.current
            let comps = cal.dateComponents([.hour, .minute], from: arrivalTime)
            if (comps.hour ?? 0) == 0 && (comps.minute ?? 0) == 0 {
                arrivalTime = dayDate
            }
        }
    }

    // MARK: - Fields

    private var kindField: some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            Text("Kind").eyebrow()
            HStack(spacing: Space.sm) {
                ForEach(ItineraryKind.allCases) { option in
                    KindPickerChip(kind: option, isSelected: option == kind) {
                        kind = option
                    }
                }
            }
        }
    }

    /// Transport-only mode picker (flight / train / car / …). Rendered right
    /// under Kind when `kind == .transport`. Uses a horizontal scroll because
    /// there are more modes than fit a single fixed row on a phone.
    private var modeField: some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            Text("Mode").eyebrow()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.sm) {
                    ForEach(TransportMode.allCases) { option in
                        TransportModePickerChip(mode: option, isSelected: option == transportMode) {
                            transportMode = option
                        }
                    }
                }
            }
        }
    }

    private var titleField: some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            Text("Title").eyebrow()
            TextField(placeholder(for: kind), text: $title)
                .paperFieldOnMac()
                .font(.edBody)
                .foregroundStyle(Tokens.ink)
                .padding(Space.md)
                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
                .paperBorder(Tokens.border, radius: Radius.md)
                .submitLabel(.done)
                .focused($titleFocused)
                .onChange(of: title) { _, newValue in
                    if newValue.count > titleMaxLength {
                        title = String(newValue.prefix(titleMaxLength))
                    }
                }
                .accessibilityLabel("Title")
        }
    }

    /// Primary date picker. For non-stay kinds: label "Date". For stay:
    /// label "Check-in". Picker displays date alone or date + time depending
    /// on `hasTime`, so the time renders inline with the date (no narrow
    /// truncated time-only picker).
    private var primaryDateField: some View {
        let label = kind == .stay ? "Check-in" : "Date"
        return VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            Text(label).eyebrow()
            VStack(spacing: 0) {
                HStack {
                    DatePicker(
                        "",
                        selection: $dayDate,
                        displayedComponents: hasTime ? [.date, .hourAndMinute] : .date
                    )
                    .paperDatePickerOnMac()
                    .labelsHidden()
                    .tint(Tokens.accent(for: .itineraries))
                    Spacer(minLength: 0)
                }
                .padding(Space.md)

                Divider().background(Tokens.divider)

                HStack {
                    Text("Include time").font(.edBody).foregroundStyle(Tokens.inkSoft)
                    Spacer()
                    Toggle("", isOn: $hasTime)
                        .labelsHidden()
                        .tint(Tokens.accent(for: .itineraries))
                }
                .padding(Space.md)
            }
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
            .paperBorder(Tokens.border, radius: Radius.md)
        }
    }

    /// Stay-only second picker for the check-out date / time. Constrained to
    /// `>= dayDate` so the user can't pick a check-out before the check-in.
    private var endDateField: some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            Text("Check-out").eyebrow()
            VStack(spacing: 0) {
                HStack {
                    DatePicker(
                        "",
                        selection: $endDate,
                        in: Calendar.current.startOfDay(for: dayDate)...,
                        displayedComponents: hasEndTime ? [.date, .hourAndMinute] : .date
                    )
                    .paperDatePickerOnMac()
                    .labelsHidden()
                    .tint(Tokens.accent(for: .itineraries))
                    Spacer(minLength: 0)
                }
                .padding(Space.md)

                Divider().background(Tokens.divider)

                HStack {
                    Text("Include time").font(.edBody).foregroundStyle(Tokens.inkSoft)
                    Spacer()
                    Toggle("", isOn: $hasEndTime)
                        .labelsHidden()
                        .tint(Tokens.accent(for: .itineraries))
                }
                .padding(Space.md)
            }
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
            .paperBorder(Tokens.border, radius: Radius.md)
        }
    }

    /// Arrival-time field for a timed activity or transport leg. Arrival shares
    /// the item's day, so the picker shows only the time. A toggle mirrors the
    /// "Include time" pattern; the picker appears only when arrival is on, so it
    /// never surfaces a stray 12:00 AM. Gated to `.activity`/`.transport` with a
    /// departure present by the caller.
    private var arrivalTimeField: some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            Text("Arrival time").eyebrow()
            VStack(spacing: 0) {
                HStack {
                    Text("Include arrival time").font(.edBody).foregroundStyle(Tokens.inkSoft)
                    Spacer()
                    Toggle("", isOn: $hasArrival)
                        .labelsHidden()
                        .tint(Tokens.accent(for: .itineraries))
                }
                .padding(Space.md)

                if hasArrival {
                    Divider().background(Tokens.divider)

                    HStack {
                        DatePicker(
                            "",
                            selection: $arrivalTime,
                            displayedComponents: .hourAndMinute
                        )
                        .paperDatePickerOnMac()
                        .labelsHidden()
                        .tint(Tokens.accent(for: .itineraries))
                        Spacer(minLength: 0)
                    }
                    .padding(Space.md)
                }
            }
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
            .paperBorder(Tokens.border, radius: Radius.md)
        }
    }

    /// Storage boundary → UTC. Read the (hour, minute) of `timeFrom` in the
    /// DEVICE calendar (what the picker shows), then build a Date on `onDay`'s
    /// calendar day with those same components anchored in UTC. The result's
    /// UTC H:M equals the picked local H:M, so a UTC-pinned display formatter
    /// renders exactly what the user picked, regardless of timezone.
    ///
    /// The conversion itself lives in `WallClock` (#398) so the wallet editor
    /// writes identical values; this stays as the local name the editor reads.
    private func utcWallClock(onDay: Date, timeFrom: Date) -> Date {
        WallClock.utcAnchor(onDay: onDay, timeFrom: timeFrom)
    }

    /// Storage boundary → picker. Inverse of `utcWallClock`: read the
    /// (hour, minute) of a stored UTC wall-clock Date in a UTC calendar, then
    /// build a DEVICE-local Date carrying those same components on `onDay`'s
    /// local calendar day, so the DatePicker surfaces the stated time.
    private func deviceLocalPickerDate(onDay: Date, utcWallClock: Date) -> Date {
        WallClock.devicePickerDate(onDay: onDay, anchor: utcWallClock)
    }

    /// Returns `existing` with the time-of-day replaced by `defaultHour:00` if
    /// the existing time is midnight; otherwise leaves it as-is. Used when
    /// the "Include time" toggle flips on so the picker doesn't surface 12:00 AM.
    private func seededTime(on existing: Date, defaultHour: Int) -> Date {
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: existing)
        if (comps.hour ?? 0) == 0 && (comps.minute ?? 0) == 0 {
            return cal.date(bySettingHour: defaultHour, minute: 0, second: 0, of: existing) ?? existing
        }
        return existing
    }

    private var notesField: some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            HStack {
                Text("Notes").eyebrow()
                Spacer()
                Text("Optional")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
            }
            ZStack(alignment: .topLeading) {
                if notes.isEmpty {
                    Text("Address, time, anything to remember…")
                        .font(.edBody)
                        .foregroundStyle(Tokens.mutedSoft)
                        .textEditorPlaceholderInset(horizontal: Space.md, vertical: Space.sm)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $notes)
                    .paperFieldOnMac()
                    .font(.edBody)
                    .foregroundStyle(Tokens.ink)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, Space.md)
                    .padding(.vertical, Space.sm)
                    .frame(minHeight: 96, alignment: .topLeading)
                    .onChange(of: notes) { _, newValue in
                        if newValue.count > notesMaxLength {
                            notes = String(newValue.prefix(notesMaxLength))
                        }
                    }
                    .accessibilityLabel("Notes")
            }
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
            .paperBorder(Tokens.border, radius: Radius.md)
        }
    }

    /// Optional street / postal address. A booking email can prefill this; the
    /// user can type / edit / clear it here. Plain text only — the tappable map
    /// affordance lives on the Google Maps link field below.
    private var addressField: some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            HStack {
                Text("Address").eyebrow()
                if isResolvingAddress {
                    ProgressView().scaleEffect(0.7)
                    Text("Resolving from link…")
                        .font(.edCaption)
                        .foregroundStyle(Tokens.muted)
                }
                Spacer()
                Text("Optional")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
            }
            TextField("Street address or area", text: $address, axis: .vertical)
                .paperFieldOnMac()
                .font(.edBody)
                .foregroundStyle(Tokens.ink)
                .lineLimit(1...3)
                .submitLabel(.done)
                .padding(Space.md)
                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
                .paperBorder(Tokens.border, radius: Radius.md)
                .onChange(of: address) { _, newValue in
                    if newValue.count > addressMaxLength {
                        address = String(newValue.prefix(addressMaxLength))
                    }
                }
                .accessibilityLabel("Address")
        }
    }

    /// Optional Google Maps link. A booking email can prefill this; the user
    /// can paste / edit / clear it here. The trailing "Open" button appears
    /// only when a link is present and opens it directly — there is no
    /// search fallback when the field is empty.
    private var googleMapsLinkField: some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            HStack {
                Text("Google Maps link").eyebrow()
                Spacer()
                Text("Optional")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
            }
            HStack(spacing: Space.sm) {
                TextField("Paste a Google Maps link", text: $googleMapsLink)
                    .paperFieldOnMac()
                    .font(.edBody)
                    .foregroundStyle(Tokens.ink)
                    .noAutocapitalization()
                    .autocorrectionDisabled(true)
                    .urlKeyboard()
                    .submitLabel(.done)
                    .padding(Space.md)
                    .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
                    .paperBorder(Tokens.border, radius: Radius.md)
                    .accessibilityLabel("Google Maps link")
                    .onChange(of: googleMapsLink) { _, newValue in
                        scheduleAddressResolve(from: newValue)
                    }

                if let url = editorMapsURL {
                    Button {
                        openURL(url)
                    } label: {
                        Image(systemName: "map")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Tokens.accent(for: .itineraries))
                            .frame(width: 48, height: 48)
                            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
                            .paperBorder(Tokens.border, radius: Radius.md)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open saved Google Maps link")
                }
            }
        }
    }

    /// Ticket section: a thumbnail of the uploaded file, a "View original"
    /// affordance, and a destructive "Remove ticket" action. Only shown when the
    /// item carries ticket data (attachment and/or barcode).
    private var ticketSection: some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            Text("Ticket").eyebrow()
            HStack(spacing: Space.md) {
                TicketAttachmentThumbnail(relativePath: ticketAttachmentPath)
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                    .paperBorder(Tokens.border, radius: Radius.sm)

                VStack(alignment: .leading, spacing: 2) {
                    Text(ticketHasBarcode ? "Scannable ticket attached" : "Ticket file attached")
                        .font(.edFootnote)
                        .foregroundStyle(Tokens.ink)
                    if !ticketAttachmentPath.isEmpty {
                        Button("View original") { showingTicketOriginal = true }
                            .font(.edCaption)
                            .foregroundStyle(Tokens.accent(for: .itineraries))
                            .buttonStyle(.plain)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(Space.md)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
            .paperBorder(Tokens.border, radius: Radius.md)

            Button {
                showingRemoveTicketConfirmation = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "trash")
                        .font(.system(size: 13, weight: .regular))
                    Text("Remove ticket")
                        .font(.edFootnote)
                }
                .foregroundStyle(Tokens.danger)
            }
            .buttonStyle(.plain)
            .padding(.top, Space.xxs)
            .accessibilityLabel("Remove ticket")
        }
    }

    private var hasTicketData: Bool {
        isEditing && (!ticketAttachmentPath.isEmpty || ticketHasBarcode)
    }

    // MARK: - Documents (#432)

    /// Boarding passes, vouchers and receipts hanging off this stop.
    ///
    /// The same section the task editor uses, pointed at a stop — see `TicketOwner`
    /// for why there is one of these rather than two. It is shown for a stop being
    /// created as well as one being edited: the whole point is that documents turn
    /// up after the booking, but a person who already has the pass in hand when
    /// they add the flight should not be told to save and come back.
    private var documentsSection: some View {
        TaskTicketSection(
            owner: documentOwner,
            context: documentContext,
            pending: $pendingDocuments,
            onExtracted: applyExtractedDocument,
            reading: $documentsReading
        )
    }

    /// The stop these documents hang off, which has no id yet while it is being
    /// composed.
    private var documentOwner: TicketOwnerRef {
        switch target {
        case .existing(let uuid): return .tripStop(uuid)
        case .new:                return .tripStop(nil)
        }
    }

    /// What the extractor is told about the stop, read off the LIVE editor rather
    /// than the stored row: a document attached while composing should be read
    /// against the title and day just typed, not against a stop that does not exist.
    ///
    /// `dayDate` already carries the picked time when `hasTime` is on (the editor
    /// seeds it that way), so it is handed over as the moment; otherwise the day
    /// alone, which is still enough to date a pass that printed no year.
    private var documentContext: TaskTicketContext {
        TaskTicketContext(
            title: trimmedTitle,
            notes: trimmedNotes,
            dueDate: hasTime ? dayDate : Calendar.current.startOfDay(for: dayDate),
            address: address.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Fill what the stop has not got from what the document said.
    ///
    /// Deliberately narrower than the task editor's version, which also moves the
    /// due date: a stop's day is the row you are attaching to, so a document is
    /// never allowed to move it. Only empty fields are filled, so nothing typed is
    /// overwritten by a read.
    private func applyExtractedDocument(_ read: TaskTicketRead) {
        if trimmedTitle.isEmpty, let suggested = read.suggestedTitle {
            title = String(suggested.prefix(titleMaxLength))
        }
        if address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let suggested = read.suggestedAddress {
            address = String(suggested.prefix(addressMaxLength))
        }
    }

    /// Write the documents held while composing, now that the stop they belong to
    /// exists.
    private func flushPendingDocuments(to itemUUID: UUID) {
        guard !pendingDocuments.isEmpty else { return }
        _ = TaskTicketService().attachAll(pendingDocuments, owner: .tripStop(itemUUID))
        pendingDocuments = []
    }

    /// Throw away documents read for a stop that was never created, files included.
    /// The bytes land on disk during the read, before there is a stop to hang them
    /// on, so abandoning the editor has to clean up or they leak.
    private func discardPendingDocuments() {
        guard !pendingDocuments.isEmpty else { return }
        let service = TaskTicketService()
        for document in pendingDocuments {
            service.discardUnattached(document)
        }
        pendingDocuments = []
    }

    /// The current editor's maps link as a URL, coercing a bare host to https.
    /// `nil` when the field is empty (so the Open button is hidden).
    private var editorMapsURL: URL? {
        let stored = googleMapsLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stored.isEmpty else { return nil }
        if let url = URL(string: stored), url.scheme != nil { return url }
        return URL(string: "https://\(stored)")
    }

    /// Auto-fill the Address field from a pasted Google Maps link (debounced).
    /// Only fills when Address is currently empty, so it never clobbers an
    /// address the user typed by hand.
    private func scheduleAddressResolve(from link: String) {
        addressResolveTask?.cancel()
        guard address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              MapsLinkResolver.looksLikeMapsLink(link) else {
            isResolvingAddress = false
            return
        }
        addressResolveTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000) // debounce keystrokes
            if Task.isCancelled { return }
            isResolvingAddress = true
            let resolved = await MapsLinkResolver().resolveAddress(from: link)
            if Task.isCancelled { return }
            if let resolved, address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                address = resolved
            }
            isResolvingAddress = false
        }
    }

    /// Destructive "Delete item" button shown at the bottom of the editor
    /// scroll content when editing an existing item. Long-press on the tile
    /// in the timeline is still available (context menu); this gives the user
    /// a discoverable in-editor path.
    private var deleteButton: some View {
        // Canonical delete treatment lives in DeleteRowButton; this surface adds
        // the confirmation dialog (wired on the toolbar/scroll parent).
        DeleteRowButton(title: "Delete item") {
            showingDeleteConfirmation = true
        }
    }

    private func placeholder(for kind: ItineraryKind) -> String {
        switch kind {
        case .stay:       return "e.g. Hanoi Hilton"
        case .transport:  return "e.g. Flight SQ424 SIN→DXB"
        case .activity:   return "e.g. Halong Bay tour"
        case .place:      return "e.g. Hội An old town"
        case .restaurant: return "e.g. Bún chả Hương Liên"
        }
    }

    // MARK: - Persistence

    private var isEditing: Bool {
        if case .existing = target { return true }
        return false
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedNotes: String {
        notes.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true

        let cal = Calendar.current

        switch target {
        case .new(let day):
            // `day` arrives as a UTC-anchored day (#506). The pickers are
            // device-local, so seed them with the local day naming that date.
            let seedDay = WallClock.deviceDay(from: day)
            dayDate = seedDay
            // Default kind heuristic: a first-day item is most often a Stay.
            if WallClock.isSameStoredDay(day, trip.startDate) {
                kind = .stay
                endDate = cal.date(byAdding: .day, value: 1, to: seedDay) ?? seedDay
            } else {
                kind = .activity
                endDate = seedDay
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                titleFocused = true
            }
        case .existing(let uuid):
            let descriptor = FetchDescriptor<LocalItineraryItem>(
                predicate: #Predicate { $0.clientUUID == uuid }
            )
            if let existing = try? modelContext.fetch(descriptor).first {
                title = existing.title
                kind = existing.kindEnum
                transportMode = existing.transportModeEnum ?? .flight
                // Stored days are UTC anchors; the pickers are device-local.
                let storedDay = WallClock.deviceDay(from: existing.dayDate)
                dayDate = storedDay
                notes = existing.notes
                address = existing.address
                googleMapsLink = existing.googleMapsLink
                ticketAttachmentPath = existing.attachmentPath
                ticketHasBarcode = existing.hasBarcode
                if let start = existing.startTime {
                    // Stored as UTC wall-clock; seed the (device-local) picker
                    // with a Date carrying the same H:M on the item's day, so
                    // the picker surfaces the stated time.
                    hasTime = true
                    dayDate = deviceLocalPickerDate(onDay: storedDay, utcWallClock: start)
                }
                if let arrival = existing.arrivalTime {
                    // Stored UTC wall-clock; seed the device-local picker on the
                    // item's day so it surfaces the stated arrival time.
                    hasArrival = true
                    arrivalTime = deviceLocalPickerDate(onDay: storedDay, utcWallClock: arrival)
                }
                if let end = existing.endDate {
                    let storedEndDay = WallClock.deviceDay(from: end)
                    endDate = storedEndDay
                    if let endT = existing.endTime {
                        hasEndTime = true
                        endDate = deviceLocalPickerDate(onDay: storedEndDay, utcWallClock: endT)
                    }
                } else if existing.kindEnum == .stay {
                    // Stay with no persisted endDate (legacy item before the
                    // field existed): seed a sane default of +1 day.
                    endDate = cal.date(byAdding: .day, value: 1, to: storedDay) ?? storedDay
                }
            }
        }
    }

    private func save() {
        let cleanTitle = trimmedTitle
        guard !cleanTitle.isEmpty else { return }
        let cleanNotes = trimmedNotes
        let cleanAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanMapsLink = googleMapsLink.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalisedDay = WallClock.dayAnchor(from: dayDate)

        // Times are persisted as UTC wall-clock: the picker carries a
        // device-local H:M, and we store a Date whose UTC H:M equals what the
        // user picked, anchored on the item's day. This makes itinerary times
        // timezone-independent (what you pick is what shows, forever). The day
        // bucket (`normalisedDay`) is anchored the same way, at UTC midnight of
        // the day the picker showed, so the day is timezone-independent too
        // (#506).
        //
        // For non-stay or when "Include time" is off: persist only the day.
        // For non-stay with time on: persist startTime as UTC wall-clock on
        // the item's day; dayDate stays start-of-day so the grouping bucket is
        // unambiguous.
        let startTimeValue: Date? = hasTime ? utcWallClock(onDay: dayDate, timeFrom: dayDate) : nil

        // Arrival time (activity or transport), stored UTC wall-clock on the
        // item's day. Only when a departure is set and arrival is on.
        let arrivalTimeValue: Date? = ((kind == .activity || kind == .transport) && hasTime && hasArrival)
            ? utcWallClock(onDay: dayDate, timeFrom: arrivalTime)
            : nil

        // Transport-only mode; every other kind clears it.
        let transportModeValue: TransportMode? = kind == .transport ? transportMode : nil

        // Stay-only end fields. Other kinds clear both.
        let endDateValue: Date? = kind == .stay ? WallClock.dayAnchor(from: endDate) : nil
        let endTimeValue: Date? = (kind == .stay && hasEndTime) ? utcWallClock(onDay: endDate, timeFrom: endDate) : nil

        switch target {
        case .new:
            let nextSort = nextSortOrder(for: normalisedDay)
            let item = LocalItineraryItem(
                tripUUID: trip.clientUUID,
                dayDate: normalisedDay,
                kind: kind,
                transportMode: transportModeValue,
                title: cleanTitle,
                notes: cleanNotes,
                startTime: startTimeValue,
                endDate: endDateValue,
                endTime: endTimeValue,
                arrivalTime: arrivalTimeValue,
                sortOrder: nextSort,
                address: cleanAddress,
                googleMapsLink: cleanMapsLink
            )
            modelContext.insert(item)
            try? modelContext.save()
            // Only now does the stop have an id to attach to (#432).
            flushPendingDocuments(to: item.clientUUID)
        case .existing(let uuid):
            let descriptor = FetchDescriptor<LocalItineraryItem>(
                predicate: #Predicate { $0.clientUUID == uuid }
            )
            if let existing = try? modelContext.fetch(descriptor).first {
                existing.title = cleanTitle
                existing.kindEnum = kind
                existing.transportModeEnum = transportModeValue
                if WallClock.startOfStoredDay(existing.dayDate) != normalisedDay {
                    // Day moved: re-sortOrder so the item lands at the end of
                    // the new day instead of slotting into the old position.
                    existing.sortOrder = nextSortOrder(for: normalisedDay)
                }
                existing.dayDate = normalisedDay
                existing.notes = cleanNotes
                existing.address = cleanAddress
                existing.googleMapsLink = cleanMapsLink
                existing.startTime = startTimeValue
                existing.endDate = endDateValue
                existing.endTime = endTimeValue
                existing.arrivalTime = arrivalTimeValue
                existing.updatedAt = Date()
            }
        }
        try? modelContext.save()
    }

    /// Remove the ticket from an existing item: delete the stored file and clear
    /// every ticket field so the row reverts to a plain timeline item. The stop
    /// itself is kept. Updates the in-editor state so the section hides
    /// immediately without needing a re-fetch.
    private func removeTicket() {
        guard case .existing(let uuid) = target else { return }
        let descriptor = FetchDescriptor<LocalItineraryItem>(
            predicate: #Predicate { $0.clientUUID == uuid }
        )
        guard let existing = try? modelContext.fetch(descriptor).first else { return }
        if !existing.attachmentPath.isEmpty {
            try? TicketStorage.shared.delete(relativePath: existing.attachmentPath)
        }
        existing.clearTicketFields()
        try? modelContext.save()
        Haptics.destructive()
        ticketAttachmentPath = ""
        ticketHasBarcode = false
    }

    /// Fetch the existing item by UUID and remove it from the model context.
    /// Triggered by the in-editor "Delete item" button after the confirmation
    /// dialog. The sheet dismisses on completion; the timeline picks up the
    /// removal via the `@Query` observer.
    private func deleteItem() {
        guard case .existing(let uuid) = target else { return }
        let descriptor = FetchDescriptor<LocalItineraryItem>(
            predicate: #Predicate { $0.clientUUID == uuid }
        )
        if let existing = try? modelContext.fetch(descriptor).first {
            ItineraryDocumentCleanup.removeEverything(attachedTo: existing)
            modelContext.delete(existing)
            try? modelContext.save()
        }
        dismiss()
    }

    /// Append-on-create ordering: max sortOrder for the day + 1. Falls back to
    /// 0 when the day has no existing items.
    private func nextSortOrder(for day: Date) -> Int {
        let tripID = trip.clientUUID
        let descriptor = FetchDescriptor<LocalItineraryItem>(
            predicate: #Predicate { $0.tripUUID == tripID && $0.dayDate == day }
        )
        let existing = (try? modelContext.fetch(descriptor)) ?? []
        return (existing.map(\.sortOrder).max() ?? -1) + 1
    }
}

// MARK: - Kind picker chip (editor sheet)

/// Selectable chip used inside the editor sheet's Kind row. Distinct from
/// `TripKindChip` (display-only chip on the timeline).
private struct KindPickerChip: View {
    let kind: ItineraryKind
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: kind.icon)
                    .font(.system(size: 12, weight: .regular))
                    .layoutPriority(1)
                Text(kind.displayName)
                    .font(.edFootnote)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, Space.sm)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .foregroundStyle(isSelected ? Tokens.accentFg : Tokens.inkSoft)
            .background(
                isSelected ? Tokens.accent(for: .itineraries) : Tokens.surface,
                in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .stroke(isSelected ? Color.clear : Tokens.border, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(kind.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Transport mode picker chip (editor sheet)

/// Selectable chip for a transport item's mode, shown in the editor's Mode row
/// (a horizontal scroll). Sizes to its content — unlike `KindPickerChip`'s
/// equal-width layout — so a scrollable row of modes reads naturally.
private struct TransportModePickerChip: View {
    let mode: TransportMode
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: mode.icon)
                    .font(.system(size: 12, weight: .regular))
                Text(mode.displayName)
                    .font(.edFootnote)
                    .lineLimit(1)
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, 6)
            .foregroundStyle(isSelected ? Tokens.accentFg : Tokens.inkSoft)
            .background(
                isSelected ? Tokens.accent(for: .itineraries) : Tokens.surface,
                in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .stroke(isSelected ? Color.clear : Tokens.border, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
