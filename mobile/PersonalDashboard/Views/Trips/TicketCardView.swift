import SwiftUI

/// Wallet-style ticket card rendered inside the trip timeline for items that
/// carry ticket data (#222). Three layouts:
///  - Boarding-pass style (flights / trains): big origin→destination codes,
///    seat / gate / terminal chips, a perforated divider, and a barcode + PNR
///    strip at the bottom.
///  - Event-ticket style (concerts, matches, …): event-type eyebrow, big title,
///    venue + MAP chip, seat / section / row chips, barcode at the bottom.
///  - Stay style (hotels): "STAY" eyebrow with the confirmation code top-right,
///    hotel name, a symmetric check-in → check-out hero (two big dates with a
///    centered bed glyph + nights count on the dashed path), a check-in /
///    check-out time strip, and an address + MAP chip. The perforation + stub
///    only appear when the stay actually has a barcode / attachment; a
///    confirmation-only stay (the common email-imported case) ends cleanly
///    after its location line.
///
/// Which layout renders is driven by `item.layout`, which the source model
/// states when it projects itself into `TicketCardData`: a trip `.stay` and a
/// wallet `.stay` card both resolve to the stay layout, and so on.
///
/// Nothing on the trip timeline renders this any more (#466): a stop draws the
/// plain card and its pass, if it earns one, lives in the Wallet. The one
/// remaining consumer is `WalletTicketCard`, which is the point. Items without
/// booking data never reach this view — they render the plain `TripTimelineRow` card unchanged. The card
/// is display-only; the presenting tap is attached by the parent row.
///
/// Takes a `TicketCardData` value rather than a `LocalItineraryItem` (#398) so
/// the Wallet section can draw a standalone card with this exact view. Every
/// property it reads is named as it was on the model, so that change was a
/// change of type and nothing more.
struct TicketCardView: View {
    let item: TicketCardData
    /// The timeline's "HH:mm / Anytime" line, passed down so the card shows the
    /// same time treatment as a normal row. Used by the flight / event layouts;
    /// the stay layout reads `startTime` / `endTime` directly so it can show
    /// both check-in and check-out times independently.
    let timeText: String?
    /// Colours this card is drawn in (#398). Defaults to the original itinerary
    /// violet, so every trip-timeline call site renders exactly as before and
    /// only the wallet opts into per-kind colour.
    var palette: WalletCardPalette = .itinerary
    /// Whether the card draws its own title. False in the wallet deck, where the
    /// coloured band above the card already carries it and printing it twice
    /// would read as a mistake. The boarding-pass layout has no title line at
    /// all, so this only affects the event and stay layouts.
    var showsTitle: Bool = true
    /// Whether the card is drawn INSIDE another card's silhouette (#398).
    ///
    /// The wallet's deck wants one continuous piece of paper: a coloured header
    /// flowing into the body, notches cut through the outline, a full-bleed stub
    /// under the tear line. So in embedded mode this view drops its own
    /// background, border and corner radius, lets the parent's `TicketShape`
    /// supply the outline, and bleeds the barcode stub edge to edge. False
    /// everywhere on the trip timeline, which keeps its self-contained card.
    var embedded: Bool = false
    /// Tap handler for the barcode stub (#479).
    ///
    /// The stub is the one part of a ticket that has an intention of its own: you
    /// tap a code to hold it up at a gate, never to edit the record behind it. In
    /// the wallet the whole card body carries a tap that opens the editor (or, for
    /// a borrowed card, the surface that owns it), so without this the barcode
    /// inherited that destination and tapping a QR code navigated away from it.
    ///
    /// `nil` on the trip timeline, where the card has no separate scan surface and
    /// the stub is a thumbnail rather than the thing you present.
    var onTapBarcode: (() -> Void)? = nil
    /// The face / back split (#481). Passed in rather than recomputed here so a
    /// card and its back can never disagree about which side owns a field. `nil`
    /// derives it from `item`, which is what a one-off call wants.
    var fields: TicketCardFields? = nil

    @Environment(\.openURL) private var openURL

    private var meta: TicketMeta? { item.meta }

    /// The resolved face / back split.
    private var face: TicketCardFields { fields ?? TicketCardFields(card: item) }

    /// A `.stay` renders the hotel layout; everything else keeps the original
    /// boarding-pass / event split.
    private var isStay: Bool { item.isStay }

