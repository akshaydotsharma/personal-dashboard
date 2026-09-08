import XCTest
@testable import DexterMac

/// The rules behind the payer / sharer avatars on a trip expense row (#508).
///
/// The roster is the whole decision — who shows, in what order, when nothing
/// shows at all — so it lives apart from the view and is tested directly.
final class SplitAvatarRosterTests: XCTestCase {

    private let priya = UUID()
    private let sam = UUID()

    private func names(_ pairs: [UUID: String]) -> (UUID) -> String? {
        { pairs[$0] }
    }

    private func colors(_ pairs: [UUID: String]) -> (UUID) -> String? {
        { pairs[$0] }
    }

    // MARK: - The payer and the split always both show

    /// A blank badge line can't be told apart from a row with nothing
    /// recorded, so the coincidence cases render like any other.
    func testNoRecordedSplitMakesThePayerTheSoleSharer() throws {
        let roster = SplitAvatarRoster.make(
            payerPersonUUID: nil,
            splits: [],
            name: names([:]),
            colorHex: colors([:])
        )
        XCTAssertEqual(roster.payer.initial, "Y")
        XCTAssertEqual(roster.sharers.map(\.initial), ["Y"])
    }

    func testASplitHoldingOnlyTheUserStillShows() throws {
        let roster = SplitAvatarRoster.make(
            payerPersonUUID: nil,
            splits: [ExpenseSplitEntry(person: nil, shares: 1)],
            name: names([:]),
            colorHex: colors([:])
        )
        XCTAssertEqual(roster.payer.initial, "Y")
        XCTAssertEqual(roster.sharers.map(\.initial), ["Y"])
        XCTAssertEqual(roster.spokenLabel, "You paid", "Speech should not repeat what the avatars show")
    }

    func testASplitHoldingOnlyThePayingParticipantStillShows() throws {
        let roster = SplitAvatarRoster.make(
            payerPersonUUID: priya,
            splits: [ExpenseSplitEntry(person: priya, shares: 1)],
            name: names([priya: "Priya"]),
            colorHex: colors([priya: "6366F1"])
        )
        XCTAssertEqual(roster.payer.initial, "P")
        XCTAssertEqual(roster.sharers.map(\.initial), ["P"])
        XCTAssertEqual(roster.spokenLabel, "Priya paid")
    }

    func testZeroShareEntriesAreNotSharers() {
        let roster = SplitAvatarRoster.make(
            payerPersonUUID: nil,
            splits: [
                ExpenseSplitEntry(person: nil, shares: 1),
                ExpenseSplitEntry(person: priya, shares: 0)
            ],
            name: names([priya: "Priya"]),
            colorHex: colors([priya: "6366F1"])
        )
        XCTAssertEqual(
            roster.sharers.map(\.initial), ["Y"],
            "A party ticked out of the bill keeps a zero-share row behind"
        )
    }

    // MARK: - Payer

    func testParticipantPayerShowsWithoutASplit() throws {
        let roster = SplitAvatarRoster.make(
            payerPersonUUID: priya,
            splits: [],
            name: names([priya: "Priya"]),
            colorHex: colors([priya: "6366F1"])
        )
        XCTAssertEqual(roster.payer.initial, "P")
        XCTAssertEqual(roster.payer.colorHex, "6366F1")
        XCTAssertEqual(roster.sharers.map(\.initial), ["P"], "Priya paid it and consumed it")
        XCTAssertEqual(roster.spokenLabel, "Priya paid")
    }

    func testUserPayerIsTheLetterY() throws {
        let roster = SplitAvatarRoster.make(
            payerPersonUUID: nil,
            splits: [
                ExpenseSplitEntry(person: nil, shares: 1),
                ExpenseSplitEntry(person: priya, shares: 1)
            ],
            name: names([priya: "Priya"]),
            colorHex: colors([priya: "6366F1"])
        )
        XCTAssertEqual(roster.payer.party, .me)
        XCTAssertEqual(roster.payer.initial, "Y")
        XCTAssertNil(roster.payer.colorHex, "The user wears the finance accent, not a person colour")
    }

    // MARK: - Sharers

