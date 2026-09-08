import Foundation

/// One card in the Wallet, whatever created it (#398).
///
/// The wallet is a VIEW over existing data, not a second copy of it. A trip's
/// boarding pass keeps living on its `LocalItineraryItem`; a card added straight
/// to the wallet lives on a `LocalWalletCard`. This type is the common shape the
/// list sorts, groups and renders, so nothing downstream of `build` knows how
/// many sources there are.
///
/// ### Adding a source
///
/// Adding one means: a case on `Source` (with its label + icon), a parameter on
/// `build`, and a mapping loop. Nothing else in the wallet changes. Task-attached
/// tickets are being built in parallel and land exactly here — see the `task`
/// note on `Source`.
struct WalletEntry: Identifiable {

    enum Source: Equatable {
        /// A standalone card, added straight to the wallet. Editable and
        /// deletable in place.
        case wallet(cardID: UUID)

        /// A ticket hanging off a trip's timeline item. Read-only in the wallet:
        /// tapping through opens the trip that owns it, because that is where
        /// its day, ordering and trip context are edited.
        case trip(itemID: UUID, tripID: UUID, tripName: String)

        /// A ticket attached to a task (#399). Read-only here for the same
        /// reason a trip's is: the task owns it, so that is where it is edited.
        case task(ticketID: UUID, todoID: UUID, taskTitle: String)

        /// A document attached to a stop on a trip's timeline (#432). Distinct
        /// from `.trip`, which is the stop's own inline ticket: a stop can hold
        /// several documents and each is its own card, so the ticket's id is what
        /// identifies this one. Chipped with the trip's name like `.trip`, because
        /// what you want to read above a boarding pass is where you are going, not
        /// which row of an itinerary it hangs off.
        case tripDocument(ticketID: UUID, itemID: UUID, tripID: UUID, tripName: String)

        /// Chip text shown above the card.
        var label: String {
            switch self {
            case .wallet:                              return "Wallet"
            case .trip(_, _, let tripName):            return tripName
            case .task(_, _, let taskTitle):           return taskTitle
            case .tripDocument(_, _, _, let tripName): return tripName
            }
        }

        /// SF Symbol for the chip.
        var icon: String {
            switch self {
            case .wallet:       return "wallet.pass"
            case .trip:         return "airplane"
            case .task:         return "checklist"
            case .tripDocument: return "airplane"
            }
        }

        /// Whether the wallet can EDIT this card itself. False for borrowed cards,
        /// which route back to the surface that owns them so there is exactly one
        /// place each record is edited.
        ///
        /// Editing only. Deleting is a separate question with a separate answer —
        /// see `deletion` (#503).
        var isEditableInWallet: Bool {
            switch self {
            case .wallet:                          return true
            case .trip, .task, .tripDocument:      return false
            }
        }

        /// What deleting this card actually removes (#503).
        ///
        /// Every card in the Wallet can be deleted from the Wallet. Editing routes
        /// back to the owning surface because a record should have one editor, but
        /// deleting does not need one: the card in front of you IS the thing you want
        /// gone, and sending someone off to find the stop that owns it to do it there
        /// is a detour, not a safeguard.
        ///
        /// What differs between the sources is not WHETHER, it is WHAT. Two of them
        /// have a row of their own to remove. The third does not: a stop's inline
        /// ticket is a set of fields ON the stop, so deleting the card clears the
        /// pass and keeps the stop. Deleting a row off someone's itinerary because
        /// they removed a boarding pass from it would destroy something they never
        /// asked about.
        enum Deletion: Equatable {
            /// Remove the `LocalWalletCard` outright, with its file.
            case walletCard(UUID)
            /// Tombstone the `LocalTaskTicket`, with its file. Its task or stop lives on.
            case document(ticketID: UUID)
            /// Clear the ticket fields off the `LocalItineraryItem`, keeping the stop.
            case stopTicket(itemID: UUID)
        }

        var deletion: Deletion {
            switch self {
            case .wallet(let cardID):                   return .walletCard(cardID)
            case .task(let ticketID, _, _):             return .document(ticketID: ticketID)
            case .tripDocument(let ticketID, _, _, _):  return .document(ticketID: ticketID)
            case .trip(let itemID, _, _):               return .stopTicket(itemID: itemID)
            }
        }

        /// The confirmation's title. A stop's inline ticket is not a card being
        /// thrown away, so it does not claim to be one.
        var deletionTitle: String {
            switch deletion {
            case .walletCard, .document: return "Delete this card?"
            case .stopTicket:            return "Remove this pass?"
            }
        }

