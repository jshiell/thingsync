import EventKit
import Foundation
import ThingsyncCore

private let defaultTimeout: TimeInterval = 30

/// A date-only `DateComponents`. Deliberately sets no time of day: a timed
/// component turns an all-day due date into a timed one -- a different
/// thing to the Reminders app -- and alarms are never set at all.
func dateComponents(for date: YearMonthDay?) -> DateComponents? {
    guard let date else { return nil }
    var components = DateComponents()
    components.year = date.year
    components.month = date.month
    components.day = date.day
    components.calendar = Calendar.current
    return components
}

/// Races `operation` against a deadline, matching Python's `_pump`
/// timeout -- lost once `_pump` itself was replaced by a continuation
/// bridge, added back deliberately rather than accepted as a silent
/// behaviour change.
private func withTimeout<T>(seconds: TimeInterval, error: @escaping @autoclosure () -> Error, operation: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw error()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

/// Enumerate, create, rename and delete thingsync's Reminders lists, and
/// scan their contents for markers.
///
/// Kept separate from `EventKitRemindersStore`: that one is about one
/// reminder at a time, in an already-resolved calendar; this one is about
/// the calendars themselves, which have no in-band identity marker of
/// their own.
@MainActor
public final class EventKitCalendarManager: CalendarManaging {
    private let store: EKEventStore
    private var cache: [String: EKCalendar] = [:]

    public init(store: EKEventStore) {
        self.store = store
    }

    public func allCalendars() -> [CalendarRef] {
        let calendars = store.calendars(for: .reminder)
        for calendar in calendars {
            cache[calendar.calendarIdentifier] = calendar
        }
        return calendars.map { CalendarRef(id: $0.calendarIdentifier, title: $0.title) }
    }

    public func create(title: String) throws -> CalendarRef {
        guard let defaultCalendar = store.defaultCalendarForNewReminders() else {
            throw RemindersError("no default Reminders list to create '\(title)' in")
        }
        let calendar = EKCalendar(for: .reminder, eventStore: store)
        calendar.title = title
        calendar.source = defaultCalendar.source
        do {
            try store.saveCalendar(calendar, commit: true)
        } catch {
            throw RemindersError("could not create list '\(title)': \(error)")
        }
        cache[calendar.calendarIdentifier] = calendar
        return CalendarRef(id: calendar.calendarIdentifier, title: calendar.title)
    }

    public func rename(calendarID: String, to title: String) throws {
        let calendar = try requireCalendar(calendarID)
        calendar.title = title
        do {
            try store.saveCalendar(calendar, commit: true)
        } catch {
            throw RemindersError("could not rename list to '\(title)': \(error)")
        }
    }

    public func delete(calendarID: String) throws {
        let calendar = try requireCalendar(calendarID)
        do {
            try store.removeCalendar(calendar, commit: true)
        } catch {
            throw RemindersError("could not delete list '\(calendar.title)': \(error)")
        }
        cache.removeValue(forKey: calendarID)
    }

    /// Every thingsync-relevant fact about `calendarIDs`' contents, in one
    /// pair of fetches rather than one pair per calendar.
    public func scan(calendarIDs: [String]) async throws -> [CalendarScan] {
        let calendars = calendarIDs.compactMap(requireCachedOrLive)
        for calendar in calendars {
            cache[calendar.calendarIdentifier] = calendar
        }

        let incomplete = try await fetch(
            store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars)
        )
        // has_foreign_reminder is computed over every reminder, complete or
        // not, since deleting a calendar deletes its completed reminders
        // too, and the safety rule cannot ignore those.
        let completed = try await fetch(
            store.predicateForCompletedReminders(withCompletionDateStarting: .distantPast, ending: .distantFuture, calendars: calendars)
        )

        var marked: [String: [String: String]] = [:]
        var foreign: Set<String> = []

        for reminder in incomplete {
            let calendarID = reminder.calendar.calendarIdentifier
            if let uuid = uuidFromMarker(reminder.url?.absoluteString) {
                marked[calendarID, default: [:]][uuid] = reminder.calendarItemIdentifier
            } else {
                foreign.insert(calendarID)
            }
        }
        for reminder in completed {
            let calendarID = reminder.calendar.calendarIdentifier
            if uuidFromMarker(reminder.url?.absoluteString) == nil {
                foreign.insert(calendarID)
            }
        }

        return calendarIDs.map { id in
            CalendarScan(
                calendarID: id,
                title: cache[id]?.title ?? "",
                marked: marked[id] ?? [:],
                hasForeignReminder: foreign.contains(id)
            )
        }
    }

    private func requireCachedOrLive(_ calendarID: String) -> EKCalendar? {
        cache[calendarID] ?? store.calendar(withIdentifier: calendarID)
    }

    private func requireCalendar(_ calendarID: String) throws -> EKCalendar {
        guard let calendar = requireCachedOrLive(calendarID) else {
            throw RemindersError("no calendar with identifier \(calendarID)")
        }
        cache[calendarID] = calendar
        return calendar
    }

    private func fetch(_ predicate: NSPredicate) async throws -> [EKReminder] {
        try await withTimeout(seconds: defaultTimeout, error: RemindersError("timed out scanning Reminders")) {
            await withCheckedContinuation { continuation in
                self.store.fetchReminders(matching: predicate) { reminders in
                    continuation.resume(returning: reminders ?? [])
                }
            }
        }
    }
}

