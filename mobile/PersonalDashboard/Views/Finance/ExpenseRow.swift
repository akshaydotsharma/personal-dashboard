import SwiftUI
import SwiftData

/// Single-row presentation of a `LocalExpense`. Tap → edit (handler passed
/// in by the parent so we don't couple the row to a sheet binding).
struct ExpenseRow: View {
    let expense: LocalExpense
    /// When true the row leads with the amount in the currency the expense was
    /// CAPTURED in, and the converted display-currency figure becomes the
    /// sub-label (trip surfaces default to as-added amounts, #258). False —
    /// the Finance list — keeps the display-currency-first layout.
    var showsOriginalFirst: Bool = false
    let onTap: () -> Void

    /// People (for the tagged person's chip colour) and trips (so a trip-tagged
    /// row in the FINANCE list can name its trip, #264), resolved once for the
    /// whole list by `ExpenseRowLookupScope` (#442).
    ///
    /// These used to be two `@Query`s declared right here. Per row that is a
    /// tiny fetch; across a full-year Finance list it was ~3,040 fetches for
    /// eight records, all of which had to be set up before the first frame.
    @Environment(\.expenseRowLookup) private var lookup: ExpenseRowLookup

    var body: some View {
        // Resolved once per paint and threaded through: `expense.splits`
        // decodes JSON, and the badge row, the badge-row gate and the
        // accessibility label all need the answer (#508 / the #442 lesson).
        let roster = splitRoster
        return HStack(spacing: Space.md) {
            Image(systemName: expense.categoryEnum.sfSymbol)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Tokens.accentFinance)
                .frame(width: RowMetrics.iconChip, height: RowMetrics.iconChip)
                .background(Tokens.paper2, in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(primaryLine)
                    .font(.edBody)
                    .foregroundStyle(Tokens.ink)
                    .lineLimit(1)
                if let secondary = secondaryLine {
                    Text(secondary)
                        .font(.edCaption)
                        .foregroundStyle(Tokens.muted)
                        .lineLimit(1)
                }
                // Statement attribution (#189): which imported statement this
                // row came off, e.g. "May 2026 Citi - 1234". Only shown for
                // statement-sourced rows that captured a header — a small
                // secondary caption that never clutters other rows.
                if let statement = expense.statementLabel.trimmedNonEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 9, weight: .regular))
                        Text(statement)
                            .lineLimit(1)
                    }
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
                }
                if hasBadges(roster) {
                    badgeRow(roster)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                // Refunds are money coming IN: shown in the success (green)
                // colour with a leading "+" so they read as a credit against
                // spend, distinct from a normal debit (#206).
                Text(showsOriginalFirst ? originalAmountLabel : sgdAmountLabel)
                    .font(.edBodyMedium)
                    .monospacedDigit()
                    .foregroundStyle(expense.isRefund ? Tokens.success : Tokens.ink)
                if showsOriginalAmount {
                    Text(showsOriginalFirst ? sgdAmountLabel : originalAmountLabel)
                        .font(.edCaption)
                        .monospacedDigit()
                        .foregroundStyle(expense.isRefund ? Tokens.success.opacity(0.8) : Tokens.mutedSoft)
                }
            }
        }
        // Same shared construction as every other record row. Expense rows keep
        // their own 10pt iOS padding, which is why the modifier takes it.
        .flatContentRow(iOSVerticalPadding: Space.sm + 2)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityLabel(accessibilityLabel(roster))
    }

    // MARK: - Person / Event badges (#183)

    private var personLabel: String? {
        expense.personName?.trimmedNonEmpty
    }

    private var eventLabel: String? {
        expense.eventName?.trimmedNonEmpty
    }

    private var hasTags: Bool {
        personLabel != nil || eventLabel != nil
    }

    /// Whether any badge (person, event, split, trip, or split avatars) should
    /// render on the secondary badge row.
    private func hasBadges(_ roster: SplitAvatarRoster?) -> Bool {
        hasTags || expense.isSplit || showsTripBadge || roster != nil
    }

    /// Who paid and who shared, for a trip expense (#508). Trip surfaces only:
    /// the Finance list already carries a trip badge naming the trip and the
    /// full bill, and its rows include every ordinary expense, which has no
    /// payer or split to describe. `nil` whenever there is nothing to say.
    private var splitRoster: SplitAvatarRoster? {
        guard showsOriginalFirst else { return nil }
        return SplitAvatarRoster.make(
            payerPersonUUID: expense.paidByPersonUUID,
            splits: expense.splits,
            name: { lookup.personName(uuid: $0) },
            colorHex: { lookup.personColorHex(uuid: $0) }
        )
    }

    /// The Finance list leads with the user's SHARE of a group-split trip
    /// expense (#264) — the full bill belongs to the trip surface. Trip
    /// surfaces (original-first) keep leading with the full amount, where the
    /// existing "your X of Y" badge carries the share.
    private var leadsWithShare: Bool {
        !showsOriginalFirst && expense.isGroupSplit
    }

    /// Finance-list rows reference the trip a row belongs to (#264). Trip
    /// surfaces don't — the whole screen IS the trip.
    private var showsTripBadge: Bool {
        !showsOriginalFirst && expense.tripUUID != nil
    }

    /// Split badge label, e.g. "1/3 of SGD 90.00" (#188). Shows the user's
    /// fraction of the derived receipt total in SGD so it lines up with the
    /// primary SGD amount above it.
    private var splitLabel: String {
        "1/\(expense.numberOfShares) of \(FinanceDashboardBand.formatMoney(expense.receiptTotalSGD))"
    }

    /// The tagged person's chip colour, resolved from the live person record
    /// (matched by FK, falling back to name). Defaults to the finance accent
    /// if the person was deleted but its denormalised name survives on the row.
    private var personTint: Color {
        guard let hex = lookup.personColorHex(uuid: expense.personUUID, name: personLabel) else {
            return Tokens.accentFinance
        }
        return Color(personHex: hex)
    }

    private func badgeRow(_ roster: SplitAvatarRoster?) -> some View {
        HStack(spacing: Space.xs) {
            if let personLabel {
                PersonEventBadge(kind: .person, label: personLabel, tint: personTint)
            }
            if let eventLabel {
                PersonEventBadge(kind: .event, label: eventLabel)
            }
            if expense.isSplit {
                splitBadge
            }
            if showsTripBadge {
                tripBadge
            }
            if let roster {
                SplitAvatarCluster(roster: roster)
            }
        }
    }

    /// Trip-reference badge on FINANCE rows (#264): names the trip, and — for
    /// a group split, where the primary amount above is the user's share —
    /// carries the full bill so the whole picture stays on the row
    /// ("Italy · of S$300.00"). Replaces `groupSplitBadge` in the Finance list.
    private var tripBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "airplane")
                .font(.system(size: 9, weight: .semibold))
            Text(tripBadgeLabel)
                .font(.edCaption)
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(Tokens.muted)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Tokens.muted.opacity(0.12), in: Capsule())
        .accessibilityLabel("Trip expense, \(tripBadgeLabel)")
    }

    private var tripName: String {
        guard let name = lookup.tripName(uuid: expense.tripUUID) else { return "Trip" }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Trip" : trimmed
    }

    private var tripBadgeLabel: String {
        guard expense.isGroupSplit else { return tripName }
        return "\(tripName) · of \(FinanceDashboardBand.formatMoney(expense.sgdAmount))"
    }

    /// Split badge (#188). Same capsule shape as `PersonEventBadge` but muted
    /// (it's a factual annotation, not a colour-coded tag), with a split-bill
    /// glyph and the "your share of receipt total" label.
    private var splitBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 9, weight: .semibold))
            Text(splitLabel)
                .font(.edCaption)
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(Tokens.muted)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Tokens.muted.opacity(0.12), in: Capsule())
        .accessibilityLabel("Split \(expense.numberOfShares) ways, your \(splitLabel)")
    }

    private var primaryLine: String {
        if let merchant = expense.merchant?.trimmedNonEmpty {
            return merchant
        }
        if let description = expense.expenseDescription?.trimmedNonEmpty {
            return description
        }
        return expense.categoryEnum.displayName
    }

    /// Secondary line: category name (if not already the primary) +
    /// description (if not already the primary).
    private var secondaryLine: String? {
        var pieces: [String] = []

        // Always show the category as a kind of tag-line — unless the
        // primary already IS the category fallback.
        let isCategoryPrimary = expense.merchant?.trimmedNonEmpty == nil &&
                                expense.expenseDescription?.trimmedNonEmpty == nil
        if !isCategoryPrimary {
            pieces.append(expense.categoryEnum.displayName)
        }

        // If both merchant and description exist, surface description on
        // the secondary line. Otherwise leave it.
        if let _ = expense.merchant?.trimmedNonEmpty,
           let description = expense.expenseDescription?.trimmedNonEmpty {
            pieces.append(description)
        }

        return pieces.isEmpty ? nil : pieces.joined(separator: " · ")
    }

    /// Primary SGD amount, with a leading "+" for refunds so a credit is
    /// unmistakable at a glance (the colour alone isn't enough for the
    /// colour-blind, and "+" carries the meaning in VoiceOver too) (#206).
    /// In the Finance list a group-split trip expense shows the user's SHARE
    /// (#264) — matching the share-based totals around it — with the full bill
    /// relegated to the trip badge.
    private var sgdAmountLabel: String {
        let value = leadsWithShare ? abs(expense.myShareSGD) : expense.sgdAmount
        let base = FinanceDashboardBand.formatMoney(value)
        return expense.isRefund ? "+\(base)" : base
    }

    /// Show the original-currency sub-label whenever the expense was captured
    /// in a currency other than the one we're displaying totals in. Previously
    /// hardcoded against "SGD"; now compares against the chosen display
    /// currency so, e.g., a USD expense shown while the display currency is USD
    /// hides the redundant sub-label, and an SGD expense shown while displaying
    /// EUR surfaces the "SGD …" original.
    private var showsOriginalAmount: Bool {
        expense.originalCurrency.uppercased() != FinanceSettings.displayCurrencyCode.uppercased()
    }

    private var originalAmountLabel: String {
        // Same share-first rule as `sgdAmountLabel` (#264): when the Finance
        // list leads with the user's share, the original-currency sub-label
        // shows the share too, so the two figures describe the same money.
        let value = leadsWithShare ? abs(expense.myShareOriginal) : expense.originalAmount
        // Shared cached formatter (#442): this used to build a NumberFormatter
        // per row, per paint.
        let formatter = FinanceFormatters.decimal(fractionDigits: 2)
        let amount = formatter.string(from: NSNumber(value: value)) ?? "\(value)"
        let base = "\(expense.originalCurrency.uppercased()) \(amount)"
        return expense.isRefund ? "+\(base)" : base
    }

    private func accessibilityLabel(_ roster: SplitAvatarRoster?) -> String {
        let spokenValue = leadsWithShare ? abs(expense.myShareSGD) : expense.sgdAmount
        let amountSpoken = expense.isRefund
            ? "refund \(FinanceDashboardBand.formatMoney(spokenValue))"
            : FinanceDashboardBand.formatMoney(spokenValue)
        var pieces: [String] = [primaryLine, amountSpoken, expense.categoryEnum.displayName]
        if showsOriginalAmount {
            pieces.append("\(originalAmountLabel) original")
        }
        if let statement = expense.statementLabel.trimmedNonEmpty {
            pieces.append("from \(statement)")
        }
        if let personLabel { pieces.append("for \(personLabel)") }
        if let eventLabel { pieces.append("event \(eventLabel)") }
        if showsTripBadge { pieces.append("on trip \(tripName)") }
        if expense.isSplit { pieces.append("split \(expense.numberOfShares) ways, your \(splitLabel)") }
        if let roster { pieces.append(roster.spokenLabel) }
        return pieces.joined(separator: ", ") + ". Tap to edit."
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