        /// The destructive button's word. "Remove" for a pass being taken off a stop
        /// that stays, because "Delete" over an itinerary row reads like the row.
        var deletionConfirmLabel: String {
            switch deletion {
            case .walletCard, .document: return "Delete"
            case .stopTicket:            return "Remove"
            }
        }

        /// The confirmation's body: what is lost, and what survives.
        ///
        /// The second half matters more than the first. Someone deleting a boarding
        /// pass off a trip stop needs to know the flight is still on their itinerary
        /// before they tap Delete, not after.
        var deletionMessage: String {
            switch self {
            case .wallet:
                return "The card and its stored ticket file are removed from this device."
            case .task(_, _, let taskTitle):
                let owner = taskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                let named = owner.isEmpty ? "its task" : "\u{201C}\(owner)\u{201D}"
                return "The card and its file are removed from \(named). The task itself stays."
            case .tripDocument(_, _, _, let tripName):
                let trip = tripName.trimmingCharacters(in: .whitespacesAndNewlines)
                let named = trip.isEmpty ? "its trip" : "\u{201C}\(trip)\u{201D}"
                return "The card and its file are removed from \(named). The stop it was attached to stays."
            case .trip:
                return "The pass and its file are removed from this stop. The stop stays on your itinerary, with its day and time."
            }
        }
    }

    let source: Source
    let card: TicketCardData

    /// What the card IS, which is what picks its colour in the deck (#398).
    ///
    /// A standalone card states its kind outright. A borrowed trip ticket has
    /// only a layout, so it maps back: a stay is a stay, a route hero is a
    /// boarding pass, everything else is an event. That mapping is lossy in one
    /// direction only — a trip rail ticket colours as a boarding pass, because
    /// the itinerary model does not carry the distinction the wallet's `transit`
    /// kind does.
    let kind: WalletCardKind

    /// The colours this card draws in.
    var palette: WalletCardPalette { kind.palette }

    /// The day the card belongs to (start-of-day, device-local). Sorting key.
    let day: Date

    /// Last day the card is still worth presenting. Equals `day` for a moment
    /// (a flight, a concert) and the check-out day for a stay, so a hotel card
    /// stays in Upcoming for the whole stay rather than dropping to Past on the
    /// morning of check-in.
    let validThrough: Date

    /// The "HH:mm → HH:mm" / "Anytime" line, formatted exactly as the trip
    /// timeline formats it (same UTC-pinned formatter, so a card reads the same
    /// in both places).
    let timeText: String?

    var id: String {
        switch source {
        case .wallet(let cardID):                  return "wallet:\(cardID.uuidString)"
        case .trip(let itemID, _, _):              return "trip:\(itemID.uuidString)"
        case .task(let ticketID, _, _):            return "task:\(ticketID.uuidString)"
        case .tripDocument(let ticketID, _, _, _): return "trip-doc:\(ticketID.uuidString)"
        }
    }

    /// `true` when this card has not passed yet, evaluated day-granularly so a
    /// card stays Upcoming for the whole of its own day (you scan today's
    /// boarding pass at 22:00, not just before its departure minute).
    func isUpcoming(asOf today: Date) -> Bool {
        validThrough >= today
    }
}

/// What a task lends to the cards hanging off it (#420): its name, and where it is.
///
/// A struct rather than three parallel dictionaries keyed on the same UUID, which is
/// three chances for one of them to be looked up and the others forgotten.
private struct TaskCardContext {
    let title: String
    let address: String
    let mapsLink: String
}

/// What a trip stop lends to the documents hanging off it (#432): its name, where
/// it is, the day it sits on, and which trip it belongs to.
///
/// Same shape and same reasoning as `TaskCardContext`. The day matters here in a
/// way it does not for a task: a document that printed no date of its own still
/// belongs on the day of the stop it was attached to, which is the difference
/// between a boarding pass sorting next to its flight and sorting under whenever
/// the file happened to be uploaded.
private struct StopCardContext {
    let tripUUID: UUID
    let title: String
    let address: String
    let mapsLink: String
    let day: Date
}

// MARK: - Grouping

/// The wallet's two groups, each already sorted.
struct WalletGroups {
    /// Not yet past, SOONEST FIRST. The card you are about to scan is the one
    /// you need at the top of the screen; a reverse-chronological upcoming list
    /// would bury today's boarding pass under next year's concert. Matches how
    /// `TripsView` orders its Active / Upcoming groups.
    var upcoming: [WalletEntry] = []

    /// Already past, MOST RECENT FIRST, so the list reads newest-to-oldest
    /// downward and old cards sink to the bottom.
    var past: [WalletEntry] = []

    var isEmpty: Bool { upcoming.isEmpty && past.isEmpty }
    var total: Int { upcoming.count + past.count }
}

extension WalletEntry {

