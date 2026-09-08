import SwiftUI
import SwiftData

/// Top-level surface where the user plans trips (issue #104).
///
/// The root view groups all `LocalTrip`s into Active / Upcoming / Past and
/// sorts each group ascending by start date.
/// Tapping a trip swaps the header in place to a detail header and renders
/// `TripDetailView` below it — same inline-swap pattern `ListsView` uses, no
/// `NavigationStack`. The leading-edge back gesture pops the detail back to
/// the root via `router.leadingEdgeBackHandler`.
///
/// Both create and edit go through `TripEditorSheet` keyed by an
/// `Identifiable` `TripEditorTarget`, mirroring `PersonalVocabularyView`.
/// Deleting a trip cascades manually: every `LocalItineraryItem` whose
/// `tripUUID` matches is deleted before the trip itself.
struct TripsView: View {
    @Environment(\.modelContext) private var modelContext

    @Bindable var router: AppRouter

    @Query(sort: \LocalTrip.startDate, order: .reverse) private var trips: [LocalTrip]

    /// Drives the trip editor sheet. `.new` for create, `.existing(_)` for edit.
    @State private var editingTrip: TripEditorTarget?

    /// `nil` means root list is showing. Setting a UUID swaps to detail.
    @State private var selectedTripUUID: UUID?

    /// Drives the read-only calendar popover from the macOS toolbar button
    /// (issue #291). On iOS the popover state lives inside `TripDetailHeader`.
    @State private var showingCalendar = false

