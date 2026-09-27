import Foundation
@preconcurrency import EventKit
import MCP

private struct ReminderResults: @unchecked Sendable {
    let values: [EKReminder]
}

@MainActor
final class EventKitService {
    private let store = EKEventStore()

    func call(_ name: String, _ a: [String: Value]) async throws -> String {
        switch name {
        case "list_reminder_lists":
            try await remindersPermission()
            return try encode(store.calendars(for: .reminder).map { ["id": $0.calendarIdentifier, "title": $0.title] })
        case "search_reminders":
            try await remindersPermission()
            let listID = a["list_id"]?.stringValue
            let lists = store.calendars(for: .reminder).filter { listID == nil || $0.calendarIdentifier == listID }
            if listID != nil && lists.isEmpty { throw Err.message("Reminder list not found. Call list_reminder_lists for available IDs.") }
            let pred = store.predicateForReminders(in: lists)
            let items = await fetchReminders(matching: pred)
            let completed = a["completed"]?.boolValue
            let query = a["query"]?.stringValue?.lowercased()
            let from = try date(a["due_from"]?.stringValue), to = try date(a["due_to"]?.stringValue)
            return try encode(items.filter { r in
                (completed == nil || r.isCompleted == completed!) &&
                (query == nil || r.title.lowercased().contains(query!) || (r.notes ?? "").lowercased().contains(query!)) &&
                (from == nil || (r.dueDateComponents?.date ?? .distantPast) >= from!) &&
                (to == nil || (r.dueDateComponents?.date ?? .distantFuture) <= to!)
            }.map(reminderJSON))
        case "create_reminder":
            try await remindersPermission()
            let reminder = EKReminder(eventStore: store)
            reminder.title = try requiredString(a, "title")
            reminder.notes = a["notes"]?.stringValue
            if let priority = a["priority"]?.intValue { guard (0...9).contains(priority) else { throw Err.message("priority must be between 0 and 9") }; reminder.priority = priority }
            if let due = try date(a["due"]?.stringValue) { reminder.dueDateComponents = Calendar.current.dateComponents([.year,.month,.day,.hour,.minute], from: due) }
            reminder.calendar = try reminderCalendar(a["list_id"]?.stringValue)
            try store.save(reminder, commit: true)
            return try encode([reminderJSON(reminder)])
        case "update_reminder", "delete_reminder":
            try await remindersPermission()
            let id = try requiredString(a, "id")
            guard let reminder = await fetchReminders(matching: store.predicateForReminders(in: nil)).first(where: { $0.calendarItemIdentifier == id }) else { throw Err.message("Reminder ID not found or stale: \(id)") }
            if name == "delete_reminder" { try store.remove(reminder, commit: true); return try encode([["deleted_id": id]]) }
            if let v = a["title"]?.stringValue { reminder.title = v }
            if let v = a["notes"]?.stringValue { reminder.notes = v }
            if let v = a["completed"]?.boolValue { reminder.isCompleted = v; reminder.completionDate = v ? Date() : nil }
            if let v = a["due"]?.stringValue { reminder.dueDateComponents = try date(v).map { Calendar.current.dateComponents([.year,.month,.day,.hour,.minute], from: $0) } }
            if let v = a["priority"]?.intValue { guard (0...9).contains(v) else { throw Err.message("priority must be between 0 and 9") }; reminder.priority = v }
            try store.save(reminder, commit: true)
            return try encode([reminderJSON(reminder)])
        case "list_calendars":
            try await calendarPermission()
            return try encode(store.calendars(for: .event).map { ["id": $0.calendarIdentifier, "title": $0.title, "writable": $0.allowsContentModifications] })
        case "search_events":
            try await calendarPermission()
            guard let start = try date(a["start"]?.stringValue), let end = try date(a["end"]?.stringValue), start < end else { throw Err.message("Provide start and end as ISO 8601 timestamps with explicit offsets; start must precede end.") }
            let calendarID = a["calendar_id"]?.stringValue
            let calendars = store.calendars(for: .event).filter { calendarID == nil || $0.calendarIdentifier == calendarID }
            if calendarID != nil && calendars.isEmpty { throw Err.message("Calendar not found. Call list_calendars for available IDs.") }
            let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: calendars))
            let query = a["query"]?.stringValue?.lowercased()
            return try encode(events.filter { query == nil || $0.title.lowercased().contains(query!) || ($0.notes ?? "").lowercased().contains(query!) }.map(eventJSON))
        case "create_event":
            try await calendarPermission()
            let e = EKEvent(eventStore: store)
            e.title = try requiredString(a, "title")
            guard let start = try date(a["start"]?.stringValue), let end = try date(a["end"]?.stringValue), start < end else { throw Err.message("start and end must be ISO 8601 timestamps with explicit offsets; start must precede end.") }
            e.startDate = start; e.endDate = end; e.isAllDay = a["all_day"]?.boolValue ?? false
            e.location = a["location"]?.stringValue; e.notes = a["notes"]?.stringValue
            e.calendar = try eventCalendar(a["calendar_id"]?.stringValue)
            try store.save(e, span: .thisEvent, commit: true)
            return try encode([eventJSON(e)])
        case "update_event", "delete_event":
            try await calendarPermission()
            let id = try requiredString(a, "id")
            guard let e = store.event(withIdentifier: id) else { throw Err.message("Event ID not found or stale: \(id)") }
            if e.hasRecurrenceRules { throw Err.message("Recurring event changes are unsupported in version one.") }
            if name == "delete_event" { try store.remove(e, span: .thisEvent, commit: true); return try encode([["deleted_id": id]]) }
            if let v = a["title"]?.stringValue { e.title = v }
            if let v = a["start"]?.stringValue { guard let d = try date(v) else { throw Err.message("Invalid start date") }; e.startDate = d }
            if let v = a["end"]?.stringValue { guard let d = try date(v) else { throw Err.message("Invalid end date") }; e.endDate = d }
            if e.startDate >= e.endDate { throw Err.message("Event end must be after start.") }
            if let v = a["all_day"]?.boolValue { e.isAllDay = v }
            if let v = a["location"]?.stringValue { e.location = v }
            if let v = a["notes"]?.stringValue { e.notes = v }
            try store.save(e, span: .thisEvent, commit: true)
            return try encode([eventJSON(e)])
        default: throw Err.message("Unknown tool: \(name)")
        }
    }

    private func encode(_ objects: [[String: Any]]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: objects, options: [.fragmentsAllowed, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
    private func remindersPermission() async throws {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if status == .notDetermined { guard try await store.requestFullAccessToReminders() else { throw Err.message("Reminders access was not granted. Enable it in System Settings > Privacy & Security > Reminders.") }; return }
        guard status == .fullAccess else { throw Err.message("Full Reminders access is required. Enable it in System Settings > Privacy & Security > Reminders.") }
    }
    private func calendarPermission() async throws {
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .notDetermined { guard try await store.requestFullAccessToEvents() else { throw Err.message("Calendar access was not granted. Enable it in System Settings > Privacy & Security > Calendars.") }; return }
        guard status == .fullAccess else { throw Err.message("Full Calendar access is required. Enable it in System Settings > Privacy & Security > Calendars.") }
    }
    private func reminderCalendar(_ id: String?) throws -> EKCalendar {
        let lists = store.calendars(for: .reminder)
        if let id { guard let found = lists.first(where: { $0.calendarIdentifier == id }) else { throw Err.message("Reminder list not found: \(id)") }; return found }
        guard let defaultList = store.defaultCalendarForNewReminders() else { throw Err.message("No default reminder list. Pass list_id from list_reminder_lists.") }
        return defaultList
    }
    private func eventCalendar(_ id: String?) throws -> EKCalendar {
        let calendars = store.calendars(for: .event).filter(\.allowsContentModifications)
        if let id { guard let found = calendars.first(where: { $0.calendarIdentifier == id }) else { throw Err.message("Writable calendar not found: \(id)") }; return found }
        guard let fallback = store.defaultCalendarForNewEvents, fallback.allowsContentModifications else { throw Err.message("No writable default calendar. Pass calendar_id from list_calendars.") }
        return fallback
    }
    private func fetchReminders(matching predicate: NSPredicate) async -> [EKReminder] {
        let result: ReminderResults = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: ReminderResults(values: reminders ?? []))
            }
        }
        return result.values
    }
    private func date(_ s: String?) throws -> Date? {
        guard let s else { return nil }
        guard s.range(of: #"(?:Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil else {
            throw Err.message("Invalid ISO 8601 date/time (include an explicit UTC offset): \(s)")
        }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        guard let d = f.date(from: s) else { throw Err.message("Invalid ISO 8601 date/time (include an explicit offset): \(s)") }
        return d
    }
    private func requiredString(_ a: [String: Value], _ k: String) throws -> String { guard let v = a[k]?.stringValue, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Err.message("Missing required string: \(k)") }; return v }
    private func iso(_ date: Date?) -> String? { guard let date else { return nil }; return ISO8601DateFormatter().string(from: date) }
    private func reminderJSON(_ r: EKReminder) -> [String: Any] { ["id":r.calendarItemIdentifier,"title":r.title ?? "","notes":r.notes.map { $0 as Any } ?? NSNull(),"due":iso(r.dueDateComponents?.date).map { $0 as Any } ?? NSNull(),"completed":r.isCompleted,"priority":r.priority,"list":r.calendar.title,"list_id":r.calendar.calendarIdentifier,"modified":iso(r.lastModifiedDate).map { $0 as Any } ?? NSNull()] }
    private func eventJSON(_ e: EKEvent) -> [String: Any] {
        let recurrenceSummary: Any
        if let rules = e.recurrenceRules, !rules.isEmpty {
            recurrenceSummary = rules.map { rule in
                switch rule.frequency {
                case .daily: "daily"
                case .weekly: "weekly"
                case .monthly: "monthly"
                case .yearly: "yearly"
                @unknown default: "unknown"
                }
            }.joined(separator: ",")
        } else {
            recurrenceSummary = NSNull()
        }

        return [
            "id": e.eventIdentifier ?? e.calendarItemIdentifier,
            "title": e.title ?? "",
            "start": iso(e.startDate) ?? "",
            "end": iso(e.endDate) ?? "",
            "all_day": e.isAllDay,
            "location": e.location.map { $0 as Any } ?? NSNull(),
            "notes": e.notes.map { $0 as Any } ?? NSNull(),
            "calendar": e.calendar.title,
            "calendar_id": e.calendar.calendarIdentifier,
            "recurring": e.hasRecurrenceRules,
            "recurrence_summary": recurrenceSummary,
        ]
    }
}

