import Foundation
import SwiftData

/// Item-level deduplication for the email-ingest path (#143).
///
/// Message-level idempotency (`LocalProcessedEmail` by Message-Id) does NOT
/// cover two real cases:
///   (a) Re-scan, which deliberately bypasses the message ledger, and
///   (b) the user forwarding the SAME booking as two different emails (two
///       Airbnb PDFs of one Florence reservation: same confirmation code,
///       same dates/title, different Message-Ids).
/// Both would otherwise add the same itinerary item twice. This helper makes
/// each proposed item dedup against what already exists on the SAME trip, so
/// either path yields exactly one row.
///
/// Scope: used ONLY by `EmailToItinerary`. Chat/capture adds never call this
/// and keep their current behaviour. The signature is also stored on the row
/// (`dedupeKey` / `sourceConfirmation`) so a later email can match it cheaply.
enum EmailItemDedupe {

    /// A proposed item parsed out of an `add_itinerary_item` tool input,
    /// reduced to the fields that define equivalence.
    struct Proposed {
        let kind: String          // ItineraryKind.rawValue, lowercased
        let dayDate: Date         // UTC-anchored day (#506)
        let endDate: Date?        // UTC-anchored day, stays only
        let title: String         // raw title (for storage)
        let confirmation: String  // extracted code, or "" if none
        let startTime: Date?      // UTC wall-clock departure time, or nil
    }

    /// Segment discriminator for a proposed item: the key that keeps distinct
    /// legs of one PNR apart while a re-forward of the SAME leg collides.
    ///
    /// Shape: `"\(kind):\(dayKey(dayDate)):\(disc)"`, where `disc` is the
    /// departure time as `HH:mm` when `startTime != nil` (two legs on the same
    /// day depart at different times), else the normalized title. For stays the
    /// checkout date is appended (matching the old structural key) so two
    /// stays sharing a check-in day stay distinct; stays carry no start_time,
    /// so they fall back to the title discriminator plus the checkout date.
    ///
    /// The `HH:mm` is read with a UTC calendar. Post-#168 all itinerary times
    /// are stored as UTC wall-clock (via `ExecuteDraftAction.parseWallClockTime`,
    /// which strips the tz designator and parses in UTC), so reading back in
    /// UTC yields the stated departure time and matches how the row's
    /// `startTime` is actually stored.
    static func segmentKey(_ proposed: Proposed) -> String {
        let day = dayKey(proposed.dayDate)
        if proposed.kind == "stay", let end = proposed.endDate {
            let disc = discriminator(startTime: proposed.startTime, title: proposed.title)
            return "stay:\(day)-\(dayKey(end)):\(disc)"
        }
        let disc = discriminator(startTime: proposed.startTime, title: proposed.title)
        return "\(proposed.kind):\(day):\(disc)"
    }

    /// The per-segment discriminator: `HH:mm` (UTC) when a start time is known,
    /// otherwise the normalized title.
    private static func discriminator(startTime: Date?, title: String) -> String {
        if let start = startTime {
            return timeKey(start)
        }
        return normalizeTitle(title)
    }

    /// Compute the equivalence signature for a proposed item on a given trip.
    ///
    /// Strongest signal first: when a confirmation/reservation code is present,
    /// equivalence is (tripUUID + confirmationCode + segment) — two different
    /// emails of the same LEG collide here regardless of how their titles/dates
    /// render, while distinct legs of one PNR stay apart on the segment.
    /// Otherwise fall back to (tripUUID + segment). The segment already carries
    /// kind + dayDate + (time or title), plus the checkout date for stays.
    static func signature(tripUUID: UUID, proposed: Proposed) -> String {
        let trip = tripUUID.uuidString.lowercased()
        let segment = segmentKey(proposed)
        if !proposed.confirmation.isEmpty {
            // Combine the code with the segment key so a single PNR covering
            // several distinct legs keeps them distinct, while a re-forward of
            // the SAME leg collides. The code still lets title/date rewordings
            // across two emails of the same leg match via `exists`'s
            // confirmation check below (now also segment-scoped).
            return "conf:\(trip):\(normalizeConfirmation(proposed.confirmation)):\(segment)"
        }
        return "k:\(trip):\(segment)"
    }