    var body: some View {
        ZStack {
            Tokens.paper.canvasIgnoresSafeArea()

            VStack(spacing: 0) {
                if let id = selectedTripUUID, let trip = trips.first(where: { $0.clientUUID == id }) {
                    // iOS: in-view detail header row. macOS: back + calendar +
                    // edit live in the native window toolbar via
                    // `.macDetailChrome` (Liquid Glass group, à la Reminders) and
                    // the window subtitle carries the date range (issue #291).
                    #if os(iOS)
                    TripDetailHeader(
                        trip: trip,
                        onBack: {
                            withAnimation(.easeOut(duration: 0.2)) { selectedTripUUID = nil }
                        },
                        onEdit: { editingTrip = .existing(id) }
                    )
                    #endif
                    TripDetailView(trip: trip)
                        .macDetailChrome(
                            title: trip.name,
                            subtitle: TripRow.formatRange(start: trip.startDate, end: trip.endDate),
                            onBack: {
                                withAnimation(.easeOut(duration: 0.2)) { selectedTripUUID = nil }
                            },
                            actions: {
                                Button { showingCalendar = true } label: {
                                    Image(systemName: "calendar")
                                }
                                .help("View calendar")
                                .popover(isPresented: $showingCalendar) {
                                    TripCalendarPopover(trip: trip)
                                }
                                Button { editingTrip = .existing(id) } label: {
                                    Image(systemName: "square.and.pencil")
                                }
                                .help("Edit trip")
                            }
                        )
                } else {
                    // iOS in-view top bar; macOS uses the native window toolbar
                    // via `.macSectionChrome` below (issue #283).
                    #if os(iOS)
                    TopBar(
                        title: "Trips",
                        onMenu: { withAnimation(.easeOut(duration: 0.2)) { router.drawerOpen = true } }
                    )
                    #endif
                    rootContent
                        .macSectionChrome("Trips")
                        // File > New Trip / Cmd-N on the trip list. Scoped to
                        // the root branch: inside a trip, Cmd-N would mean a new
                        // itinerary item, which is a different action (#295).
                        #if os(macOS)
                        .focusedSceneValue(\.newItemAction, NewItemAction(title: "New Trip") {
                            editingTrip = .new
                        })
                        #endif
                }
            }

            if selectedTripUUID == nil {
                Button {
                    editingTrip = .new
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(EdIconCircleButtonStyle(kind: .primary))
                .padding(.trailing, 22)
                .padding(.bottom, BottomTabBarMetrics.fabBottomInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .accessibilityLabel("New trip")
            }
        }
        .activeSection(.itineraries)
        // Section vs detail chrome is applied per-branch above so the macOS
        // window title tracks the open trip instead of staying on "Trips"
        // (issue #291).
        .onAppear {
            consumeFocus()
            syncBackHandler()
        }
        .onChange(of: router.focus) { _, _ in consumeFocus() }
        .onDisappear {
            if selectedTripUUID != nil {
                router.leadingEdgeBackHandler = nil
            }
        }
        .onChange(of: selectedTripUUID) { _, _ in syncBackHandler() }
        .sheet(item: $editingTrip) { target in
            TripEditorSheet(target: target)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Root content

    @ViewBuilder
    private var rootContent: some View {
        if trips.isEmpty {
            emptyState
        } else {
            tripList
        }
    }

    private var emptyState: some View {
        VStack(spacing: Space.md) {
            Spacer()
            Image(systemName: "airplane")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Tokens.muted)
            Text("Plan your next trip")
                .font(.edHeading)
                .foregroundStyle(Tokens.ink)
                .multilineTextAlignment(.center)
            Text("Add a destination and date range, then lay out the day-by-day timeline of stays, activities, places, and restaurants.")
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

    /// Trips split into the three travel states, each ordered ascending by
    /// start date so the earliest sits at the top of its group.
    ///
    /// The boundaries are day-granular (start/end dates are stored normalised to
    /// `startOfDay`), so a trip spanning today is Active for the whole of today
    /// and only drops to Past once its end date is behind us.
    private struct TripGroups {
        var active: [LocalTrip] = []
        var upcoming: [LocalTrip] = []
        var past: [LocalTrip] = []
    }

    private var tripGroups: TripGroups {
        // Trip days are UTC anchors, so "today" is anchored before comparing
        // against them (#506).
        let today = WallClock.todayAnchor()
        var groups = TripGroups()
        for trip in trips {
            if WallClock.startOfStoredDay(trip.endDate) < today {
                groups.past.append(trip)
            } else if WallClock.startOfStoredDay(trip.startDate) > today {
                groups.upcoming.append(trip)
            } else {
                groups.active.append(trip)
            }
        }
        // End date breaks ties so two trips starting the same day order by the
        // one that wraps up first.
        let ascending: (LocalTrip, LocalTrip) -> Bool = {
            ($0.startDate, $0.endDate) < ($1.startDate, $1.endDate)
        }
        groups.active.sort(by: ascending)
        groups.upcoming.sort(by: ascending)
        groups.past.sort(by: ascending)
        return groups
    }

    private var tripList: some View {
        let groups = tripGroups
        return List {
            tripSection(
                title: "Active",
                trips: groups.active,
                phase: .active,
                accent: Tokens.success,
                soft: Tokens.successSoft
            )
            tripSection(
                title: "Upcoming",
                trips: groups.upcoming,
                phase: .upcoming,
                accent: Tokens.accent(for: .itineraries),
                soft: Tokens.paper2
            )
            tripSection(
                title: "Past",
                trips: groups.past,
                phase: .past,
                accent: Tokens.muted,
                soft: Tokens.paper2
            )

            Color.clear
                .frame(height: 96)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Tokens.paper)
        .scrollDismissesKeyboard(.interactively)
    }

    /// One travel-state group. Empty groups render nothing at all rather than a
    /// bare header, so a user with only future trips sees just "Upcoming".
    @ViewBuilder
    private func tripSection(
        title: String,
        trips: [LocalTrip],
        phase: TripPhase,
        accent: Color,
        soft: Color
    ) -> some View {
        if !trips.isEmpty {
            Section {
                ForEach(trips) { trip in
                    TripRow(trip: trip, itemCount: itemCount(for: trip), phase: phase) {
                        withAnimation(.easeOut(duration: 0.2)) {
                            selectedTripUUID = trip.clientUUID
                        }
                    }
                    .swipeToDeleteTrash {
                        delete(trip)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .contentRowInsets(vertical: Space.xs)
                }
            } header: {
                tripSectionHeader(title: title, count: trips.count, accent: accent, soft: soft)
            }
        }
    }

    /// Same shape as the Tasks section headers: accent-coloured title plus a
    /// count capsule, left-aligned on the paper background.
    private func tripSectionHeader(title: String, count: Int, accent: Color, soft: Color) -> some View {
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
        .textCase(nil)
        .padding(.horizontal, Space.lg)
        .padding(.top, Space.sm)
        .padding(.bottom, Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.paper)
    }

    // MARK: - Activity deep-link consumption

    /// The Activity timeline sets `router.focus` to a `.itineraries` focus whose
    /// `id` is the trip UUID, then pushes this section. Open that trip's detail
    /// and clear the focus so it doesn't re-fire. If the trip can't be resolved
    /// (deleted since), we just clear focus and leave the root list showing.
    private func consumeFocus() {
        guard let focus = router.focus, focus.section == .itineraries else { return }
        if trips.contains(where: { $0.clientUUID == focus.id }) {
            withAnimation(.easeOut(duration: 0.2)) { selectedTripUUID = focus.id }
        }
        router.focus = nil
    }

    // MARK: - Back-swipe wiring (mirrors ListsView.syncBackHandler)

    private func syncBackHandler() {
        let binding = $selectedTripUUID
        if selectedTripUUID != nil {
            router.leadingEdgeBackHandler = {
                withAnimation(.easeOut(duration: 0.2)) {
                    binding.wrappedValue = nil
                }
            }
        } else {
            router.leadingEdgeBackHandler = nil
        }
    }

    // MARK: - Persistence

    /// Cascade delete: items first (so no orphans linger in the store), then
    /// the trip. Same pattern Lists uses for embedded items, just spelled out
    /// across two model types.
    private func delete(_ trip: LocalTrip) {
        let tripID = trip.clientUUID
        let descriptor = FetchDescriptor<LocalItineraryItem>(
            predicate: #Predicate { $0.tripUUID == tripID }
        )
        if let items = try? modelContext.fetch(descriptor) {
            for item in items { modelContext.delete(item) }
        }
        // The cover file is deliberately LEFT on disk (#428). Art is keyed on the
        // destination now, so another trip to the same place may be using this exact
        // file, and deleting it here would blank that trip's tile. It also means
        // deleting and recreating a trip reuses the art it already paid for.
        // `TripCoverService.reapOrphanedCovers()` collects what nothing references.
        modelContext.delete(trip)
        try? modelContext.save()
    }

    /// Cheap count for the row badge. Item counts will be small enough that a
    /// per-row fetch is fine for a skeleton; revisit if a trip ever holds
    /// hundreds of items.
    private func itemCount(for trip: LocalTrip) -> Int {
        let tripID = trip.clientUUID
        let descriptor = FetchDescriptor<LocalItineraryItem>(
            predicate: #Predicate { $0.tripUUID == tripID }
        )
        return (try? modelContext.fetchCount(descriptor)) ?? 0
    }
}

// MARK: - Editor target

/// Identifiable wrapper used as the `.sheet(item:)` payload for the trip
/// editor. Carries the UUID (not the live model) so the sheet stays stateless
/// across re-renders.
enum TripEditorTarget: Identifiable {
    case new
    case existing(UUID)

    var id: String {
        switch self {
        case .new:                return "new"
        case .existing(let uuid): return uuid.uuidString
        }
    }
}

// MARK: - Row

/// A trip tile: a full-bleed destination photo band across the top, and all of
/// the text below it on paper (#428).
///
/// ## Why this does NOT use `flatContentRow()`
///
/// This is the one section that stays a CARD on macOS rather than converging on
/// the flat full-bleed row of #303 (the Reminders / Mail shape), and the opt-out
/// is deliberate.
///
/// Full-bleed rows on macOS put the row's leading edge directly on the sidebar
/// seam. The project has already had to add two insets for exactly that reason —
/// `RowMetrics.accentRailInset` for the task priority bar and
/// `RowMetrics.priorityWashInset` for the priority wash — because colour landing
/// on the seam reads as a second pane. A 220pt photograph on that seam is the
/// same problem at very much higher volume: it would read as a split view, not as
/// a list row. So the card, its `Radius.card` clip and
/// `TripCoverMetrics.cardHorizontalInset` stay.
///
/// The count capsule and the chevron are gone. `TicketCardView`'s documented
/// grammar is no icons and no rules, and the photograph now does the visual work
/// they were standing in for. Losing the chevron is what makes
/// `.accessibilityAddTraits(.isButton)` mandatory below: this row navigates via
/// `.onTapGesture`, which VoiceOver does not announce as actionable on its own.
private struct TripRow: View {
    let trip: LocalTrip
    let itemCount: Int
    let phase: TripPhase
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            TripCoverBand(trip: trip, phase: phase)
            textBlock
        }
        .background(Tokens.surface)
        // The clip comes first and the border second. Reversing them lets the clip
        // eat the stroke at the four corners, which reads as a card with chipped
        // edges and is very easy to miss on a screenshot.
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .paperBorder(borderColor, radius: Radius.card)
        .padding(.horizontal, TripCoverMetrics.cardHorizontalInset)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        // One element carrying everything the tile says, in reading order. The
        // band is hidden inside `TripCoverBand`, so `children: .ignore` is not
        // discarding information — the count in particular MUST be here now that
        // the capsule is gone.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Text block

    /// `Space.lg` horizontal and `Space.md` vertical, a deliberate departure from
    /// `RowMetrics.horizontalPadding` (12pt on iOS). The band sets the tile's
    /// optical width now, and 12pt reads tight against a 328pt-wide photograph.
    private var textBlock: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(trip.name)
                .font(nameFont)
                .foregroundStyle(nameColor)
                // Not optional: at `.accessibility3`, `lineLimit(1)` truncates
                // "Vietnam" to roughly four characters.
                .lineLimit(2)
            metaLine
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, TripCoverMetrics.textHorizontalPadding)
        .padding(.vertical, TripCoverMetrics.textVerticalPadding)
    }

    /// One line: relative status, date range, item count, " · " separated.
    ///
    /// Entirely in `Tokens.muted`. Never `Tokens.mutedSoft`, which measures about
    /// 2.6:1 on `Tokens.surface` in light mode and fails AA as body text.
    private var metaLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: TripCoverMetrics.statusDotGap) {
            if phase == .active {
                Circle()
                    .fill(Tokens.success)
                    .frame(
                        width: TripCoverMetrics.statusDotSize,
                        height: TripCoverMetrics.statusDotSize
                    )
                    // A `Circle` has no baseline of its own, so one is supplied
                    // from its own height. Without this the dot centres on a
                    // two-line meta string and drifts away from "Day 3 of 8".
                    .alignmentGuide(.firstTextBaseline) { $0.height - 1 }
            }
            Text(metaText)
                .font(.edFootnote)
                .foregroundStyle(Tokens.muted)
                .lineLimit(2)
        }
    }

    private var metaText: String {
        var parts: [String] = []
        if let relativeStatus { parts.append(relativeStatus) }
        parts.append(Self.formatRange(start: trip.startDate, end: trip.endDate))
        parts.append(itemCountText)
        return parts.joined(separator: " · ")
    }

    private var itemCountText: String {
        itemCount == 1 ? "1 item" : "\(itemCount) items"
    }

    /// "Day 3 of 8" while you are on the trip, "In 12 days" before it. Nothing for
    /// a Past trip, whose date range already says everything there is to say.
    private var relativeStatus: String? {
        // Day counts run in the UTC calendar because the trip's days are
        // anchored there (#506); "today" is anchored to match.
        let today = WallClock.todayAnchor()
        let start = WallClock.startOfStoredDay(trip.startDate)
        let end = WallClock.startOfStoredDay(trip.endDate)

        switch phase {
        case .active:
            let total = WallClock.storedDayCount(from: start, to: end) + 1
            guard total > 0 else { return nil }
            let day = WallClock.storedDayCount(from: start, to: today) + 1
            return "Day \(min(max(day, 1), total)) of \(total)"
        case .upcoming:
            let days = WallClock.storedDayCount(from: today, to: start)
            guard days > 0 else { return nil }
            return days == 1 ? "In 1 day" : "In \(days) days"
        case .past:
            return nil
        }
    }

    // MARK: - Phase differentiation

    /// `.edTitle` is what `TripDetailHeader` already uses for the trip name, so
    /// the name is typographically identical in tile and detail and the trip reads
    /// as one object across the navigation. Past steps down to `.edHeading` /
    /// `inkSoft`, which is part of how a lush old photograph is stopped from
    /// out-shouting a trip you are currently on — the other part is on the band.
    private var nameFont: Font {
        phase == .past ? .edHeading : .edTitle
    }

    private var nameColor: Color {
        phase == .past ? Tokens.inkSoft : Tokens.ink
    }

    private var borderColor: Color {
        phase == .active ? Tokens.borderStrong : Tokens.border
    }

    // MARK: - Accessibility

    /// "Vietnam. 12 to 20 September 2026. Day 3 of 8. 14 items. Opens the trip."
    private var accessibilityLabel: String {
        var parts: [String] = [trip.name, spokenRange]
        if let relativeStatus { parts.append(relativeStatus) }
        parts.append(itemCountText)
        parts.append("Opens the trip")
        return parts.joined(separator: ". ") + "."
    }

    /// The date range spelled out for speech. `formatRange` is right on screen but
    /// its en dash and abbreviated months read poorly aloud.
    private var spokenRange: String {
        // Format the device-local day naming each anchored date, never the
        // anchor itself: an anchor formatted locally prints the day before,
        // anywhere west of UTC (#506).
        let cal = Calendar.current
        let start = WallClock.deviceDay(from: trip.startDate)
        let end = WallClock.deviceDay(from: trip.endDate)
        let full = Date.FormatStyle.dateTime.day().month(.wide).year()
        if cal.isDate(start, inSameDayAs: end) {
            return start.formatted(full)
        }
        let sameYear = cal.component(.year, from: start)
            == cal.component(.year, from: end)
        let startPart = sameYear
            ? start.formatted(.dateTime.day().month(.wide))
            : start.formatted(full)
        return "\(startPart) to \(end.formatted(full))"
    }

    /// "1 May – 10 May 2026" / "28 Dec 2026 – 3 Jan 2027" / single-day
    /// "5 Mar 2026". Year is suppressed on the start side when both dates
    /// share the same year.
    static func formatRange(start rawStart: Date, end rawEnd: Date) -> String {
        // Callers pass a trip's anchored days. Format the device-local day
        // naming each date so the label reads the same in every zone (#506).
        let start = WallClock.deviceDay(from: rawStart)
        let end = WallClock.deviceDay(from: rawEnd)
        let cal = Calendar.current
        let sameDay = cal.isDate(start, inSameDayAs: end)
        let sameYear = cal.component(.year, from: start) == cal.component(.year, from: end)

        let startNoYear = start.formatted(.dateTime.day().month(.abbreviated))
        let endFull = end.formatted(.dateTime.day().month(.abbreviated).year())
        let startFull = start.formatted(.dateTime.day().month(.abbreviated).year())

        if sameDay { return startFull }
        if sameYear { return "\(startNoYear) – \(endFull)" }
        return "\(startFull) – \(endFull)"
    }
}

// MARK: - Detail header

/// Header shown above `TripDetailView` when a trip is selected. Mirrors
/// `ListDetailHeader` in `ListsView.swift`: back chevron + label, centred
/// title, trailing affordance (Edit instead of Delete because trip edits
/// span name + dates + notes and warrant the full sheet).
private struct TripDetailHeader: View {
    let trip: LocalTrip
    let onBack: () -> Void
    let onEdit: () -> Void

