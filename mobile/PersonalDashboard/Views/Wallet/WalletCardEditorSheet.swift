import SwiftUI
import SwiftData

/// `.sheet(item:)` payload for the wallet card editor. Carries the UUID rather
/// than the live model so the sheet stays stateless across re-renders, matching
/// `ItineraryItemEditorTarget` / `TripEditorTarget`.
enum WalletCardEditorTarget: Identifiable {
    case new
    case existing(UUID)

    var id: String {
        switch self {
        case .new:                return "new"
        case .existing(let uuid): return uuid.uuidString
        }
    }
}

/// Create or edit a standalone wallet card (#398).
///
/// Two ways in:
///  - **Add manually**, for a card with no file behind it: a confirmation code
///    you read out at a desk, a membership, a pass whose barcode never scanned.
///  - **Fill in an upload**, when the extraction degraded. The file, the decoded
///    barcode and whatever was read are already saved (an upload is never lost),
///    so this opens on a real card and the user completes it.
///
/// Ticket data is NOT editable here beyond removing it, which mirrors the
/// itinerary editor: the barcode and the stored file come from the upload
/// pipeline, and the only sensible edit is to drop them. Removing deletes the
/// file and clears the barcode, leaving a typed card behind.
struct WalletCardEditorSheet: View {
    let target: WalletCardEditorTarget

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query private var cards: [LocalWalletCard]

    // MARK: Form state

    @State private var kind: WalletCardKind = .pass
    @State private var title: String = ""
    @State private var dayDate: Date = Calendar.current.startOfDay(for: .now)
    @State private var hasTime: Bool = false
    @State private var hasArrival: Bool = false
    @State private var arrivalTime: Date = Calendar.current.startOfDay(for: .now)
    @State private var endDate: Date = Calendar.current.startOfDay(for: .now)
    @State private var hasEndTime: Bool = false
    @State private var venue: String = ""
    @State private var address: String = ""
    @State private var seat: String = ""
    @State private var gate: String = ""
    @State private var confirmation: String = ""
    @State private var notes: String = ""

    /// Loaded from the existing card and round-tripped untouched on save. Only
    /// "Remove ticket" changes them.
    @State private var ticketAttachmentPath: String = ""
    @State private var ticketHasBarcode: Bool = false

    @State private var didLoad = false
    @State private var showingDeleteConfirmation = false
    @State private var showingRemoveTicketConfirmation = false
    @State private var showingTicketOriginal = false

    @FocusState private var titleFocused: Bool

    private let titleMaxLength = 120

    private var isEditing: Bool {
        if case .existing = target { return true }
        return false
    }