    /// Build the wallet's entries from every source.
    ///
    /// - Parameters:
    ///   - cards: every standalone `LocalWalletCard`.
    ///   - itineraryItems: every `LocalItineraryItem`. Only those carrying
    ///     ticket data are taken; the rest are ordinary timeline rows and have
    ///     no card to show.
    ///   - trips: used only to resolve a trip's name for the source chip. An
    ///     item whose trip has vanished is still shown, labelled "Trip", rather
    ///     than dropped: the ticket is the user's, the trip is just context.
    ///   - taskTickets: every live `LocalTaskTicket` (#399), whether it hangs off a
    ///     task or off a trip stop (#432). Only those that are actually a pass are
    ///     taken — see `LocalTaskTicket.belongsInWallet`. The model held nothing but
    ///     tickets when it was written, but the picker behind it now accepts any
    ///     document (#400), so the rest are ordinary attachments and have no card to
    ///     show.
    ///   - todos: used only to resolve the owning task's title, which is both the
    ///     source chip and the card's fallback name.
    static func build(
        cards: [LocalWalletCard],
        itineraryItems: [LocalItineraryItem],
        trips: [LocalTrip],
        taskTickets: [LocalTaskTicket] = [],
        todos: [LocalTodo] = []
    ) -> [WalletEntry] {
        var tripNames: [UUID: String] = [:]
        for trip in trips { tripNames[trip.clientUUID] = trip.name }
        // LIVE tasks only. Deleting a task soft-deletes the task but does not
        // cascade to its tickets, so a ticket can outlive its owner — and a
        // wallet card that routes back to a task the user already deleted is
        // worse than no card. An orphan is skipped rather than shown unlabelled.
        //
        // The address and the map link travel with the title (#420). A ticket row has
        // no address of its own, and the task it hangs off usually does — so without
        // this the card cannot show where the event is even though the app knows.
        var taskContext: [UUID: TaskCardContext] = [:]
        for todo in todos where todo.deletedAt == nil {
            taskContext[todo.clientUUID] = TaskCardContext(
                title: todo.title,
                address: todo.address,
                mapsLink: todo.googleMapsLink
            )
        }
        // The same, for the stops that documents hang off (#432). A stop is
        // hard-deleted rather than tombstoned, so its absence from this map is what
        // makes an orphaned document skip the Wallet.
        var stopContext: [UUID: StopCardContext] = [:]
        for item in itineraryItems {
            stopContext[item.clientUUID] = StopCardContext(
                tripUUID: item.tripUUID,
                title: item.title,
                address: item.address,
                mapsLink: item.googleMapsLink,
                day: item.dayDate
            )
        }

        var out: [WalletEntry] = []
        out.reserveCapacity(cards.count + itineraryItems.count + taskTickets.count)

        for card in cards {
            let data = TicketCardData(card)
            out.append(
                WalletEntry(
                    source: .wallet(cardID: card.clientUUID),
                    card: data,
                    kind: card.kindEnum,
                    day: card.dayDate,
                    validThrough: card.endDate ?? card.dayDate,
                    timeText: timeLine(for: data)
                )
            )
        }

        for item in itineraryItems {
            // `belongsInWallet` is the shared rule (#405, #414): the person's own
            // override, else something scannable, else a document judged to be
            // presented at a door that also prints a credential.
            //
            // Narrowed in #432 from "has any attachment at all". That was true
            // enough while the only file that could reach a stop came off the ticket
            // scanner; now that any document can be attached by hand, it would put
            // every rental receipt on the shelf next to the boarding passes.
            //
            // #432 paired that with a second arm on the confirmation code, reasoning
            // that a PNR is what you read out at a counter. It admitted 11 of 12
            // booked stops on the store it shipped to — every email-imported flight
            // and every hotel — and buried the one card with a barcode among them
            // (#434). A confirmation code is a booking record, not a pass: every
            // booking has one, so gating on it is not a gate. It keeps its place on
            // the timeline row and in the stay card, which is where you read it.
            guard item.belongsInWallet else { continue }
            let data = TicketCardData(item)
            out.append(
                WalletEntry(
                    source: .trip(
                        itemID: item.clientUUID,
                        tripID: item.tripUUID,
                        tripName: tripNames[item.tripUUID] ?? "Trip"
                    ),
                    card: data,
                    kind: Self.kind(for: data.layout),
                    day: item.dayDate,
                    validThrough: item.endDate ?? item.dayDate,
                    timeText: timeLine(for: data)
                )
            )
        }

        for ticket in taskTickets {
            // Not every attachment is a pass (#405). The picker takes any
            // document, so a restaurant reservation or an appointment card gets
            // stored here too — worth keeping on the record it belongs to, but
            // nothing you present at a door, and a Wallet full of those is a Wallet
            // you stop trusting to hold the thing you are about to scan.
            guard ticket.belongsInWallet else { continue }

            // A document on a trip stop (#432) borrows the stop's name, address and
            // day, exactly as a task's borrows the task's.
            if case .tripStop(let itemID) = ticket.owner {
                guard let stop = stopContext[itemID] else { continue }
                let data = TicketCardData(
                    ticket,
                    ownerTitle: stop.title,
                    ownerAddress: stop.address,
                    ownerMapsLink: stop.mapsLink
                )
                out.append(
                    WalletEntry(
                        source: .tripDocument(
                            ticketID: ticket.clientUUID,
                            itemID: itemID,
                            tripID: stop.tripUUID,
                            tripName: tripNames[stop.tripUUID] ?? "Trip"
                        ),
                        card: data,
                        // Always an event, for the reason a task's document is: this
                        // model carries no travel grammar to colour it by, even when
                        // the stop it hangs off is a flight.
                        kind: .event,
                        // The document's own printed day when it read one, and the
                        // stop's day when it did not. A boarding pass uploaded in
                        // March for a flight in June belongs in June.
                        day: ticket.eventDate ?? stop.day,
                        // Never ages out on a date it did not print — same reasoning
                        // as a task's document, and here the stop's day is a real
                        // enough anchor to fall back to.
                        validThrough: ticket.eventDate ?? stop.day,
                        timeText: printedTime(ticket.startTimeText)
                    )
                )
                continue
            }

            guard let task = taskContext[ticket.todoClientUUID] else { continue }
            let taskTitle = task.title
            let data = TicketCardData(
                ticket,
                ownerTitle: taskTitle,
                ownerAddress: task.address,
                ownerMapsLink: task.mapsLink
            )
            out.append(
                WalletEntry(
                    source: .task(
                        ticketID: ticket.clientUUID,
                        todoID: ticket.todoClientUUID,
                        taskTitle: taskTitle
                    ),
                    card: data,
                    // Always an event: the model carries no travel grammar, so
                    // there is nothing else it could honestly be.
                    kind: .event,
                    day: data.primaryDate,
                    // An undated ticket never falls into Past. Its day is only a
                    // sorting fallback (the row's creation date), so ageing it
                    // out on that basis would hide a pass that may still be
                    // good — a membership card, or a ticket whose date the
                    // extractor could not read.
                    validThrough: ticket.eventDate ?? .distantFuture,
                    // The printed time, verbatim. Not reformatted, because the
                    // number on the card has to match the number at the gate.
                    timeText: printedTime(ticket.startTimeText)
                )
            )
        }

        return out
    }