/// Create, update, move and complete reminders, given an already-resolved
/// calendar for each write. Calendar identity itself is
/// `EventKitCalendarManager`'s job.
///
/// Every write commits immediately (`commit: true`) rather than batching
/// behind one final commit: a crash partway through a first run must not
/// leave created reminders unrecorded, which is the duplication path this
/// whole design exists to avoid.
@MainActor
public final class EventKitRemindersStore: ReminderSinking {
    private let store: EKEventStore

    public init(store: EKEventStore = EKEventStore()) {
        self.store = store
    }

    /// Ask for full access. Prompts the first time, on macOS 14+.
    public func requestAccess() async throws {
        let granted = try await withTimeout(seconds: defaultTimeout, error: RemindersError("timed out waiting for the Reminders permission prompt")) {
            try await self.store.requestFullAccessToReminders()
        }
        guard granted else {
            throw RemindersError("Reminders access was not granted; run `thingsync doctor` for the specifics")
        }
    }

    /// Which cached identifiers still resolve, and which calendar each is
    /// actually in now -- calendar-aware, so a reminder that moved (by
    /// hand, or because its to-do's project changed) is never mistaken for
    /// one that is still exactly where it was left.
    public func resolveLive(_ identifiers: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for identifier in identifiers {
            if let reminder = store.calendarItem(withIdentifier: identifier) as? EKReminder {
                result[identifier] = reminder.calendar.calendarIdentifier
            }
        }
        return result
    }

    public func create(calendarID: String, payload: ReminderPayload) throws -> String {
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = try requireCalendar(calendarID)
        apply(payload, to: reminder)
        try save(reminder)
        return reminder.calendarItemIdentifier
    }

    public func update(identifier: String, payload: ReminderPayload) throws {
        let reminder = try require(identifier)
        apply(payload, to: reminder)
        try save(reminder)
    }

    public func move(identifier: String, calendarID: String, payload: ReminderPayload) throws {
        let reminder = try require(identifier)
        reminder.calendar = try requireCalendar(calendarID)
        apply(payload, to: reminder)
        try save(reminder)
    }

    public func complete(identifier: String) throws {
        let reminder = try require(identifier)
        reminder.isCompleted = true
        try save(reminder)
    }

    public func delete(identifier: String) throws {
        let reminder = try require(identifier)
        do {
            try store.remove(reminder, commit: true)
        } catch {
            throw RemindersError("could not delete reminder \(identifier): \(error)")
        }
    }

    private func require(_ identifier: String) throws -> EKReminder {
        guard let reminder = store.calendarItem(withIdentifier: identifier) as? EKReminder else {
            throw RemindersError("no reminder with identifier \(identifier)")
        }
        return reminder
    }

    private func requireCalendar(_ calendarID: String) throws -> EKCalendar {
        guard let calendar = store.calendar(withIdentifier: calendarID) else {
            throw RemindersError("no calendar with identifier \(calendarID)")
        }
        return calendar
    }

    private func apply(_ payload: ReminderPayload, to reminder: EKReminder) {
        reminder.title = payload.title
        reminder.notes = payload.notes.isEmpty ? nil : payload.notes
        reminder.url = URL(string: payload.url)
        reminder.dueDateComponents = dateComponents(for: payload.dueDate)
        reminder.startDateComponents = dateComponents(for: payload.startDate)
        // Alarms are never set. startDateComponents alone does not notify,
        // and an alarm per mirrored to-do would be an avalanche.
    }

    private func save(_ reminder: EKReminder) throws {
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw RemindersError("could not save reminder '\(reminder.title ?? "")': \(error)")
        }
    }
}
