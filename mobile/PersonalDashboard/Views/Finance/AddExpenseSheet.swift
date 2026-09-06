import SwiftUI
import SwiftData
import PDFKit
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Cross-platform receipt image alias + loaders (issue #281). The receipt
/// viewers are backed by UIKit on iOS and AppKit on macOS; both take the
/// platform-native image type, so a single alias keeps their call sites
/// identical.
#if canImport(UIKit)
typealias ReceiptPlatformImage = UIImage
#else
typealias ReceiptPlatformImage = NSImage
#endif

/// Load a receipt image file into the platform-native image type. Returns nil
/// when the file is missing or not a decodable image (e.g. a PDF).
func loadReceiptPlatformImage(_ url: URL) -> ReceiptPlatformImage? {
    #if canImport(UIKit)
    return UIImage(contentsOfFile: url.path)
    #else
    return NSImage(contentsOfFile: url.path)
    #endif
}

extension Image {
    /// Build a SwiftUI `Image` from a receipt file on disk, cross-platform.
    /// Fails (returns nil) when the file can't be decoded as an image.
    init?(receiptFileURL url: URL) {
        guard let platformImage = loadReceiptPlatformImage(url) else { return nil }
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}

/// Editor target for the AddExpense / EditExpense sheet.
///
/// - `.new`: blank form, source defaults to `.manual`.
/// - `.existing(uuid)`: load by clientUUID, preserve receipt + source.
/// - `.prefilled(PrefilledExpense)`: seed fields from a scan/photo/PDF
///   capture (receipt already saved to disk; Vision may have failed).
enum ExpenseEditorTarget: Identifiable, Hashable {
    case new
    case existing(String)
    case prefilled(PrefilledExpense)

    var id: String {
        switch self {
        case .new:                return "new"
        case .existing(let uuid): return "existing:\(uuid)"
        case .prefilled(let p):   return "prefilled:\(p.receiptImagePath)"
        }
    }
}

/// Trip context passed to the expense sheet when adding / editing an expense
/// that belongs to a trip with participants (#258). Its presence (with a
/// non-empty participant list) swaps the #188 "split N ways" stepper for the
/// full settle-up UI: a payer picker + a per-person shares editor. Absent (the
/// Finance surface) the sheet behaves exactly as before.
struct TripExpenseContext {
    let tripUUID: UUID
    /// The trip's participants (people other than the user). Resolved by the
    /// caller from the trip's `participantPersonUUIDs`.
    let participants: [LocalPerson]
}

/// Identifies one party in a trip split: the user ("me") or a specific person.
enum SplitPartyID: Hashable {
    case me
    case person(UUID)
}

/// Editable per-party split row backing the trip split editor. `included`
/// gates whether the party is part of this bill; `shares` is their weight.
struct SplitDraft: Identifiable {
    let party: SplitPartyID
    let name: String
    /// Chip colour hex; nil for the user ("me").
    let colorHex: String?
    var included: Bool
    var shares: Int

    var id: SplitPartyID { party }
}

/// AddExpense / EditExpense form. One sheet handles create, edit, and
/// "create-from-scanned-receipt" keyed off `target`. FX conversion runs
/// on save (cached so it doesn't block on the home currency).
struct AddExpenseSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let target: ExpenseEditorTarget

    /// Optional trip context (#258). Non-nil (with participants) turns on the
    /// settle-up split UI and stamps `tripUUID` on save. Defaults to nil so the
    /// Finance call sites (`AddExpenseSheet(target:)`) are unchanged.
    var tripContext: TripExpenseContext? = nil

    /// Per-party split editor state (trip context only). Seeded in
    /// `loadIfNeeded`. Order is [You, participant, participant, …].
    @State private var splitDrafts: [SplitDraft] = []

    /// Who fronted the money. Defaults to the user.
    @State private var payerParty: SplitPartyID = .me

    @State private var amountText: String = ""
    @State private var currency: String = FinanceSettings.displayCurrencyCode
    @State private var category: ExpenseCategory = .other
    @State private var date: Date = Date()
    @State private var merchant: String = ""
    @State private var descriptionField: String = ""
    @State private var paymentMethod: String = ""

    /// Person / Event tags (#183). Nil = untagged. Held as resolved
    /// (uuid, name) pairs so save can stamp both the FK and the denormalised
    /// name. On edit these seed from the row's stored uuid/name.
    @State private var selectedPerson: ExpenseTag?
    @State private var selectedEvent: ExpenseTag?
    @State private var showingPersonPicker: Bool = false
    @State private var showingEventPicker: Bool = false

    /// Existing tags, listed inline in the Person / Event menus (#463). The
    /// picker sheet is now only the create surface, so the common case — pick
    /// one of the handful of people or events you already have — never leaves
    /// this sheet. Same sort as the picker sheet: people alphabetically,
    /// events most-recently-touched first.
    @Query(sort: [SortDescriptor(\LocalPerson.name, order: .forward)])
    private var allPeople: [LocalPerson]

    @Query(sort: [SortDescriptor(\LocalEvent.updatedAt, order: .reverse)])
    private var allEvents: [LocalEvent]

    /// How many people the bill is split among (#188). The amount field holds
    /// the RECEIPT TOTAL; on save we divide by this to get the stored per-share
    /// amount. Default 1 = not split. Clamped to 1...50 by the stepper.
    @State private var numberOfShares: Int = 1

    /// Where this expense will be tagged as having come from. Defaults to
    /// `.manual` for `.new`; carried over from the existing row on edit;
    /// set by `PrefilledExpense.source` on prefill.
    @State private var source: ExpenseSource = .manual

    /// Relative path under `Documents/`. Non-nil if a receipt is attached.
    @State private var receiptImagePath: String?

    /// Statement attribution (#189), e.g. "May 2026 Citi - 1234". Read-only —
    /// set only when editing an expense that was imported from a statement;
    /// shown as a small caption so the user can see which statement it came
    /// off. Empty for every other source.
    @State private var statementLabel: String = ""

    /// Banner state when the user came in from a failed extraction.
    @State private var extractionBanner: String?

    /// Self-reported confidence from the model. Shown as a subtle hint when
    /// `.low` so the user double-checks the amount.
    @State private var extractionConfidence: ExtractedExpense.Confidence?

    /// Full-size receipt viewer flag.
    @State private var showingReceiptViewer: Bool = false

    /// "Add to Finance" toggle for trip expenses (#277). Trip expenses are
    /// opt-in to the Finance tab: this backs `!hiddenFromFinance`. Seeded from
    /// the existing row on edit, and defaults OFF for a new trip expense (so a
    /// manually-added trip expense stays out of Finance unless flipped here).
    /// Only rendered / written for trip expenses — never touched for personal
    /// Finance expenses.
    @State private var addToFinance: Bool = false

    /// Whether the row being EDITED is a trip expense (`tripUUID != nil`),
    /// captured on load. For `.new` / `.prefilled` the trip signal is
    /// `tripContext`, so this stays false there.
    @State private var existingIsTripExpense: Bool = false

    @State private var loaded: Bool = false
    @State private var saving: Bool = false
    @State private var errorMessage: String?

    @FocusState private var amountFocused: Bool

    private var isEditing: Bool {
        if case .existing = target { return true }
        return false
    }

    private var amountValue: Double {
        Double(amountText.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    /// The user's per-person share of the entered receipt total (#188). This
    /// is what gets stored as `originalAmount`. Equal-split only in v1.
    private var perShareValue: Double {
        amountValue / Double(max(numberOfShares, 1))
    }

    private var canSave: Bool {
        amountValue > 0 && !saving
    }

    /// Show the "Add to Finance" toggle only for trip expenses (#277): a new /
    /// prefilled expense opened with a trip context, or an existing row that
    /// already belongs to a trip. Never for personal Finance expenses.
    private var showsFinanceToggle: Bool {
        tripContext != nil || existingIsTripExpense
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: Space.lg) {
                        if let extractionBanner {
                            banner(extractionBanner)
                        }
                        if receiptImagePath != nil {
                            receiptThumbnail
                        }
                        amountField
                        if extractionConfidence == .low {
                            confidenceHint
                        }
                        categoryField
                        dateField
                        merchantField
                        descriptionFieldView
                        paymentField
                        if let statement = statementLabel.trimmedNonEmpty {
                            statementAttribution(statement)
                        }
                        // The "for/with person" tag (#183) is redundant on a
                        // trip expense — "Split between" carries who it's for.
                        if tripContext == nil {
                            personField
                        }
                        eventField
                        // Trip context with participants → full settle-up split
                        // UI (payer + per-person shares). Otherwise the existing
                        // #188 "split N ways" stepper, visually unchanged.
                        if tripSplitActive {
                            tripSplitSection
                        } else {
                            sharesField
                        }

                        // Trip expenses are opt-in to Finance (#277).
                        if showsFinanceToggle {
                            financeToggleField
                        }

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.edFootnote)
                                .foregroundStyle(Tokens.danger)
                                .padding(.top, Space.sm)
                        }
                    }
                    .padding(Space.lg)
                }
            }
            .navigationTitle(navigationTitleText)
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Tokens.muted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Add") {
                        Task { await save() }
                    }
                    .disabled(!canSave)
                    .foregroundStyle(canSave ? Tokens.ink : Tokens.muted)
                }
            }
        }
        .sheet(isPresented: $showingReceiptViewer) {
            if let path = receiptImagePath {
                ReceiptFullViewer(relativePath: path)
            }
        }
        .sheet(isPresented: $showingPersonPicker) {
            PersonPickerSheet(selection: $selectedPerson, startsInCreateMode: true)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingEventPicker) {
            EventPickerSheet(selection: $selectedEvent, startsInCreateMode: true)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onAppear { loadIfNeeded() }
    }

    private var navigationTitleText: String {
        switch target {
        case .new:                return "New expense"
        case .existing:           return "Edit expense"
        case .prefilled:          return "Review expense"
        }
    }

    // MARK: - Banner + confidence hint

    private func banner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: Space.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Tokens.warning)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text("We saved your receipt")
                    .font(.edBodyMedium)
                    .foregroundStyle(Tokens.ink)
                Text(message)
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Space.md)
        .background(Tokens.warningSoft, in: RoundedRectangle(cornerRadius: Radius.md))
        .paperBorder(Tokens.warning.opacity(0.35), radius: Radius.md)
    }

    private var confidenceHint: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: "info.circle")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Tokens.muted)
            Text("Low confidence on the total — double-check the amount.")
                .font(.edCaption)
                .foregroundStyle(Tokens.muted)
        }
        .padding(.horizontal, Space.xs)
    }

    // MARK: - Receipt thumbnail

    private var receiptThumbnail: some View {
        HStack(spacing: Space.md) {
            ReceiptThumbnailImage(relativePath: receiptImagePath)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                .onTapGesture { showingReceiptViewer = true }
                .accessibilityLabel("View full receipt")

            VStack(alignment: .leading, spacing: 2) {
                Text("Receipt attached")
                    .font(.edBodyMedium)
                    .foregroundStyle(Tokens.ink)
                Text("Tap to view")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.muted)
            }
            Spacer()
            Button {
                removeReceipt()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Tokens.danger)
                    .padding(8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove receipt")
        }
        .padding(Space.md)
        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
        .paperBorder(Tokens.border, radius: Radius.md)
    }

    private func removeReceipt() {
        guard let path = receiptImagePath else { return }
        try? ReceiptStorage.shared.delete(relativePath: path)
        receiptImagePath = nil
        // If we still have the prefilled banner up, hide it — the user has
        // chosen to start over without the receipt context.
        extractionBanner = nil
    }

    // MARK: - Fields

    private var amountField: some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            Text("Amount").eyebrow()
            HStack(spacing: Space.sm) {
                TextField("0.00", text: $amountText)
                    .paperFieldOnMac()
                    .decimalKeyboard()
                    .font(.edDisplay)
                    .foregroundStyle(Tokens.ink)
                    .focused($amountFocused)
                    .padding(.vertical, Space.sm)
                    .padding(.horizontal, Space.md)
                    .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
                    .paperBorder(Tokens.border, radius: Radius.md)

                Menu {
                    ForEach(SupportedCurrency.all, id: \.self) { code in
                        Button(code) { currency = code }
                    }
                } label: {
                    HStack(spacing: Space.sm) {
                        Text(currency)
                            .font(.edBodyMedium)
                            .foregroundStyle(Tokens.ink)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Tokens.muted)
                    }
                    .contentShape(Rectangle())
                }
                .paperMenuOnMac()
                .dropdownFieldSurface(fullWidth: false)
                .frame(height: 52)
                .accessibilityLabel("Currency")
            }
        }
    }

    private var categoryField: some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            Text("Category").eyebrow()
            Menu {
                ForEach(ExpenseCategory.allCases) { cat in
                    Button {
                        category = cat
                    } label: {
                        Label(cat.displayName, systemImage: cat.sfSymbol)
                    }
                }
            } label: {
                HStack(spacing: Space.sm) {
                    Image(systemName: category.sfSymbol)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Tokens.accentFinance)
                        .frame(width: 24)
                    Text(category.displayName)
                        .font(.edBody)
                        .foregroundStyle(Tokens.ink)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Tokens.muted)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .paperMenuOnMac()
            .dropdownFieldSurface()
            .accessibilityLabel("Category")
        }
    }

    private var dateField: some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            Text("Date").eyebrow()
            HStack {
                Text("When did this happen?")
                    .font(.edBody)
                    .foregroundStyle(Tokens.inkSoft)
                Spacer()
                DatePicker("", selection: $date, in: ...Date(), displayedComponents: .date)
                    .paperDatePickerOnMac()
                    .labelsHidden()
                    .tint(Tokens.accentFinance)
            }
            .padding(Space.md)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
            .paperBorder(Tokens.border, radius: Radius.md)
        }
    }

    private var merchantField: some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            HStack {
                Text("Merchant").eyebrow()
                Spacer()
                Text("Optional")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
            }
            TextField("e.g. Starbucks", text: $merchant)
                .paperFieldOnMac()
                .font(.edBody)
                .foregroundStyle(Tokens.ink)
                .padding(Space.md)
                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
                .paperBorder(Tokens.border, radius: Radius.md)
        }
    }

    private var descriptionFieldView: some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            HStack {
                Text("Description").eyebrow()
                Spacer()
                Text("Optional")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
            }
            TextField("Lunch with Sarah", text: $descriptionField)
                .paperFieldOnMac()
                .font(.edBody)
                .foregroundStyle(Tokens.ink)
                .padding(Space.md)
                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
                .paperBorder(Tokens.border, radius: Radius.md)
        }
    }

    private var paymentField: some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            HStack {
                Text("Payment method").eyebrow()
                Spacer()
                Text("Optional")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
            }
            TextField("Cash, Visa **1234, …", text: $paymentMethod)
                .paperFieldOnMac()
                .font(.edBody)
                .foregroundStyle(Tokens.ink)
                .padding(Space.md)
                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
                .paperBorder(Tokens.border, radius: Radius.md)
        }
    }

    /// "Add to Finance" toggle for trip expenses (#277). A trip expense lives on
    /// its trip's tab regardless; this only controls whether it also counts in
    /// the Finance tab's totals. Written to `hiddenFromFinance` on save.
    private var financeToggleField: some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            Text("Finance").eyebrow()
            Toggle(isOn: $addToFinance) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add to Finance")
                        .font(.edBody)
                        .foregroundStyle(Tokens.ink)
                    Text("Count this in your Finance totals")
                        .font(.edCaption)
                        .foregroundStyle(Tokens.mutedSoft)
                }
            }
            .tint(Tokens.accentFinance)
            .padding(Space.md)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
            .paperBorder(Tokens.border, radius: Radius.md)
        }
    }

    /// Read-only statement attribution caption (#189). Mirrors the receipt
    /// thumbnail's flat-surface treatment but text-only — it's provenance, not
    /// an editable field, so it sits below the inputs as a quiet footnote.
    private func statementAttribution(_ statement: String) -> some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "doc.text")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Tokens.muted)
            VStack(alignment: .leading, spacing: 2) {
                Text("Imported from statement")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
                Text(statement)
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.inkSoft)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(Space.md)
        .background(Tokens.surface2, in: RoundedRectangle(cornerRadius: Radius.md))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Imported from statement \(statement)")
    }

    // MARK: - Person / Event tags (#183)

    private var personField: some View {
        tagSelectorRow(
            label: "Person",
            icon: "person",
            placeholder: "Who was this for?",
            value: selectedPerson?.name,
            onClear: { selectedPerson = nil }
        ) {
            if selectedPerson != nil {
                Button("None") { selectedPerson = nil }
                Divider()
            }
            ForEach(allPeople, id: \.clientUUID) { person in
                Button(person.name) {
                    selectedPerson = ExpenseTag(uuid: person.clientUUID, name: person.name)
                }
            }
            if !allPeople.isEmpty { Divider() }
            Button {
                showingPersonPicker = true
            } label: {
                Label("New person…", systemImage: "plus.circle")
            }
        }
    }

    private var eventField: some View {
        tagSelectorRow(
            label: "Event",
            icon: "calendar",
            placeholder: "Which occasion or trip?",
            value: selectedEvent?.name,
            onClear: { selectedEvent = nil }
        ) {
            if selectedEvent != nil {
                Button("None") { selectedEvent = nil }
                Divider()
            }
            ForEach(allEvents, id: \.clientUUID) { event in
                Button(event.name) {
                    selectedEvent = ExpenseTag(uuid: event.clientUUID, name: event.name)
                }
            }
            if !allEvents.isEmpty { Divider() }
            Button {
                showingEventPicker = true
            } label: {
                Label("New event…", systemImage: "plus.circle")
            }
        }
    }

    // MARK: - Split shares (#188)

    /// A stepper for how many people the bill is split among, plus a live
    /// "Your share" readout so the user sees exactly what will be stored
    /// before saving. The amount field holds the receipt total; the stored
    /// expense is `total ÷ shares`. Sits below Person / Event because it's the
    /// same "who was this with" mental model — the split follows the people.
    private var sharesField: some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            HStack {
                Text("Split").eyebrow()
                Spacer()
                Text("Optional")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
            }
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack(spacing: Space.sm) {
                    Image(systemName: "person.2")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Tokens.accentFinance)
                        .frame(width: 24)
                    Text(numberOfShares == 1 ? "Not split" : "Split \(numberOfShares) ways")
                        .font(.edBody)
                        .foregroundStyle(numberOfShares == 1 ? Tokens.inkSoft : Tokens.ink)
                    Spacer()
                    Stepper(
                        "",
                        value: $numberOfShares,
                        in: 1...50
                    )
                    .labelsHidden()
                    .tint(Tokens.accentFinance)
                }

                if numberOfShares > 1 {
                    shareReadout
                }
            }
            .padding(Space.md)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
            .paperBorder(Tokens.border, radius: Radius.md)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(numberOfShares == 1 ? "Split: not split" : "Split \(numberOfShares) ways")
    }

    /// "Your share: CUR X of CUR Y" line shown only when the bill is split.
    /// Amounts are in the entered currency (pre-FX) so it reads back exactly
    /// what the user typed divided by the number of people.
    private var shareReadout: some View {
        let cur = currency.uppercased()
        return HStack(spacing: 4) {
            Text("Your share:")
                .font(.edCaption)
                .foregroundStyle(Tokens.muted)
            Text("\(cur) \(formatShare(perShareValue))")
                .font(.edCaption)
                .monospacedDigit()
                .foregroundStyle(Tokens.ink)
            Text("of \(cur) \(formatShare(amountValue))")
                .font(.edCaption)
                .monospacedDigit()
                .foregroundStyle(Tokens.mutedSoft)
        }
    }

    private func formatShare(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    // MARK: - Trip split (#258)

    /// True when a trip context with at least one participant is active — the
    /// signal to swap in the settle-up UI.
    private var tripSplitActive: Bool {
        if let tripContext { return !tripContext.participants.isEmpty }
        return false
    }

    /// Parties currently sharing the bill (included, positive shares).
    private var includedDrafts: [SplitDraft] {
        splitDrafts.filter { $0.included && $0.shares > 0 }
    }

    private var totalShares: Int {
        includedDrafts.reduce(0) { $0 + $1.shares }
    }

    /// This party's slice of the entered amount, in the entered currency.
    private func splitAmount(for draft: SplitDraft) -> Double {
        guard totalShares > 0, draft.included, draft.shares > 0 else { return 0 }
        return amountValue * Double(draft.shares) / Double(totalShares)
    }

    /// Whether the bill is shared with someone other than the user. Only then
    /// do we persist a split; a "just me" configuration stays an unsplit
    /// personal expense so it counts fully in personal totals.
    private var hasOtherParticipantsInSplit: Bool {
        includedDrafts.contains {
            if case .person = $0.party { return true }
            return false
        }
    }

    private var tripSplitSection: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            payerField
            splitField
        }
    }

    /// "Paid by" picker — who fronted the money. Defaults to You.
    private var payerField: some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            Text("Paid by").eyebrow()
            Menu {
                Button { payerParty = .me } label: { Label("You", systemImage: "person.fill") }
                ForEach(tripContext?.participants ?? [], id: \.clientUUID) { person in
                    Button { payerParty = .person(person.clientUUID) } label: { Text(person.name) }
                }
            } label: {
                HStack(spacing: Space.sm) {
                    Circle()
                        .fill(payerColor)
                        .frame(width: 12, height: 12)
                        .frame(width: 24)
                    Text(payerName)
                        .font(.edBody)
                        .foregroundStyle(Tokens.ink)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Tokens.muted)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .paperMenuOnMac()
            .dropdownFieldSurface()
            .accessibilityLabel("Paid by \(payerName)")
        }
    }

    /// "Split between" editor: a tappable include circle, a colour dot + name,
    /// the party's slice of the bill, and a shares stepper per included party.
    private var splitField: some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            HStack {
                Text("Split between").eyebrow()
                Spacer()
                Text(hasOtherParticipantsInSplit ? "\(includedDrafts.count) people" : "Just you")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
            }
            VStack(spacing: 0) {
                ForEach($splitDrafts) { $draft in
                    splitRow($draft)
                    if draft.id != splitDrafts.last?.id {
                        Divider().background(Tokens.divider)
                    }
                }
            }
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
            .paperBorder(Tokens.border, radius: Radius.md)

            if hasOtherParticipantsInSplit {
                tripShareReadout
            }
        }
    }

    private func splitRow(_ draft: Binding<SplitDraft>) -> some View {
        let d = draft.wrappedValue
        return HStack(spacing: Space.sm) {
            Button {
                draft.wrappedValue.included.toggle()
            } label: {
                Image(systemName: d.included ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(d.included ? Tokens.accentFinance : Tokens.mutedSoft)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(d.included ? "\(d.name) included" : "\(d.name) excluded")

            Circle()
                .fill(partyColor(d))
                .frame(width: 10, height: 10)
            Text(d.name)
                .font(.edBody)
                .foregroundStyle(d.included ? Tokens.ink : Tokens.muted)
                .lineLimit(1)

            Spacer()

            if d.included {
                Text("\(currency.uppercased()) \(formatShare(splitAmount(for: d)))")
                    .font(.edCaption)
                    .monospacedDigit()
                    .foregroundStyle(Tokens.muted)
                shareControl(draft)
            }
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
    }

    /// Custom −/n/+ share control: unlike a bare `Stepper`, the current share
    /// count sits visibly between the buttons. Minusing below 1 removes the
    /// person from the split (same as unticking them); shares reset to 1 so
    /// re-including starts clean.
    private func shareControl(_ draft: Binding<SplitDraft>) -> some View {
        HStack(spacing: 0) {
            Button {
                if draft.wrappedValue.shares <= 1 {
                    draft.wrappedValue.included = false
                    draft.wrappedValue.shares = 1
                } else {
                    draft.wrappedValue.shares -= 1
                }
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Tokens.ink)
                    .frame(width: 30, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Fewer shares for \(draft.wrappedValue.name)")

            Text("\(draft.wrappedValue.shares)")
                .font(.edFootnoteStrong)
                .monospacedDigit()
                .foregroundStyle(Tokens.ink)
                .frame(minWidth: 20)

            Button {
                draft.wrappedValue.shares = min(draft.wrappedValue.shares + 1, 20)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Tokens.ink)
                    .frame(width: 30, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("More shares for \(draft.wrappedValue.name)")
        }
        .background(Tokens.surface2, in: RoundedRectangle(cornerRadius: Radius.sm))
        .accessibilityElement(children: .contain)
        .accessibilityValue("\(draft.wrappedValue.name) shares: \(draft.wrappedValue.shares)")
    }

    /// "Your share: CUR X of CUR Y" line, shown when the bill is shared.
    private var tripShareReadout: some View {
        let cur = currency.uppercased()
        let mine = splitDrafts.first { $0.party == .me }.map { splitAmount(for: $0) } ?? 0
        return HStack(spacing: 4) {
            Text("Your share:")
                .font(.edCaption)
                .foregroundStyle(Tokens.muted)
            Text("\(cur) \(formatShare(mine))")
                .font(.edCaption)
                .monospacedDigit()
                .foregroundStyle(Tokens.ink)
            Text("of \(cur) \(formatShare(amountValue))")
                .font(.edCaption)
                .monospacedDigit()
                .foregroundStyle(Tokens.mutedSoft)
        }
    }

    private var payerName: String {
        switch payerParty {
        case .me: return "You"
        case .person(let id):
            return tripContext?.participants.first { $0.clientUUID == id }?.name ?? "You"
        }
    }

    private var payerColor: Color {
        switch payerParty {
        case .me: return Tokens.accentFinance
        case .person(let id):
            if let person = tripContext?.participants.first(where: { $0.clientUUID == id }) {
                return Color(personHex: person.colorHex)
            }
            return Tokens.accentFinance
        }
    }

    private func partyColor(_ draft: SplitDraft) -> Color {
        if let hex = draft.colorHex { return Color(personHex: hex) }
        return Tokens.accentFinance
    }

    /// Seed the split editor (trip context only). New expenses default to an
    /// equal split across everyone; editing a split expense reconstructs its
    /// stored entries; editing an UNSPLIT trip expense keeps it unsplit (only
    /// "You" ticked) so it never silently converts to a split on save.
    private func seedTripSplit() {
        guard let ctx = tripContext else { return }

        var existingSplits: [ExpenseSplitEntry] = []
        var existingPayer: UUID?
        if case .existing(let uuid) = target {
            let descriptor = FetchDescriptor<LocalExpense>(
                predicate: #Predicate { $0.clientUUID == uuid }
            )
            if let row = try? modelContext.fetch(descriptor).first {
                existingSplits = row.splits
                existingPayer = row.paidByPersonUUID
            }
        }
        let editingUnsplit: Bool = {
            if case .existing = target { return existingSplits.isEmpty }
            return false
        }()

        func makeDraft(party: SplitPartyID, name: String, colorHex: String?) -> SplitDraft {
            let entry: ExpenseSplitEntry? = {
                switch party {
                case .me: return existingSplits.first { $0.personUUID == nil }
                case .person(let id): return existingSplits.first { $0.personID == id }
                }
            }()
            let included: Bool
            let shares: Int
            if !existingSplits.isEmpty {
                included = entry != nil
                shares = max(entry?.shares ?? 1, 1)
            } else if editingUnsplit {
                included = (party == .me)
                shares = 1
            } else {
                included = true
                shares = 1
            }
            return SplitDraft(party: party, name: name, colorHex: colorHex, included: included, shares: shares)
        }

        var drafts: [SplitDraft] = [makeDraft(party: .me, name: "You", colorHex: nil)]
        for person in ctx.participants {
            drafts.append(makeDraft(party: .person(person.clientUUID), name: person.name, colorHex: person.colorHex))
        }
        splitDrafts = drafts

        // Payer defaults to You; fall back to You if the stored payer is no
        // longer on the trip.
        if let payer = existingPayer, ctx.participants.contains(where: { $0.clientUUID == payer }) {
            payerParty = .person(payer)
        } else {
            payerParty = .me
        }

        // Trip splits store the FULL bill and carry the breakdown in
        // `splitsData`; the #188 per-share model must stay off.
        numberOfShares = 1
    }

    /// Write the split state onto a row on save (trip context only). Persists a
    /// split only when someone other than the user shares the bill; otherwise
    /// clears the split so it's a plain personal expense.
    ///
    /// The payer is written on BOTH paths (#504). It used to live inside the
    /// split branch, so an expense that stayed "Just you" had its `Paid by`
    /// selection overwritten with nil on every save — the picker was offered,
    /// accepted the choice, and discarded it, and `seedTripSplit` then read the
    /// nil back as "You". An unsplit expense with another payer is a real
    /// state: the cost is the user's, someone else fronted the money.
    private func applyTripSplit(to row: LocalExpense) {
        guard tripContext != nil else { return }
        if hasOtherParticipantsInSplit {
            row.splits = includedDrafts.map { draft in
                switch draft.party {
                case .me: return ExpenseSplitEntry(person: nil, shares: draft.shares)
                case .person(let id): return ExpenseSplitEntry(person: id, shares: draft.shares)
                }
            }
        } else {
            row.splits = []
        }
        if case .person(let id) = payerParty {
            row.paidByPersonUUID = id
        } else {
            row.paidByPersonUUID = nil
        }
    }

    /// Shared "tappable field that opens a picker" row for Person / Event.
    /// Shows the selected name (or a placeholder), a chevron, and a clear
    /// button when a value is set.
    /// A tag field that drops its options down in place (#463), the same shape
    /// `categoryField` and `payerField` already use. It used to push a picker
    /// sheet, which on macOS meant a second window-modal surface for what reads
    /// as a dropdown — and one that collapsed to nothing (#461). Creating a tag
    /// still opens the picker sheet, straight into its add form: a new event
    /// carries dates and a trip link, which no menu can host.
    private func tagSelectorRow<MenuContent: View>(
        label: String,
        icon: String,
        placeholder: String,
        value: String?,
        onClear: @escaping () -> Void,
        @ViewBuilder menuContent: () -> MenuContent
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            HStack {
                Text(label).eyebrow()
                Spacer()
                Text("Optional")
                    .font(.edCaption)
                    .foregroundStyle(Tokens.mutedSoft)
            }
            HStack(spacing: Space.sm) {
                Menu {
                    menuContent()
                } label: {
                    HStack(spacing: Space.sm) {
                        Image(systemName: icon)
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(Tokens.accentFinance)
                            .frame(width: 24)
                        Text(value ?? placeholder)
                            .font(.edBody)
                            .foregroundStyle(value == nil ? Tokens.inkSoft : Tokens.ink)
                            .lineLimit(1)
                        Spacer(minLength: Space.sm)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Tokens.muted)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .paperMenuOnMac()

                // The clear button shares the field's surface rather than
                // sitting outside it, so a tagged row is the same box as an
                // untagged one with one more glyph in it.
                if value != nil {
                    Button(action: onClear) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(Tokens.mutedSoft)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear \(label.lowercased())")
                }
            }
            .dropdownFieldSurface()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value ?? "none")")
    }

    // MARK: - Persistence

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true

        switch target {
        case .new:
            source = .manual
            // Focus the amount field shortly after the sheet finishes its
            // open animation. SwiftUI ignores focus changes made inside
            // .onAppear on a freshly presented sheet.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                amountFocused = true
            }

        case .existing(let uuid):
            let descriptor = FetchDescriptor<LocalExpense>(
                predicate: #Predicate { $0.clientUUID == uuid }
            )
            if let existing = try? modelContext.fetch(descriptor).first {
                // Shares first: the stored `originalAmount` is the per-share
                // figure, so we reconstruct the RECEIPT TOTAL for the field
                // (share × shares) — consistent with what the user typed on
                // entry. Save() re-divides by shares to store the share again.
                numberOfShares = max(existing.numberOfShares, 1)
                amountText = formatAmountForEdit(existing.receiptTotalOriginal)
                currency = existing.originalCurrency
                category = existing.categoryEnum
                date = existing.date
                merchant = existing.merchant ?? ""
                descriptionField = existing.expenseDescription ?? ""
                paymentMethod = existing.paymentMethod ?? ""
                receiptImagePath = existing.receiptImagePath
                source = existing.sourceEnum
                statementLabel = existing.statementLabel
                if let uuid = existing.personUUID, let name = existing.personName?.trimmedNonEmpty {
                    selectedPerson = ExpenseTag(uuid: uuid, name: name)
                }
                if let uuid = existing.eventUUID, let name = existing.eventName?.trimmedNonEmpty {
                    selectedEvent = ExpenseTag(uuid: uuid, name: name)
                }
                // "Add to Finance" toggle state (#277). Only a trip expense
                // shows the toggle; seed it from the row's current flag so the
                // switch reflects reality on open.
                existingIsTripExpense = existing.tripUUID != nil
                addToFinance = !existing.hiddenFromFinance
            }

        case .prefilled(let prefill):
            source = prefill.source
            receiptImagePath = prefill.receiptImagePath
            extractionBanner = prefill.extractionError
            extractionConfidence = prefill.confidence

            if let amount = prefill.amount {
                amountText = formatAmountForEdit(amount)
            }
            if let cur = prefill.currency, !cur.isEmpty {
                currency = cur.uppercased()
            }
            if let cat = prefill.category {
                category = cat
            }
            if let d = prefill.date {
                date = d
            }
            if let m = prefill.merchant {
                merchant = m
            }
            if let desc = prefill.descriptionText {
                descriptionField = desc
            }
            // For a successful extraction we don't auto-focus — the user is
            // reviewing fields, not typing from scratch. For a failure we
            // jump straight to the amount field after the sheet settles.
            if !prefill.extractionSucceeded {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    amountFocused = true
                }
            }
        }

        // Seed the settle-up split editor after the base fields load (#258).
        if tripSplitActive {
            seedTripSplit()
        }
    }

    private func save() async {
        guard amountValue > 0 else {
            errorMessage = "Enter an amount greater than zero."
            return
        }
        saving = true
        errorMessage = nil
        defer { saving = false }

        let store = SwiftDataStore.shared
        let fx = FXService(store: store)
        let service = ExpenseService(store: store)

        // The amount field holds the RECEIPT TOTAL; the user's SHARE is what
        // we store (#188). Divide first, then FX-convert the share so
        // `originalAmount` / `sgdAmount` are already the per-person figure and
        // every aggregation site stays correct without change. Equal split only.
        //
        // Trip splits (#258) use a DIFFERENT model: the row stores the FULL
        // bill and the breakdown lives in `splitsData`, so the #188 division is
        // forced off (shares = 1) and `applyTripSplit` writes the split after.
        let shares = tripSplitActive ? 1 : max(numberOfShares, 1)
        let shareAmount = amountValue / Double(shares)

        let conversion: (sgdAmount: Double, rate: Double)
        do {
            conversion = try await fx.convert(shareAmount, from: currency)
        } catch {
            errorMessage = "Couldn't convert \(currency) to SGD. Try again when online."
            return
        }

        do {
            switch target {
            case .new, .prefilled:
                let row = try service.addExpense(
                    date: date,
                    category: category,
                    merchant: merchant,
                    expenseDescription: descriptionField,
                    originalAmount: shareAmount,
                    originalCurrency: currency,
                    sgdAmount: conversion.sgdAmount,
                    fxRate: conversion.rate,
                    paymentMethod: paymentMethod,
                    source: source,
                    personUUID: selectedPerson?.uuid,
                    personName: selectedPerson?.name,
                    eventUUID: selectedEvent?.uuid,
                    eventName: selectedEvent?.name,
                    numberOfShares: shares
                )
                // ExpenseService.addExpense doesn't take receiptImagePath
                // (Phase A signature). Set it directly and save again — the
                // service does the same context.save() pattern.
                if let path = receiptImagePath {
                    row.receiptImagePath = path
                    try modelContext.save()
                }
                // Trip linkage + settle-up split (#258). Stamp the tripUUID and
                // write the split; only persisted when a trip context is active.
                if let ctx = tripContext {
                    row.tripUUID = ctx.tripUUID
                    // Trip expenses are opt-in to Finance (#277). The "Add to
                    // Finance" toggle is the control; it defaults OFF, so a
                    // newly added trip expense stays out of Finance totals
                    // unless the user flips it in this same sheet. The trip's
                    // own tiles / settle-up count it regardless.
                    row.hiddenFromFinance = !addToFinance
                    applyTripSplit(to: row)
                    try modelContext.save()
                }

            case .existing(let uuid):
                let descriptor = FetchDescriptor<LocalExpense>(
                    predicate: #Predicate { $0.clientUUID == uuid }
                )
                if let existing = try modelContext.fetch(descriptor).first {
                    try service.updateExpense(
                        existing,
                        date: date,
                        category: category,
                        merchant: merchant,
                        expenseDescription: descriptionField,
                        originalAmount: shareAmount,
                        originalCurrency: currency,
                        sgdAmount: conversion.sgdAmount,
                        fxRate: conversion.rate,
                        paymentMethod: paymentMethod,
                        person: .some(selectedPerson),
                        event: .some(selectedEvent),
                        numberOfShares: shares
                    )
                    // Persist receipt-path / source changes (e.g. user
                    // removed the image, or scan path → manual edit).
                    existing.receiptImagePath = receiptImagePath
                    existing.source = source.rawValue
                    // Trip linkage + settle-up split (#258). Only touched when a
                    // trip context is active, so editing a trip expense from the
                    // Finance surface (no context) round-trips splits untouched.
                    if let ctx = tripContext {
                        existing.tripUUID = ctx.tripUUID
                        applyTripSplit(to: existing)
                    }
                    // "Add to Finance" toggle (#277). The sheet is the control
                    // for trip expenses now, so write the flag from the toggle
                    // whether the edit came from the trip tab (trip context) or
                    // the Finance surface (no context). Gated to trip expenses
                    // so a personal Finance expense is never touched.
                    if existingIsTripExpense {
                        existing.hiddenFromFinance = !addToFinance
                    }
                    try modelContext.save()
                }
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Strip trailing zeros from the persisted amount so editing doesn't
    /// show "67.500000" on load.
    private func formatAmountForEdit(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

private extension String {
    /// Trim whitespace, return nil for empty. Local copy of the same helper
    /// used elsewhere in Finance (kept file-private to avoid a public API).
    var trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

// MARK: - Person picker (#183)

/// Pick an existing person or create a new one inline. Selecting a person
/// dismisses; "New person" reveals an inline name field that find-or-creates
/// on Add. Case-insensitive reuse is handled by `PersonService.findOrCreate`.
struct PersonPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var selection: ExpenseTag?

    /// Open straight into the add form (#463). The expense sheet now lists the
    /// existing people in its own dropdown, so it reaches this sheet only to
    /// create one. Defaults to false, which is the browse-then-pick behaviour
    /// the Trips participant row still uses.
    var startsInCreateMode: Bool = false

    @Query(sort: [SortDescriptor(\LocalPerson.name, order: .forward)])
    private var people: [LocalPerson]

    @State private var addingNew: Bool = false
    @State private var newName: String = ""
    @State private var errorMessage: String?

    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()
                List {
                    if addingNew {
                        newPersonRow
                    } else {
                        Button {
                            addingNew = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { nameFocused = true }
                        } label: {
                            Label("New person", systemImage: "plus.circle")
                                .foregroundStyle(Tokens.accentFinance)
                        }
                        .listRowBackground(Tokens.surface)
                    }

                    // In create mode the caller already listed these in its own
                    // dropdown, so repeating them here is noise (#463).
                    ForEach(startsInCreateMode ? [] : people, id: \.clientUUID) { person in
                        Button {
                            selection = ExpenseTag(uuid: person.clientUUID, name: person.name)
                            dismiss()
                        } label: {
                            HStack(spacing: Space.sm) {
                                Circle()
                                    .fill(Color(personHex: person.colorHex))
                                    .frame(width: 12, height: 12)
                                Text(person.name)
                                    .foregroundStyle(Tokens.ink)
                                Spacer()
                                if selection?.uuid == person.clientUUID {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Tokens.accentFinance)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Tokens.surface)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Tokens.paper)
            }
            .navigationTitle(startsInCreateMode ? "New person" : "Person")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Tokens.muted)
                }
            }
            .onAppear {
                guard startsInCreateMode, !addingNew else { return }
                addingNew = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { nameFocused = true }
            }
        }
        // iOS sizes this sheet with presentation detents, which macOS ignores. A
        // macOS sheet sizes itself to its content, and a List reports no
        // intrinsic height, so without a floor the sheet collapses to the
        // height of its navigation bar and the rows are unreachable (#461).
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 460,
               minHeight: startsInCreateMode ? 220 : 460,
               idealHeight: startsInCreateMode ? 260 : 560)
        #endif
    }

    private var newPersonRow: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            TextField("Name", text: $newName)
                .paperFieldOnMac()
                .font(.edBody)
                .foregroundStyle(Tokens.ink)
                .focused($nameFocused)
                .submitLabel(.done)
                .onSubmit { commitNew() }
            if let errorMessage {
                Text(errorMessage)
                    .font(.edCaption)
                    .foregroundStyle(Tokens.danger)
            }
            HStack {
                Button("Cancel") { cancelNew() }
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.muted)
                    .buttonStyle(.borderless)
                Spacer()
                Button("Add") { commitNew() }
                    .font(.edFootnote)
                    .foregroundStyle(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Tokens.muted : Tokens.accentFinance)
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .buttonStyle(.borderless)
            }
        }
        .listRowBackground(Tokens.surface)
    }

    /// Backing out of the form. When the sheet exists only to create (#463)
    /// there is nothing behind the form to go back to, so leave altogether.
    private func cancelNew() {
        if startsInCreateMode { dismiss(); return }
        addingNew = false
        newName = ""
        errorMessage = nil
    }

    private func commitNew() {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let person = try PersonService.default().findOrCreate(name: trimmed)
            selection = ExpenseTag(uuid: person.clientUUID, name: person.name)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Event picker (#183)

/// Pick an existing event or create one inline (name + optional date range +
/// optional Trip link). Reuse is case-insensitive via
/// `EventService.findOrCreate`.
struct EventPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var selection: ExpenseTag?

    /// Open straight into the add form (#463). See `PersonPickerSheet`.
    var startsInCreateMode: Bool = false

    @Query(sort: [SortDescriptor(\LocalEvent.updatedAt, order: .reverse)])
    private var events: [LocalEvent]

    @Query(sort: [SortDescriptor(\LocalTrip.startDate, order: .reverse)])
    private var trips: [LocalTrip]

    @State private var addingNew: Bool = false
    @State private var newName: String = ""
    @State private var useDates: Bool = false
    @State private var startDate: Date = Date()
    @State private var endDate: Date = Date()
    @State private var linkedTrip: LocalTrip?
    @State private var errorMessage: String?

    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()
                List {
                    if addingNew {
                        newEventSection
                    } else {
                        Button {
                            addingNew = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { nameFocused = true }
                        } label: {
                            Label("New event", systemImage: "plus.circle")
                                .foregroundStyle(Tokens.accentFinance)
                        }
                        .listRowBackground(Tokens.surface)
                    }

                    // See PersonPickerSheet: the caller's dropdown already
                    // lists these when we are here only to create one (#463).
                    ForEach(startsInCreateMode ? [] : events, id: \.clientUUID) { event in
                        Button {
                            selection = ExpenseTag(uuid: event.clientUUID, name: event.name)
                            dismiss()
                        } label: {
                            HStack(spacing: Space.sm) {
                                Image(systemName: "calendar")
                                    .foregroundStyle(Tokens.accentFinance)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(event.name)
                                        .foregroundStyle(Tokens.ink)
                                    if let subtitle = dateSubtitle(event) {
                                        Text(subtitle)
                                            .font(.edCaption)
                                            .foregroundStyle(Tokens.muted)
                                    }
                                }
                                Spacer()
                                if selection?.uuid == event.clientUUID {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Tokens.accentFinance)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Tokens.surface)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Tokens.paper)
            }
            .navigationTitle(startsInCreateMode ? "New event" : "Event")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Tokens.muted)
                }
            }
            .onAppear {
                guard startsInCreateMode, !addingNew else { return }
                addingNew = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { nameFocused = true }
            }
        }
        // iOS sizes this sheet with presentation detents, which macOS ignores. A
        // macOS sheet sizes itself to its content, and a List reports no
        // intrinsic height, so without a floor the sheet collapses to the
        // height of its navigation bar and the rows are unreachable (#461).
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 460,
               minHeight: startsInCreateMode ? 220 : 460,
               idealHeight: startsInCreateMode ? 260 : 560)
        #endif
    }

    @ViewBuilder
    private var newEventSection: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            TextField("Event name", text: $newName)
                .paperFieldOnMac()
                .font(.edBody)
                .foregroundStyle(Tokens.ink)
                .focused($nameFocused)
                .submitLabel(.done)
                .onSubmit { commitNew() }

            Toggle("Set dates", isOn: $useDates.animation())
                .font(.edFootnote)
                .tint(Tokens.accentFinance)

            if useDates {
                DatePicker("From", selection: $startDate, displayedComponents: .date)
                    .paperDatePickerOnMac()
                    .font(.edFootnote)
                    .tint(Tokens.accentFinance)
                DatePicker("To", selection: $endDate, in: startDate..., displayedComponents: .date)
                    .paperDatePickerOnMac()
                    .font(.edFootnote)
                    .tint(Tokens.accentFinance)
            }

            if !trips.isEmpty {
                Menu {
                    Button("None") { linkedTrip = nil }
                    ForEach(trips, id: \.clientUUID) { trip in
                        Button(trip.name) { linkedTrip = trip }
                    }
                } label: {
                    HStack {
                        Text("Link to trip")
                            .font(.edFootnote)
                            .foregroundStyle(Tokens.inkSoft)
                        Spacer()
                        Text(linkedTrip?.name ?? "None")
                            .font(.edFootnote)
                            .foregroundStyle(Tokens.ink)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Tokens.muted)
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.edCaption)
                    .foregroundStyle(Tokens.danger)
            }

            HStack {
                Button("Cancel") { resetNew() }
                    .font(.edFootnote)
                    .foregroundStyle(Tokens.muted)
                    .buttonStyle(.borderless)
                Spacer()
                Button("Add") { commitNew() }
                    .font(.edFootnote)
                    .foregroundStyle(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Tokens.muted : Tokens.accentFinance)
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .buttonStyle(.borderless)
            }
        }
        .listRowBackground(Tokens.surface)
    }

    private func dateSubtitle(_ event: LocalEvent) -> String? {
        let fmt = DateFormatter()
        fmt.dateFormat = "d MMM yyyy"
        if let start = event.startDate, let end = event.endDate {
            return "\(fmt.string(from: start)) – \(fmt.string(from: end))"
        }
        if let start = event.startDate {
            return fmt.string(from: start)
        }
        return nil
    }

    private func resetNew() {
        if startsInCreateMode { dismiss(); return }
        addingNew = false
        newName = ""
        useDates = false
        linkedTrip = nil
        errorMessage = nil
    }

    private func commitNew() {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let event = try EventService.default().findOrCreate(
                name: trimmed,
                startDate: useDates ? startDate : nil,
                endDate: useDates ? endDate : nil,
                tripUUID: linkedTrip?.clientUUID
            )
            selection = ExpenseTag(uuid: event.clientUUID, name: event.name)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Receipt rendering helpers

/// Small inline preview of a stored receipt. Renders the image for
/// `.jpg/.heic/.png` and a generic doc icon for `.pdf` (we don't need to
/// rasterise a PDF for a 64pt thumbnail — the icon is enough signal).
struct ReceiptThumbnailImage: View {
    let relativePath: String?

    var body: some View {
        Group {
            if let path = relativePath,
               let url = ReceiptStorage.shared.load(relativePath: path) {
                if isPDF(path) {
                    pdfPlaceholder
                } else if let image = Image(receiptFileURL: url) {
                    image
                        .resizable()
                        .scaledToFill()
                } else {
                    missingPlaceholder
                }
            } else {
                missingPlaceholder
            }
        }
        .background(Tokens.surface2)
    }

    private func isPDF(_ path: String) -> Bool {
        path.lowercased().hasSuffix(".pdf")
    }

    private var pdfPlaceholder: some View {
        Image(systemName: "doc.text.fill")
            .font(.system(size: 26, weight: .regular))
            .foregroundStyle(Tokens.accentFinance)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var missingPlaceholder: some View {
        Image(systemName: "photo")
            .font(.system(size: 22, weight: .regular))
            .foregroundStyle(Tokens.muted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Full-screen receipt viewer. Sheet presented from AddExpenseSheet when
/// the user taps the thumbnail.
///
/// Both branches are UIKit-backed for a native, smooth zoom that doesn't
/// fight the sheet's own gestures:
///  - Images: a `UIScrollView` + `UIImageView` with `viewForZooming`, so
///    pinch-to-zoom, drag-to-pan-while-zoomed, and double-tap-to-toggle
///    (fit ↔ 2.5×) all come from the platform. Fixed hand-rolled gesture
///    math would jank and clip; the scroll view gets it right for free.
///  - PDFs: a `PDFView` with `autoScales = true`, which gives native
///    pinch-zoom and page scrolling.
///
/// Branch is chosen by the receipt's file extension (.pdf ⇒ PDF viewer).
/// State resets on every present because the viewer is rebuilt each time
/// the sheet opens (the `UIViewRepresentable`s make fresh views).
struct ReceiptFullViewer: View {
    let relativePath: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()
                content
            }
            .navigationTitle("Receipt")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Tokens.ink)
                }
            }
        }
        #if os(macOS)
        // Without an explicit size a macOS sheet shrinks to its content's ideal
        // size, and both branches below are scroll-view-backed, so that size is
        // next to nothing: the sheet opened as a title, a hairline of receipt and
        // a Done button (#474). `TicketOriginalViewer` hit this first and carries
        // the same fix; a receipt is the same kind of document, read the same way,
        // so it gets the same numbers rather than new ones.
        .frame(minWidth: 560, idealWidth: 720, minHeight: 560, idealHeight: 860)
        #endif
    }

    @ViewBuilder
    private var content: some View {
        if let url = ReceiptStorage.shared.load(relativePath: relativePath) {
            if relativePath.lowercased().hasSuffix(".pdf") {
                PDFKitView(url: url)
                    .ignoresSafeArea(edges: .bottom)
            } else if let image = loadReceiptPlatformImage(url) {
                ZoomableImageView(image: image)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                // Present but undecodable is a damaged file, not an absent one,
                // so it keeps its own wording.
                undecodable
            }
        } else {
            notOnThisDevice
        }
    }

    private var undecodable: some View {
        Text("Receipt is no longer available.")
            .font(.edBody)
            .foregroundStyle(Tokens.muted)
    }

    /// The bytes are not on this device. Since #471 they follow the row.
    private var notOnThisDevice: some View {
        Text(SyncAssetMessage.missing(
            "Receipt",
            isArriving: SyncAssetInbox.shared.isArriving(relativePath)
        ))
        .font(.edBody)
        .foregroundStyle(Tokens.muted)
    }
}

