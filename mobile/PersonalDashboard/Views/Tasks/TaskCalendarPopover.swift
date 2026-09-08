import SwiftUI
import SwiftData

/// Read-only, navigable month calendar shown in an anchored popover from the
/// Tasks section header (#385).
///
/// The sibling of `TripCalendarPopover`, but scoped to everything the user has
/// dated rather than to one trip: task due dates, trip date ranges, and the
/// itinerary items inside those trips all light up their day. Paging is free in
/// both directions; the calendar opens on the current month.
///
/// Hovering a day (macOS) or tapping it (iOS, which has no hover) floats a card
/// listing that day's agenda. The card is deliberately `allowsHitTesting(false)`
/// so the pointer never enters it — hover stays latched on the cell underneath
/// and the card cannot flicker itself in and out of existence.
///
/// Purely for viewing: nothing here edits or navigates. The grid is the
/// DEVICE's calendar, so its day math runs through `Calendar.current`, matching
/// how `LocalTodo.dueDate` is stored.
///
/// Trip and itinerary days are the exception: those are UTC anchors (#506), so
/// each is projected onto the grid with `WallClock.deviceDay(from:)` before it
/// is matched to a cell. Itinerary *times* are UTC-anchored wall clock and
/// render through `TimelineEntry.itineraryTimeFormatter`, exactly as the trip
/// timeline does.
struct TaskCalendarPopover: View {
    @Query(filter: #Predicate<LocalTodo> { $0.deletedAt == nil })
    private var todos: [LocalTodo]

    @Query private var trips: [LocalTrip]

    @Query private var itineraryItems: [LocalItineraryItem]

    /// First-of-month (device-local) of the month on screen.
    @State private var displayedMonth: Date = {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return cal.dateInterval(of: .month, for: today)?.start ?? today
    }()

    /// The day whose agenda card is floating, if any. Set by hover on macOS and
    /// by tap on iOS.
    @State private var focusedDay: Date?

    /// Measured size of the floating card. The card hugs its own content, so
    /// its size isn't knowable up front, and placement needs both axes: the
    /// height to decide whether to flip above the hovered row, the width to
    /// centre it on the cell and pull it back inside the popover at the edges.
    @State private var cardSize: CGSize = .zero

    private let taskAccent = Tokens.accent(for: .tasks)
    private let tripAccent = Tokens.accent(for: .itineraries)

    /// Popover content width. Wider than the trip calendar's 300 because the
    /// agenda card floats inside these same bounds and needs room for a title
    /// plus a time.
    private let contentWidth: CGFloat = 340

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            monthHeader
            weekdayHeader
            grid
            legend
        }
        .padding(Space.lg)
        .frame(width: contentWidth)
        // Same raised-card surface as `TripCalendarPopover` so the two
        // calendars read as one component in two places.
        .background(
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .fill(Tokens.surface)
        )
        .paperBorder(Tokens.border, radius: Radius.lg)
        .shadowLg()
        .overlayPreferenceValue(DayCellAnchorKey.self) { anchors in
            floatingCard(anchors: anchors)
        }
        .presentationBackground(Tokens.surface)
        .presentationCompactAdaptation(.popover)
    }

    // MARK: - Month header (title + paging chevrons)

    private var monthHeader: some View {
        HStack(spacing: Space.sm) {
            Text(monthTitle(displayedMonth))
                .font(.edBodyMedium)
                .foregroundStyle(Tokens.ink)
            Spacer(minLength: 0)
            if !isCurrentMonth {
                Button { goToToday() } label: {
                    Text("Today")
                        .font(.edCaption)
                        .foregroundStyle(taskAccent)
                        .padding(.horizontal, Space.sm)
                        .frame(height: 28)
                        .contentShape(Rectangle())
                }
                .macPlainButtonStyle()
                .accessibilityLabel("Jump to this month")
            }
            Button { changeMonth(by: -1) } label: {
                chevron("chevron.left")
            }
            .macPlainButtonStyle()
            .accessibilityLabel("Previous month")
            Button { changeMonth(by: 1) } label: {
                chevron("chevron.right")
            }
            .macPlainButtonStyle()
            .accessibilityLabel("Next month")
        }
    }

    private func chevron(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Tokens.muted)
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
    }

    // MARK: - Weekday header

    private var weekdayHeader: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.edEyebrow)
                    .textCase(.uppercase)
                    .foregroundStyle(Tokens.mutedSoft)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Day grid

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(Array(cells(for: displayedMonth).enumerated()), id: \.offset) { _, date in
                if let date {
                    dayCell(date)
                } else {
                    Color.clear.frame(height: cellHeight)
                }
            }
        }
    }

    private func dayCell(_ date: Date) -> some View {
        let cal = Calendar.current
        let dayNumber = cal.component(.day, from: date)
        let inTrip = !trips(covering: date).isEmpty
        let hasTask = !tasks(on: date).isEmpty
        let hasPlan = !plans(on: date).isEmpty
        let isToday = cal.isDateInToday(date)
        let isFocused = focusedDay == date

        return ZStack {
            // A trip is a SPAN, so it reads as a wash behind the whole day
            // rather than as another dot competing with the point events.
            if inTrip {
                Circle().fill(tripAccent.opacity(0.22))
            }
            if isToday {
                Circle().strokeBorder(Tokens.ink, lineWidth: 1.5)
            }
            if isFocused {
                Circle().strokeBorder(taskAccent, lineWidth: 2)
            }

            VStack(spacing: 2) {
                Text("\(dayNumber)")
                    .font(.edCaption)
                    .foregroundStyle(dayNumberColor(inTrip: inTrip, hasTask: hasTask))
                // Point events sit under the number as dots, so a day can carry
                // a task and a plan without either one hiding the other. Filled
                // vs hollow, not just hue: at 5pt the tasks indigo and the
                // itineraries violet are almost the same colour, so shape is
                // what actually distinguishes them.
                HStack(spacing: 3) {
                    if hasTask { taskMarker }
                    if hasPlan { planMarker }
                }
                .frame(height: 5)
            }
        }
        .frame(height: cellHeight)
        .contentShape(Circle())
        .anchorPreference(key: DayCellAnchorKey.self, value: .bounds) { [date: $0] }
        .onHover { inside in
            if inside {
                focusedDay = date
            } else if focusedDay == date {
                focusedDay = nil
            }
        }
        .onTapGesture {
            focusedDay = (focusedDay == date) ? nil : date
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(for: date))
    }

    private var taskMarker: some View {
        Circle().fill(taskAccent).frame(width: 5, height: 5)
    }

    private var planMarker: some View {
        Circle().strokeBorder(tripAccent, lineWidth: 1.2).frame(width: 5, height: 5)
    }

    private func dayNumberColor(inTrip: Bool, hasTask: Bool) -> Color {
        if inTrip || hasTask { return Tokens.ink }
        return Tokens.muted
    }

    // MARK: - Legend

    private var legend: some View {
        HStack(spacing: Space.md) {
            legendItem(label: "Trip") {
                Circle().fill(tripAccent.opacity(0.22)).frame(width: 12, height: 12)
            }
            legendItem(label: "Task") {
                taskMarker.frame(width: 12)
            }
            legendItem(label: "Plan") {
                planMarker.frame(width: 12)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, Space.xs)
    }

    private func legendItem<Swatch: View>(
        label: String,
        @ViewBuilder swatch: () -> Swatch
    ) -> some View {
        HStack(spacing: Space.xs) {
            swatch()
            Text(label)
                .font(.edCaption)
                .foregroundStyle(Tokens.muted)
        }
    }

    // MARK: - Floating day-agenda card

    /// The hover/tap card, positioned against the focused cell's bounds.
    ///
    /// Sized to its own content rather than to the calendar, and centred on the
    /// hovered cell, so a two-line day doesn't leave a band of empty middle. A
    /// small triangle points back at the cell — above the card when it sits
    /// below the cell, below it when it has flipped up.
    ///
    /// Clamped only against the popover's own edges, so it is never clipped.
    /// Non-interactive by design (see the type doc).
    ///
    /// It is allowed to cover the month title. An earlier version protected the
    /// title by refusing to place the card above the grid, which meant a tall
    /// card on a middle row got shoved down over its own day with no pointer —
    /// it read as a glitch, and you couldn't tell which date it belonged to.
    /// Being anchored to the right day matters more than keeping the month
    /// visible, and the card's own header carries the full date anyway.
    @ViewBuilder
    private func floatingCard(anchors: [Date: Anchor<CGRect>]) -> some View {
        GeometryReader { geo in
            if let day = focusedDay,
               let anchor = anchors[day] {
                let entries = agenda(for: day)
                if !entries.isEmpty {
                    let cell = geo[anchor]
                    let gap: CGFloat = 6
                    // Breathing room the card is never allowed to spend, on all
                    // four sides. Without it the card's far edge lands flush on
                    // the popover boundary and its rounded corners are shaved
                    // off by the popover's own — which reads as the card being
                    // cut off rather than merely tight. Worst on iPhone, where
                    // the popover is far smaller than on the Mac.
                    let inset: CGFloat = 6

                    // Vertical: take whichever side of the cell has more room,
                    // and let the card size itself to fit that side. Deciding
                    // the side from free space rather than from the card's own
                    // height is what stops a dense day (Sep 7 carries eleven
                    // items) from being clamped across the cell it belongs to.
                    let spaceAbove = cell.minY - gap - inset
                    let spaceBelow = geo.size.height - cell.maxY - gap - inset
                    let placeBelow = spaceBelow > spaceAbove
                    let budget = max(spaceAbove, spaceBelow) - arrowHeight
                    // `cardSize` measures the SLOT, not the card — see the note
                    // on `dayCard`. That is fine here: the slot is exactly the
                    // space on its side of the cell, so both branches land the
                    // card's near edge `gap` away from the day, and the clamps
                    // below are only guarding the frame after the focused day
                    // changes, when the measurement is still the last day's.
                    let rawTop = placeBelow
                        ? cell.maxY + gap
                        : cell.minY - gap - cardSize.height
                    let top = min(max(rawTop, 0), max(geo.size.height - cardSize.height, 0))

                    // Horizontal: centred on the cell, pulled back inside the
                    // popover at the edges.
                    let rawLeft = cell.midX - cardSize.width / 2
                    let left = min(
                        max(rawLeft, inset),
                        max(geo.size.width - cardSize.width - inset, inset)
                    )

                    // A pointer that doesn't point at the cell is worse than no
                    // pointer. The card is now sized to its side, so it always
                    // clears; this is a backstop for the frame after the
                    // focused day changes, when `cardSize` is still the
                    // previous day's.
                    let clearsBelow = placeBelow && top >= cell.maxY
                    let clearsAbove = !placeBelow && top + cardSize.height <= cell.minY
                    let arrow: ArrowDirection? = clearsBelow ? .up : (clearsAbove ? .down : nil)
                    // Keep the triangle off the card's rounded corners.
                    let arrowX = min(max(cell.midX - left, Radius.md + 8),
                                     max(cardSize.width - Radius.md - 8, Radius.md + 8))

                    VStack(spacing: 0) {
                        if arrow == .up {
                            cardArrow(.up).offset(x: arrowX - cardSize.width / 2, y: 1)
                        }
                        dayCard(
                            day: day,
                            entries: entries,
                            budget: budget,
                            width: geo.size.width - inset * 2,
                            placeBelow: placeBelow
                        )
                        if arrow == .down {
                            cardArrow(.down).offset(x: arrowX - cardSize.width / 2, y: -1)
                        }
                    }
                    .background(
                        GeometryReader { cardGeo in
                            Color.clear.preference(
                                key: CardSizeKey.self,
                                value: cardGeo.size
                            )
                        }
                    )
                    // Hidden until measured: placement needs the real size, and
                    // one frame at the wrong spot reads as a jump.
                    .opacity(cardSize == .zero ? 0 : 1)
                    .offset(x: left, y: top)
                }
            }
        }
        .onPreferenceChange(CardSizeKey.self) { size in
            if size.width > 0, size.height > 0 { cardSize = size }
        }
        .allowsHitTesting(false)
    }

    private enum ArrowDirection { case up, down }

    /// The pointer triangle. Filled to match the card and stroked on its two
    /// legs only — the base is left open and the whole thing overlaps the card
    /// by a point, so the card's own border doesn't draw a line across it.
    private func cardArrow(_ direction: ArrowDirection) -> some View {
        ZStack {
            CardArrowShape(pointsUp: direction == .up, closed: true)
                .fill(Tokens.paper2)
            CardArrowShape(pointsUp: direction == .up, closed: false)
                .stroke(Tokens.borderStrong, lineWidth: 1)
        }
        .frame(width: 14, height: arrowHeight)
    }

    /// Picks the longest version of the list that fits in `budget`.
    ///
    /// A fixed entry cap can't work here: the room available depends on which
    /// row the day sits in, so any constant is either too small for a
    /// bottom-row day (which has the whole calendar above it) or too big for a
    /// second-row one, and too big means the card gets clamped over its own
    /// date. `ViewThatFits` settles it against the real laid-out heights
    /// instead of arithmetic on font metrics, which would drift the moment a
    /// token changed.
    ///
    /// `maxHeight` is what bounds the proposal `ViewThatFits` measures against,
    /// but it is also greedy: the frame grows to the whole budget. So this view
    /// is a SLOT of `budget` points with the card parked at one end, NOT a view
    /// the size of the card, and everything downstream has to respect that.
    /// The card parks at the end nearest the day — top when the slot hangs
    /// below the cell, bottom when it hangs above — so the slack always falls
    /// on the far side and the card stays welded to its pointer. Parking it at
    /// the top in both cases strands the card at the top of the popover with
    /// the arrow still down by the cell.
    private func dayCard(
        day: Date,
        entries: [AgendaEntry],
        budget: CGFloat,
        width: CGFloat,
        placeBelow: Bool
    ) -> some View {
        let titleCap = titleWidthCap(forCardWidth: width)
        return ViewThatFits(in: .vertical) {
            cardBody(day: day, entries: entries, limit: entries.count, titleCap: titleCap)
            cardBody(day: day, entries: entries, limit: 10, titleCap: titleCap)
            cardBody(day: day, entries: entries, limit: 8, titleCap: titleCap)
            cardBody(day: day, entries: entries, limit: 6, titleCap: titleCap)
            cardBody(day: day, entries: entries, limit: 4, titleCap: titleCap)
            cardBody(day: day, entries: entries, limit: 3, titleCap: titleCap)
            cardBody(day: day, entries: entries, limit: 2, titleCap: titleCap)
            cardBody(day: day, entries: entries, limit: 1, titleCap: titleCap)
        }
        .frame(maxHeight: max(budget, 0), alignment: placeBelow ? .top : .bottom)
    }

    /// How wide a title may get before it truncates, derived from the room the
    /// card actually has.
    ///
    /// The card hugs its content, so its width is whatever its widest row wants
    /// and nothing downstream can shrink it: clamping the card's origin only
    /// slides an over-wide card sideways, it still runs past the popover and
    /// gets shaved by its rounded corners. A fixed cap can't work either, since
    /// the popover on iPhone is much smaller than on the Mac. Capping the one
    /// unbounded element against the real width is what makes the card
    /// physically unable to overflow.
    ///
    /// `trailingReserve` covers the row's fixed furniture (card padding, the
    /// icon and its two gaps) plus the widest detail string this view can
    /// produce, which is a stay's "Check-out · 12:00 AM".
    private func titleWidthCap(forCardWidth width: CGFloat) -> CGFloat {
        let trailingReserve: CGFloat = 182
        return max(90, width - trailingReserve)
    }

    private func cardBody(
        day: Date,
        entries: [AgendaEntry],
        limit: Int,
        titleCap: CGFloat
    ) -> some View {
        let shown = entries.prefix(limit)
        let overflow = entries.count - shown.count

        return VStack(alignment: .leading, spacing: Space.xs) {
            // Reads as the card's title, in ink rather than a muted eyebrow:
            // with the card floating over the grid, this line plus the pointer
            // are what tell you which day you're looking at.
            Text(day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                .font(.edEyebrow)
                .textCase(.uppercase)
                .foregroundStyle(Tokens.inkSoft)

            ForEach(shown) { entry in
                HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                    Image(systemName: entry.icon)
                        .font(.system(size: 11))
                        .foregroundStyle(entry.tint)
                        .frame(width: 14, alignment: .center)
                    Text(entry.title)
                        .font(.edCaption)
                        .foregroundStyle(Tokens.ink)
                        .strikethrough(entry.struckThrough, color: Tokens.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        // The only unbounded element in the row, so this is
                        // what keeps the card inside the popover. See
                        // `titleWidthCap(forCardWidth:)`.
                        .frame(maxWidth: titleCap, alignment: .leading)
                    if let detail = entry.detail {
                        Spacer(minLength: Space.md)
                        Text(detail)
                            .font(.edCaption)
                            .foregroundStyle(Tokens.muted)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                }
            }

            if overflow > 0 {
                Text("+\(overflow) more")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
            }
        }
        .padding(Space.sm)
        // Hug the content instead of spanning the calendar. `Spacer` inside the
        // rows is greedy, so without this the card takes the full proposed
        // width and leaves a dead band between each title and its time. Fixed
        // at its ideal width, the spacers only stretch shorter rows out to the
        // widest one, which is what keeps the times in a column.
        //
        // Vertical is fixed too, so each candidate reports its true height to
        // `ViewThatFits`. Left free, a too-tall candidate would compress to the
        // proposal and claim to fit.
        .fixedSize()
        .background(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .fill(Tokens.paper2)
        )
        .paperBorder(Tokens.borderStrong, radius: Radius.md)
        .shadowLg()
    }

    /// Height of the pointer triangle, deducted from the space a card may use.
    private let arrowHeight: CGFloat = 7

    // MARK: - Month paging

    private func changeMonth(by delta: Int) {
        let cal = Calendar.current
        guard let next = cal.date(byAdding: .month, value: delta, to: displayedMonth) else { return }
        focusedDay = nil
        withAnimation(.easeInOut(duration: 0.2)) { displayedMonth = next }
    }

    private func goToToday() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let monthStart = cal.dateInterval(of: .month, for: today)?.start else { return }
        focusedDay = nil
        withAnimation(.easeInOut(duration: 0.2)) { displayedMonth = monthStart }
    }

    private var isCurrentMonth: Bool {
        Calendar.current.isDate(displayedMonth, equalTo: Date(), toGranularity: .month)
    }

    // MARK: - Agenda assembly

    /// One line in the floating card.
    private struct AgendaEntry: Identifiable {
        let id: String
        let icon: String
        let tint: Color
        let title: String
        let detail: String?
        let struckThrough: Bool
    }

    /// Everything dated on `day`, ordered trips → itinerary items → tasks.
    /// Trips lead because they're the day's context; the plans and tasks that
    /// follow happen inside it.
    private func agenda(for day: Date) -> [AgendaEntry] {
        var entries: [AgendaEntry] = []

        for trip in trips(covering: day) {
            entries.append(
                AgendaEntry(
                    id: "trip-\(trip.clientUUID.uuidString)",
                    // Suitcase, not a plane: the plane glyph belongs to the
                    // flight items below, and the trip line is the day's
                    // context rather than another thing happening in it.
                    icon: "suitcase.fill",
                    tint: tripAccent,
                    title: tripTitle(trip),
                    detail: tripDayLabel(trip, on: day),
                    struckThrough: false
                )
            )
        }

        for plan in plans(on: day) {
            entries.append(
                AgendaEntry(
                    id: "plan-\(plan.item.clientUUID.uuidString)-\(plan.isCheckOut ? "out" : "in")",
                    icon: planIcon(plan),
                    tint: tripAccent,
                    title: plan.item.title,
                    detail: planDetail(plan),
                    struckThrough: false
                )
            )
        }

        for todo in tasks(on: day) {
            entries.append(
                AgendaEntry(
                    id: "task-\(todo.clientUUID.uuidString)",
                    icon: todo.completed ? "checkmark.circle.fill" : "circle",
                    tint: todo.completed
                        ? Tokens.muted
                        : Tokens.priorityColor(for: TaskPriority(rawValue: todo.priority) ?? .none),
                    title: todo.title,
                    detail: taskDetail(todo),
                    struckThrough: todo.completed
                )
            )
        }

        return entries
    }

    /// "Italy trip" without doubling up when the user already named it one.
    private func tripTitle(_ trip: LocalTrip) -> String {
        let name = trip.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "Trip" }
        return name.lowercased().contains("trip") ? name : "\(name) trip"
    }

    /// "Day 3 of 7" — cheap orientation for a day sitting mid-trip.
    private func tripDayLabel(_ trip: LocalTrip, on day: Date) -> String? {
        let cal = Calendar.current
        let start = cal.startOfDay(for: WallClock.deviceDay(from: trip.startDate))
        let end = cal.startOfDay(for: WallClock.deviceDay(from: trip.endDate))
        guard let index = cal.dateComponents([.day], from: start, to: day).day,
              let span = cal.dateComponents([.day], from: start, to: end).day
        else { return nil }
        return "Day \(index + 1) of \(span + 1)"
    }

    private func planIcon(_ plan: DayPlan) -> String {
        if plan.item.kindEnum == .transport, let mode = plan.item.transportModeEnum {
            return mode.icon
        }
        return plan.item.kindEnum.icon
    }

    /// Times come from the UTC-anchored wall clock, matching the trip timeline
    /// so the calendar and the itinerary can never disagree.
    private func planDetail(_ plan: DayPlan) -> String? {
        let format: (Date) -> String = { TimelineEntry.itineraryTimeFormatter.string(from: $0) }
        if plan.isCheckOut {
            if let out = plan.item.endTime { return "Check-out · \(format(out))" }
            return "Check-out"
        }
        if plan.item.kindEnum == .stay {
            if let inTime = plan.item.startTime { return "Check-in · \(format(inTime))" }
            return "Check-in"
        }
        if let start = plan.item.startTime { return format(start) }
        return nil
    }

    /// Task due times are plain device-local dates, so they use the local
    /// formatter. A due time pinned to midnight reads as "no particular time"
    /// and shows the priority instead.
    private func taskDetail(_ todo: LocalTodo) -> String? {
        guard let due = todo.dueDate else { return nil }
        let cal = Calendar.current
        if cal.startOfDay(for: due) == due {
            let priority = TaskPriority(rawValue: todo.priority) ?? .none
            return priority == .none ? nil : priority.label
        }
        return due.formatted(.dateTime.hour().minute())
    }

    // MARK: - Derived day data

    /// A single itinerary appearance on a day. A `.stay` shows up twice: once
    /// on its check-in day and once on its check-out day.
    private struct DayPlan {
        let item: LocalItineraryItem
        let isCheckOut: Bool
    }

    private func trips(covering day: Date) -> [LocalTrip] {
        let cal = Calendar.current
        return trips
            .filter { trip in
                let start = cal.startOfDay(for: WallClock.deviceDay(from: trip.startDate))
                let end = cal.startOfDay(for: WallClock.deviceDay(from: trip.endDate))
                return day >= start && day <= end
            }
            .sorted { $0.startDate < $1.startDate }
    }

    /// Mirrors `TripDetailView.grouped`: every item lands on its `dayDate`, and
    /// a `.stay` whose check-out differs from its check-in also lands on the
    /// check-out day. Sorted the way the timeline sorts — timed entries by
    /// time, then by `sortOrder`.
    private func plans(on day: Date) -> [DayPlan] {
        let cal = Calendar.current
        var result: [DayPlan] = []
        for item in itineraryItems {
            let inDay = cal.startOfDay(for: WallClock.deviceDay(from: item.dayDate))
            if inDay == day {
                result.append(DayPlan(item: item, isCheckOut: false))
            }
            if item.kindEnum == .stay, let endDate = item.endDate {
                let outDay = cal.startOfDay(for: WallClock.deviceDay(from: endDate))
                if outDay != inDay && outDay == day {
                    result.append(DayPlan(item: item, isCheckOut: true))
                }
            }
        }
        return result.sorted { lhs, rhs in
            let lTime = lhs.isCheckOut ? lhs.item.endTime : lhs.item.startTime
            let rTime = rhs.isCheckOut ? rhs.item.endTime : rhs.item.startTime
            switch (lTime, rTime) {
            case let (l?, r?) where l != r: return l < r
            case (nil, _?): return false
            case (_?, nil): return true
            default: return lhs.item.sortOrder < rhs.item.sortOrder
            }
        }
    }

    /// Tasks due on `day`, in the order the day happens: incomplete first, then
    /// earliest due time. A time pinned to midnight means "no particular time"
    /// (see `taskDetail`) and so leads the list on its own. Priority only breaks
    /// ties between tasks at the same time — ranking by it first read as random
    /// on a card that prints a clock beside every row (#422).
    private func tasks(on day: Date) -> [LocalTodo] {
        let cal = Calendar.current
        return todos
            .filter { todo in
                guard let due = todo.dueDate else { return false }
                return cal.startOfDay(for: due) == day
            }
            .sorted { lhs, rhs in
                if lhs.completed != rhs.completed { return !lhs.completed }
                let lDue = lhs.dueDate ?? .distantPast
                let rDue = rhs.dueDate ?? .distantPast
                if lDue != rDue { return lDue < rDue }
                let lRank = (TaskPriority(rawValue: lhs.priority) ?? .none).sortRank
                let rRank = (TaskPriority(rawValue: rhs.priority) ?? .none).sortRank
                return lRank < rRank
            }
    }

    private func accessibilityLabel(for date: Date) -> String {
        let day = date.formatted(.dateTime.weekday(.wide).day().month(.wide))
        let entries = agenda(for: date)
        guard !entries.isEmpty else { return day }
        return "\(day). \(entries.map(\.title).joined(separator: ", "))"
    }

    // MARK: - Grid math

    private let cellHeight: CGFloat = 38

    /// Seven equal columns for the weekday grid.
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

    /// Sun–Sat single-letter symbols. `veryShortWeekdaySymbols` is always
    /// Sunday-first (index 0 = Sunday) regardless of the locale's first
    /// weekday, matching the leading-blank offset computed from `.weekday`.
    private var weekdaySymbols: [String] {
        Calendar.current.veryShortWeekdaySymbols
    }

    /// Grid cells for a month: leading `nil` blanks to align the 1st under its
    /// weekday column (Sunday-first), then one date per day of the month.
    private func cells(for monthStart: Date) -> [Date?] {
        let cal = Calendar.current
        guard let range = cal.range(of: .day, in: .month, for: monthStart) else { return [] }
        // `.weekday` is 1=Sunday…7=Saturday, so Sunday needs 0 leading blanks.
        let leading = cal.component(.weekday, from: monthStart) - 1
        var result: [Date?] = Array(repeating: nil, count: leading)
        for day in range {
            result.append(cal.date(byAdding: .day, value: day - 1, to: monthStart))
        }
        return result
    }

    private func monthTitle(_ monthStart: Date) -> String {
        monthStart.formatted(.dateTime.month(.wide).year())
    }
}

// MARK: - Preference keys

/// Every day cell's bounds, so the floating agenda card can anchor itself to
/// the hovered/tapped one without the cell knowing anything about the card.
private struct DayCellAnchorKey: PreferenceKey {
    static let defaultValue: [Date: Anchor<CGRect>] = [:]

    static func reduce(
        value: inout [Date: Anchor<CGRect>],
        nextValue: () -> [Date: Anchor<CGRect>]
    ) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Measured size of the agenda card, fed back so it can be centred on the
/// hovered cell and flipped above the row rather than clipped at an edge.
private struct CardSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next.width > 0, next.height > 0 { value = next }
    }
}

// MARK: - Pointer triangle

/// The card's pointer. `closed` fills the whole triangle; open draws only the
/// two legs, so the base can be left out and the card's border doesn't show
/// through as a line across the arrow.
private struct CardArrowShape: Shape {
    let pointsUp: Bool
    let closed: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if pointsUp {
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }
        if closed { path.closeSubpath() }
        return path
    }
}