    /// True when an equivalent item already exists on the trip. Checks both the
    /// stored `dedupeKey` (fast path for items the email path created) AND a
    /// structural comparison against existing rows (covers items created before
    /// this field existed, and confirmation-vs-structural mismatches).
    @MainActor
    static func exists(signature: String, proposed: Proposed, tripUUID: UUID, context: ModelContext) -> Bool {
        // Fast path: a previously-ingested item carrying the same dedupeKey.
        // The dedupeKey is segment-precise (it embeds the segment via
        // `signature`), so this only hits a row that is the SAME segment.
        let sig = signature
        let byKey = (try? context.fetchCount(
            FetchDescriptor<LocalItineraryItem>(
                predicate: #Predicate { $0.dedupeKey == sig }
            )
        )) ?? 0
        if byKey > 0 { return true }

        let targetSegment = segmentKey(proposed)

        // Confirmation + segment match: a row that stored the same code AND
        // whose segment equals the proposed segment. Same code alone is NOT
        // enough — distinct legs of one PNR share the code but differ on the
        // segment, so leg 2 must NOT be treated as existing just because leg 1
        // carries the PNR. Fetch code candidates, then match segment in memory.
        if !proposed.confirmation.isEmpty {
            let conf = normalizeConfirmation(proposed.confirmation)
            let candidates = (try? context.fetch(
                FetchDescriptor<LocalItineraryItem>(
                    predicate: #Predicate { $0.tripUUID == tripUUID && $0.sourceConfirmation == conf }
                )
            )) ?? []
            for row in candidates where rowSegment(row) == targetSegment {
                return true
            }
            // No candidate shares the segment: fall through to the structural
            // pass (which is itself segment-based) rather than declaring a hit.
        }

        // Structural fallback: compare against all items on the trip (covers
        // chat-created or pre-field rows that have no dedupeKey). Done in
        // memory because the segment (normalized title / HH:mm) isn't
        // expressible in a #Predicate. A match is an equal segment.
        let fk = tripUUID
        let rows = (try? context.fetch(
            FetchDescriptor<LocalItineraryItem>(predicate: #Predicate { $0.tripUUID == fk })
        )) ?? []
        for row in rows where rowSegment(row) == targetSegment {
            return true
        }
        return false
    }

    /// Find the existing row a proposed item is equivalent to, and report
    /// whether the match was made on the confirmation code (the strong signal)
    /// or only structurally. Mirrors `exists`'s matching order, but returns the
    /// row instead of a bool so the reconcile-update path (#165) can update it.
    ///
    /// `byConfirmation` is true ONLY when the proposed item carries a
    /// confirmation code AND that normalized code equals the row's stored
    /// `sourceConfirmation`. A `dedupeKey` fast-path hit or a structural
    /// fallback match both return `byConfirmation == false`, so the caller can
    /// keep today's SKIP behaviour for anything short of a confirmation match.
    @MainActor
    static func match(signature: String, proposed: Proposed, tripUUID: UUID, context: ModelContext) -> (row: LocalItineraryItem, byConfirmation: Bool)? {
        let targetSegment = segmentKey(proposed)

        // Confirmation + segment match first (the only path allowed to trigger
        // an update). A row that stored the same normalized code AND shares the
        // proposed segment is the SAME leg — reconcile updates it. If the PNR
        // matches but no row shares the segment (a new leg of the same ticket),
        // fall through so the leg is ADDED, not merged into a sibling leg.
        if !proposed.confirmation.isEmpty {
            let conf = normalizeConfirmation(proposed.confirmation)
            if !conf.isEmpty {
                let candidates = (try? context.fetch(
                    FetchDescriptor<LocalItineraryItem>(
                        predicate: #Predicate { $0.tripUUID == tripUUID && $0.sourceConfirmation == conf }
                    )
                )) ?? []
                if let row = candidates.first(where: { rowSegment($0) == targetSegment }) {
                    return (row, true)
                }
            }
        }

        // Fast path: a previously-ingested item carrying the same dedupeKey.
        // This is a structural identity, not a confirmation identity. The
        // dedupeKey is segment-precise, so this is already a same-segment hit.
        let sig = signature
        if let row = try? context.fetch(
            FetchDescriptor<LocalItineraryItem>(
                predicate: #Predicate { $0.dedupeKey == sig }
            )
        ).first {
            return (row, false)
        }

        // Structural fallback: compare against all items on the trip (covers
        // chat-created or pre-field rows that have no dedupeKey). In memory
        // because the segment (normalized title / HH:mm) isn't expressible in a
        // #Predicate. Matches an equal segment.
        let fk = tripUUID
        let rows = (try? context.fetch(
            FetchDescriptor<LocalItineraryItem>(predicate: #Predicate { $0.tripUUID == fk })
        )) ?? []
        if let row = rows.first(where: { rowSegment($0) == targetSegment }) {
            return (row, false)
        }
        return nil
    }

    /// The segment key for an existing stored row, computed the SAME way as
    /// `segmentKey(_:)` for a proposed item, so `exists`/`match` compare like
    /// for like. Threads the row's `startTime` through the same UTC `HH:mm`
    /// discriminator.
    private static func rowSegment(_ row: LocalItineraryItem) -> String {
        let proposed = Proposed(
            kind: row.kind.lowercased(),
            dayDate: row.dayDate,
            endDate: row.endDate,
            title: row.title,
            confirmation: "",
            startTime: row.startTime
        )
        return segmentKey(proposed)
    }

    // MARK: - Normalisation

    static func normalizeTitle(_ title: String) -> String {
        let lowered = title.lowercased()
        let collapsed = lowered.replacingOccurrences(
            of: "\\s+", with: " ", options: .regularExpression
        )
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizeConfirmation(_ code: String) -> String {
        code.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    /// `yyyy-MM-dd` read in UTC. Days are stored as UTC anchors (#506), so the
    /// key must be read in the same calendar the day was written in. Read
    /// through `Calendar.current` (the default the gregorian initializer gives
    /// you) the key moved with the device timezone, exactly as `timeKey` below
    /// would have if it had not been pinned to UTC: re-forwarding the same
    /// booking email from another zone then produced a different key, and a
    /// duplicate stop.
    private static func dayKey(_ date: Date) -> String {
        let c = WallClock.dayCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// `HH:mm` read in UTC. Post-#168 itinerary times are stored as UTC
    /// wall-clock, so reading the hour/minute in UTC returns the stated
    /// departure time — the same anchor `ExecuteDraftAction.parseWallClockTime`
    /// uses when it stores the row.
    private static func timeKey(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? cal.timeZone
        let c = cal.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    // MARK: - Confirmation-code extraction

    /// Pull a booking/reservation/confirmation code out of free text. Looks for
    /// an explicit "confirmation code"/"booking reference"/"PNR"/"reservation"
    /// label followed by an alphanumeric token, then falls back to a standalone
    /// 6–12 char uppercase-alphanumeric token (airline PNRs, Airbnb codes).
    /// Returns "" when nothing convincing is found.
    static func extractConfirmation(from text: String) -> String {
        // Most-specific labels first. A generic "reservation"/"reference" label
        // can appear far from the actual code (e.g. "Reservation details ...
        // coming4 guests"), so prefer the strong labels and, within each label,
        // take the BEST nearby token, not just the first.
        let labels = [
            "confirmation code", "confirmation number", "confirmation",
            "booking reference", "booking ref", "booking code", "booking id",
            "reservation code", "reservation number",
            "record locator", "reference number",
            "pnr", "booking", "reservation", "reference",
        ]
        let lower = text.lowercased()
        for label in labels {
            guard let r = lower.range(of: label) else { continue }
            // Look only at a short window after the label so a distant word
            // doesn't get picked. Codes sit right next to their label.
            let tail = text[r.upperBound...]
            let window = String(tail.prefix(60))
            if let token = bestCodeToken(in: window) {
                return token
            }
        }
        // Label-free fallback: scan the whole text for a strong code token.
        if let token = bestCodeToken(in: text, strongOnly: true) {
            return token
        }
        return ""
    }

    /// Pick the most code-like token in `text`. A "strong" code is ≥8 chars OR
    /// has ≥2 digits — this rejects word+digit artifacts like "coming4" while
    /// accepting real PNRs and Airbnb codes (HM84R8EPNF, ABC123).
    ///
    /// PDF text normalisation can glue a code to the next word ("HM84R8EPNF" +
    /// "Cancellation" -> "HM84R8EPNFCancellation"), so we first try a regex
    /// that captures an UPPERCASE-alphanumeric run of 6–12 chars (with ≥1
    /// digit) even when it's the prefix of a longer mixed-case run — codes are
    /// upper-case, the glued word that follows starts with one capital then
    /// lowercase, so the uppercase run ends cleanly at the code boundary.
    /// Falls back to whitespace/punctuation token splitting.
    private static func bestCodeToken(in text: String, strongOnly: Bool = false) -> String? {
        // 1) Uppercase-run regex: capture a 6–13 run of [A-Z0-9] that starts at
        //    a non-alphanumeric boundary. When the run is immediately followed
        //    by a lowercase letter, the trailing uppercase char is the start of
        //    a glued next word (PDF normalisation removed the space, e.g.
        //    "HM84R8EPNFCancellation"), so drop it. This recovers the code even
        //    when it's fused to the following word.
        let pattern = "(?<![A-Za-z0-9])[A-Z0-9]{6,13}"
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let ns = text as NSString
            for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                var token = ns.substring(with: m.range)
                let after = m.range.location + m.range.length
                if after < ns.length {
                    let nextChar = ns.substring(with: NSRange(location: after, length: 1))
                    if nextChar.rangeOfCharacter(from: .lowercaseLetters) != nil {
                        token = String(token.dropLast())
                    }
                }
                guard token.count >= 6, token.count <= 12 else { continue }
                let digits = token.filter { $0.isNumber }.count
                guard digits >= 1, digits < token.count else { continue }
                let isStrong = token.count >= 8 || digits >= 2
                if isStrong { return token }
            }
        }
        // 2) Token-split fallback (handles lowercase/mixed codes).
        let tokens = text.split { !($0.isLetter || $0.isNumber) }
        var weak: String?
        for raw in tokens.prefix(40) {
            let t = String(raw)
            guard t.count >= 6, t.count <= 14 else { continue }
            let upper = t.uppercased()
            guard upper.allSatisfy({ $0.isLetter || $0.isNumber }) else { continue }
            let digits = upper.filter { $0.isNumber }.count
            guard digits >= 1, digits < upper.count else { continue }
            let isStrong = upper.count >= 8 || digits >= 2
            if isStrong { return upper }
            if !strongOnly, weak == nil { weak = upper }
        }
        return strongOnly ? nil : weak
    }
}
