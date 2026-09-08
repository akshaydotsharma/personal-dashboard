import Foundation

/// On-device chat draft. Replaces the server-issued `Draft` for the chat
/// surface: carries the action type, the raw JSON tool input (passed
/// straight to `ExecuteDraftAction`), and a pre-rendered preview string.
///
/// `id` is a synthetic local UUID — drafts in chat-mode never persist to
/// any backend, so SwiftUI just needs a stable identity for `ForEach`.
struct ChatDraft: Identifiable, Hashable, Sendable {
    let id: UUID
    let actionType: DraftActionType
    let input: AnthropicJSONValue
    let preview: String

    init(id: UUID = UUID(), actionType: DraftActionType, input: AnthropicJSONValue, preview: String) {
        self.id = id
        self.actionType = actionType
        self.input = input
        self.preview = preview
    }
}

extension ChatDraft {
    /// Build a human-readable summary for one tool call. Ported from
    /// `generateDraftSummary` in server/ai/chatToDrafts.js so cards render
    /// the same prose users have been seeing from the server.
    static func makePreview(actionType: DraftActionType, input: AnthropicJSONValue) -> String {
        let dict = input.objectValue ?? [:]

        switch actionType {
        case .deleteTodo:
            return "Delete todo (ID: \(dict["id"]?.stringValue ?? "?"))"
        case .deleteNote:
            return "Delete note (ID: \(dict["id"]?.stringValue ?? "?"))"
        case .deleteList:
            return "Delete list (ID: \(dict["id"]?.stringValue ?? "?"))"
        case .deleteFolder:
            return "Delete folder (ID: \(dict["id"]?.stringValue ?? "?"))"

        case .removeListItem:
            let listId = dict["list_id"]?.stringValue ?? "?"
            let idx = dict["item_index"]?.intValue.map(String.init) ?? "?"
            return "Remove item [\(idx)] from list (ID: \(listId))"

        case .completeTodo:
            let completed = dict["completed"]?.boolValue ?? true
            let verb = completed ? "Complete" : "Uncomplete"
            return "\(verb) task (ID: \(dict["id"]?.stringValue ?? "?"))"

        case .updateListItem:
            let listId = dict["list_id"]?.stringValue ?? "?"
            let idx = dict["item_index"]?.intValue.map(String.init) ?? "?"
            var summary = "Edit item [\(idx)] in list (ID: \(listId))"
            if let text = dict["text"]?.stringValue, !text.isEmpty {
                summary += ": \"\(text)\""
            }
            if let checked = dict["checked"]?.boolValue {
                summary += checked ? " (mark done)" : " (mark undone)"
            }
            return summary

        case .updateTodo:
            var summary = "Edit task (ID: \(dict["id"]?.stringValue ?? "?"))"
            if let title = dict["title"]?.stringValue, !title.isEmpty, title != "null" {
                summary += ": \"\(title)\""
            }
            if let raw = dict["priority"]?.stringValue, !raw.isEmpty {
                if raw == "null" {
                    summary += " {clear priority}"
                } else if let p = TaskPriority(aiString: raw) {
                    summary += " {\(p.label)}"
                }
            }
            return summary

        case .updateNote:
            var summary = "Edit note (ID: \(dict["id"]?.stringValue ?? "?"))"
            if let title = dict["title"]?.stringValue, !title.isEmpty, title != "null" {
                summary += ": \"\(title)\""
            }
            return summary

        case .appendToNote:
            var summary = "Append to note (ID: \(dict["id"]?.stringValue ?? "?"))"
            if let content = dict["content"]?.stringValue,
               !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                let snippet = trimmed.count > 60 ? String(trimmed.prefix(57)) + "…" : trimmed
                summary += ": \"\(snippet)\""
            }
            return summary

        case .updateList:
            var summary = "Edit list (ID: \(dict["id"]?.stringValue ?? "?"))"
            if let title = dict["title"]?.stringValue, !title.isEmpty, title != "null" {
                summary += ": \"\(title)\""
            }
            return summary

        case .addToList:
            let count = dict["new_items"]?.arrayValue?.count ?? 0
            return "Add \(count) item\(count == 1 ? "" : "s") to list (ID: \(dict["id"]?.stringValue ?? "?"))"

        case .updateFolder:
            let name = dict["name"]?.stringValue ?? ""
            return "Rename folder (ID: \(dict["id"]?.stringValue ?? "?")) to \"\(name)\""

        case .createTodo:
            var summary = "Task: \"\(dict["title"]?.stringValue ?? "Untitled")\""
            if let due = dict["due_at"]?.stringValue, !due.isEmpty, due != "null",
               let date = Self.parseISODate(due) {
                summary += " (due: \(Self.dateOnly.string(from: date)))"
            }
            if let tag = dict["tag"]?.stringValue, !tag.isEmpty, tag != "null" {
                summary += " [\(tag)]"
            }
            if let p = TaskPriority(aiString: dict["priority"]?.stringValue), p != .none {
                summary += " {\(p.label)}"
            }
            return summary

        case .createNote:
            return "Note: \"\(dict["title"]?.stringValue ?? "Untitled")\""

        case .createList:
            let count = dict["items"]?.arrayValue?.count ?? 0
            return "List: \"\(dict["title"]?.stringValue ?? "Untitled")\" with \(count) item\(count == 1 ? "" : "s")"

        case .createTrip:
            let name = dict["name"]?.stringValue ?? "Untitled"
            let start = (dict["start_date"]?.stringValue).flatMap(Self.parseAnyDate)
            let end = (dict["end_date"]?.stringValue).flatMap(Self.parseAnyDate)
            if let start, let end {
                let range = Self.dateRange(start: start, end: end)
                let days = Self.inclusiveDays(start: start, end: end)
                return "\(name) · \(range) · \(days) day\(days == 1 ? "" : "s")"
            }
            return "Trip: \"\(name)\""

        case .addItineraryItems:
            let items = dict["items"]?.arrayValue ?? []
            if items.count == 1, let only = items.first?.objectValue {
                let title = only["title"]?.stringValue ?? "Untitled"
                let kindRaw = (only["kind"]?.stringValue ?? "").lowercased()
                let kindEnum = ItineraryKind(rawValue: kindRaw)
                // For transport, prefer the specific mode label (Flight / Train)
                // over the generic "Transport", matching the timeline chip.
                let modeLabel = (kindEnum == .transport)
                    ? TransportMode(rawValue: (only["mode"]?.stringValue ?? "").lowercased())?.displayName
                    : nil
                let kind = modeLabel ?? kindEnum?.displayName ?? "Item"
                // We don't know Day N without the trip context; show date only.
                let day = (only["day_date"]?.stringValue).flatMap(Self.parseAnyDate)
                let dayDisplay = day.map { Self.shortDayMonth.string(from: $0) } ?? ""
                if !dayDisplay.isEmpty {
                    return "\(title) · \(kind) · \(dayDisplay)"
                }
                return "\(title) · \(kind)"
            }
            // Multiple items. Build a comma-joined list of titles and
            // truncate the joined run to ~40 chars total to stay readable.
            let titles = items.compactMap { $0.objectValue?["title"]?.stringValue }
            let joined = titles.joined(separator: ", ")
            let truncated = joined.count > 40 ? String(joined.prefix(37)) + "…" : joined
            return "\(items.count) item\(items.count == 1 ? "" : "s"): \(truncated)"

        case .updateTrip:
            return Self.updateTripSummary(dict: dict)

        case .updateItineraryItem:
            return Self.updateItineraryItemSummary(dict: dict)

        case .deleteTrip:
            return "Delete trip (ID: \(dict["id"]?.stringValue ?? "?"))"

        case .deleteItineraryItem:
            return "Delete itinerary item (ID: \(dict["id"]?.stringValue ?? "?"))"

        case .addExpense:
            return Self.addExpenseSummary(dict: dict)

        case .addRecurringExpense:
            return Self.addRecurringExpenseSummary(dict: dict)

        case .clearExpenses:
            return Self.clearExpensesSummary(dict: dict)

        case .unknown:
            return "Unknown action"
        }
    }

    /// Preview for `clear_expenses`. The card is rendered before the executor
    /// runs, so the exact count isn't known here — describe the SCOPE instead
    /// ("Clear Groceries expenses after 1 Jun 2026"). An unfiltered clear reads
    /// "Clear ALL expenses"; without confirm_all it flags that confirmation is
    /// still required, mirroring the executor's guard.
    private static func clearExpensesSummary(dict: [String: AnthropicJSONValue]) -> String {
        let after = (dict["after_date"]?.stringValue).flatMap(parseAnyDate)
        let before = (dict["before_date"]?.stringValue).flatMap(parseAnyDate)
        let categoryRaw = (dict["category"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let category = categoryRaw.isEmpty ? nil : ExpenseCategory(rawValue: categoryRaw)
        let source = (dict["source"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let confirmAll = dict["confirm_all"]?.boolValue ?? false

        let hasFilter = after != nil || before != nil || !categoryRaw.isEmpty || !source.isEmpty
        if !hasFilter {
            return confirmAll ? "Clear ALL expenses" : "Clear ALL expenses — needs confirmation"
        }

        var parts: [String] = []
        if let category {
            parts.append(category.displayName)
        } else if !categoryRaw.isEmpty {
            parts.append(categoryRaw)
        }
        var scope = "Clear \(parts.isEmpty ? "" : parts.joined() + " ")expenses"
        // Name the import source (#251), e.g. "Clear expenses imported from DBS".
        if !source.isEmpty {
            scope += " imported from \(source)"
        }
        if let after, let before {
            scope += " between \(shortDayMonth.string(from: after)) and \(shortDayMonth.string(from: before))"
        } else if let after {
            scope += " after \(shortDayMonth.string(from: after))"
        } else if let before {
            scope += " before \(shortDayMonth.string(from: before))"
        }
        return scope
    }

    /// Preview for `add_recurring_expense`. Reads like a recurring rule:
    /// "Rent · SGD 2000.00/mo · on the 1st · Bills & Utilities".
    private static func addRecurringExpenseSummary(dict: [String: AnthropicJSONValue]) -> String {
        let amount = dict["amount"]?.doubleValue
            ?? Double(dict["amount"]?.stringValue ?? "")
            ?? 0
        let currency = (dict["currency"]?.stringValue ?? "SGD")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let cleanedCurrency = currency.isEmpty ? "SGD" : currency

        let categoryRaw = (dict["category"]?.stringValue ?? "").lowercased()
        let categoryName = ExpenseCategory(rawValue: categoryRaw)?.displayName ?? "Other"

        let merchant = (dict["merchant"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let description = (dict["description"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let headline: String
        if !merchant.isEmpty {
            headline = merchant
        } else if !description.isEmpty {
            headline = description
        } else {
            headline = categoryName
        }

        let day = max(min(dict["day_of_month"]?.intValue
            ?? Int(dict["day_of_month"]?.stringValue ?? "")
            ?? 1, 31), 1)

        let amountString = String(format: "%@ %.2f/mo", cleanedCurrency, amount)
        var line = headline == categoryName
            ? "\(amountString) · on the \(ordinal(day))"
            : "\(headline) · \(amountString) · on the \(ordinal(day)) · \(categoryName)"

        if let endRaw = dict["end_date"]?.stringValue, let end = parseAnyDate(endRaw) {
            line += " · until \(shortDayMonth.string(from: end))"
        }
        return line
    }

    /// "1st", "2nd", "3rd", "21st", "31st" for the day-of-month readout.
    private static func ordinal(_ n: Int) -> String {
        let suffix: String
        switch (n % 100, n % 10) {
        case (11, _), (12, _), (13, _): suffix = "th"
        case (_, 1): suffix = "st"
        case (_, 2): suffix = "nd"
        case (_, 3): suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }

    /// Preview for `add_expense`. Format aims for the same scannable shape
    /// the user sees on the Finance list: "Merchant · SGD 67.50 · Category".
    private static func addExpenseSummary(dict: [String: AnthropicJSONValue]) -> String {
        let amount = dict["original_amount"]?.doubleValue
            ?? Double(dict["original_amount"]?.stringValue ?? "")
            ?? 0
        let currency = (dict["original_currency"]?.stringValue ?? "SGD")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let cleanedCurrency = currency.isEmpty ? "SGD" : currency

        let categoryRaw = (dict["category"]?.stringValue ?? "").lowercased()
        let categoryName = ExpenseCategory(rawValue: categoryRaw)?.displayName ?? "Other"

        let merchant = (dict["merchant"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let description = (dict["description"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let headline: String
        if !merchant.isEmpty {
            headline = merchant
        } else if !description.isEmpty {
            headline = description
        } else {
            headline = categoryName
        }

        // Split shares (#188). `amount` from the model is the FULL receipt
        // total; the stored expense is the user's equal share. Preview the
        // share (what actually lands) and annotate the fraction.
        let shares = max(dict["number_of_shares"]?.intValue
            ?? Int(dict["number_of_shares"]?.stringValue ?? "")
            ?? 1, 1)
        let displayAmount = amount / Double(shares)

        let amountString = String(format: "%@ %.2f", cleanedCurrency, displayAmount)
        let shareSuffix = shares > 1 ? " (your 1/\(shares) share)" : ""
        // Base line: headline · amount[ (your 1/N share)] [· category],
        // skipping the category when it's already the headline.
        var line = headline == categoryName
            ? "\(headline) · \(amountString)\(shareSuffix)"
            : "\(headline) · \(amountString)\(shareSuffix) · \(categoryName)"

        // Person / Event tags (#183) so the confirm card shows what the
        // expense was tagged with before the user commits.
        let person = (dict["person_name"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let event = (dict["event_name"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !person.isEmpty {
            line += " · with \(person)"
        }
        if !event.isEmpty {
            line += " · \(event)"
        }

        // Trip / group split (#258): who paid + how many ways, when present, so
        // the confirm card reads "Sam paid · split 4 ways" before the user
        // commits. Payer is named only when someone other than the user paid.
        let payer = (dict["paid_by"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let splitWith = dict["split_with"]?.arrayValue?.compactMap { $0.stringValue } ?? []
        if !payer.isEmpty, !isMeToken(payer) {
            line += " · \(payer) paid"
        }
        if splitWith.count > 1 {
            line += " · split \(splitWith.count) ways"
        }
        return line
    }

    /// True when a split name refers to the user rather than another person.
    /// Mirrors `ExecuteDraftAction.isMeToken` so the preview and the executor
    /// agree on who the user is.
    private static func isMeToken(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["me", "myself", "i", "you", "self"].contains(t)
    }

    /// Build the preview for `edit_trip`. Falls back to a generic line if
    /// no field actually carries a change.
    private static func updateTripSummary(dict: [String: AnthropicJSONValue]) -> String {
        var pieces: [String] = []
        if let name = dict["name"]?.stringValue, !name.isEmpty, name != "null" {
            pieces.append("Rename to \(name)")
        }
        let start = (dict["start_date"]?.stringValue).flatMap { $0.isEmpty || $0 == "null" ? nil : parseAnyDate($0) }
        let end = (dict["end_date"]?.stringValue).flatMap { $0.isEmpty || $0 == "null" ? nil : parseAnyDate($0) }
        if let start, let end {
            pieces.append("Move to \(dateRange(start: start, end: end))")
        } else if let start {
            pieces.append("Start \(shortDayMonth.string(from: start))")
        } else if let end {
            pieces.append("End \(shortDayMonth.string(from: end))")
        }
        if let raw = dict["notes"]?.stringValue {
            if raw == "null" {
                pieces.append("Clear notes")
            } else if !raw.isEmpty {
                pieces.append("Update notes")
            }
        }
        if pieces.isEmpty {
            return "Edit trip (ID: \(dict["id"]?.stringValue ?? "?"))"
        }
        return pieces.joined(separator: " · ")
    }

    private static func updateItineraryItemSummary(dict: [String: AnthropicJSONValue]) -> String {
        var pieces: [String] = []
        if let title = dict["title"]?.stringValue, !title.isEmpty, title != "null" {
            pieces.append("Rename to \(title)")
        }
        if let raw = dict["day_date"]?.stringValue, !raw.isEmpty, raw != "null",
           let day = parseAnyDate(raw) {
            pieces.append("Move to \(shortDayMonth.string(from: day))")
        }
        if let raw = dict["kind"]?.stringValue, !raw.isEmpty, raw != "null",
           let kind = ItineraryKind(rawValue: raw.lowercased()) {
            pieces.append("Kind \(kind.displayName)")
        }
        if let raw = dict["notes"]?.stringValue {
            if raw == "null" {
                pieces.append("Clear notes")
            } else if !raw.isEmpty {
                pieces.append("Update notes")
            }
        }
        if pieces.isEmpty {
            return "Edit itinerary item (ID: \(dict["id"]?.stringValue ?? "?"))"
        }
        return pieces.joined(separator: " · ")
    }

    /// Inclusive day count between two dates, counted in UTC to match the
    /// calendar `parseAnyDate` read them in (#506).
    private static func inclusiveDays(start: Date, end: Date) -> Int {
        max(1, WallClock.storedDayCount(from: start, to: end) + 1)
    }

    /// "14–21 Jun" / "29 Jun – 5 Jul" / "30 Dec 2026 – 4 Jan 2027".
    private static func dateRange(start: Date, end: Date) -> String {
        let cal = Calendar(identifier: .gregorian)
        let sameYear = cal.component(.year, from: start) == cal.component(.year, from: end)
        let sameMonth = sameYear && cal.component(.month, from: start) == cal.component(.month, from: end)
        let currentYear = cal.component(.year, from: Date()) == cal.component(.year, from: start)

        if sameMonth {
            let day1 = String(cal.component(.day, from: start))
            let day2 = String(cal.component(.day, from: end))
            let mon = monthShort.string(from: end)
            return "\(day1)–\(day2) \(mon)"
        }
        if sameYear && currentYear {
            return "\(dayMonth.string(from: start)) – \(dayMonth.string(from: end))"
        }
        // Cross-year (or distant year): include both years.
        return "\(dayMonthYear.string(from: start)) – \(dayMonthYear.string(from: end))"
    }

    static func parseAnyDate(_ raw: String) -> Date? {
        if raw.isEmpty || raw == "null" { return nil }
        if let d = iso8601Fractional.date(from: raw) { return d }
        if let d = iso8601.date(from: raw) { return d }
        if let d = dateOnlyUTC.date(from: raw) { return d }
        return nil
    }

    // Every one of these prints a day that `parseAnyDate` read in UTC, so they
    // read in UTC too. Unpinned, a draft preview showed the day BEFORE the one
    // the model wrote, anywhere west of UTC — the same class of defect as #506,
    // and it made a correct draft look wrong before the user confirmed it.
    private static let monthShort: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "MMM"; return f
    }()

    private static let dayMonth: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "d MMM"; return f
    }()

    private static let dayMonthYear: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "d MMM yyyy"; return f
    }()

    private static let shortDayMonth: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "d MMM"; return f
    }()

    private static let dateOnlyUTC: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func parseISODate(_ raw: String) -> Date? {
        if let d = iso8601Fractional.date(from: raw) { return d }
        return iso8601.date(from: raw)
    }

    private static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()
}

extension ChatDraft {
    // MARK: - View accessors

    /// Title or name from the tool input, if the action carries one. Backs
    /// the chat preview card's headline line.
    var title: String? {
        let dict = input.objectValue ?? [:]
        if let t = dict["title"]?.stringValue, !t.isEmpty, t != "null" { return t }
        if let n = dict["name"]?.stringValue, !n.isEmpty, n != "null" { return n }
        return nil
    }

    /// Body / description / content blob, if any.
    var bodyPreview: String? {
        let dict = input.objectValue ?? [:]
        for key in ["body", "description", "content"] {
            if let v = dict[key]?.stringValue, !v.isEmpty, v != "null" {
                return v
            }
        }
        return nil
    }

    /// Items array for `draft_list` / `add_to_list` previews.
    var itemTexts: [String]? {
        let dict = input.objectValue ?? [:]
        let raw = dict["items"]?.arrayValue ?? dict["new_items"]?.arrayValue ?? []
        guard !raw.isEmpty else { return nil }
        return raw.compactMap { $0.objectValue?["text"]?.stringValue }
    }

    /// Due date as a `Date`, parsed from the `due_at` ISO string.
    var dueDate: Date? {
        guard let raw = input.objectValue?["due_at"]?.stringValue,
              !raw.isEmpty, raw != "null" else { return nil }
        return Self.parseISODate(raw)
    }

    /// Tag chip, if present.
    var tag: String? {
        guard let t = input.objectValue?["tag"]?.stringValue,
              !t.isEmpty, t != "null" else { return nil }
        return t
    }
}
