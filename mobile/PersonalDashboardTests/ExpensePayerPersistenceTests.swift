import XCTest
import SwiftData
@testable import PersonalDashboard

/// A payer on an UNSPLIT trip expense (#504).
///
/// The defect survived a build and a screenshot because nothing failed. The
/// `Paid by` picker was rendered, it accepted "Papa", the sheet closed, and the
/// save wrote `nil` anyway: `applyTripSplit` only assigned the payer inside its
/// split branch, and a "Just you" expense always took the other one. Reopening
/// read that `nil` back and drew "You", so the choice appeared to revert.
///
/// Fixing the write alone is not enough, which is why the balance half is
/// asserted too. `LocalExpense.myShareSGD` treats an unsplit expense as the
/// user's cost in full, while `TripSettlement.totals` credited it to the payer.
/// The two agreed only while an unsplit row implied the user paid. Once another
/// person can front one, crediting the payer nets the row to zero and hides a
/// real debt, at the same time as Finance counts the amount as the user's spend.
@MainActor
final class ExpensePayerPersistenceTests: XCTestCase {

    private let papa = UUID()
    private let trip = UUID()

    private func unsplitExpense(paidBy: UUID?) -> LocalExpense {
        LocalExpense(
            category: "bills_and_utilities",
            merchant: "Small Cash - Change Payer",
            originalAmount: 20,
            originalCurrency: "EUR",
            sgdAmount: 29.46,
            fxRate: 1.473,
            source: "manual",
            tripUUID: trip,
            paidByPersonUUID: paidBy
        )
    }

    // MARK: - The row can hold the state at all

    /// The shape the fixed save path now produces: no split entries, and a payer
    /// who is not the user. Before #504 this combination did not exist in the
    /// store, in 1,828 rows.
    func testUnsplitExpenseCanCarryAnotherPayer() {
        let expense = unsplitExpense(paidBy: papa)
        XCTAssertTrue(expense.splits.isEmpty)
        XCTAssertEqual(expense.paidByPersonUUID, papa)
        XCTAssertFalse(expense.isGroupSplit)
    }

    /// Clearing the payer back to "You" must still store nil, not a stale id.
    func testUnsplitExpenseWithoutAPayerStaysNil() {
        XCTAssertNil(unsplitExpense(paidBy: nil).paidByPersonUUID)
    }

    // MARK: - Finance is untouched

    /// The user's share of an unsplit expense is the whole amount regardless of
    /// who fronted it. This is the invariant the balance change is aligned to,
    /// so it must not move.
    func testMyShareIsTheFullAmountWhoeverPaid() {
        XCTAssertEqual(unsplitExpense(paidBy: papa).myShareSGD, 29.46, accuracy: 0.001)
        XCTAssertEqual(unsplitExpense(paidBy: nil).myShareSGD, 29.46, accuracy: 0.001)
    }

    // MARK: - Settle-up agrees with Finance

    /// The regression. Before the fix `owed` went to the payer, so Papa was both
    /// paid and owed 29.46, the row netted to zero, and the debt vanished.
    func testUnsplitExpensePaidByAnotherPersonIsOwedByTheUser() {
        let totals = TripSettlement.totals(expenses: [unsplitExpense(paidBy: papa)])

        XCTAssertEqual(totals[.person(papa)]?.paid ?? 0, 29.46, accuracy: 0.001)
        XCTAssertEqual(totals[.person(papa)]?.owed ?? 0, 0, accuracy: 0.001)
        XCTAssertEqual(totals[.me]?.paid ?? 0, 0, accuracy: 0.001)
        XCTAssertEqual(totals[.me]?.owed ?? 0, 29.46, accuracy: 0.001)
    }

    /// The user owes Papa the full amount, and the group still nets to zero.
    func testTheUserOwesThePayerTheWholeAmount() {
        let balances = TripSettlement.compute(expenses: [unsplitExpense(paidBy: papa)])

        let mine = balances.first { $0.party == .me }
        let theirs = balances.first { $0.party == .person(papa) }
        XCTAssertEqual(mine?.net ?? 0, -29.46, accuracy: 0.001)
        XCTAssertEqual(theirs?.net ?? 0, 29.46, accuracy: 0.001)
        XCTAssertEqual(balances.reduce(0) { $0 + $1.net }, 0, accuracy: 0.001)
    }

    /// Every expense already in the store is unsplit with a nil payer, or split.
    /// The unsplit-and-nil case must behave exactly as before: the user pays and
    /// owes it, it nets to zero, and no balance is raised.
    func testExistingUnsplitRowsAreUnaffected() {
        let totals = TripSettlement.totals(expenses: [unsplitExpense(paidBy: nil)])
        XCTAssertEqual(totals[.me]?.paid ?? 0, 29.46, accuracy: 0.001)
        XCTAssertEqual(totals[.me]?.owed ?? 0, 29.46, accuracy: 0.001)
        XCTAssertTrue(TripSettlement.compute(expenses: [unsplitExpense(paidBy: nil)]).isEmpty)
    }

    /// A split expense is untouched by the change: the shares still decide who
    /// owes what, and the payer still only affects `paid`.
    func testSplitExpenseStillDividesByShares() {
        let expense = unsplitExpense(paidBy: papa)
        expense.splits = [
            ExpenseSplitEntry(person: nil, shares: 1),
            ExpenseSplitEntry(person: papa, shares: 1),
        ]
        let totals = TripSettlement.totals(expenses: [expense])

        XCTAssertEqual(totals[.me]?.owed ?? 0, 14.73, accuracy: 0.001)
        XCTAssertEqual(totals[.person(papa)]?.owed ?? 0, 14.73, accuracy: 0.001)
        XCTAssertEqual(totals[.person(papa)]?.paid ?? 0, 29.46, accuracy: 0.001)
    }
}
