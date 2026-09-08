import Foundation
import SwiftData

/// Local-first SwiftData model for an event an expense can be tagged with
/// (#183). Answers "what did the Bali trip cost me?" or "how much on Diwali
/// gifts?".
///
/// A general grouping — not travel-specific — so it doesn't force a date range
/// or travel framing onto non-travel groupings. When the event IS travel, it
/// can optionally point at an existing `LocalTrip` via `tripUUID` so trip spend
/// rolls up. Expenses link back via `LocalExpense.eventUUID` (join by
/// `clientUUID`, like the rest of the local models), with the event name
/// denormalised onto the row so it stays self-describing after a delete.
///
/// Mirrors the `LocalTrip` shape (name + optional dates + notes + timestamps).
@Model
final class LocalEvent {
    @Attribute(.unique) var clientUUID: UUID

    /// Event title (e.g. "Bali trip", "Diwali gifts"). Required. Matched
    /// case-insensitively by `EventService.findOrCreate` so the same name
    /// reuses one record.
    var name: String

    /// Optional first day of the event, inclusive. Stored as a UTC-anchored
    /// day via `WallClock.dayAnchor(from:)` when set, so the day does not move
    /// with the device timezone (#506). Nil for open-ended groupings.
    var startDate: Date?

    /// Optional last day of the event, inclusive. Same UTC-anchored day shape
    /// as `startDate`.
    var endDate: Date?

    /// Optional link to an existing `LocalTrip` (`LocalTrip.clientUUID`) so
    /// travel spend rolls up under the trip. Nil for non-travel events.
    var tripUUID: UUID?

    /// Free-form notes. Empty when none. Mirrors `LocalTrip.notes`.
    var notes: String = ""

    var createdAt: Date
    var updatedAt: Date

    init(
        clientUUID: UUID = UUID(),
        name: String,
        startDate: Date? = nil,
        endDate: Date? = nil,
        tripUUID: UUID? = nil,
        notes: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.clientUUID = clientUUID
        self.name = name
        self.startDate = startDate
        self.endDate = endDate
        self.tripUUID = tripUUID
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
