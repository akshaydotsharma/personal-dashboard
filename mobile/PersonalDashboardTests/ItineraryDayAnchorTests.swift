import XCTest
@testable import PersonalDashboard

/// Calendar days do not move when the device timezone does (#506).
///
/// The defect these pin: an itinerary day, a stay's check-out day, a trip's
/// start and end, and an event's range were all written as a device-local
/// `Calendar.startOfDay`. That is an instant, not a day, so the day each one
/// reported changed with the device timezone. An Italy itinerary built in
/// Singapore (UTC+8) and India (UTC+5:30) read one day early once the Mac was
/// on `Europe/Rome`, and the stops added in Italy read correctly — which split
/// a single day across two headers.
///
/// Nothing here is hypothetical. `repairedDayAnchor` is exercised against the
/// exact values found in the live store: 62 stops at 18:30Z, 5 at 16:00Z, 6 at
/// 22:00Z, and a trip start of `2026-09-01 16:00Z` that displayed as 1 Sep.
///
/// Timezone is swapped through `NSTimeZone.default`, which is what
/// `TimeZone.current` and therefore `Calendar.current` read. `tearDown` puts it
/// back, so one test's zone cannot leak into the next.
final class ItineraryDayAnchorTests: XCTestCase {

    private var originalZone: TimeZone!

    override func setUp() {
        super.setUp()
        originalZone = NSTimeZone.default
    }

    override func tearDown() {
        NSTimeZone.default = originalZone
        super.tearDown()
    }

    // MARK: - Helpers

