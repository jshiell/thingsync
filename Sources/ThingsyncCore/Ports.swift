/// A write to the Reminders store failed, or access was refused.
public struct RemindersError: Error, Equatable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

/// One of thingsync's own Reminders lists — a value type, never the live
/// EventKit object, so calendar identity can cross the Core/Adapters
/// boundary without dragging non-`Sendable` EventKit types with it.
public struct CalendarRef: Hashable, Sendable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// What one calendar's contents say, for one run.
///
/// `marked` covers incomplete reminders only — what `Planner.plan` consumes.
/// `hasForeignReminder` is computed over every reminder, complete or not,
/// since deleting a calendar deletes its completed reminders too, and the
/// safety rule cannot ignore those.
public struct CalendarScan: Hashable, Sendable {
    public let calendarID: String
    public let title: String
    public let marked: [String: String]
    public let hasForeignReminder: Bool

    public init(calendarID: String, title: String, marked: [String: String], hasForeignReminder: Bool) {
        self.calendarID = calendarID
        self.title = title
        self.marked = marked
        self.hasForeignReminder = hasForeignReminder
    }
}

/// Everything a sync run needs from a reminder store, given an
/// already-resolved calendar for each write. Calendar-level identity
/// (enumerate, create, rename, delete, scan) is the separate, narrower
/// `CalendarManaging` contract, since a calendar has no in-band marker to
/// resolve by, unlike a reminder.
public protocol ReminderSinking {
    /// Ask for full access. Prompts the first time, on macOS 14+.
    func requestAccess() async throws

    /// Which cached identifiers still resolve, and which calendar each is
    /// actually in now — calendar-aware, so a reminder that moved (by hand,
    /// or because its to-do's project changed) is never mistaken for one
    /// that is still exactly where it was left.
    func resolveLive(_ identifiers: [String]) -> [String: String]
    func create(calendarID: String, payload: ReminderPayload) throws -> String
    func update(identifier: String, payload: ReminderPayload) throws
    func move(identifier: String, calendarID: String, payload: ReminderPayload) throws
    func complete(identifier: String) throws
    func delete(identifier: String) throws
}

/// Enumerate, create, rename and delete thingsync's Reminders lists, and
/// scan their contents for markers.
public protocol CalendarManaging {
    func allCalendars() -> [CalendarRef]
    func create(title: String) throws -> CalendarRef
    func rename(calendarID: String, to title: String) throws
    func delete(calendarID: String) throws

    /// Every thingsync-relevant fact about `calendarIDs`' contents, in one
    /// pair of fetches rather than one pair per calendar.
    func scan(calendarIDs: [String]) async throws -> [CalendarScan]
}

/// Where a runner writes its plan/refusal lines (`out`) versus its
/// `"Refusing: …"`/`"State error: …"`/`"Reminders error: …"` lines (`err`) —
/// injected so tests can capture both streams without touching real stdio.
public protocol Output {
    func out(_ line: String)
    func err(_ line: String)
}

/// One process's parent pid and executable name, as reported by the OS.
public typealias ProcLookup = (Int32) -> (ppid: Int32, name: String)?