    /// Drives the read-only calendar popover (#230). Held locally so the
    /// change stays contained to the header and the `.popover` anchors to the
    /// calendar button.
    @State private var showingCalendar = false

    var body: some View {
        HStack(spacing: Space.md) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("Trips")
                }
                .font(.edBody)
                .foregroundStyle(Tokens.muted)
                .frame(height: 44)
                .contentShape(Rectangle())
            }
            // macOS: strip the hard default-bordered button chrome (issue #289).
            .macPlainButtonStyle()
            Spacer()
            VStack(spacing: 2) {
                Text(trip.name)
                    .font(.edTitle)
                    .foregroundStyle(Tokens.ink)
                    .lineLimit(1)
                Text(TripRow.formatRange(start: trip.startDate, end: trip.endDate))
                    .font(.edCaption)
                    .foregroundStyle(Tokens.muted)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                showingCalendar = true
            } label: {
                Image(systemName: "calendar")
                    .frame(width: 44, height: 44)
                    .foregroundStyle(Tokens.muted)
            }
            .accessibilityLabel("View calendar")
            // macOS: quiet Reminders-style rounded chrome instead of the hard
            // square default button background (issue #289). No-op on iOS.
            .macPlainButtonStyle()
            .macHeaderIconChrome()
            .popover(isPresented: $showingCalendar) {
                TripCalendarPopover(trip: trip)
            }
            Button(action: onEdit) {
                Image(systemName: "square.and.pencil")
                    .frame(width: 44, height: 44)
                    .foregroundStyle(Tokens.muted)
            }
            .accessibilityLabel("Edit trip")
            .macPlainButtonStyle()
            .macHeaderIconChrome()
        }
        .padding(.horizontal, Space.md)
        .frame(height: 56)
        .background(Tokens.paper.overlay(alignment: .bottom) {
            Rectangle().fill(Tokens.divider).frame(height: 0.5)
        })
    }
}

