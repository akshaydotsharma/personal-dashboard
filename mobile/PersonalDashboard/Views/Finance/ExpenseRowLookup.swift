import SwiftUI
import SwiftData

/// The people and trips an `ExpenseRow` needs for its badges, fetched ONCE per
/// list rather than once per row (#442).
///
/// `ExpenseRow` used to declare its own `@Query` for people and a second one for
/// trips. Four people and four trips is a trivial fetch, which is why it read as
/// cheap, but a `@Query` belongs to the VIEW that declares it: a Finance list
/// showing a full year registered roughly 3,040 separate fetches to look up
/// eight records, and every one of them had to be set up before the first frame
/// could paint. Hoisting the two queries into `ExpenseRowLookupScope` and
/// passing the result down through the environment makes it two.
struct ExpenseRowLookup {
    /// Colour by person FK.
    private var colorByPersonUUID: [UUID: String] = [:]

    /// Name / colour pairs, kept as a list rather than a dictionary so the
    /// name fallback can use the same `.caseInsensitive` comparison the row
    /// used before. People are few, so the linear scan costs nothing.
    private var namedColors: [(name: String, colorHex: String)] = []

    /// Name by person FK, for the split avatars (#508), which resolve a person
    /// id straight out of the split payload rather than reading a denormalised
    /// name off the expense row.
    private var nameByPersonUUID: [UUID: String] = [:]

    /// Trip name by trip FK.
    private var nameByTripUUID: [UUID: String] = [:]

    /// Used by any surface that renders an `ExpenseRow` without injecting a
    /// scope. Behaves exactly like a store with no people and no trips: the
    /// person badge falls back to the Finance accent and a trip badge reads
    /// "Trip", which is the same fallback the per-row query produced for a
    /// deleted person or trip.
    static let empty = ExpenseRowLookup()

    private init() {}

    init(people: [LocalPerson], trips: [LocalTrip]) {
        for person in people {
            colorByPersonUUID[person.clientUUID] = person.colorHex
            nameByPersonUUID[person.clientUUID] = person.name
            namedColors.append((name: person.name, colorHex: person.colorHex))
        }
        for trip in trips {
            nameByTripUUID[trip.clientUUID] = trip.name
        }
    }

    /// Colour for a row's person badge: FK first, then the denormalised name
    /// (which survives the person being deleted). `nil` when neither resolves,
    /// letting the caller pick its own default tint.
    func personColorHex(uuid: UUID?, name: String?) -> String? {
        if let uuid, let hex = colorByPersonUUID[uuid] { return hex }
        if let name {
            for entry in namedColors
            where entry.name.compare(name, options: .caseInsensitive) == .orderedSame {
                return entry.colorHex
            }
        }
        return nil
    }

    /// Display name for a person id, or `nil` when the person has been deleted
    /// since a split recorded them.
    func personName(uuid: UUID) -> String? {
        nameByPersonUUID[uuid]
    }

    /// Colour for a person id alone (no denormalised-name fallback), for the
    /// split avatars where the id is all the payload carries.
    func personColorHex(uuid: UUID) -> String? {
        colorByPersonUUID[uuid]
    }

    /// Name of the trip a row belongs to, or `nil` when the FK is missing or the
    /// trip has been deleted.
    func tripName(uuid: UUID?) -> String? {
        guard let uuid else { return nil }
        return nameByTripUUID[uuid]
    }
}

private struct ExpenseRowLookupKey: EnvironmentKey {
    static let defaultValue = ExpenseRowLookup.empty
}

extension EnvironmentValues {
    var expenseRowLookup: ExpenseRowLookup {
        get { self[ExpenseRowLookupKey.self] }
        set { self[ExpenseRowLookupKey.self] = newValue }
    }
}

/// Wrap a list of `ExpenseRow`s in this so they share one people / trips fetch.
///
/// Every surface that renders expense rows should use it — Finance, a trip's
/// expenses tab, the parsed-file detail — because without it the rows silently
/// fall back to `ExpenseRowLookup.empty` and lose their person colours and trip
/// names.
struct ExpenseRowLookupScope<Content: View>: View {
    @Query(sort: [SortDescriptor(\LocalPerson.name, order: .forward)])
    private var people: [LocalPerson]

    @Query private var trips: [LocalTrip]

    @ViewBuilder var content: Content

    var body: some View {
        content
            .environment(\.expenseRowLookup, ExpenseRowLookup(people: people, trips: trips))
    }
}
