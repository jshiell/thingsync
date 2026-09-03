public typealias PersistState = (String?, State) throws -> Void

private let destructiveThreshold = 10

/// Refuse to clear reminders wholesale unless explicitly authorised.
///
/// A planner bug or a half-read database should not be able to silently
/// empty someone's reminders. List deletion has its own, separate gate: it
/// always needs `--yes`, regardless of how many lists are involved.
public func refusalForBulkDestruction(_ actions: [SyncAction], assumeYes: Bool) -> String? {
    if assumeYes { return nil }

    let destructive = destructiveActions(actions)
    guard destructive.count > destructiveThreshold else { return nil }

    return
        "\(destructive.count) reminders would be completed or deleted, which is more than the \(destructiveThreshold) allowed without confirmation. Re-run with --dry-run to inspect the plan, or --yes to go ahead."
}

/// Carry out the reminder-level plan, recording each success before moving
/// on.
///
/// Every project's (and the fallback's) state is persisted after every
/// action rather than once at the end: a crash partway through must not
/// leave created or moved reminders unrecorded.
public func executeSyncActions(
    _ actions: [SyncAction],
    sink: ReminderSinking,
    states: inout [String?: State],
    stateKeyForUUID: [String: String?],
    persist: PersistState
) throws -> [ActionKind: Int] {
    var tally: [ActionKind: Int] = [:]

    for action in actions {
        let key = stateKeyForUUID[action.uuid]!

        switch action.kind {
        case .create:
            let identifier = try sink.create(calendarID: action.calendarID!, payload: action.payload!)
            states[key]?.items[action.uuid] = StateEntry(reminderID: identifier, hash: action.payload!.contentHash())
        case .move:
            // Drop any stale record of this to-do under its old project
            // first: a crash here just means the next run's marker scan
            // finds the reminder still sitting in its old calendar and
            // retries the move, never a duplicate.
            for (otherKey, var otherState) in states where otherKey != key {
                if otherState.items.removeValue(forKey: action.uuid) != nil {
                    states[otherKey] = otherState
                    try persist(otherKey, otherState)
                }
            }
            try sink.move(identifier: action.reminderID!, calendarID: action.calendarID!, payload: action.payload!)
            states[key]?.items[action.uuid] = StateEntry(reminderID: action.reminderID!, hash: action.payload!.contentHash())
        case .adopt, .update:
            try sink.update(identifier: action.reminderID!, payload: action.payload!)
            states[key]?.items[action.uuid] = StateEntry(reminderID: action.reminderID!, hash: action.payload!.contentHash())
        case .complete:
            try sink.complete(identifier: action.reminderID!)
            states[key]?.items.removeValue(forKey: action.uuid)
        case .delete:
            try sink.delete(identifier: action.reminderID!)
            states[key]?.items.removeValue(forKey: action.uuid)
        case .forget:
            states[key]?.items.removeValue(forKey: action.uuid)
        case .skip:
            tally[action.kind, default: 0] += 1
            continue
        }

        tally[action.kind, default: 0] += 1
        try persist(key, states[key]!)
    }

    return tally
}