    /// A UTC instant, spelled out.
    private func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d; comps.hour = h; comps.minute = min
        return WallClock.dayCalendar.date(from: comps)!
    }

    /// `yyyy-MM-dd` of a date read in UTC.
    private func utcDayString(_ date: Date) -> String {
        let c = WallClock.dayCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// `yyyy-MM-dd` of a date read in the CURRENT device zone — what a plain
    /// `.formatted` or `Calendar.current` call would report.
    private func deviceDayString(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    private func inZone(_ identifier: String, _ body: () throws -> Void) rethrows {
        NSTimeZone.default = TimeZone(identifier: identifier)!
        try body()
    }

    /// Every zone the store's real rows were written in, plus two west of UTC
    /// (where the failure mode inverts) and one at the far east.
    private let zones = [
        "Asia/Singapore",     // UTC+8  — where the Italy trip was created
        "Asia/Kolkata",       // UTC+5:30 — where 62 of its stops were last edited
        "Europe/Rome",        // UTC+2  — where the bug was observed
        "America/New_York",   // UTC-4/-5 — west of UTC, the inverse failure
        "America/Los_Angeles",// UTC-7/-8
        "Pacific/Auckland",   // UTC+12/+13
        "UTC",
    ]

    // MARK: - The repair recovers the intended day

    /// The four distinct values actually present in the store, each with the
    /// day the user meant.
    func testRepairRecoversTheIntendedDayFromEveryStoredOffset() {
        let cases: [(stored: Date, intended: String, note: String)] = [
            (utc(2026, 9, 1, 16, 0),  "2026-09-02", "midnight in UTC+8, the Italy trip start"),
            (utc(2026, 9, 2, 18, 30), "2026-09-03", "midnight in UTC+5:30, 62 Italy stops"),
            (utc(2026, 9, 3, 22, 0),  "2026-09-04", "midnight in UTC+2, the Verona trains"),
            (utc(2026, 8, 31, 22, 0), "2026-09-01", "midnight in UTC+2, the lone 1 Sep ticket"),
            (utc(2026, 9, 4, 5, 0),   "2026-09-04", "midnight in UTC-5"),
            (utc(2026, 9, 4, 8, 0),   "2026-09-04", "midnight in UTC-8"),
            (utc(2026, 9, 3, 13, 0),  "2026-09-04", "midnight in UTC+11"),
            (utc(2026, 1, 15, 0, 0),  "2026-01-15", "already anchored"),
        ]
        for c in cases {
            XCTAssertEqual(
                utcDayString(WallClock.repairedDayAnchor(c.stored)),
                c.intended,
                "repair of \(c.note)"
            )
        }
    }

    /// The migration is allowed to run again — on a retry after a failed save,
    /// or on a value arriving from a peer that already migrated.
    func testRepairIsIdempotent() {
        for c in [utc(2026, 9, 1, 16, 0), utc(2026, 9, 2, 18, 30), utc(2026, 9, 4, 5, 0)] {
            let once = WallClock.repairedDayAnchor(c)
            let twice = WallClock.repairedDayAnchor(once)
            let thrice = WallClock.repairedDayAnchor(twice)
            XCTAssertEqual(once, twice, "second run moved the value")
            XCTAssertEqual(once, thrice, "third run moved the value")
            XCTAssertTrue(WallClock.isDayAnchored(once), "repair did not land on UTC midnight")
        }
    }

    // MARK: - The regression itself

    /// The headline assertion. One fixed stored value names the same calendar
    /// day in every zone. This is what the old storage could not do.
    func testAnAnchoredDayNamesTheSameCalendarDayInEveryZone() {
        let stored = utc(2026, 9, 2)   // Day 1 of the Italy trip
        for zone in zones {
            inZone(zone) {
                XCTAssertEqual(
                    deviceDayString(WallClock.deviceDay(from: stored)),
                    "2026-09-02",
                    "an anchored day read the wrong date in \(zone)"
                )
            }
        }
    }

    /// The counter-test, so the one above cannot pass for the wrong reason. The
    /// OLD write path really does move the day, and by exactly one. Delete the
    /// fix and this is the assertion that starts failing.
    func testTheOldDeviceLocalWritePathMovesTheDay() {
        // What the old code stored for "2 September" while in Singapore.
        var singapore = Calendar(identifier: .gregorian)
        singapore.timeZone = TimeZone(identifier: "Asia/Singapore")!
        let storedTheOldWay = singapore.startOfDay(for: utc(2026, 9, 2, 12, 0))

        XCTAssertEqual(utcDayString(storedTheOldWay), "2026-09-01",
                       "precondition: a Singapore midnight is the previous UTC day")

        inZone("Europe/Rome") {
            XCTAssertEqual(deviceDayString(storedTheOldWay), "2026-09-01",
                           "the old value should read one day early in Rome")
        }
        inZone("Asia/Singapore") {
            XCTAssertEqual(deviceDayString(storedTheOldWay), "2026-09-02",
                           "the old value reads correctly only in its own zone")
        }
        // And the repair fixes precisely that.
        XCTAssertEqual(utcDayString(WallClock.repairedDayAnchor(storedTheOldWay)), "2026-09-02")
    }

    /// The split day the user saw: Verona sightseeing written in India and the
    /// Verona trains written in Italy both belong to Friday 4 September, and
    /// after the repair they land in the same bucket.
    func testTheSplitVeronaDayRejoinsAfterTheRepair() {
        let sightseeingWrittenInIndia = utc(2026, 9, 3, 18, 30)
        let trainsWrittenInItaly = utc(2026, 9, 3, 22, 0)

        inZone("Europe/Rome") {
            XCTAssertNotEqual(
                deviceDayString(sightseeingWrittenInIndia),
                deviceDayString(trainsWrittenInItaly),
                "precondition: the two really did land on different days"
            )
        }

        let a = WallClock.repairedDayAnchor(sightseeingWrittenInIndia)
        let b = WallClock.repairedDayAnchor(trainsWrittenInItaly)
        XCTAssertEqual(a, b, "the two halves of the Verona day did not rejoin")
        XCTAssertEqual(utcDayString(a), "2026-09-04")
        XCTAssertTrue(WallClock.isSameStoredDay(a, b))
    }

    // MARK: - Write and read round trip

    /// Pick 2 September in any zone; store it; read it back in any other zone.
    /// The day survives all 49 combinations.
    func testPickerRoundTripSurvivesAZoneChange() {
        for writeZone in zones {
            var written: Date!
            inZone(writeZone) {
                // What a DatePicker set to 2 Sep hands the editor.
                let picked = Calendar.current.date(
                    from: DateComponents(year: 2026, month: 9, day: 2, hour: 14, minute: 30)
                )!
                written = WallClock.dayAnchor(from: picked)
            }
            XCTAssertEqual(utcDayString(written), "2026-09-02",
                           "written in \(writeZone)")
            XCTAssertTrue(WallClock.isDayAnchored(written),
                          "a picked day must be stored at UTC midnight, not with its time")

            for readZone in zones {
                inZone(readZone) {
                    XCTAssertEqual(
                        deviceDayString(WallClock.deviceDay(from: written)),
                        "2026-09-02",
                        "written in \(writeZone), read in \(readZone)"
                    )
                }
            }
        }
    }

    // MARK: - The ISO write path

    /// The extractors and the tool loop hand over a string. The day is the one
    /// the model wrote, whatever offset trails it.
    func testISODayAnchorReadsTheDayAsWritten() {
        let cases = [
            "2026-09-04":                    "2026-09-04",
            "2026-09-04T14:00:00+02:00":     "2026-09-04",
            "2026-09-04T01:00:00+08:00":     "2026-09-04",
            "2026-09-04T23:30:00-05:00":     "2026-09-04",
            "2026-09-04T00:00:00Z":          "2026-09-04",
            "2026-12-31":                    "2026-12-31",
            "2026-02-29":                    "",           // not a leap year
            "2026-13-01":                    "",
            "not-a-date":                    "",
            "2026-9-4":                      "",
        ]
        // Parsing must not depend on where the device is.
        for zone in ["Asia/Singapore", "America/Los_Angeles", "UTC"] {
            inZone(zone) {
                for (input, expected) in cases {
                    let parsed = WallClock.dayAnchor(fromISO: input)
                    if expected.isEmpty {
                        XCTAssertNil(parsed, "\"\(input)\" should not parse (\(zone))")
                    } else {
                        XCTAssertEqual(parsed.map(utcDayString), expected,
                                       "\"\(input)\" in \(zone)")
                    }
                }
            }
        }
    }

    // MARK: - Day arithmetic

    /// "Day 1: Wed, 2 Sep" through "Day 11" for the real Italy range, from
    /// every zone.
    func testDayNumberingIsStableAcrossZones() {
        let start = utc(2026, 9, 2)
        let end = utc(2026, 9, 12)
        for zone in zones {
            inZone(zone) {
                XCTAssertEqual(WallClock.storedDayCount(from: start, to: start) + 1, 1, zone)
                XCTAssertEqual(WallClock.storedDayCount(from: start, to: utc(2026, 9, 4)) + 1, 3, zone)
                XCTAssertEqual(WallClock.storedDayCount(from: start, to: end) + 1, 11, zone)
            }
        }
    }

    /// A stay's nights, counted across a DST boundary. Europe moves its clocks
    /// on 25 October 2026, so a device-calendar count of these two days can
    /// come back short.
    func testDaySpanIsUnaffectedByADSTBoundary() {
        let checkIn = utc(2026, 10, 24)
        let checkOut = utc(2026, 10, 26)
        for zone in zones {
            inZone(zone) {
                XCTAssertEqual(
                    WallClock.storedDayCount(from: checkIn, to: checkOut), 2,
                    "nights miscounted in \(zone)"
                )
            }
        }
    }

    /// `storedDay(_:byAdding:)` keeps the value anchored, including over a DST
    /// boundary and a month end.
    func testAddingDaysKeepsTheValueAnchored() {
        inZone("Europe/Rome") {
            XCTAssertEqual(utcDayString(WallClock.storedDay(utc(2026, 10, 24), byAdding: 2)), "2026-10-26")
            XCTAssertEqual(utcDayString(WallClock.storedDay(utc(2026, 9, 30), byAdding: 1)), "2026-10-01")
            XCTAssertTrue(WallClock.isDayAnchored(WallClock.storedDay(utc(2026, 10, 24), byAdding: 2)))
        }
    }

    /// "Today" is whichever day the DEVICE says it is — that part is meant to be
    /// local — but the result is anchored so it can be compared against stored
    /// days. A fixed `now` is passed in rather than reading the clock, or the
    /// test would flake for one second a day at local midnight.
    func testTodayAnchorNamesTheDeviceDayAndIsAnchored() {
        // 2026-09-02 20:00Z. Already 3 Sep in Singapore, still 2 Sep in Rome
        // and in New York — so the three zones must disagree, and each must
        // agree with its own device calendar.
        let now = utc(2026, 9, 2, 20, 0)
        let expected = [
            "Asia/Singapore":    "2026-09-03",
            "Asia/Kolkata":      "2026-09-03",
            "Europe/Rome":       "2026-09-02",
            "America/New_York":  "2026-09-02",
            "UTC":               "2026-09-02",
        ]
        for (zone, day) in expected {
            inZone(zone) {
                let today = WallClock.todayAnchor(now: now)
                XCTAssertTrue(WallClock.isDayAnchored(today),
                              "todayAnchor was not anchored in \(zone)")
                XCTAssertEqual(utcDayString(today), day,
                               "todayAnchor named the wrong day in \(zone)")
                XCTAssertEqual(utcDayString(today), deviceDayString(now),
                               "todayAnchor disagreed with the device calendar in \(zone)")
            }
        }
    }
}