    var body: some View {
        if embedded {
            // The parent draws the outline, the wash and the notches.
            cardContent
        } else {
            cardContent
                // The whole card carries a soft itinerary-accent wash
                // (theme-aware) so it reads as a distinct physical ticket in the
                // timeline, not another row.
                .background(ticketFill, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
                .paperBorder(palette.border, radius: Radius.lg)
                .contentShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        }
    }

    private var cardContent: some View {
        VStack(spacing: 0) {
            topContent
                // The rich stay's hero panel bleeds to the card's own edges, so
                // it supplies its own padding and takes none from here.
                .padding(.horizontal, embedded ? 0 : Space.lg)
                .padding(.top, embedded ? 0 : Space.lg)
                .padding(.bottom, embedded ? 0 : Space.lg)

            // The tear-off stub only exists when there's something to separate.
            // Flights / events always have a barcode or attachment, so they're
            // unchanged; on the timeline a confirmation-only stay has neither
            // and its card ends cleanly after the top content. In the wallet
            // that same stay tears off its confirmation code instead — that IS
            // what you read out at a desk, so the ticket has a stub either way.
            if showsStub {
                // Embedded, the tear line sits on the stub's own paper and the
                // holes are cut from the card's outline, so it draws the dashes
                // and nothing else. Standalone, it paints its own notches.
                PerforatedDivider(cutout: embedded, lineColor: perforationLine)
                    .background(embedded ? stubPaper : .clear)

                barcodeStub
                    .padding(.horizontal, embedded ? 0 : Space.lg)
                    .padding(.top, embedded ? 0 : Space.md)
                    .padding(.bottom, embedded ? 0 : Space.lg)
                    // One box for every kind of stub (#481). A 132pt QR fills it;
                    // a short PDF417 strip and a bare confirmation code centre in
                    // it rather than shortening the card they sit on. The paper is
                    // painted on the box rather than on the content, so the spare
                    // room reads as more stub rather than as a gap under it.
                    .frame(height: embedded ? TicketCardMetrics.stub : nil)
                    .background(embedded ? stubPaper : Color.clear)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The dashes' colour. Embedded they run across the stub, so they take its
    /// own muted ink instead of the page border colour, which would vanish.
    private var perforationLine: Color {
        embedded ? stubMuted.opacity(0.5) : Tokens.borderStrong
    }

    /// The stub's paper and ink. The wallet tints it per kind so the bottom of
    /// the card belongs to the card; the trip timeline keeps the flat white it
    /// has always had.
    private var stubPaper: Color { embedded ? palette.stubPaper : Tokens.ticketStub }
    private var stubInk: Color { embedded ? palette.stubInk : Tokens.ticketStubInk }
    private var stubMuted: Color { embedded ? palette.stubMuted : Tokens.ticketStubMuted }

    /// Whether the card grows a tear line and a stub beneath it.
    ///
    /// Always, in the wallet (#481). A card whose bottom half sometimes exists is
    /// a card that is sometimes 200 points shorter, and the deck's whole premise
    /// is that every card is the same size. A pass with nothing to scan tears off
    /// its confirmation code instead, which is the thing you read out at a desk.
    ///
    /// The rule is the same for every kind: the stub holds the thing you USE on
    /// the day. A boarding pass or a cinema ticket tears off its barcode. A
    /// hotel booking has nothing to scan, so it tears off its address and a way
    /// to get there.
    private var showsStub: Bool { embedded || item.hasTicket }

    /// A wallet stay with nothing scannable, but somewhere to go.
    private var hasLocationStub: Bool {
        embedded && isStay && !item.hasTicket
            && (!item.address.isEmpty || item.mapsURL != nil)
    }

    /// Subtle top-to-bottom accent gradient. Rich enough to feel like a ticket,
    /// light enough that ink keeps contrast in both light and dark.
    private var ticketFill: LinearGradient {
        LinearGradient(
            colors: [palette.tintTop, palette.tintBottom],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Top content (layout switch)

    @ViewBuilder
    private var topContent: some View {
        if embedded {
            richTop
        } else {
            switch item.layout {
            case .stay:         compactStayTop
            case .boardingPass: boardingPassTop
            case .event:        eventTop
            }
        }
    }

    // MARK: - Rich (wallet) layout

    /// The wallet's card is a page, not a row, whatever kind it is: an
    /// illustrated hero panel carrying the card's headline fact, then a labelled
    /// detail list. Every layout gets it — a boarding pass and a cinema ticket
    /// have as much to say as a hotel booking, and the compact timeline
    /// treatment squeezes all three into a strip.
    private var richTop: some View {
        VStack(spacing: 0) {
            heroPanel
            faceBlock
        }
        .frame(maxWidth: .infinity)
    }

    /// The card's headline fact on generated artwork: a wash in the card's own
    /// colour with an oversized glyph bleeding off the right edge. Generated
    /// rather than photographic — there is no artwork to ship or fetch, and it
    /// stays correct at any palette.
    private var heroPanel: some View {
        heroContent
            .padding(.horizontal, Space.lg)
            // Deep enough that the artwork is a panel in its own right rather
            // than a tinted strip behind two lines of text.
            .padding(.vertical, Space.xxl)
            // Fixed rather than sized to its content (#481): a stay hero carries
            // two dates where an event carries one, and a card whose top half
            // changed height per kind would break the deck's rhythm.
            .frame(maxWidth: .infinity, minHeight: TicketCardMetrics.hero, maxHeight: TicketCardMetrics.hero)
            .background(alignment: .trailing) {
                ZStack(alignment: .trailing) {
                    LinearGradient(
                        colors: [palette.accent.opacity(0.16), palette.accent.opacity(0.02)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: watermarkGlyph)
                        .font(.system(size: 150, weight: .light))
                        .foregroundStyle(palette.accent.opacity(0.09))
                        .rotationEffect(.degrees(-12))
                        .offset(x: 44, y: 12)
                        .accessibilityHidden(true)
                }
                .clipped()
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(palette.factRule).frame(height: 0.5)
            }
    }

    @ViewBuilder
    private var heroContent: some View {
        switch item.layout {
        case .stay:         stayHero
        case .boardingPass: routeHero
        case .event:        eventHero
        }
    }

    /// A trip item hands over "airplane" unconditionally (it predates the glyph
    /// being configurable), so a stay and an event state their own rather than
    /// putting a plane on a hotel or a cinema seat.
    private var watermarkGlyph: String {
        switch item.layout {
        case .stay:         return "bed.double.fill"
        case .boardingPass: return item.heroGlyph
        case .event:        return "ticket.fill"
        }
    }

    /// The event's two-endpoint hero, mirroring the flight's route and the
    /// stay's dates: the day on one side, the printed start time on the other.
    /// Collapses to a centred date when there is no time, rather than showing an
    /// endpoint with nothing in it.
    @ViewBuilder
    private var eventHero: some View {
        if let time = eventBigTime {
            HStack(alignment: .top, spacing: Space.sm) {
                heroEndpoint(bigDate(item.primaryDate), label: "DATE", alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 5) {
                    dashSegment
                    Image(systemName: "ticket.fill")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(palette.accent)
                        .accessibilityHidden(true)
                    dashSegment
                }
                .padding(.top, 6)

                heroEndpoint(time, label: "STARTS", alignment: .trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        } else {
            heroEndpoint(bigDate(item.primaryDate), label: "DATE", alignment: .center)
                .frame(maxWidth: .infinity)
        }
    }

    /// The event's start time. Prefers the formatted value off a real `Date`,
    /// falling back to the timeline's own string — which is how a task ticket's
    /// time arrives, stored verbatim as printed so it cannot drift by timezone.
    private var eventBigTime: String? {
        if let formatted = departureTimeText { return formatted }
        return departureTime
    }

    /// The face's written half: one full-width line naming the thing, then a row
    /// of up to three fields side by side (#481).
    ///
    /// Fixed height, which is what makes every card in the deck the same size.
    /// This block used to render every fact the extractor read, so a chatty
    /// document produced a card three times the height of a quiet one and pushed
    /// the barcode off the bottom of it. The slots here are the typed ones this
    /// app understands; everything else the document printed is on the back.
    ///
    /// Flush left, label over value, no rules between them: a pass's own grammar
    /// (#413), and the reason the block reads as printed stock rather than as a
    /// settings screen.
    private var faceBlock: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            if let secondary = face.secondary {
                faceField(secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !face.auxiliary.isEmpty {
                HStack(alignment: .top, spacing: Space.md) {
                    ForEach(face.auxiliary) { row in
                        faceField(row)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.horizontal, Space.lg)
        // Deeper above than below: the gap under the hero artwork is what separates
        // the card's illustrated half from its written one (#484).
        .padding(.top, Space.xl)
        .padding(.bottom, Space.lg)
        // Top-aligned inside a fixed box: a sparse card leaves the space empty
        // rather than floating two fields in the middle of the ticket.
        .frame(height: TicketCardMetrics.face, alignment: .top)
    }

    private func faceField(_ row: TicketCardFields.Row) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.label.uppercased())
                .font(.edEyebrow)
                .tracking(1.0)
                .foregroundStyle(Tokens.muted)
                .lineLimit(1)
            Text(row.value)
                .font(.edBodyMedium)
                .foregroundStyle(row.isUnknown ? Tokens.mutedSoft : Tokens.ink)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "JUL 3" style month + day, shared by the stay and event heroes.
    /// "SEP 4". The incoming value is a UTC anchor — either an anchored day or
    /// a UTC wall-clock time, both of which carry the intended calendar day in
    /// their UTC components — so it is projected to the device-local day naming
    /// that date before formatting. Format the anchor directly and the card
    /// prints the day before, anywhere west of UTC (#506).
    private func bigDate(_ date: Date) -> String {
        WallClock.deviceDay(from: date)
            .formatted(.dateTime.month(.abbreviated).day()).uppercased()
    }

    /// One end of a two-endpoint hero: a big value over a small label.
    private func heroEndpoint(_ value: String, label: String, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 3) {
            Text(value)
                .font(.edDisplay)
                .foregroundStyle(Tokens.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.edEyebrow)
                .tracking(1.0)
                .foregroundStyle(Tokens.muted)
                .lineLimit(1)
        }
        .multilineTextAlignment(alignment == .leading ? .leading : (alignment == .trailing ? .trailing : .center))
    }

    // MARK: Boarding-pass top

    private var boardingPassTop: some View {
        VStack(spacing: Space.lg) {
            // Label bar: "BOARDING PASS" on the left, operator + flight on the
            // right. A caption strip, not the hero.
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Text(item.eyebrow)
                    .font(.edEyebrow)
                    .textCase(.uppercase)
                    .tracking(1.4)
                    .foregroundStyle(palette.accent)
                Spacer(minLength: Space.sm)
                if !operatorLabel.isEmpty {
                    Text(operatorLabel)
                        .font(.edFootnote)
                        .foregroundStyle(Tokens.inkSoft)
                        .lineLimit(1)
                }
            }

            routeHero
            factsRow(boardingPassFacts)
        }
    }

    /// Symmetric route hero: big airport codes at the outer edges, a centered
    /// plane on a dashed path between them, city + time stacked under each code.
    private var routeHero: some View {
        HStack(alignment: .top, spacing: Space.sm) {
            routeEndpoint(
                code: meta?.originCode,
                city: meta?.originCity,
                time: departureTimeText,
                alignment: .leading
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            planeConnector
                .padding(.top, 6)

            routeEndpoint(
                code: meta?.destinationCode,
                city: meta?.destinationCity,
                time: arrivalTimeText,
                alignment: .trailing
            )
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// A centered plane between two short dashed segments: the classic pass
    /// "flight path". Its natural width is balanced by the two `maxWidth:
    /// .infinity` endpoints on either side, keeping the hero symmetric. The
    /// glyph comes from the card (a rail ticket shows a tram, not a plane).
    private var planeConnector: some View {
        HStack(spacing: 5) {
            dashSegment
            Image(systemName: item.heroGlyph)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(palette.accent)
                .accessibilityHidden(true)
            dashSegment
        }
    }

    private var dashSegment: some View {
        DashedLine()
            .stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .foregroundStyle(Tokens.mutedSoft)
            .frame(width: 16, height: 1)
    }

    /// One end of the route: big code, small city, optional time. `alignment`
    /// pins the stack to its outer edge so the two ends mirror each other.
    private func routeEndpoint(code: String?, city: String?, time: String?, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 3) {
            Text(code ?? "—")
                .font(.edDisplay)
                .foregroundStyle(Tokens.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let city, !city.isEmpty {
                Text(city.uppercased())
                    .font(.edEyebrow)
                    .tracking(1.0)
                    .foregroundStyle(Tokens.muted)
                    .lineLimit(1)
            }
            if let time, !time.isEmpty {
                // Time reads as a real detail on the pass, not a footnote:
                // bumped to body-medium ink, still subordinate to the display
                // airport code above it.
                Text(time)
                    .font(.edBodyMedium)
                    .monospacedDigit()
                    .foregroundStyle(Tokens.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .multilineTextAlignment(alignment == .leading ? .leading : .trailing)
    }

    /// The departure time from the timeline's own time treatment, unless untimed.
    /// Used by the event layout (a single moment) where `timeText` is one time.
    private var departureTime: String? {
        guard let t = timeText, !t.isEmpty, t != "Anytime" else { return nil }
        return t
    }

    /// Departure / arrival times for the boarding-pass hero, derived straight
    /// from the item so each endpoint shows its own clock (the combined
    /// `timeText` pairs both with an arrow, which we don't want per-endpoint).
    /// Both go through the shared UTC-pinned formatter.
    private var departureTimeText: String? {
        guard let t = item.startTime else { return nil }
        return TimelineEntry.itineraryTimeFormatter.string(from: t)
    }

    private var arrivalTimeText: String? {
        guard let t = item.arrivalTime else { return nil }
        return TimelineEntry.itineraryTimeFormatter.string(from: t)
    }

    /// "IndiGo · 6E681" for the label bar, from whatever of the two is present.
    private var operatorLabel: String {
        [meta?.airline, meta?.flightNumber]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    // MARK: Event top

    private var eventTop: some View {
        VStack(spacing: Space.md) {
            Text(item.eyebrow)
                .font(.edEyebrow)
                .textCase(.uppercase)
                .tracking(1.4)
                .foregroundStyle(palette.accent)

            if showsTitle {
                Text(item.title)
                    .font(.edTitle)
                    .foregroundStyle(Tokens.ink)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }

            if !item.venue.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(Tokens.muted)
                    Text(item.venue)
                        .font(.edCaption)
                        .foregroundStyle(Tokens.muted)
                        .lineLimit(1)
                }
            }

            // Time is the event's primary "when": promoted out of the equal-
            // weight facts strip into a prominent accent-led line under the
            // venue, so it reads first among the details.
            if let time = departureTime {
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(palette.accent)
                    Text(time)
                        .font(.edBodyMedium)
                        .monospacedDigit()
                        .foregroundStyle(Tokens.ink)
                        .lineLimit(1)
                }
            }

            if !eventFacts.isEmpty {
                factsRow(eventFacts)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Stay top

    /// Hotel layout: a "STAY" eyebrow with the confirmation code on the right
    /// (mirroring the flight-number placement), the hotel name, a symmetric
    /// check-in → check-out hero, a check-in / check-out time strip, and an
    /// address + MAP line. Every datum appears once: the confirmation lives in
    /// the eyebrow, the nights count on the hero path, and the times in the
    /// facts strip.
    private var compactStayTop: some View {
        VStack(spacing: Space.lg) {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Text(item.eyebrow)
                    .font(.edEyebrow)
                    .textCase(.uppercase)
                    .tracking(1.4)
                    .foregroundStyle(palette.accent)
                Spacer(minLength: Space.sm)
                if !confirmationCode.isEmpty {
                    Text(confirmationCode)
                        .font(.edFootnote)
                        .foregroundStyle(Tokens.inkSoft)
                        .lineLimit(1)
                }
            }

            if showsTitle {
                Text(item.title)
                    .font(.edTitle)
                    .foregroundStyle(Tokens.ink)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity)
            }

            stayHero

            if !stayFacts.isEmpty {
                factsRow(stayFacts)
            }

            stayLocationLine
        }
        .frame(maxWidth: .infinity)
    }

    /// Symmetric stay hero: big check-in date, a centered bed glyph + nights
    /// count on the dashed path, big check-out date. Collapses to a single
    /// centered date when there's no distinct check-out (nil `endDate` or a
    /// same-day stay) so we never invent a second date or a fake nights count.
    @ViewBuilder
    private var stayHero: some View {
        if hasCheckOut {
            HStack(alignment: .top, spacing: Space.sm) {
                stayEndpoint(label: "CHECK-IN", date: item.primaryDate, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                stayConnector
                    .padding(.top, 6)

                stayEndpoint(label: "CHECK-OUT", date: item.endDate ?? item.primaryDate, alignment: .trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        } else {
            stayEndpoint(label: "CHECK-IN", date: item.primaryDate, alignment: .center)
                .frame(maxWidth: .infinity)
        }
    }

    /// A centered bed glyph between two short dashed segments (the stay's
    /// "duration path"), with the nights count stacked beneath it. Balances the
    /// two `maxWidth: .infinity` date endpoints on either side, keeping the hero
    /// symmetric like the flight route hero's plane connector.
    private var stayConnector: some View {
        VStack(spacing: 4) {
            HStack(spacing: 5) {
                dashSegment
                Image(systemName: "bed.double.fill")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(palette.accent)
                    .accessibilityHidden(true)
                dashSegment
            }
            if let nights = nightsCount {
                Text(nights == 1 ? "1 NIGHT" : "\(nights) NIGHTS")
                    .font(.edEyebrow)
                    .tracking(1.0)
                    .foregroundStyle(Tokens.muted)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    /// One end of the stay hero: big date, small "CHECK-IN" / "CHECK-OUT" label.
    /// `alignment` pins the stack to its outer edge so the two ends mirror.
    private func stayEndpoint(label: String, date: Date, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 3) {
            Text(bigDate(date))
                .font(.edDisplay)
                .foregroundStyle(Tokens.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.edEyebrow)
                .tracking(1.0)
                .foregroundStyle(Tokens.muted)
                .lineLimit(1)
        }
        .multilineTextAlignment(alignment == .leading ? .leading : (alignment == .trailing ? .trailing : .center))
    }

    /// Address + MAP chip line, reusing the same MAP-pill pattern as the plain
    /// timeline row. Renders only when there's an address to show or a resolvable
    /// maps URL (explicit link, or derived from the address).
    @ViewBuilder
    private var stayLocationLine: some View {
        let hasAddress = !item.address.isEmpty
        let url = item.mapsURL
        if hasAddress || url != nil {
            HStack(alignment: .center, spacing: 6) {
                if hasAddress {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(Tokens.muted)
                    Text(item.address)
                        .font(.edCaption)
                        .foregroundStyle(Tokens.muted)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: Space.sm)
                if let url {
                    mapChip(url: url)
                }
            }
        }
    }

    /// The MAP pill. Its own tap target opens Google Maps without triggering the
    /// card's tap (which goes to the scan surface / editor).
    private func mapChip(url: URL) -> some View {
        Button {
            openURL(url)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "map.fill")
                    .font(.system(size: 10, weight: .regular))
                Text("MAP")
                    .font(.edEyebrow)
                    .textCase(.uppercase)
                    .tracking(1.4)
            }
            .foregroundStyle(palette.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(palette.accent.opacity(0.12), in: Capsule(style: .continuous))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open in Google Maps")
    }

    // MARK: Stay derived values

    /// Nights between check-in (`dayDate`) and check-out (`endDate`), or `nil`
    /// when there's no distinct check-out. Never returns 0 or negative — a
    /// same-day / missing check-out collapses the hero instead of showing "0
    /// nights".
    private var nightsCount: Int? {
        guard let end = item.endDate else { return nil }
        // Both days are UTC anchors, so the span is counted in the UTC calendar
        // (#506). Counted in the device calendar, a DST boundary between the two
        // could drop or add a night.
        let n = WallClock.storedDayCount(from: item.primaryDate, to: end)
        return n > 0 ? n : nil
    }

    /// Whether to render the symmetric two-date hero vs the collapsed single date.
    private var hasCheckOut: Bool { nightsCount != nil }

    /// Check-in / check-out times, formatted with the same UTC-pinned formatter
    /// as the timeline so they show the stated booking time regardless of the
    /// device timezone. `nil` when the corresponding time wasn't set.
    private var checkInTimeText: String? {
        guard let t = item.startTime else { return nil }
        return TimelineEntry.itineraryTimeFormatter.string(from: t)
    }

    private var checkOutTimeText: String? {
        guard let t = item.endTime else { return nil }
        return TimelineEntry.itineraryTimeFormatter.string(from: t)
    }

    // MARK: - Facts

    /// Boarding-pass facts: the four canonical slots always render so the grid
    /// stays a balanced 4-column strip. Unknown gate/terminal show an em dash
    /// (via `TicketField`) rather than a fabricated value.
    private var boardingPassFacts: [TicketFact] {
        [
            TicketFact(label: "Seat",     value: item.seat, allowDash: true),
            TicketFact(label: "Gate",     value: TicketField.code(item.gate), allowDash: true),
            TicketFact(label: "Terminal", value: TicketField.code(meta?.terminal), allowDash: true),
            TicketFact(label: "Cabin",    value: meta?.cabin, allowDash: true)
        ]
    }

    /// Event facts: only the slots that carry a real value, so a sparse ticket
    /// doesn't show empty columns. Time is deliberately excluded here: it's
    /// promoted to its own prominent line above the facts strip (see `eventTop`).
    private var eventFacts: [TicketFact] {
        [
            TicketFact(label: "Section", value: meta?.section),
            TicketFact(label: "Row",     value: meta?.row),
            TicketFact(label: "Seat",    value: item.seat.isEmpty ? nil : item.seat)
        ].filter { $0.value != nil }
    }

    /// Stay facts: the check-in and check-out times, each shown only when set.
    /// A balanced strip of whatever exists (0, 1, or 2 columns). Nights and the
    /// confirmation code deliberately aren't repeated here — they already live
    /// on the hero path and in the eyebrow respectively.
    private var stayFacts: [TicketFact] {
        [
            TicketFact(label: "Check-in",  value: checkInTimeText),
            TicketFact(label: "Check-out", value: checkOutTimeText)
        ].filter { $0.value != nil }
    }

    private func factsRow(_ facts: [TicketFact]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(facts.enumerated()), id: \.element.id) { index, fact in
                if index > 0 {
                    Rectangle()
                        .fill(palette.factRule)
                        .frame(width: 0.5, height: 26)
                }
                TicketFactCell(fact: fact)
            }
        }
    }

    // MARK: - Barcode stub (below the perforation)

    /// The tear-off stub: a white panel (both themes) with the code centered and
    /// the PNR / reference centered beneath, so it reads as a scannable ticket
    /// stub rather than a lopsided thumbnail.
    @ViewBuilder
    private var barcodeStub: some View {
        if !item.hasTicket && !hasLocationStub {
            codeStub
        } else if hasLocationStub {
            StayLocationStub(
                address: item.address,
                mapsURL: item.mapsURL,
                paper: palette.stubPaper,
                ink: palette.stubInk,
                muted: palette.stubMuted,
                buttonFill: palette.band
            )
        } else if let onTapBarcode {
            // The stub's own gesture sits INSIDE the body's, so SwiftUI hands the
            // tap to this one and the body's handler never fires for it.
            scannableStub
                .contentShape(Rectangle())
                .onTapGesture(perform: onTapBarcode)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Present this code")
        } else {
            scannableStub
        }
    }

    /// The stub of a card with nothing to scan and nowhere to go: a hand-typed
    /// membership, a booking held under a reference (#481).
    ///
    /// It prints the code large and monospaced, because that is what the stub is
    /// FOR — the thing you read out at a desk. Empty when there is no code either,
    /// which keeps the card's silhouette without inventing content for it.
    private var codeStub: some View {
        VStack(spacing: Space.xs) {
            if !confirmationCode.isEmpty {
                Text(pnrLabel)
                    .font(.edEyebrow)
                    .tracking(1.4)
                    .foregroundStyle(stubMuted)
                Text(confirmationCode)
                    .font(.edDisplay)
                    .monospaced()
                    .foregroundStyle(stubInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, embedded ? Space.lg : Space.md)
        .padding(.horizontal, Space.md)
        .background {
            if embedded {
                stubPaper
            } else {
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .fill(Tokens.ticketStub)
            }
        }
    }

    private var scannableStub: some View {
        VStack(spacing: Space.sm) {
            BarcodeImageView(
                payload: item.barcodePayload,
                symbology: item.barcodeSymbology,
                attachmentPath: item.attachmentPath,
                height: stubBarcodeHeight,
                // The wallet's stub is the bottom of a full ticket rather than a
                // thumbnail on a timeline row, so the code gets the room a
                // scannable code deserves.
                compact: !embedded,
                alignment: .center
            )
            // The generated code is black on WHITE, so on tinted paper it would
            // otherwise read as a white rectangle dropped on the ticket. Giving
            // it a deliberate plate turns that into the quiet zone a scanner
            // wants anyway.
            .padding(embedded ? Space.md : 0)
            .background {
                if embedded {
                    RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                        .fill(Tokens.ticketStub)
                }
            }
            // A square code in a full-width plate reads as a slab with a QR
            // dropped in the middle; the plate hugs it instead. A wide PDF417
            // genuinely wants the width, so it keeps it.
            .frame(maxWidth: barcodePlateWidth)

            // A stay already shows its confirmation in the eyebrow, so the stub
            // stays code-free (just the scannable barcode). Flights / events
            // keep their PNR / REF line beneath the code.
            if !confirmationCode.isEmpty && !isStay {
                HStack(spacing: 6) {
                    Text(pnrLabel)
                        .font(.edEyebrow)
                        .tracking(1.4)
                        .foregroundStyle(stubMuted)
                    Text(confirmationCode)
                        .font(.edMono)
                        .foregroundStyle(stubInk)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, embedded ? Space.lg : Space.md)
        .padding(.horizontal, Space.md)
        .background {
            if embedded {
                // Bleeds to the card's own edges: the stub IS the bottom of the
                // ticket, not a panel sitting on it.
                stubPaper
            } else {
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .fill(Tokens.ticketStub)
            }
        }
    }

    /// A square QR/Aztec wants more height than a wide 1D/PDF417 strip. The
    /// wallet's full ticket gets a bigger code than the timeline thumbnail: it
    /// is the thing you hold up at a gate.
    private var stubBarcodeHeight: CGFloat {
        switch BarcodeSymbology(rawValue: item.barcodeSymbology) ?? .other {
        case .qr, .aztec, .other: return embedded ? 132 : 84
        case .pdf417, .code128:   return embedded ? 76 : 52
        }
    }

    /// How wide the white code plate may grow. `.infinity` for the wide 1D /
    /// PDF417 strips, which fill it honestly.
    private var barcodePlateWidth: CGFloat {
        guard embedded else { return .infinity }
        switch BarcodeSymbology(rawValue: item.barcodeSymbology) ?? .other {
        case .qr, .aztec, .other: return stubBarcodeHeight + Space.xxl + Space.md
        case .pdf417, .code128:   return .infinity
        }
    }

    private var confirmationCode: String {
        item.sourceConfirmation.trimmingCharacters(in: .whitespaces)
    }

    private var pnrLabel: String {
        item.isBoardingPassStyle ? "PNR" : "REF"
    }
}

// MARK: - Ticket facts

/// One labelled fact in the card's evenly-distributed facts strip.
private struct TicketFact: Identifiable {
    let id = UUID()
    let label: String
    let value: String?
    /// When true (boarding-pass slots), an absent value renders an em dash so
    /// the 4-column grid stays balanced. Event slots pass false and are filtered
    /// out upstream instead.
    var allowDash: Bool = false

    init(label: String, value: String?, allowDash: Bool = false) {
        self.label = label
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.value = (trimmed?.isEmpty == false) ? trimmed : nil
        self.allowDash = allowDash
    }
}

/// A centered label-over-value cell that expands to an equal share of the row,
/// so any number of facts distributes symmetrically across the card width.
private struct TicketFactCell: View {
    let fact: TicketFact

    private var isUnknown: Bool { fact.value == nil }

    var body: some View {
        VStack(spacing: 3) {
            Text(fact.label.uppercased())
                .font(.edEyebrow)
                .tracking(1.0)
                .foregroundStyle(Tokens.muted)
            Text(fact.value ?? TicketField.unknownDash)
                .font(.edFootnote)
                .foregroundStyle(isUnknown ? Tokens.mutedSoft : Tokens.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Perforated divider

/// The classic ticket "tear" line: a dashed rule with a punched notch at each
/// edge. Purely decorative.
///
/// Two ways to punch the notches, and which one is right depends on what is
/// behind the card:
///  - **Painted** (`cutout: false`, the trip timeline): circles filled with the
///    page colour, drawn on top of the card. Cheap, and correct as long as the
///    card really does sit on `Tokens.paper`.
///  - **Cut** (`cutout: true`, the wallet): the enclosing card removes the holes
///    from its own outline via `TicketShape`, so anything behind shows through
///    and the notches survive a card stacked on another card. This mode draws
///    only the dashes and reports where they sit.
struct PerforatedDivider: View {
    var notch: CGFloat = 14
    /// See the note above: `true` means the parent cuts the holes.
    var cutout: Bool = false
    var lineColor: Color = Tokens.borderStrong

    var body: some View {
        ZStack {
            DashedLine()
                .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .foregroundStyle(lineColor)
                .frame(height: 1)
                .padding(.horizontal, notch)

            if !cutout {
                HStack {
                    notchCircle
                    Spacer()
                    notchCircle
                }
            }
        }
        .frame(height: notch)
        // Only meaningful in cutout mode; harmless otherwise (nothing upstream
        // reads the preference).
        .ticketNotchAnchor()
    }

    private var notchCircle: some View {
        Circle()
            .fill(Tokens.paper)
            .frame(width: notch, height: notch)
            .overlay(
                Circle().strokeBorder(Tokens.border, lineWidth: 0.5)
            )
            // Pull each notch half over the card edge for the punched look.
            .offset(x: 0)
    }
}

/// Horizontal hairline used by the perforation.
private struct DashedLine: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

// MARK: - Barcode image view (shared with the scan screen)

/// Renders a scannable barcode from a stored payload + symbology, regenerated
/// on-device with CoreImage. Falls back to the cropped original attachment when
/// the symbology can't be regenerated (e.g. DataMatrix), and to a neutral
/// placeholder when nothing is available. Rendering runs off the main actor and
/// the result is cached in `@State`, so it's cheap inside a scrolling list.
struct BarcodeImageView: View {
    let payload: String
    let symbology: String
    let attachmentPath: String
    /// Target render height in points.
    var height: CGFloat = 64
    /// Compact mode limits the on-card thumbnail width so a wide PDF417 doesn't
    /// dominate the card; the full scan screen uses `compact = false`.
    var compact: Bool = false
    /// Placement of the code within its available width. The timeline card
    /// centers it on the stub; the editor thumbnail keeps the default leading.
    var alignment: Alignment = .leading

    @State private var rendered: PlatformImage?
    @State private var didAttempt = false

    var body: some View {
        Group {
            if let rendered {
                Image(platformImage: rendered)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
                    .frame(height: height)
                    .frame(maxWidth: compact ? 180 : .infinity)
                    .frame(maxWidth: .infinity, alignment: alignment)
            } else {
                placeholder
            }
        }
        .task(id: cacheKey) { await renderIfNeeded() }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
            .fill(Tokens.surface2)
            .frame(height: height)
            .frame(maxWidth: compact ? 180 : .infinity)
            .frame(maxWidth: .infinity, alignment: alignment)
            .overlay(
                Image(systemName: "barcode")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(Tokens.mutedSoft)
            )
    }

    private var cacheKey: String { "\(symbology)|\(payload.count)|\(attachmentPath)|\(Int(height))" }

    private func renderIfNeeded() async {
        guard rendered == nil, !didAttempt else { return }
        didAttempt = true
        let payloadCopy = payload
        let symbol = BarcodeSymbology(rawValue: symbology) ?? .other
        // Regenerate off the main actor; CoreImage + UIGraphicsImageRenderer are
        // safe off-main and this keeps scrolling smooth.
        let image = await Task.detached(priority: .userInitiated) { () -> PlatformImage? in
            if let regenerated = BarcodeService.render(payload: payloadCopy, symbology: symbol, targetLongEdge: 900) {
                return regenerated
            }
            return nil
        }.value
        if let image {
            rendered = image
            return
        }
        // Fall back to the original attachment, cropped to the barcode if we can
        // re-detect it (bounding box isn't persisted).
        if let fallback = await loadAttachmentBarcodeCrop() {
            rendered = fallback
        }
    }

    /// Load the original attachment and crop to its barcode's bounding box when
    /// detectable, so the fallback shows the code rather than the whole ticket.
    private func loadAttachmentBarcodeCrop() async -> PlatformImage? {
        guard !attachmentPath.isEmpty,
              let url = TicketStorage.shared.load(relativePath: attachmentPath) else { return nil }
        let isPDF = TicketStorage.isPDF(attachmentPath)
        return await Task.detached(priority: .userInitiated) { () -> PlatformImage? in
            let base: PlatformImage?
            if isPDF {
                let data = (try? Data(contentsOf: url))
                base = data.flatMap { BarcodeService.renderFirstPage(pdfData: $0) }
            } else {
                base = loadReceiptPlatformImage(url)
            }
            guard let base else { return nil }
            if let decoded = BarcodeService.decode(image: base) {
                return BarcodeService.crop(image: base, toNormalized: decoded.boundingBox)
            }
            return base
        }.value
    }
}