enum Err: LocalizedError { case message(String); var errorDescription: String? { if case .message(let s) = self { return s }; return nil } }

private func schema(_ properties: [String: Value], required: [String] = []) -> Value {
    var body: [String: Value] = ["type": .string("object"), "properties": .object(properties)]
    if !required.isEmpty { body["required"] = .array(required.map(Value.string)) }
    return .object(body)
}
private func stringProp(_ description: String) -> Value { .object(["type": .string("string"), "description": .string(description)]) }
private func boolProp(_ description: String) -> Value { .object(["type": .string("boolean"), "description": .string(description)]) }
private func numberProp(_ description: String) -> Value { .object(["type": .string("integer"), "description": .string(description)]) }

@main struct LocalCalendarMCP {
    static func main() async throws {
        let args = CommandLine.arguments
        func option(_ name: String, fallback: String) -> String { guard let i = args.firstIndex(of: name), args.indices.contains(i + 1) else { return fallback }; return args[i + 1] }
        guard option("--host", fallback: "127.0.0.1") == "127.0.0.1" else { fatalError("This server only binds to 127.0.0.1") }
        let service = EventKitService()
        let app = HTTPApp(host: "127.0.0.1", port: Int(option("--port", fallback: "8765")) ?? 8765, endpoint: "/mcp") { _, transport in
            let server = Server(name: "local-calendar-reminders", version: "1.0.0", instructions: "Local Apple Calendar and Reminders. Dates use ISO 8601 with offsets. Writes affect native data.", capabilities: .init(tools: .init()))
            let tools: [Tool] = [
                Tool(name:"list_reminder_lists",description:"List available Reminders lists and stable IDs.",inputSchema:schema([:])),
                Tool(name:"search_reminders",description:"Search reminders. Optional completion and due bounds; due bounds use ISO 8601.",inputSchema:schema(["list_id":stringProp("Reminder list ID"),"query":stringProp("Title or notes contains"),"completed":boolProp("Completion filter"),"due_from":stringProp("Inclusive due lower bound"),"due_to":stringProp("Inclusive due upper bound")])),
                Tool(name:"create_reminder",description:"Create a native reminder; specify list_id to choose destination.",inputSchema:schema(["title":stringProp("Reminder title"),"notes":stringProp("Optional notes"),"due":stringProp("Optional ISO 8601 due timestamp"),"priority":numberProp("Priority 0 to 9"),"list_id":stringProp("Optional destination list ID")],required:["title"])),
                Tool(name:"update_reminder",description:"Update fields on one reminder by stable ID; omitted fields remain unchanged.",inputSchema:schema(["id":stringProp("Stable reminder ID"),"title":stringProp("New title"),"notes":stringProp("New notes"),"due":stringProp("New ISO 8601 due timestamp"),"priority":numberProp("Priority 0 to 9"),"completed":boolProp("Completion state")],required:["id"])),
                Tool(name:"delete_reminder",description:"Delete exactly one reminder by stable ID.",inputSchema:schema(["id":stringProp("Stable reminder ID")],required:["id"])),
                Tool(name:"list_calendars",description:"List available event calendars and stable IDs.",inputSchema:schema([:])),
                Tool(name:"search_events",description:"Search events in a required bounded time range; use ISO 8601 timestamps with explicit offsets.",inputSchema:schema(["start":stringProp("Inclusive range start"),"end":stringProp("Exclusive range end"),"calendar_id":stringProp("Optional calendar ID"),"query":stringProp("Optional title or notes text")],required:["start","end"])),
                Tool(name:"create_event",description:"Create a native Calendar event. Times require ISO 8601 explicit offsets.",inputSchema:schema(["title":stringProp("Event title"),"start":stringProp("Start timestamp"),"end":stringProp("End timestamp"),"all_day":boolProp("All-day flag"),"location":stringProp("Location"),"notes":stringProp("Notes"),"calendar_id":stringProp("Destination calendar ID")],required:["title","start","end"])),
                Tool(name:"update_event",description:"Update one event by ID. Recurring events are rejected.",inputSchema:schema(["id":stringProp("Stable event ID"),"title":stringProp("New title"),"start":stringProp("New start timestamp"),"end":stringProp("New end timestamp"),"all_day":boolProp("All-day flag"),"location":stringProp("Location"),"notes":stringProp("Notes")],required:["id"])),
                Tool(name:"delete_event",description:"Delete one event by ID. Recurring events are rejected.",inputSchema:schema(["id":stringProp("Stable event ID")],required:["id"]))
            ]
            await server.withMethodHandler(ListTools.self) { _ in .init(tools: tools) }
            await server.withMethodHandler(CallTool.self) { params in
                do {
                    let result = try await service.call(params.name, params.arguments ?? [:])
                    return .init(content: [.text(text: result, annotations: nil, _meta: nil)], isError: false)
                } catch { return .init(content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)], isError: true) }
            }
            return server
        }
        print("Local Calendar MCP listening at http://127.0.0.1:\(option("--port", fallback: "8765"))/mcp")
        try await app.start()
    }
}
