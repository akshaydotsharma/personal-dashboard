import Foundation

/// Conversions across the wall-clock storage boundary used by ticket and
/// itinerary times.
///
/// ### Why times are stored this way
///
/// A ticket states a LOCAL time at its own location: a flight boards at 19:00 in
/// Milan whatever timezone the phone is in. Storing that as a real instant means
/// the displayed time moves when the device timezone changes, which is exactly
/// what #163 / #168 were about. So the stored `Date` is an ANCHOR, not an
/// instant: its components in a UTC calendar are the printed local time. A
/// UTC-pinned display formatter (`TimelineEntry.itineraryTimeFormatter`) then
/// renders precisely what was on the ticket, anywhere in the world.
///
/// Extracted from the itinerary editor's private helpers (#398) so the wallet
/// editor writes byte-identical values rather than carrying a second copy that
/// could drift. The itinerary editor now delegates here; behaviour is unchanged.
enum WallClock {

    /// Picker → storage. Read the (hour, minute) of `timeFrom` in the DEVICE
    /// calendar (what the picker shows), then build a Date on `onDay`'s calendar
    /// day with those same components anchored in UTC.
    static func utcAnchor(onDay: Date, timeFrom: Date) -> Date {
        let local = Calendar.current
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let day = local.dateComponents([.year, .month, .day], from: onDay)
        let time = local.dateComponents([.hour, .minute], from: timeFrom)
        var comps = DateComponents()
        comps.year = day.year
        comps.month = day.month
        comps.day = day.day
        comps.hour = time.hour
        comps.minute = time.minute
        comps.second = 0
        return utc.date(from: comps) ?? timeFrom
    }

    /// Storage → picker. Inverse of `utcAnchor`: read the (hour, minute) of a
    /// stored anchor in a UTC calendar, then build a DEVICE-local Date carrying
    /// those components on `onDay`'s local calendar day, so a `DatePicker`
    /// surfaces the stated time.
    static func devicePickerDate(onDay: Date, anchor: Date) -> Date {
        let local = Calendar.current
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let time = utc.dateComponents([.hour, .minute], from: anchor)
        return local.date(
            bySettingHour: time.hour ?? 0,
            minute: time.minute ?? 0,
            second: 0,
            of: onDay
        ) ?? onDay
    }

    /// Drop the seconds a `DatePicker` never showed, in the DEVICE calendar.
    ///
    /// Unrelated to the UTC anchoring above — this one is about *granularity*, not
    /// about which timezone a stated time belongs to. A `Date` is an instant, so it
    /// always carries seconds and a fraction of a second, but a picker configured
    /// `[.date, .hourAndMinute]` lets nobody see or set them. Whatever the value was
    /// seeded with therefore survives into storage: a task editor opening on
    /// `Date().addingTimeInterval(3600)` stored a due time of `16:28:44.910929` for
    /// a 4:28 PM pick (#444).
    ///
    /// That is invisible until something compares or schedules against it. It made
    /// reminders fire most of a minute late, and it makes two tasks that both read
    /// "4:28 PM" sort by a difference nobody can see. So a value that came from a
    /// minute-granularity picker is stored at minute granularity.
    ///
    /// Truncates rather than rounds: 4:28 means the moment 4:28 begins.
    static func minutePrecision(_ date: Date) -> Date {
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return calendar.date(from: parts) ?? date
    }

    // MARK: - Days

