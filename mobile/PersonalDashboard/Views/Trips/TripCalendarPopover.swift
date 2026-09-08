import SwiftUI
import SwiftData

/// Read-only, navigable month calendar shown in an anchored popover from the
/// trip detail header (#230). Renders a SINGLE standard weekday-column month
/// grid that the user can page through with prev/next chevrons to reach any
/// month, past or future. On open it defaults to the trip's start month.
///
/// Purely for viewing: no day is tappable, nothing is edited. The only actions
/// are paging months and dismissing the popover.
///
/// The trip's own days are highlighted so the user can see what weekday each
/// date falls on and which days have events. Which days count as "has events"
/// is derived exactly the way `TripDetailView.grouped` buckets items — item
/// `dayDate`, plus the check-out `endDate` for a `.stay` whose check-out
/// differs from its check-in — so the calendar can never disagree with the
/// timeline. Events only exist inside the trip range, so months outside the
/// trip correctly show a plain weekday-reference grid.
///
/// The grid itself is the DEVICE's calendar, so all grid math stays in
/// `Calendar.current`. Stored days are UTC anchors (#506), so each one is
/// projected onto the grid with `WallClock.deviceDay(from:)` first. Projecting
/// is the whole job: read an anchor in the device calendar directly and it
/// lands on the previous cell, anywhere west of UTC.
struct TripCalendarPopover: View {
    let trip: LocalTrip

    @Query private var items: [LocalItineraryItem]

    /// First-of-month (device-local) of the month currently on screen. Seeded
    /// to the trip's start month; paged freely with the header chevrons.
    @State private var displayedMonth: Date

    init(trip: LocalTrip) {
        self.trip = trip
        let tripID = trip.clientUUID
        _items = Query(
            filter: #Predicate<LocalItineraryItem> { $0.tripUUID == tripID }
        )
        let cal = Calendar.current
        let start = cal.startOfDay(for: WallClock.deviceDay(from: trip.startDate))
        let monthStart = cal.dateInterval(of: .month, for: start)?.start ?? start
        _displayedMonth = State(initialValue: monthStart)
    }

    private let accent = Tokens.accent(for: .itineraries)

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            monthHeader
            weekdayHeader
            grid
            legend
        }
        .padding(Space.lg)
        .frame(width: 300)
        // Elevated raised-card surface (the same `Tokens.surface` token used by
        // every card/tile in TripDetailView), a hairline border and a soft
        // drop shadow so the popover clearly floats above the timeline rather
        // than blending into the tiles behind it.
        .background(
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .fill(Tokens.surface)
        )
        .paperBorder(Tokens.border, radius: Radius.lg)
        .shadowLg()
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
                    Color.clear.frame(height: 32)
                }
            }
        }
        .id(displayedMonth)
        .transition(.opacity)
    }

    private func dayCell(_ date: Date) -> some View {
        let cal = Calendar.current
        let dayNumber = cal.component(.day, from: date)
        let inTrip = date >= tripStart && date <= tripEnd
        let hasEvent = eventDays.contains(date)
        let isToday = cal.isDateInToday(date)

        let fill: Color
        let fg: Color
        if inTrip && hasEvent {
            fill = accent
            fg = Tokens.accentFg
        } else if inTrip {
            // In the trip but nothing planned yet: a soft neutral fill, clearly
            // softer than the vivid accent, so the trip's shape reads at a
            // glance without competing with the "has plans" days.
            fill = Tokens.borderStrong
            fg = Tokens.inkSoft
        } else {
            // Outside the trip range — present only for weekday reference.
            fill = .clear
            fg = Tokens.muted
        }

        return ZStack {
            Circle().fill(fill)
            if isToday {
                Circle().strokeBorder(Tokens.ink, lineWidth: 1.5)
            }
            Text("\(dayNumber)")
                .font(.edCaption)
                .foregroundStyle(fg)
        }
        .frame(height: 32)
    }

    // MARK: - Legend

    private var legend: some View {
        HStack(spacing: Space.lg) {
            legendItem(color: accent, label: "Has plans")
            legendItem(color: Tokens.borderStrong, label: "No plans")
            Spacer(minLength: 0)
        }
        .padding(.top, Space.xs)
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: Space.xs) {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
            Text(label)
                .font(.edCaption)
                .foregroundStyle(Tokens.muted)
        }
    }

    // MARK: - Month paging

    private func changeMonth(by delta: Int) {
        let cal = Calendar.current
        guard let next = cal.date(byAdding: .month, value: delta, to: displayedMonth) else { return }
        withAnimation(.easeInOut(duration: 0.2)) { displayedMonth = next }
    }

    // MARK: - Derived data

    private var tripStart: Date { Calendar.current.startOfDay(for: WallClock.deviceDay(from: trip.startDate)) }
    private var tripEnd: Date { Calendar.current.startOfDay(for: WallClock.deviceDay(from: trip.endDate)) }

    /// Set of start-of-day dates that carry at least one event. Mirrors
    /// `TripDetailView.grouped`: every item lands on its `dayDate`, and a
    /// `.stay` whose `endDate` differs from `dayDate` also lights up the
    /// check-out day. Uses `dayDate`/`endDate`, projected onto the device's
    /// calendar, never the UTC-anchored `startTime`, matching how the timeline
    /// groups.
    private var eventDays: Set<Date> {
        let cal = Calendar.current
        var days = Set<Date>()
        for item in items {
            let inDay = cal.startOfDay(for: WallClock.deviceDay(from: item.dayDate))
            days.insert(inDay)
            if item.kindEnum == .stay, let endDate = item.endDate {
                let outDay = cal.startOfDay(for: WallClock.deviceDay(from: endDate))
                if outDay != inDay { days.insert(outDay) }
            }
        }
        return days
    }

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