    private var existingCard: LocalWalletCard? {
        guard case .existing(let id) = target else { return nil }
        return cards.first(where: { $0.clientUUID == id })
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasTicketData: Bool {
        isEditing && (!ticketAttachmentPath.isEmpty || ticketHasBarcode)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Tokens.paper.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: Space.lg) {
                        kindField
                        titleField
                        primaryDateField
                        if kind == .stay {
                            endDateField
                        }
                        // An arrival only means something for a travel card that
                        // already has a departure time: no lone arrival.
                        if kind.layout == .boardingPass && hasTime {
                            arrivalTimeField
                        }
                        // Seat / gate are printed on travel and seated tickets; a
                        // generic pass has neither, so the fields stay hidden
                        // rather than inviting junk into the card's facts strip.
                        if kind != .pass {
                            seatGateFields
                        }
                        if kind != .boardingPass {
                            venueField
                        }
                        confirmationField
                        addressField
                        notesField
                        if hasTicketData {
                            ticketSection
                        }
                        if isEditing {
                            deleteButton
                                .padding(.top, Space.sm)
                        }
                    }
                    .padding(Space.lg)
                }
            }
            .navigationTitle(isEditing ? "Edit card" : "New card")
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
                    .disabled(trimmedTitle.isEmpty)
                    .foregroundStyle(trimmedTitle.isEmpty ? Tokens.muted : Tokens.ink)
                }
            }
            .alert("Delete this card?", isPresented: $showingDeleteConfirmation) {
                Button("Delete", role: .destructive) { deleteCard() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The card and its stored ticket file are removed from this device.")
            }
            .alert("Remove this ticket?", isPresented: $showingRemoveTicketConfirmation) {
                Button("Remove", role: .destructive) { removeTicket() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The scanned barcode and the saved file will be deleted. The card and its details stay in your wallet.")
            }
            .sheet(isPresented: $showingTicketOriginal) {
                TicketOriginalViewer(attachmentPath: ticketAttachmentPath)
            }
        }
        .onAppear { loadIfNeeded() }
        .onChange(of: kind) { _, newKind in
            // Switching to stay: make sure check-out is at least the day after
            // check-in. Switching away: reset the flag so the persisted shape
            // matches what the UI shows. Mirrors the itinerary editor.
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
            if newKind.layout != .boardingPass { hasArrival = false }
        }
        .onChange(of: dayDate) { _, newValue in
            guard kind == .stay else { return }
            let cal = Calendar.current
            let inDay = cal.startOfDay(for: newValue)
            if cal.startOfDay(for: endDate) < inDay {
                endDate = cal.date(byAdding: .day, value: 1, to: inDay) ?? inDay
            }
        }
        .onChange(of: hasTime) { _, newValue in
            guard newValue else { return }
            dayDate = seededTime(on: dayDate, defaultHour: 9)
        }
        .onChange(of: hasEndTime) { _, newValue in
            guard newValue else { return }
            endDate = seededTime(on: endDate, defaultHour: 11)
        }
        .onChange(of: hasArrival) { _, newValue in
            guard newValue else { return }
            let comps = Calendar.current.dateComponents([.hour, .minute], from: arrivalTime)
            if (comps.hour ?? 0) == 0 && (comps.minute ?? 0) == 0 {
                arrivalTime = dayDate
            }
        }
    }

    // MARK: - Fields

    private var kindField: some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            Text("Kind").eyebrow()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.sm) {
                    ForEach(WalletCardKind.allCases) { option in
                        WalletKindChip(kind: option, isSelected: option == kind) {
                            kind = option
                        }
                    }
                }
                .padding(.vertical, 2)
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

    private var primaryDateField: some View {
        let label = kind == .stay ? "Check-in" : "Date"
        return VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            Text(label).eyebrow()
            VStack(spacing: 0) {
                datePickerRow(
                    selection: $dayDate,
                    range: nil,
                    includesTime: hasTime,
                    accessibilityLabel: label
                )

                Divider().background(Tokens.divider)

                toggleRow(title: "Include time", isOn: $hasTime)
            }
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
            .paperBorder(Tokens.border, radius: Radius.md)
        }
    }

    private var endDateField: some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            Text("Check-out").eyebrow()
            VStack(spacing: 0) {
                datePickerRow(
                    selection: $endDate,
                    range: Calendar.current.startOfDay(for: dayDate)...,
                    includesTime: hasEndTime,
                    accessibilityLabel: "Check-out"
                )

                Divider().background(Tokens.divider)

                toggleRow(title: "Include time", isOn: $hasEndTime)
            }
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
            .paperBorder(Tokens.border, radius: Radius.md)
        }
    }

    private var arrivalTimeField: some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            Text("Arrival").eyebrow()
            VStack(spacing: 0) {
                if hasArrival {
                    HStack {
                        DatePicker("", selection: $arrivalTime, displayedComponents: [.hourAndMinute])
                            .paperDatePickerOnMac()
                            .labelsHidden()
                            .tint(Tokens.accent(for: .wallet))
                            .accessibilityLabel("Arrival time")
                        Spacer(minLength: 0)
                    }
                    .padding(Space.md)

                    Divider().background(Tokens.divider)
                }

                toggleRow(title: "Include arrival", isOn: $hasArrival)
            }
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
            .paperBorder(Tokens.border, radius: Radius.md)
        }
    }

    private var seatGateFields: some View {
        HStack(alignment: .top, spacing: Space.md) {
            plainField(label: "Seat", placeholder: "12A", text: $seat)
            // Gate is a boarding-pass idea; a seated event has a section / row
            // instead, which comes from the upload rather than being typed.
            if kind.layout == .boardingPass {
                plainField(label: "Gate", placeholder: "B22", text: $gate)
            }
        }
    }

    private var venueField: some View {
        plainField(
            label: "Venue",
            placeholder: kind == .stay ? "Hotel name" : "The O2, London",
            text: $venue
        )
    }

    private var confirmationField: some View {
        plainField(label: "Confirmation", placeholder: "Booking reference", text: $confirmation)
    }

    private var addressField: some View {
        plainField(label: "Address", placeholder: "Street, city", text: $address)
    }

    private var notesField: some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            Text("Notes").eyebrow()
            TextField("Anything else worth remembering", text: $notes, axis: .vertical)
                .paperFieldOnMac()
                .font(.edBody)
                .foregroundStyle(Tokens.ink)
                .lineLimit(3...6)
                .padding(Space.md)
                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
                .paperBorder(Tokens.border, radius: Radius.md)
                .accessibilityLabel("Notes")
        }
    }

    /// Thumbnail of the uploaded file, a "View original" affordance, and the
    /// destructive remove. Only shown when the card carries ticket data.
    private var ticketSection: some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            Text("Ticket").eyebrow()
            HStack(spacing: Space.md) {
                TicketAttachmentThumbnail(relativePath: ticketAttachmentPath)
                VStack(alignment: .leading, spacing: 4) {
                    Text(ticketHasBarcode ? "Scannable ticket attached" : "Ticket file attached")
                        .font(.edBody)
                        .foregroundStyle(Tokens.ink)
                    if !ticketAttachmentPath.isEmpty {
                        Button("View original") { showingTicketOriginal = true }
                            .font(.edFootnote)
                            .foregroundStyle(Tokens.accent(for: .wallet))
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
                        .font(.system(size: 12, weight: .medium))
                    Text("Remove ticket")
                        .font(.edFootnote)
                }
                .foregroundStyle(Tokens.danger)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove ticket")
        }
    }

    private var deleteButton: some View {
        Button {
            showingDeleteConfirmation = true
        } label: {
            HStack(spacing: Space.sm) {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .medium))
                Text("Delete card")
                    .font(.edBodyMedium)
            }
            .foregroundStyle(Tokens.danger)
            .frame(maxWidth: .infinity)
            .padding(Space.md)
            .background(Tokens.dangerSoft, in: RoundedRectangle(cornerRadius: Radius.md))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Delete card")
    }

    // MARK: - Field builders

    private func plainField(label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: Space.fieldLabelGap) {
            Text(label).eyebrow()
            TextField(placeholder, text: text)
                .paperFieldOnMac()
                .font(.edBody)
                .foregroundStyle(Tokens.ink)
                .padding(Space.md)
                .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Radius.md))
                .paperBorder(Tokens.border, radius: Radius.md)
                .accessibilityLabel(label)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func datePickerRow(
        selection: Binding<Date>,
        range: PartialRangeFrom<Date>?,
        includesTime: Bool,
        accessibilityLabel: String
    ) -> some View {
        HStack {
            if let range {
                DatePicker(
                    "",
                    selection: selection,
                    in: range,
                    displayedComponents: includesTime ? [.date, .hourAndMinute] : .date
                )
                .paperDatePickerOnMac()
                .labelsHidden()
                .tint(Tokens.accent(for: .wallet))
            } else {
                DatePicker(
                    "",
                    selection: selection,
                    displayedComponents: includesTime ? [.date, .hourAndMinute] : .date
                )
                .paperDatePickerOnMac()
                .labelsHidden()
                .tint(Tokens.accent(for: .wallet))
            }
            Spacer(minLength: 0)
        }
        .padding(Space.md)
        .accessibilityLabel(accessibilityLabel)
    }

    private func toggleRow(title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title).font(.edBody).foregroundStyle(Tokens.inkSoft)
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(Tokens.accent(for: .wallet))
        }
        .padding(Space.md)
    }

    private func placeholder(for kind: WalletCardKind) -> String {
        switch kind {
        case .boardingPass: return "SQ322 · SIN→LHR"
        case .transit:      return "Milan → Rome"
        case .event:        return "Coldplay · Wembley"
        case .stay:         return "Hotel name"
        case .pass:         return "What is this pass for?"
        }
    }

    /// Replace a midnight time-of-day with `defaultHour:00` so flipping a time
    /// toggle on doesn't open the picker at 12:00 AM. Mirrors the itinerary
    /// editor's `seededTime`.
    private func seededTime(on existing: Date, defaultHour: Int) -> Date {
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: existing)
        guard (comps.hour ?? 0) == 0, (comps.minute ?? 0) == 0 else { return existing }
        return cal.date(bySettingHour: defaultHour, minute: 0, second: 0, of: existing) ?? existing
    }

    // MARK: - Load

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        guard let card = existingCard else { return }

        kind = card.kindEnum
        title = card.title
        venue = card.venue
        address = card.address
        seat = card.seat
        gate = card.gate
        confirmation = card.sourceConfirmation
        notes = card.notes
        ticketAttachmentPath = card.attachmentPath
        ticketHasBarcode = card.hasBarcode

        // Stored days are UTC anchors and stored times are UTC wall-clock
        // anchors (#506), so each is converted back to the device-local picker
        // value: the local day naming the stored date, carrying the printed H:mm.
        let storedDay = WallClock.deviceDay(from: card.dayDate)
        dayDate = storedDay
        if let start = card.startTime {
            hasTime = true
            dayDate = WallClock.devicePickerDate(onDay: storedDay, anchor: start)
        }
        if let arrival = card.arrivalTime {
            hasArrival = true
            arrivalTime = WallClock.devicePickerDate(onDay: storedDay, anchor: arrival)
        }
        if let end = card.endDate {
            let storedEndDay = WallClock.deviceDay(from: end)
            endDate = storedEndDay
            if let endT = card.endTime {
                hasEndTime = true
                endDate = WallClock.devicePickerDate(onDay: storedEndDay, anchor: endT)
            }
        } else {
            endDate = Calendar.current.date(byAdding: .day, value: 1, to: storedDay) ?? storedDay
        }
    }

    // MARK: - Persistence

    private func save() {
        // The day is anchored at UTC midnight of the day the picker showed, so
        // it stops moving with the device timezone (#506).
        let day = WallClock.dayAnchor(from: dayDate)
        let startValue: Date? = hasTime ? WallClock.utcAnchor(onDay: dayDate, timeFrom: dayDate) : nil
        let arrivalValue: Date? = (kind.layout == .boardingPass && hasTime && hasArrival)
            ? WallClock.utcAnchor(onDay: dayDate, timeFrom: arrivalTime)
            : nil
        let endDateValue: Date? = kind == .stay ? WallClock.dayAnchor(from: endDate) : nil
        let endTimeValue: Date? = (kind == .stay && hasEndTime)
            ? WallClock.utcAnchor(onDay: endDate, timeFrom: endDate)
            : nil

        // Only the fields the current kind actually shows are persisted, so
        // switching kind never leaves a stale value rendering on the card.
        let venueValue = kind == .boardingPass ? "" : venue.trimmingCharacters(in: .whitespacesAndNewlines)
        let seatValue = kind == .pass ? "" : seat.trimmingCharacters(in: .whitespacesAndNewlines)
        let gateValue = kind.layout == .boardingPass ? gate.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let addressValue = address.trimmingCharacters(in: .whitespacesAndNewlines)

        if let card = existingCard {
            card.kindEnum = kind
            card.title = trimmedTitle
            card.dayDate = day
            card.startTime = startValue
            card.arrivalTime = arrivalValue
            card.endDate = endDateValue
            card.endTime = endTimeValue
            card.venue = venueValue
            card.address = addressValue
            card.seat = seatValue
            card.gate = gateValue
            card.sourceConfirmation = confirmation.trimmingCharacters(in: .whitespacesAndNewlines)
            card.notes = notes
            // Re-derive the map link from the current venue/address unless an
            // explicit link was stored by the extractor. `mapsURL` falls back to
            // deriving one anyway, so leaving this empty costs nothing.
            card.updatedAt = Date()
        } else {
            let card = LocalWalletCard(
                kind: kind,
                title: trimmedTitle,
                dayDate: day,
                startTime: startValue,
                arrivalTime: arrivalValue,
                endDate: endDateValue,
                endTime: endTimeValue,
                notes: notes,
                venue: venueValue,
                address: addressValue,
                seat: seatValue,
                gate: gateValue,
                sourceConfirmation: confirmation.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            modelContext.insert(card)
        }
        try? modelContext.save()
    }

    private func deleteCard() {
        guard let card = existingCard else { return }
        if !card.attachmentPath.isEmpty {
            try? TicketStorage.shared.delete(relativePath: card.attachmentPath)
        }
        modelContext.delete(card)
        try? modelContext.save()
        Haptics.destructive()
        dismiss()
    }

    /// Drop the upload: delete the stored file and clear every field that came
    /// from it, leaving the typed card behind. Same contract as the itinerary
    /// editor's `removeTicket`.
    private func removeTicket() {
        guard let card = existingCard else { return }
        if !card.attachmentPath.isEmpty {
            try? TicketStorage.shared.delete(relativePath: card.attachmentPath)
        }
        card.attachmentPath = ""
        card.barcodePayload = ""
        card.barcodeSymbology = ""
        card.ticketMetaJSON = ""
        card.updatedAt = Date()
        try? modelContext.save()
        ticketAttachmentPath = ""
        ticketHasBarcode = false
        Haptics.destructive()
    }
}

// MARK: - Kind chip

/// Selectable kind chip, mirroring `KindPickerChip` on the itinerary editor.
private struct WalletKindChip: View {
    let kind: WalletCardKind
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: kind.icon)
                    .font(.system(size: 11, weight: .medium))
                Text(kind.displayName)
                    .font(.edFootnote)
            }
            .foregroundStyle(isSelected ? Tokens.accentFg : Tokens.inkSoft)
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm)
            .background(
                isSelected ? Tokens.accent(for: .wallet) : Tokens.surface,
                in: Capsule(style: .continuous)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(isSelected ? Color.clear : Tokens.border, lineWidth: 0.5)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(kind.displayName)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