// MARK: - Zoomable image (scroll-view-backed)

#if os(iOS)
/// A `UIScrollView` wrapping a `UIImageView`, exposing native pinch-to-zoom,
/// pan-while-zoomed, and double-tap-to-toggle. `viewForZooming` is what makes
/// the scroll view drive the zoom; the image is centred in `layoutSubviews`
/// so it stays anchored while fit and while zoomed out.
private struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> CenteringScrollView {
        let scrollView = CenteringScrollView()
        scrollView.delegate = context.coordinator
        scrollView.backgroundColor = .clear
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.bouncesZoom = true
        // Minimum is set to fit in `updateZoomScales`; start at 1.0.
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 5.0

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        scrollView.imageView = imageView
        scrollView.addSubview(imageView)

        // Double-tap toggles between fit and a comfortable zoom.
        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        return scrollView
    }

    func updateUIView(_ uiView: CenteringScrollView, context: Context) {
        // No dynamic props to sync; the image is fixed for the viewer's life.
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? CenteringScrollView)?.imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            (scrollView as? CenteringScrollView)?.centerImage()
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView = recognizer.view as? CenteringScrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 {
                // Zoomed in → reset to fit.
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                // At fit → zoom toward the tapped point.
                let target = min(scrollView.minimumZoomScale * 2.5, scrollView.maximumZoomScale)
                let point = recognizer.location(in: scrollView.imageView)
                let size = scrollView.bounds.size
                let w = size.width / target
                let h = size.height / target
                let rect = CGRect(x: point.x - w / 2, y: point.y - h / 2, width: w, height: h)
                scrollView.zoom(to: rect, animated: true)
            }
        }
    }
}

