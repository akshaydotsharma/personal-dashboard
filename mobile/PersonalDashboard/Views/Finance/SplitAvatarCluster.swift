import SwiftUI

/// Who paid a trip expense and who it was split between, as letter avatars on
/// the expense row (#508).
///
/// The settle-up model (#258) stores the payer in `paidByPersonUUID` and the
/// per-person slices in `splitsData`, but the row surfaced neither, so the only
/// way to see "did I pay for this one, and was Priya in on it?" was to open the
/// editor. This puts both on the row's badge line.
///
/// The roster derivation is deliberately free of SwiftUI: it takes name and
/// colour resolvers rather than a `Color`, so the ordering, dedupe, cap and
/// suppression rules can be unit-tested without a view.

// MARK: - Model

/// One party in a split, ready to render as an avatar.
struct SplitAvatarParty: Identifiable, Equatable {
    let party: SplitPartyID
    /// Spoken name: "You", the person's name, or "Someone" for a person who
    /// has been deleted since the split was recorded.
    let name: String
    /// The person's chip colour. `nil` for the user and for an unresolved
    /// person, both of which fall back to the finance accent.
    let colorHex: String?
    /// The single character the avatar draws. "Y" for the user, "?" when the
    /// person can't be resolved.
    let initial: String

    var id: SplitPartyID { party }

    /// Whether a filled avatar in this party's colour needs dark lettering.
    /// The person palette runs from a dark emerald to a bright amber, so a
    /// single on-fill ink can't stay legible across it. `nil` for the user,
    /// whose fill is the theme-aware finance accent and whose ink therefore
    /// has to flip with the theme rather than with a fixed colour.
    var prefersDarkInk: Bool? {
        guard let colorHex else { return nil }
        guard let fill = SplitAvatarRoster.relativeLuminance(hex: colorHex) else { return false }
        // Whichever ink actually contrasts better, rather than a threshold:
        // half the palette sits near the white/black crossover, where a
        // guessed cutoff picks the worse of the two.
        let dark = SplitAvatarRoster.contrastRatio(fill, SplitAvatarRoster.darkInkLuminance)
        let light = SplitAvatarRoster.contrastRatio(fill, 1.0)
        return dark > light
    }
}

/// The payer plus the parties the bill was divided between.
struct SplitAvatarRoster: Equatable {
    /// At most this many sharer avatars render; the rest collapse into "+n".
    static let maxSharers = 4

    let payer: SplitAvatarParty

    /// Parties holding a positive share, payer first, deduped. Never empty: an
    /// expense with no recorded split was consumed by whoever paid it, so the
    /// payer stands as the sole sharer.
    let sharers: [SplitAvatarParty]

    /// The avatars that render, capped.
    var visibleSharers: [SplitAvatarParty] {
        Array(sharers.prefix(Self.maxSharers))
    }

    /// How many sharers the cap left out.
    var overflowCount: Int {
        max(sharers.count - Self.maxSharers, 0)
    }

    /// Build the roster for one expense. Always answers both halves of the
    /// question, including when they coincide: an expense you paid and shared
    /// with nobody reads "Y paid · Y", not a blank badge line. A row that says
    /// nothing can't be told apart from a row with nothing recorded, and on the
    /// trip surface every row has a payer even when no split was entered.
    ///
    /// - Parameters:
    ///   - payerPersonUUID: `LocalExpense.paidByPersonUUID`; nil = the user.
    ///   - splits: `LocalExpense.splits`.
    ///   - name: resolves a person id to a display name, nil if deleted.
    ///   - colorHex: resolves a person id to its chip colour.
    static func make(
        payerPersonUUID: UUID?,
        splits: [ExpenseSplitEntry],
        name: (UUID) -> String?,
        colorHex: (UUID) -> String?
    ) -> SplitAvatarRoster {
        func party(for id: UUID?) -> SplitAvatarParty {
            guard let id else {
                return SplitAvatarParty(party: .me, name: "You", colorHex: nil, initial: "Y")
            }
            let resolved = name(id)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let resolved, !resolved.isEmpty else {
                return SplitAvatarParty(
                    party: .person(id),
                    name: "Someone",
                    colorHex: nil,
                    initial: "?"
                )
            }
            return SplitAvatarParty(
                party: .person(id),
                name: resolved,
                colorHex: colorHex(id),
                initial: initial(of: resolved)
            )
        }

        let payer = party(for: payerPersonUUID)

        // Positive shares only — a zero-share entry is a party who was ticked
        // out of the bill, and the split editor leaves those behind.
        var seen: Set<SplitPartyID> = []
        var sharers: [SplitAvatarParty] = []
        for entry in splits where entry.shares > 0 {
            let candidate = party(for: entry.personID)
            guard seen.insert(candidate.party).inserted else { continue }
            sharers.append(candidate)
        }
        // Payer first, so the row reads left to right as "P paid, split P + Y".
        if let index = sharers.firstIndex(where: { $0.party == payer.party }), index != 0 {
            sharers.insert(sharers.remove(at: index), at: 0)
        }

        // No recorded split means the payer consumed the bill alone.
        if sharers.isEmpty {
            sharers = [payer]
        }
        return SplitAvatarRoster(payer: payer, sharers: sharers)
    }