    /// The task ticket's printed start time, or "Anytime" when it has none —
    /// matching how an untimed itinerary card reads.
    private static func printedTime(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Anytime" : trimmed
    }

    /// Map a borrowed card's layout back to a kind, for colour only.
    private static func kind(for layout: TicketCardLayout) -> WalletCardKind {
        switch layout {
        case .stay:         return .stay
        case .boardingPass: return .boardingPass
        case .event:        return .event
        }
    }

    /// Split into upcoming / past and sort each group. `today` is a
    /// UTC-anchored day, matching how `day` and `validThrough` are stored (#506).
    static func grouped(_ entries: [WalletEntry], today: Date) -> WalletGroups {
        var groups = WalletGroups()
        for entry in entries {
            if entry.isUpcoming(asOf: today) {
                groups.upcoming.append(entry)
            } else {
                groups.past.append(entry)
            }
        }
        // Sort on (day, time-of-day) so two cards on the same day order by their
        // printed time, and a timed card comes before an untimed one. `.distantPast`
        // for a missing time keeps untimed cards last within their day.
        let key: (WalletEntry) -> (Date, Date) = { ($0.day, $0.card.startTime ?? .distantPast) }
        groups.upcoming.sort { key($0) < key($1) }
        groups.past.sort { key($0) > key($1) }
        return groups
    }

    /// The card's time line, mirroring `TimelineEntry.dateTimeLine`: a stay
    /// shows its check-in time, a moment shows "departure → arrival" when both
    /// are known, and an untimed card says "Anytime".
    private static func timeLine(for card: TicketCardData) -> String {
        let format: (Date) -> String = { TimelineEntry.itineraryTimeFormatter.string(from: $0) }
        if card.isStay {
            guard let checkIn = card.startTime else { return "Check-in" }
            return "Check-in · \(format(checkIn))"
        }
        guard let start = card.startTime else { return "Anytime" }
        if let arrival = card.arrivalTime {
            return "\(format(start)) → \(format(arrival))"
        }
        return format(start)
    }
}