/// A `UIScrollView` that keeps its single `imageView` sized to fit and
/// centred. The minimum zoom scale is the aspect-fit scale, so "fit" is the
/// true zoomed-out state and pinch-out never leaves dead space. Recomputes on
/// bounds changes (rotation, sheet resize).
private final class CenteringScrollView: UIScrollView {
    var imageView: UIImageView?
    private var lastBoundsSize: CGSize = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        // Recompute fit only when the bounds actually change, so a zoom
        // (which triggers layout) doesn't clobber the user's current scale.
        if bounds.size != lastBoundsSize {
            lastBoundsSize = bounds.size
            configureForFit()
        }
        centerImage()
    }

    /// Size the image view to the image's natural size, set the content size,
    /// and derive the aspect-fit scale as the minimum zoom (and initial zoom).
    private func configureForFit() {
        guard let imageView, let image = imageView.image, bounds.width > 0, bounds.height > 0 else { return }
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else { return }

        imageView.frame = CGRect(origin: .zero, size: imageSize)
        contentSize = imageSize

        let scaleW = bounds.width / imageSize.width
        let scaleH = bounds.height / imageSize.height
        let fitScale = min(scaleW, scaleH)

        minimumZoomScale = fitScale
        maximumZoomScale = max(fitScale * 5, fitScale)
        zoomScale = fitScale
    }

    /// Keep the image centred when it's smaller than the viewport (fit /
    /// zoomed-out), and pinned to the edges once it overflows (zoomed-in).
    func centerImage() {
        guard let imageView else { return }
        let boundsSize = bounds.size
        var frame = imageView.frame
        frame.origin.x = frame.width < boundsSize.width
            ? (boundsSize.width - frame.width) / 2
            : 0
        frame.origin.y = frame.height < boundsSize.height
            ? (boundsSize.height - frame.height) / 2
            : 0
        imageView.frame = frame
    }
}
#else
/// macOS receipt image viewer (issue #281). An `NSScrollView` with
/// `allowsMagnification` gives trackpad pinch-to-zoom and drag-to-pan for
/// free; the document `NSImageView` is sized to the image's natural size and
/// scaled proportionally. No hand-rolled gesture math, matching the iOS
/// scroll-view approach.
private struct ZoomableImageView: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 1.0
        scrollView.maxMagnification = 5.0
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let imageView = NSImageView()
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.frame = NSRect(origin: .zero, size: image.size)
        scrollView.documentView = imageView

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        // Keep the document view sized to the current image; the image is
        // fixed for the viewer's life, so nothing to reconcile.
        (nsView.documentView as? NSImageView)?.image = image
    }
}
#endif

// MARK: - PDF (PDFKit-backed)

/// A `PDFView` with `autoScales = true`, which gives native pinch-zoom,
/// page scrolling, and a fit-to-width initial layout. Loaded from the
/// on-disk receipt URL. `PDFView` is UIKit-backed on iOS and AppKit-backed
/// on macOS, so the representable splits by platform but shares the same
/// configuration (issue #281).
#if os(iOS)
private struct PDFKitView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = .clear
        pdfView.document = PDFDocument(url: url)
        return pdfView
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document == nil {
            uiView.document = PDFDocument(url: url)
        }
    }
}
#else
private struct PDFKitView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = .clear
        pdfView.document = PDFDocument(url: url)
        return pdfView
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document == nil {
            nsView.document = PDFDocument(url: url)
        }
    }
}
#endif