    /// A UTC calendar. Every stored DAY is read, grouped and compared through
    /// this one, never through `Calendar.current`.
    ///
    /// ### Why days are stored this way
    ///
    /// A day field names a calendar day, not a moment: Day 1 of a trip is
    /// 2 September wherever you happen to be standing. Storing it as a
    /// device-local `startOfDay` makes it an instant, so the day it reports
    /// changes with the device timezone. #506: an Italy itinerary built in
    /// Singapore (UTC+8) and India (UTC+5:30) read one day early once the Mac
    /// was on `Europe/Rome`, and the six stops added in Italy read correctly,
    /// which split one day across two headers.
    ///
    /// So a stored day is an ANCHOR at UTC midnight, exactly as a stored time
    /// is an anchor carrying its printed hour. `dayAnchor(from:)` is the write
    /// side; `dayCalendar` and ``deviceDay(from:)`` are the read side.
    static let dayCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// Picker → storage. Read the calendar day of a DEVICE-local picker value,
    /// then anchor that same day at UTC midnight.
    ///
    /// Discards any time of day the picker carried. A day field holds a day;
    /// the time lives in `startTime` / `endTime` via ``utcAnchor(onDay:timeFrom:)``.
    static func dayAnchor(from deviceDate: Date) -> Date {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: deviceDate)
        var comps = DateComponents()
        comps.year = parts.year
        comps.month = parts.month
        comps.day = parts.day
        return dayCalendar.date(from: comps) ?? startOfStoredDay(deviceDate)
    }

    /// Storage → device. Build the DEVICE-local midnight of the anchored day.
    ///
    /// The one read helper for both jobs a stored day has outside storage: it
    /// gives a `DatePicker` the day to surface, and it gives a device-local
    /// formatter (`.formatted`, `Text(_:style:)`) a value that prints that same
    /// day. Format an anchor directly and it prints the day before, anywhere
    /// west of UTC.
    ///
    /// Also required before feeding a stored day to
    /// ``devicePickerDate(onDay:anchor:)``: that helper sets an hour on `onDay`
    /// in the device calendar, and a raw UTC midnight read west of UTC lands on
    /// the previous local day.
    static func deviceDay(from anchor: Date) -> Date {
        let parts = dayCalendar.dateComponents([.year, .month, .day], from: anchor)
        var comps = DateComponents()
        comps.year = parts.year
        comps.month = parts.month
        comps.day = parts.day
        return Calendar.current.date(from: comps) ?? anchor
    }

    /// Normalise a stored day to its anchor. Idempotent for an anchored value,
    /// so it is safe to call on a read path without knowing the write path.
    static func startOfStoredDay(_ date: Date) -> Date {
        dayCalendar.startOfDay(for: date)
    }

    /// True when two stored days name the same calendar day.
    static func isSameStoredDay(_ lhs: Date, _ rhs: Date) -> Bool {
        startOfStoredDay(lhs) == startOfStoredDay(rhs)
    }

    /// Shift an anchored day by whole days, staying anchored.
    static func storedDay(_ date: Date, byAdding days: Int) -> Date {
        dayCalendar.date(byAdding: .day, value: days, to: startOfStoredDay(date))
            ?? startOfStoredDay(date)
    }

    /// Whole days from `start` to `end`, both anchored. Used for "Day N".
    static func storedDayCount(from start: Date, to end: Date) -> Int {
        dayCalendar.dateComponents(
            [.day],
            from: startOfStoredDay(start),
            to: startOfStoredDay(end)
        ).day ?? 0
    }

    /// Today, as an anchored day. The device decides which day "today" is;
    /// the result is then anchored so it compares against stored days.
    static func todayAnchor(now: Date = Date()) -> Date {
        dayAnchor(from: now)
    }

    /// The anchored day named by the leading `yyyy-MM-dd` of an ISO 8601
    /// string, ignoring any time and offset that follow.
    ///
    /// For an LLM-authored or email-extracted day this is the faithful reading:
    /// the model writes `"2026-09-04"` (or `"2026-09-04T14:00:00+02:00"`) and
    /// the day it means is 4 September, whatever offset trails it. Parsing the
    /// whole string to an instant and then asking a calendar for its day makes
    /// the answer depend on a timezone nobody chose.
    ///
    /// Returns nil when the string does not begin with a valid date.
    static func dayAnchor(fromISO raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 10 else { return nil }
        let head = String(trimmed.prefix(10))
        let parts = head.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let year = Int(parts[0]), parts[0].count == 4,
              let month = Int(parts[1]), parts[1].count == 2,
              let day = Int(parts[2]), parts[2].count == 2
        else { return nil }
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        guard let date = dayCalendar.date(from: comps),
              dayCalendar.component(.month, from: date) == month,
              dayCalendar.component(.day, from: date) == day
        else { return nil }
        return date
    }

    // MARK: - Day migration

    /// Recover the intended calendar day from a legacy device-local
    /// `startOfDay` value by snapping it to the NEAREST UTC midnight (#506).
    ///
    /// A local midnight always sits within 14 hours of a UTC midnight, and the
    /// nearest one is the day the user meant:
    ///
    /// - `2026-09-01 16:00Z` (midnight in UTC+8) → `2026-09-02 00:00Z`
    /// - `2026-09-02 18:30Z` (midnight in UTC+5:30) → `2026-09-03 00:00Z`
    /// - `2026-09-03 22:00Z` (midnight in UTC+2) → `2026-09-04 00:00Z`
    /// - `2026-09-04 05:00Z` (midnight in UTC-5) → `2026-09-04 00:00Z`
    ///
    /// Idempotent: an already-anchored value sits exactly on a UTC midnight, so
    /// it is its own nearest one and the migration can run repeatedly.
    ///
    /// Limit: a zone at or beyond UTC+12 / UTC-12 is exactly half a day from
    /// two midnights and can round the wrong way. Those are Baker Island and a
    /// handful of Pacific date-line zones; no row in this store came from one.
    static func repairedDayAnchor(_ stored: Date) -> Date {
        let day: TimeInterval = 86_400
        let snapped = (stored.timeIntervalSince1970 / day).rounded() * day
        return Date(timeIntervalSince1970: snapped)
    }

    /// True when a stored value is already anchored at UTC midnight.
    static func isDayAnchored(_ date: Date) -> Bool {
        date.timeIntervalSince1970.truncatingRemainder(dividingBy: 86_400) == 0
    }

}