    /// Relative luminance of the dark lettering a filled avatar uses when
    /// white would be the weaker of the two. Black rather than the ink token:
    /// indigo and violet clear 4.5:1 against black and miss it against
    /// `0x1F1B16`, and the fill is a fixed brand colour, so the letter can't
    /// borrow the theme's ink either.
    static let darkInkLuminance: Double = 0

    /// WCAG contrast ratio between two relative luminances.
    static func contrastRatio(_ a: Double, _ b: Double) -> Double {
        let lighter = max(a, b)
        let darker = min(a, b)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// WCAG relative luminance of a "RRGGBB" hex string, or `nil` when it
    /// can't be parsed. Used to decide whether a filled avatar wants white or
    /// near-black lettering.
    static func relativeLuminance(hex: String) -> Double? {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else { return nil }
        func channel(_ raw: UInt32) -> Double {
            let c = Double(raw) / 255.0
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let r = channel((value >> 16) & 0xFF)
        let g = channel((value >> 8) & 0xFF)
        let b = channel(value & 0xFF)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    /// What VoiceOver reads: names, never letters. "Priya paid, split between
    /// Priya and you".
    var spokenLabel: String {
        let paid = payer.party == .me ? "You paid" : "\(payer.name) paid"
        // The cluster repeats the payer when nobody else was in on the bill.
        // The avatars show that; saying "split between you" would not.
        guard sharers != [payer] else { return paid }
        let spoken = sharers.map { $0.party == .me ? "you" : $0.name }
        return "\(paid), split between \(spoken.formatted(.list(type: .and)))"
    }

    /// First character of a name, uppercased. Grapheme-safe, so an emoji or a
    /// Devanagari name yields one whole character rather than half of one.
    static func initial(of name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "?" }
        return String(first).uppercased()
    }
}

// MARK: - View

/// The badge-line indicator: the payer's avatar, the word "paid", and the
/// sharers as a light cluster.
struct SplitAvatarCluster: View {
    let roster: SplitAvatarRoster

    var body: some View {
        HStack(spacing: 4) {
            SplitAvatar(party: roster.payer, style: .payer)
            Text("paid")
                .font(.edCaption)
                .foregroundStyle(Tokens.muted)
            Text("·")
                .font(.edCaption)
                .foregroundStyle(Tokens.mutedSoft)
            HStack(spacing: 2) {
                ForEach(roster.visibleSharers) { sharer in
                    SplitAvatar(party: sharer, style: .sharer)
                }
                if roster.overflowCount > 0 {
                    Text("+\(roster.overflowCount)")
                        .font(.edCaption)
                        .monospacedDigit()
                        .foregroundStyle(Tokens.muted)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(roster.spokenLabel)
    }
}

/// One letter avatar. The payer is filled so it leads the line; sharers are
/// tinted so the cluster stays quiet behind it.
private struct SplitAvatar: View {
    enum Style {
        case payer
        case sharer

        var diameter: CGFloat { self == .payer ? 17 : 16 }
    }

    let party: SplitAvatarParty
    let style: Style

    private var tint: Color {
        guard let hex = party.colorHex else { return Tokens.accentFinance }
        return Color(personHex: hex)
    }

    /// Lettering for a filled avatar. `Tokens.paper` for the user, because the
    /// finance accent it sits on flips with the theme and `paper` flips with
    /// it; a fixed white or near-black for a person, because their palette
    /// colour does not change between themes.
    private var payerInk: Color {
        switch party.prefersDarkInk {
        case .none:     return Tokens.paper
        case .some(true):  return .black
        case .some(false): return .white
        }
    }

    var body: some View {
        Text(party.initial)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(style == .payer ? payerInk : tint)
            .frame(width: style.diameter, height: style.diameter)
            .background(style == .payer ? tint : tint.opacity(0.16), in: Circle())
            .overlay {
                if style == .sharer {
                    Circle().strokeBorder(tint.opacity(0.35), lineWidth: 0.5)
                }
            }
    }
}