// MARK: - Trip editor sheet

private struct TripEditorSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let target: TripEditorTarget

    @State private var name: String = ""
    @State private var startDate: Date = Calendar.current.startOfDay(for: Date())
    @State private var endDate: Date = Calendar.current.startOfDay(for: Date())
    @State private var notes: String = ""
    @State private var loaded: Bool = false
    @FocusState private var nameFocused: Bool

    /// Trip participants for expense splitting (#258). Held as an ordered list
    /// of `LocalPerson.clientUUID`s; encoded to `participantsData` on save.
    @State private var participantUUIDs: [UUID] = []
    /// Selection binding for the reused `PersonPickerSheet` (find-or-create).
    @State private var pickedParticipant: ExpenseTag?
    @State private var showingParticipantPicker: Bool = false

    /// All people, so the stored participant UUIDs resolve to names + colours.
    @Query(sort: [SortDescriptor(\LocalPerson.name, order: .forward)])
    private var allPeople: [LocalPerson]

    private let nameMaxLength = 64
    private let notesMaxLength = 1000

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: Space.lg) {
                        nameField
                        dateFields
                        participantsField
                        notesField
                    }
                    .padding(Space.lg)
                }
            }
            .navigationTitle(isEditing ? "Edit trip" : "New trip")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Tokens.muted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Add") {
                        save()
                        dismiss()
                    }
                    .disabled(trimmedName.isEmpty)
                    .foregroundStyle(trimmedName.isEmpty ? Tokens.muted : Tokens.ink)
                }
            }
        }
        .onAppear { loadIfNeeded() }
        .onChange(of: startDate) { _, newStart in
            // Keep end >= start. Adjust silently rather than reject.
            if endDate < newStart { endDate = newStart }
        }
    }

    // MARK: - Fields

    private var nameField: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("Destination").eyebrow()
            TextField("e.g. Vietnam", text: $name)
                .paperFieldOnMac()
                .font(.edBody)
                .foregroundStyle(Tokens.ink)
                .padding(Space.md)
                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
                .paperBorder(Tokens.border, radius: Radius.md)
                .submitLabel(.done)
                .focused($nameFocused)
                .onChange(of: name) { _, newValue in
                    if newValue.count > nameMaxLength {
                        name = String(newValue.prefix(nameMaxLength))
                    }
                }
                .accessibilityLabel("Destination")
        }
    }

    private var dateFields: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("Dates").eyebrow()
            VStack(spacing: Space.sm) {
                HStack {
                    Text("Start").font(.edBody).foregroundStyle(Tokens.inkSoft)
                    Spacer()
                    DatePicker("", selection: $startDate, displayedComponents: .date)
                        .paperDatePickerOnMac()
                        .labelsHidden()
                        .tint(Tokens.accent(for: .itineraries))
                }
                Rectangle().fill(Tokens.divider).frame(height: 0.5)
                HStack {
                    Text("End").font(.edBody).foregroundStyle(Tokens.inkSoft)
                    Spacer()
                    DatePicker("", selection: $endDate, in: startDate..., displayedComponents: .date)
                        .paperDatePickerOnMac()
                        .labelsHidden()
                        .tint(Tokens.accent(for: .itineraries))
                }
            }
            .padding(Space.md)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
            .paperBorder(Tokens.border, radius: Radius.md)
        }
    }

    /// Participants for expense splitting (#258). Colcoured person chips with a
    /// remove affordance, plus an "Add" chip that opens the reused
    /// `PersonPickerSheet` (find-or-create by name). Horizontally scrollable so
    /// a large group never blows out the sheet width.
    private var participantsField: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                Text("Participants").eyebrow()
                Spacer()
                // Headcount includes the user — "3 going" means You + 2.
                Text("\(participantPeople.count + 1) going")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.sm) {
                    youChip
                    ForEach(participantPeople, id: \.clientUUID) { person in
                        participantChip(person)
                    }
                    addParticipantChip
                }
                .padding(.vertical, 2)
            }
        }
        .sheet(isPresented: $showingParticipantPicker) {
            PersonPickerSheet(selection: $pickedParticipant)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: pickedParticipant) { _, newValue in
            if let tag = newValue, !participantUUIDs.contains(tag.uuid) {
                participantUUIDs.append(tag.uuid)
            }
            // Reset so picking the same person twice in a row still fires.
            pickedParticipant = nil
        }
    }

    /// Resolved participant records, preserving the stored order.
    private var participantPeople: [LocalPerson] {
        participantUUIDs.compactMap { id in allPeople.first { $0.clientUUID == id } }
    }

    /// The user's own chip — always first, not removable. Makes the headcount
    /// readable at a glance ("You, Rohan, Sam" = 3 going).
    private var youChip: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Tokens.accentFinance)
                .frame(width: 8, height: 8)
            Text("You")
                .font(.edFootnote)
                .foregroundStyle(Tokens.ink)
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, 6)
        .background(Tokens.surface2, in: Capsule())
        .accessibilityLabel("You are going")
    }

    private func participantChip(_ person: LocalPerson) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color(personHex: person.colorHex))
                .frame(width: 8, height: 8)
            Text(person.name)
                .font(.edFootnote)
                .foregroundStyle(Tokens.ink)
                .lineLimit(1)
            Button {
                participantUUIDs.removeAll { $0 == person.clientUUID }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Tokens.mutedSoft)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(person.name)")
        }
        .padding(.leading, Space.sm)
        .padding(.trailing, Space.xs + 2)
        .padding(.vertical, 6)
        .background(Tokens.surface2, in: Capsule())
    }

    private var addParticipantChip: some View {
        Button {
            showingParticipantPicker = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                Text("Add")
                    .font(.edFootnote)
            }
            .foregroundStyle(Tokens.accent(for: .itineraries))
            .padding(.horizontal, Space.sm)
            .padding(.vertical, 6)
            .background(Tokens.accent(for: .itineraries).opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add participant")
    }

    private var notesField: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                Text("Notes").eyebrow()
                Spacer()
                Text("Optional")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
            }
            ZStack(alignment: .topLeading) {
                if notes.isEmpty {
                    Text("Anything to remember about this trip…")
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

    // MARK: - Persistence

    private var isEditing: Bool {
        if case .existing = target { return true }
        return false
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedNotes: String {
        notes.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true

        if case let .existing(uuid) = target {
            let descriptor = FetchDescriptor<LocalTrip>(
                predicate: #Predicate { $0.clientUUID == uuid }
            )
            if let existing = try? modelContext.fetch(descriptor).first {
                name = existing.name
                // Stored days are UTC anchors; the pickers are device-local (#506).
                startDate = WallClock.deviceDay(from: existing.startDate)
                endDate = WallClock.deviceDay(from: existing.endDate)
                notes = existing.notes
                participantUUIDs = existing.participantPersonUUIDs
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                nameFocused = true
            }
        }
    }

    private func save() {
        let cleanName = trimmedName
        guard !cleanName.isEmpty else { return }
        let cleanNotes = trimmedNotes
        // A trip's start and end name calendar days, so they are anchored at
        // UTC midnight rather than at device-local midnight (#506). Stored the
        // old way, an itinerary built in one timezone read a day early in
        // another.
        let normalisedStart = WallClock.dayAnchor(from: startDate)
        let normalisedEnd = WallClock.dayAnchor(from: endDate)

        // Set when this save creates a trip or changes an existing trip's name.
        // Only those two cases want a cover fetch: moving the dates or editing
        // the notes does not change the destination (#428).
        var needsCoverFetch: UUID?

        switch target {
        case .new:
            let trip = LocalTrip(
                name: cleanName,
                startDate: normalisedStart,
                endDate: normalisedEnd,
                notes: cleanNotes
            )
            trip.participantPersonUUIDs = participantUUIDs
            modelContext.insert(trip)
            needsCoverFetch = trip.clientUUID
        case .existing(let uuid):
            let descriptor = FetchDescriptor<LocalTrip>(
                predicate: #Predicate { $0.clientUUID == uuid }
            )
            if let existing = try? modelContext.fetch(descriptor).first {
                let renamed = existing.name != cleanName
                existing.name = cleanName
                existing.startDate = normalisedStart
                existing.endDate = normalisedEnd
                existing.notes = cleanNotes
                existing.participantPersonUUIDs = participantUUIDs
                existing.updatedAt = Date()
                if renamed {
                    // The destination changed, so the cached illustration is now of the
                    // wrong city. Clearing the state (rather than leaving it
                    // `resolved`) is what puts the trip back into the never-attempted
                    // state the service generates for. The old file stays: it is keyed on
                    // the PREVIOUS destination and another trip may still be going there.
                    existing.coverImagePath = nil
                    existing.coverArtPromptVersion = nil
                    existing.coverImageState = nil
                    needsCoverFetch = uuid
                }
            } else {
                let trip = LocalTrip(
                    name: cleanName,
                    startDate: normalisedStart,
                    endDate: normalisedEnd,
                    notes: cleanNotes
                )
                trip.participantPersonUUIDs = participantUUIDs
                modelContext.insert(trip)
                needsCoverFetch = trip.clientUUID
            }
        }
        try? modelContext.save()

        // Fetch on WRITE, never on render. Detached so dismissing the sheet is not
        // waiting on up to three HTTP requests, and so the row that appears behind
        // the sheet renders immediately with generated art and swaps to the
        // photograph when it lands (#428).
        if let needsCoverFetch {
            Task { await TripCoverService.shared.resolveOnWrite(tripUUID: needsCoverFetch) }
        }
    }
}
