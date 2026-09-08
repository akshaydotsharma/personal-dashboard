import Foundation
import SwiftData

/// Errors thrown by `EventService`. Only surfaces empty-name and persistence
/// failures — callers rarely branch on them.
enum EventServiceError: LocalizedError {
    case emptyName
    case persistence(Error)

    var errorDescription: String? {
        switch self {
        case .emptyName:            return "Event name can't be empty."
        case .persistence(let err): return err.localizedDescription
        }
    }
}

/// CRUD + find-or-create over `LocalEvent` (#183). Backs the Event picker in
/// the AddExpense sheet, the Event filter, and the AI's find-or-create by
/// name. Operates on the shared SwiftData context.
///
/// Structure mirrors `ExpenseService` / `PersonService`.
@MainActor
struct EventService {
    let store: SwiftDataStore

    init(store: SwiftDataStore) {
        self.store = store
    }

    static func `default`() -> EventService {
        EventService(store: .shared)
    }

    // MARK: - Read

    /// All events, most-recently-updated first so the freshest groupings sit
    /// at the top of the picker (matches how trips are ordered in AI context).
    func all() throws -> [LocalEvent] {
        let descriptor = FetchDescriptor<LocalEvent>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return try store.context.fetch(descriptor)
    }

    // MARK: - Find-or-create

    /// Return the existing event whose name matches `name` (case-insensitive,
    /// trimmed), or create one. Optional dates + trip link are applied ONLY
    /// when a new event is created; an existing match is returned untouched so
    /// repeated tagging doesn't clobber the user's saved details. Throws on an
    /// empty name.
    @discardableResult
    func findOrCreate(
        name: String,
        startDate: Date? = nil,
        endDate: Date? = nil,
        tripUUID: UUID? = nil
    ) throws -> LocalEvent {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EventServiceError.emptyName }

        if let existing = try all().first(where: {
            $0.name.compare(trimmed, options: .caseInsensitive) == .orderedSame
        }) {
            return existing
        }

        let now = Date()
        let row = LocalEvent(
            name: trimmed,
            startDate: startDate.map(WallClock.dayAnchor(from:)),
            endDate: endDate.map(WallClock.dayAnchor(from:)),
            tripUUID: tripUUID,
            createdAt: now,
            updatedAt: now
        )
        store.context.insert(row)
        try save()
        return row
    }

    // MARK: - Update / delete

    /// Update an event in place. Every field is a tri-state via a wrapper:
    /// omit the argument to leave it untouched; pass `.some(nil)` to clear a
    /// date / trip link; pass `.some(value)` to set it. `name` clears nothing
    /// (empty throws) since a nameless event is meaningless.
    func update(
        _ event: LocalEvent,
        name: String? = nil,
        startDate: Date?? = nil,
        endDate: Date?? = nil,
        tripUUID: UUID?? = nil
    ) throws {
        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw EventServiceError.emptyName }
            event.name = trimmed
        }
        if let startDate {
            event.startDate = startDate.map(WallClock.dayAnchor(from:))
        }
        if let endDate {
            event.endDate = endDate.map(WallClock.dayAnchor(from:))
        }
        if let tripUUID {
            event.tripUUID = tripUUID
        }
        event.updatedAt = Date()
        try save()
    }

    /// Delete an event. Expenses that referenced it keep their denormalised
    /// `eventName` (self-describing) but lose the live link.
    func delete(_ event: LocalEvent) throws {
        store.context.delete(event)
        try save()
    }

    // MARK: - Helpers

    private func save() throws {
        do {
            try store.context.save()
        } catch {
            throw EventServiceError.persistence(error)
        }
    }
}
