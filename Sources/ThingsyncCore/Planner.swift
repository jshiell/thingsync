/// The core decision: given Things, the state and a scan of the target
/// list, what should happen to each reminder?
///
/// Pure by construction. Every fact about the outside world — which
/// reminders every thingsync-owned calendar already carries, and which
/// cached identifiers still resolve (and where) — is passed in, so the
/// whole algorithm is testable without EventKit.
///
/// This plans across every project's to-dos and calendar at once, not one
/// list at a time: a to-do whose project changed needs to be told apart
/// from one that was simply deleted, and per-list planning cannot do that —
/// it would see the to-do vanish from its old list (COMPLETE) and reappear
/// as brand new in its new one (CREATE), duplicating it permanently.

public enum ActionKind: String, Hashable, Sendable {
    case create
    case adopt
    case update
    case move
    case skip
    case complete
    case delete
    case forget
}

public struct SyncAction: Hashable, Sendable {
    public let kind: ActionKind
    public let uuid: String
    public let payload: ReminderPayload?
    public let reminderID: String?
    public let calendarID: String?

    public init(
        kind: ActionKind,
        uuid: String,
        payload: ReminderPayload? = nil,
        reminderID: String? = nil,
        calendarID: String? = nil
    ) {
        self.kind = kind
        self.uuid = uuid
        self.payload = payload
        self.reminderID = reminderID
        self.calendarID = calendarID
    }
}

/// A to-do's project, or the fallback inbox — a double-optional
/// `[String: String?]` lookup is a bug magnet, so this stands in for
/// Python's `project_uuid: str | None` dict key throughout the planner.
public enum ProjectKey: Hashable, Sendable {
    case project(String)
    case inbox

    public init(projectUUID: String?) {
        self = projectUUID.map(ProjectKey.project) ?? .inbox
    }
}

/// Where one reminder actually is, in place of Python's bare `(calendar_id,
/// reminder_id)` tuple.
public struct ReminderLocation: Hashable, Sendable {
    public let calendarID: String
    public let reminderID: String

    public init(calendarID: String, reminderID: String) {
        self.calendarID = calendarID
        self.reminderID = reminderID
    }
}

public enum OnDone: String, Sendable {
    case complete
    case delete
}

/// Find the reminder mirroring `uuid`, in the order the plan prescribes:
///
/// 1. the cached `calendarItemIdentifier`, if it still resolves — `live`
///    maps a resolving identifier to the calendar it is actually in now,
///    which is what makes a hand-moved or project-changed reminder visible
///    as such rather than silently "still fine, still here";
/// 2. otherwise a marker carrying this Things UUID, found by the global scan.
///
/// Step 2 is what tells "the user deleted it" apart from "iCloud rotated
/// the identifier". It must never collapse into "absent".
public func resolve(
    uuid: String,
    cached: StateEntry?,
    markers: [String: ReminderLocation],
    live: [String: String]
) -> ReminderLocation? {
    if let cached, let liveCalendar = live[cached.reminderID] {
        return ReminderLocation(calendarID: liveCalendar, reminderID: cached.reminderID)
    }
    return markers[uuid]
}

/// Decide what to do about every open to-do, and every to-do that has
/// stopped being one, across every project at once.
public func plan(
    todos: some Sequence<ThingsTodo>,
    items: [String: StateEntry],
    markers: [String: ReminderLocation],
    live: [String: String],
    calendarForProject: [ProjectKey: String],
    onDone: OnDone = .complete
) -> [SyncAction] {
    var actions: [SyncAction] = []
    let todosArray = Array(todos)

    for todo in todosArray {
        // A missing key here is a caller bug (every key must be seeded up
        // front, as cli.py's setdefault does) and must fail as loudly as
        // Python's unguarded KeyError, not silently default to the inbox.
        let targetCalendar = calendarForProject[ProjectKey(projectUUID: todo.projectUUID)]!
        let payload = toPayload(todo, inProjectList: todo.projectUUID != nil)
        let cached = items[todo.uuid]
        let found = resolve(uuid: todo.uuid, cached: cached, markers: markers, live: live)

        guard let found else {
            // Either never mirrored, or mirrored and since deleted by hand.
            // Both reduce to the same thing: nothing out there to update.
            actions.append(SyncAction(kind: .create, uuid: todo.uuid, payload: payload, calendarID: targetCalendar))
            continue
        }

        if found.calendarID != targetCalendar {
            // Found, but in the wrong list: the to-do's project changed
            // since it was last mirrored. Relocating it is the only way to
            // avoid completing the old copy and creating a duplicate.
            actions.append(
                SyncAction(kind: .move, uuid: todo.uuid, payload: payload, reminderID: found.reminderID, calendarID: targetCalendar)
            )
        } else if cached == nil || cached!.reminderID != found.reminderID {
            // Found by marker rather than by cached identifier, so the
            // mapping is new or stale. Re-record it and write the payload.
            actions.append(
                SyncAction(kind: .adopt, uuid: todo.uuid, payload: payload, reminderID: found.reminderID, calendarID: targetCalendar)
            )
        } else if cached!.hash != payload.contentHash() {
            actions.append(
                SyncAction(kind: .update, uuid: todo.uuid, payload: payload, reminderID: found.reminderID, calendarID: targetCalendar)
            )
        } else {
            actions.append(SyncAction(kind: .skip, uuid: todo.uuid, reminderID: found.reminderID, calendarID: targetCalendar))
        }
    }

    let openUUIDs = Set(todosArray.map(\.uuid))
    let closing: ActionKind = onDone == .delete ? .delete : .complete

    for uuid in items.keys.sorted() {
        if openUUIDs.contains(uuid) { continue }
        // Completed, cancelled, trashed or simply gone from Things.
        let found = resolve(uuid: uuid, cached: items[uuid], markers: markers, live: live)
        if let found {
            actions.append(SyncAction(kind: closing, uuid: uuid, reminderID: found.reminderID))
        } else {
            // Nothing left to act on; just stop tracking it.
            actions.append(SyncAction(kind: .forget, uuid: uuid))
        }
    }

    return actions
}

public let destructiveActionKinds: Set<ActionKind> = [.complete, .delete]

/// The actions that remove work from the user's list.
///
/// A planner bug should not be able to silently clear a list, so the CLI
/// gates these behind `--yes` once there are more than a handful.
public func destructiveActions(_ actions: some Sequence<SyncAction>) -> [SyncAction] {
    actions.filter { destructiveActionKinds.contains($0.kind) }
}
