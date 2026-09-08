import Foundation

/// Which of the three ticket layouts a card draws (#222, generalised in #398).
///
/// Was previously implied by two booleans read straight off
/// `LocalItineraryItem` (`kindEnum == .stay`, then `isBoardingPassStyle`). Named
/// explicitly now that a second source feeds the same card and has to be able
/// to state its layout rather than fake an itinerary kind.
enum TicketCardLayout {
    /// Big origin→destination codes, seat / gate / terminal, PNR on the stub.
    case boardingPass
    /// Event-type eyebrow, big title, venue, section / row / seat.
    case event
    /// Check-in → check-out hero with the nights count.
    case stay
}

/// Everything the wallet-style ticket surfaces need to draw a card, projected
/// out of whichever model owns it (#398).
///
/// `TicketCardView` and `TicketScanView` used to take a `LocalItineraryItem`
/// directly, which meant a scannable card could only ever exist inside a trip.
/// They now take this value type instead, so the trip timeline and the wallet
/// render byte-for-byte the same card from different storage. The property names
/// deliberately match `LocalItineraryItem`'s so that refactor was a change of
/// type and nothing else.
///
/// A value type, not a view model: it is built at render time from a live model
/// (cheap, a few string copies plus one small JSON decode) and holds no
/// identity. Mutating a card means mutating its model, never this.
struct TicketCardData {
    var layout: TicketCardLayout

    /// The eyebrow printed above the title ("BOARDING PASS", "STAY", the event
    /// type, …). Carried rather than derived so a rail ticket can say "TICKET"
    /// while a flight says "BOARDING PASS" from the same layout.
    var eyebrow: String

    /// SF Symbol sitting on the dashed path in the middle of the boarding-pass
    /// route hero (and the stay hero). Carried so a rail card gets a tram
    /// instead of a plane. Trip items always pass "airplane", which is what the
    /// timeline drew before this was configurable.
    var heroGlyph: String

    var title: String

    /// Check-in date for the stay layout. Start-of-day, device-local.
    var primaryDate: Date

    /// UTC wall-clock anchored times: the stored value's UTC H:mm is the time
    /// printed on the ticket. See `LocalItineraryItem.startTime`.
    var startTime: Date?
    var arrivalTime: Date?
    /// Stay check-out day / time.
    var endDate: Date?
    var endTime: Date?

    var seat: String
    var gate: String
    var venue: String
    var address: String
    var mapsURL: URL?
    var sourceConfirmation: String

    var attachmentPath: String
    var barcodePayload: String
    var barcodeSymbology: String

    var meta: TicketMeta?

    var isStay: Bool { layout == .stay }
    var isBoardingPassStyle: Bool { layout == .boardingPass }