    func testPayerLeadsTheSharerCluster() throws {
        let roster = SplitAvatarRoster.make(
            payerPersonUUID: sam,
            splits: [
                ExpenseSplitEntry(person: nil, shares: 1),
                ExpenseSplitEntry(person: priya, shares: 1),
                ExpenseSplitEntry(person: sam, shares: 1)
            ],
            name: names([priya: "Priya", sam: "Sam"]),
            colorHex: colors([priya: "6366F1", sam: "F59E0B"])
        )
        XCTAssertEqual(roster.sharers.map(\.initial), ["S", "Y", "P"])
        XCTAssertEqual(roster.spokenLabel, "Sam paid, split between Sam, you, and Priya")
    }

    func testOneSharerWhoIsNotThePayerStillShowsTheCluster() throws {
        let roster = SplitAvatarRoster.make(
            payerPersonUUID: nil,
            splits: [ExpenseSplitEntry(person: priya, shares: 1)],
            name: names([priya: "Priya"]),
            colorHex: colors([priya: "6366F1"])
        )
        XCTAssertEqual(roster.sharers.map(\.initial), ["P"], "The user paid and Priya owes all of it")
    }

    func testDuplicateEntriesForOnePersonCollapse() throws {
        let roster = SplitAvatarRoster.make(
            payerPersonUUID: priya,
            splits: [
                ExpenseSplitEntry(person: priya, shares: 1),
                ExpenseSplitEntry(person: priya, shares: 2)
            ],
            name: names([priya: "Priya"]),
            colorHex: colors([priya: "6366F1"])
        )
        XCTAssertEqual(roster.sharers.count, 1)
    }

    func testDeletedPersonReadsAsSomeone() throws {
        let roster = SplitAvatarRoster.make(
            payerPersonUUID: priya,
            splits: [],
            name: names([:]),
            colorHex: colors([:])
        )
        XCTAssertEqual(roster.payer.initial, "?")
        XCTAssertEqual(roster.payer.name, "Someone")
        XCTAssertNil(roster.payer.colorHex)
        XCTAssertEqual(roster.sharers.map(\.initial), ["?"])
    }

    // MARK: - Cap

    func testMoreThanFourSharersCollapseIntoACounter() throws {
        let extras = (0..<5).map { _ in UUID() }
        var lookup: [UUID: String] = [:]
        for (index, id) in extras.enumerated() { lookup[id] = "Person \(index)" }
        let roster = SplitAvatarRoster.make(
            payerPersonUUID: nil,
            splits: [ExpenseSplitEntry(person: nil, shares: 1)]
                + extras.map { ExpenseSplitEntry(person: $0, shares: 1) },
            name: names(lookup),
            colorHex: colors([:])
        )
        XCTAssertEqual(roster.sharers.count, 6)
        XCTAssertEqual(roster.visibleSharers.count, 4)
        XCTAssertEqual(roster.overflowCount, 2)
    }

    // MARK: - Initials and ink

    func testInitialIsGraphemeSafeAndUppercased() {
        XCTAssertEqual(SplitAvatarRoster.initial(of: "  priya "), "P")
        XCTAssertEqual(SplitAvatarRoster.initial(of: "आकाश"), "आ")
        XCTAssertEqual(SplitAvatarRoster.initial(of: ""), "?")
    }

    /// The person palette spans a dark indigo to a bright amber, so a single
    /// on-fill ink cannot stay legible across it. The choice is the better of
    /// the two WCAG contrast ratios, so the assertion here is that every
    /// palette colour reaches at least 4.5:1 with the ink it gets.
    func testEveryPaletteColourGetsTheHigherContrastInk() {
        for hex in PersonService.palette {
            let party = SplitAvatarParty(party: .person(UUID()), name: "X", colorHex: hex, initial: "X")
            let fill = try? XCTUnwrap(SplitAvatarRoster.relativeLuminance(hex: hex))
            let luminance = try! XCTUnwrap(fill)
            let dark = SplitAvatarRoster.contrastRatio(luminance, SplitAvatarRoster.darkInkLuminance)
            let light = SplitAvatarRoster.contrastRatio(luminance, 1.0)
            let chosen = party.prefersDarkInk == true ? dark : light
            XCTAssertEqual(party.prefersDarkInk, dark > light, "\(hex) took the weaker ink")
            XCTAssertGreaterThanOrEqual(chosen, 4.5, "\(hex) lettering falls below 4.5:1")
        }
    }

    func testTheUserAvatarLeavesTheInkToTheTheme() {
        XCTAssertNil(
            SplitAvatarParty(party: .me, name: "You", colorHex: nil, initial: "Y").prefersDarkInk,
            "The user's fill flips with the theme, so its ink has to as well"
        )
    }
}