    /// `true` when there is something to tear off: a stored file and/or a
    /// decoded barcode. Drives the perforation + stub.
    var hasTicket: Bool {
        !attachmentPath.trimmingCharacters(in: .whitespaces).isEmpty
            || !barcodePayload.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var hasBarcode: Bool {
        !barcodePayload.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

// MARK: - Projections

extension TicketCardData {

    /// Project a trip timeline item. Reproduces the pre-#398 behaviour exactly:
    /// a `.stay` takes the stay layout, anything else splits on
    /// `isBoardingPassStyle`, and the event eyebrow is the extracted event type
    /// falling back to "TICKET".
    init(_ item: LocalItineraryItem) {
        let meta = item.ticketMeta
        let layout: TicketCardLayout
        if item.kindEnum == .stay {
            layout = .stay
        } else if item.isBoardingPassStyle {
            layout = .boardingPass
        } else {
            layout = .event
        }

        self.layout = layout
        self.eyebrow = Self.eyebrow(for: layout, eventType: meta?.eventType)
        // Unconditionally the plane, matching what the timeline drew before the
        // glyph became configurable. A rail item on a trip keeps its existing
        // card exactly; only wallet cards opt into a per-kind glyph.
        self.heroGlyph = "airplane"
        self.title = item.title
        self.primaryDate = item.dayDate
        self.startTime = item.startTime
        self.arrivalTime = item.arrivalTime
        self.endDate = item.endDate
        self.endTime = item.endTime
        self.seat = item.seat
        self.gate = item.gate
        self.venue = item.venue
        self.address = item.address
        self.mapsURL = item.mapsURL
        self.sourceConfirmation = item.sourceConfirmation
        self.attachmentPath = item.attachmentPath
        self.barcodePayload = item.barcodePayload
        self.barcodeSymbology = item.barcodeSymbology
        self.meta = meta
    }

    /// Project a standalone wallet card. The kind states the layout outright,
    /// so a rail ticket draws the pass layout without having to claim it is a
    /// flight.
    init(_ card: LocalWalletCard) {
        let kind = card.kindEnum
        let meta = card.ticketMeta

        // The boarding-pass layout is built around a route hero: two big airport
        // codes with a glyph between them. Those codes only ever come from an
        // upload (BCBP or extraction), so a HAND-TYPED travel card has none, and
        // that layout would render "—  ✈  —" with two empty endpoints. Fall back
        // to the event layout in that case: title, venue, time, facts, all of
        // which a typed card does have. The eyebrow still says BOARDING PASS /
        // TICKET, so it reads as the kind the user picked.
        let hasRoute = !(meta?.originCode ?? "").isEmpty || !(meta?.destinationCode ?? "").isEmpty
        let resolvedLayout: TicketCardLayout = (kind.layout == .boardingPass && !hasRoute)
            ? .event
            : kind.layout

        self.layout = resolvedLayout
        // The kind's own eyebrow wins for travel and stays ("BOARDING PASS",
        // "TICKET", "STAY"); an event prefers the extracted event type
        // ("CONCERT", "FOOTBALL MATCH") when the extractor read one.
        // An event card prefers the extracted event type ("CONCERT", "FOOTBALL
        // MATCH"); every other kind states its own eyebrow. Keyed on the KIND's
        // layout, not the resolved one, so a typed travel card falling back to
        // the event layout still says "BOARDING PASS" rather than "TICKET".
        self.eyebrow = kind.layout == .event
            ? Self.eyebrow(for: .event, eventType: meta?.eventType)
            : kind.eyebrow
        self.heroGlyph = kind.icon
        self.title = card.title
        self.primaryDate = card.dayDate
        self.startTime = card.startTime
        self.arrivalTime = card.arrivalTime
        self.endDate = card.endDate
        self.endTime = card.endTime
        self.seat = card.seat
        self.gate = card.gate
        self.venue = card.venue
        self.address = card.address
        self.mapsURL = card.mapsURL
        self.sourceConfirmation = card.sourceConfirmation
        self.attachmentPath = card.attachmentPath
        self.barcodePayload = card.barcodePayload
        self.barcodeSymbology = card.barcodeSymbology
        self.meta = meta
    }

    /// Project a document attached to a task (#399, surfaced in the wallet by
    /// #398) or to a trip stop (#432). Always the event layout: the model was
    /// built for event tickets and deliberately carries no route, airline or BCBP
    /// grammar.
    ///
    /// - Parameters:
    ///   - ownerTitle: the owning record's title, used when the extractor could
    ///     not read an event name off the document — "Spider-Man" as you typed it
    ///     beats a blank card.
    ///   - ownerAddress: the owning record's address. See the note on `address` below.
    ///   - ownerMapsLink: the owning record's stored map link, same reason.
    init(
        _ ticket: LocalTaskTicket,
        ownerTitle: String,
        ownerAddress: String = "",
        ownerMapsLink: String = ""
    ) {
        let meta = ticket.ticketMeta
        let event = ticket.eventTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = event.isEmpty ? ownerTitle : event

        self.layout = .event
        self.eyebrow = Self.eyebrow(for: .event, eventType: meta?.eventType)
        self.heroGlyph = "ticket"
        self.title = resolvedTitle
        // Undated tickets fall back to the day the row was created, purely so
        // the card has somewhere to sort. `WalletEntry` keeps them out of Past
        // regardless — see the `validThrough` note there.
        self.primaryDate = ticket.eventDate ?? WallClock.dayAnchor(from: ticket.createdAt)
        // The task model stores the printed time as a STRING on purpose (#163 /
        // #168: a Date reformats into the phone's timezone and stops matching the
        // number the gate is reading). So there is no `Date` to hand over here —
        // the printed text reaches the card through `WalletEntry.timeText`.
        self.startTime = nil
        self.arrivalTime = nil
        self.endDate = nil
        self.endTime = nil
        self.seat = ticket.seat
        self.gate = ticket.gate
        self.venue = ticket.venue
        // The document's own address wins; the owning task's is the fallback (#420).
        //
        // A task ticket has no address column, so this used to be blank and the card
        // could never show one — even when the task it hangs off had both an address
        // and a map link typed on it, which is the usual case by the time someone
        // attaches a ticket. Two sources, in order of authority: a `.pkpass` states
        // the street address on its back, and failing that the task is what a person
        // wrote down about where they are going.
        self.address = meta?.address?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ownerAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        self.mapsURL = Self.mapsURL(
            explicit: meta?.directionsURL ?? ownerMapsLink,
            name: resolvedTitle,
            address: self.address
        )
        self.sourceConfirmation = ticket.reference
        self.attachmentPath = ticket.attachmentPath
        self.barcodePayload = ticket.barcodePayload
        self.barcodeSymbology = ticket.barcodeSymbology
        self.meta = meta
    }

    /// A tappable map target: the link we were given if there is one, otherwise a
    /// Google Maps search built from the place's name and address (#420).
    ///
    /// Mirrors `LocalItineraryItem.mapsURL`, which resolves the same two sources in
    /// the same order, so a card's MAP chip behaves identically whichever model it
    /// came from. `nil` with no link and no address, because a bare title is not a
    /// reliable map target and a chip that lands on the wrong building is worse than
    /// no chip.
    private static func mapsURL(explicit: String?, name: String, address: String) -> URL? {
        let stored = (explicit ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !stored.isEmpty {
            if let url = URL(string: stored), url.scheme != nil { return url }
            if let url = URL(string: "https://\(stored)") { return url }
        }
        return LocalItineraryItem.googleMapsSearchURL(name: name, address: address)
    }

    private static func eyebrow(for layout: TicketCardLayout, eventType: String?) -> String {
        switch layout {
        case .boardingPass:
            return "BOARDING PASS"
        case .stay:
            return "STAY"
        case .event:
            let type = eventType?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (type.isEmpty ? "TICKET" : type).uppercased()
        }
    }
}
