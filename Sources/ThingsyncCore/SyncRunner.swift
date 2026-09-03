import Foundation

public typealias PersistState = (String?, State) throws -> Void

public struct SyncOptions: Sendable {
    public var project: String?
    public var dryRun: Bool
    public var onDone: OnDone
    public var assumeYes: Bool

    public init(project: String? = nil, dryRun: Bool = false, onDone: OnDone = .complete, assumeYes: Bool = false) {
        self.project = project
        self.dryRun = dryRun
        self.onDone = onDone
        self.assumeYes = assumeYes
    }
}

public enum ProjectSelection {
    case found(ThingsProject)
    case error(String)
}

/// The one project named `name`, or an error message.
public func selectProject(_ projects: [ThingsProject], named name: String) -> ProjectSelection {
    let matches = projects.filter { $0.title == name && $0.status == "incomplete" }
    if matches.isEmpty {
        return .error("no open project named \(pythonRepr(name))")
    }
    if matches.count > 1 {
        return .error("\(pythonRepr(name)) matches \(matches.count) projects; --project cannot disambiguate duplicate titles")
    }
    return .found(matches[0])
}

private func calendarInfos(existingCalendars: [CalendarRef], scans: [CalendarScan], todoByUUID: [String: ThingsTodo]) -> [CalendarInfo] {
    zip(existingCalendars, scans).map { _, scan in
        let attested = Set(
            scan.marked.keys.compactMap { uuid -> String? in
                guard let todo = todoByUUID[uuid] else { return nil }
                return todo.projectUUID
            }
        )
        return CalendarInfo(calendarID: scan.calendarID, title: scan.title, attestedProjectUUIDs: attested, hasForeignReminder: scan.hasForeignReminder)
    }
}

/// Maps a thrown error onto the same "State error: …" / "Reminders error:
/// …" stderr line and exit code `main()` uses, regardless of which command
/// (sync or rebuild-state) raised it -- both funnel through the identical
/// top-level catch in Python.
public func errorReport(for error: Error) -> (message: String, code: Int32)? {
    if let error = error as? LegacyStateError {
        return ("State error: \(error)", 1)
    }
    if let error = error as? StateError {
        return ("State error: \(error)", 1)
    }
    if let error = error as? RemindersError {
        return ("Reminders error: \(error)", 1)
    }
    return nil
}

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

/// Orchestrates one `sync` run: legacy-state guard, project selection,
/// list planning/execution, reminder planning/execution, and the tally
/// summary -- matching cli.py's sync_command phase order exactly.
public final class SyncRunner {
    private let sink: ReminderSinking
    private let calendarManager: CalendarManaging
    private let output: Output

    public init(sink: ReminderSinking, calendarManager: CalendarManaging, output: Output) {
        self.sink = sink
        self.calendarManager = calendarManager
        self.output = output
    }

    public func run(
        _ options: SyncOptions,
        loadTodos: () throws -> [ThingsTodo],
        loadProjects: () throws -> [ThingsProject]
    ) async throws -> Int32 {
        // Phase 1: the legacy-state guard runs before anything else, so no
        // per-project code can ever run against state it would silently
        // duplicate -- and before Things or Reminders is even opened.
        try checkForLegacyState()

        let todos = try loadTodos()
        let projects = try loadProjects()
        let todoByUUID = Dictionary(uniqueKeysWithValues: todos.map { ($0.uuid, $0) })
        let projectByUUID = Dictionary(uniqueKeysWithValues: projects.map { ($0.uuid, $0) })

        var selectedProject: ThingsProject?
        if let projectName = options.project {
            switch selectProject(projects, named: projectName) {
            case .error(let message):
                output.err("Refusing: \(message)")
                return 1
            case .found(let project):
                selectedProject = project
            }
        }

        try await sink.requestAccess()

        // Phase 2: list planning and execution.
        let existingCalendars = calendarManager.allCalendars()
        let scans = try await calendarManager.scan(calendarIDs: existingCalendars.map(\.id))
        var calendarByID = Dictionary(uniqueKeysWithValues: existingCalendars.map { ($0.id, $0) })
        let calendarInfoList = calendarInfos(existingCalendars: existingCalendars, scans: scans, todoByUUID: todoByUUID)

        let regPath = registryPath()
        var registry = try load(from: regPath)

        let listActions = planLists(projects: projects, registry: registry, calendars: calendarInfoList)

        var calendarForProject: [ProjectKey: String] = [:]
        var executedListActions: [ListAction] = []

        for action in listActions {
            let executeThisOne = selectedProject == nil || action.projectUUID == selectedProject?.uuid
            let key = ProjectKey.project(action.projectUUID)

            switch action.kind {
            case .createList:
                if !executeThisOne {
                    // Guarantees no reminder-planning step ever targets an
                    // unselected project's (possibly not-yet-existing) list.
                    calendarForProject[key] = "__pending__:\(action.projectUUID)"
                } else if options.dryRun {
                    calendarForProject[key] = "(new list) \(action.title)"
                } else {
                    let calendar = try calendarManager.create(title: action.title)
                    calendarByID[calendar.id] = calendar
                    calendarForProject[key] = calendar.id
                    registry.projects[action.projectUUID] = RegistryEntry(calendarID: calendar.id, title: action.title)
                    try save(registry, to: regPath)
                }
            case .renameList:
                calendarForProject[key] = action.calendarID!
                if executeThisOne, !options.dryRun {
                    try calendarManager.rename(calendarID: action.calendarID!, to: action.title)
                    registry.projects[action.projectUUID] = RegistryEntry(calendarID: action.calendarID, title: action.title)
                    try save(registry, to: regPath)
                }
            case .adoptList:
                calendarForProject[key] = action.calendarID!
                if executeThisOne, !options.dryRun {
                    if calendarByID[action.calendarID!]?.title != action.title {
                        try calendarManager.rename(calendarID: action.calendarID!, to: action.title)
                    }
                    registry.projects[action.projectUUID] = RegistryEntry(calendarID: action.calendarID, title: action.title)
                    try save(registry, to: regPath)
                }
            case .keep:
                if action.reason == nil {
                    calendarForProject[key] = action.calendarID!
                }
            case .deleteList:
                break
            }

            if executeThisOne {
                executedListActions.append(action)
                output.out(describeListAction(action))
            }
        }

        if let fallbackCalendar = existingCalendars.first(where: { $0.title == fallbackListTitle }) {
            calendarForProject[.inbox] = fallbackCalendar.id
        } else if options.dryRun {
            calendarForProject[.inbox] = "(new list) \(fallbackListTitle)"
        } else {
            let fallbackCalendar = try calendarManager.create(title: fallbackListTitle)
            calendarForProject[.inbox] = fallbackCalendar.id
        }

        // A todo/project race between the two Things reads (each its own
        // transaction) could leave a todo pointing at a project this run
        // never planned a list for. Route it to the fallback rather than
        // crashing the whole sync over a to-do that will resolve itself
        // next run.
        for todo in todos {
            let key = ProjectKey(projectUUID: todo.projectUUID)
            if calendarForProject[key] == nil {
                calendarForProject[key] = calendarForProject[.inbox]
            }
        }

        // Phase 3: state loading and reminder planning.
        let openProjectUUIDs = Set(projects.filter { $0.status == "incomplete" }.map(\.uuid))
        let projectUUIDsToLoad = openProjectUUIDs.union(registry.projects.keys).sorted()

        var states: [String?: State] = [:]
        var stateKeyForUUID: [String: String?] = [:]

        for uuid in projectUUIDsToLoad {
            let entry = registry.projects[uuid]
            let project = projectByUUID[uuid]
            let title = project.map(listTitle(for:)) ?? entry?.title ?? uuid
            let state = try load(from: projectStatePath(uuid), targetList: title, projectUUID: uuid)
            states[uuid] = state
            for todoUUID in state.items.keys {
                stateKeyForUUID[todoUUID] = uuid
            }
        }

        let inboxState = try load(from: inboxStatePath(), targetList: fallbackListTitle, projectUUID: nil)
        states[nil] = inboxState
        for todoUUID in inboxState.items.keys {
            stateKeyForUUID[todoUUID] = nil
        }

        for todo in todos {
            stateKeyForUUID[todo.uuid] = todo.projectUUID
        }

        var items: [String: StateEntry] = [:]
        for state in states.values {
            items.merge(state.items) { _, new in new }
        }

        var markers: [String: ReminderLocation] = [:]
        for scan in scans {
            for (uuid, reminderID) in scan.marked {
                markers[uuid] = ReminderLocation(calendarID: scan.calendarID, reminderID: reminderID)
            }
        }

        let allReminderIDs = Array(Set(states.values.flatMap { $0.items.values.map(\.reminderID) }))
        let live = sink.resolveLive(allReminderIDs)

        var reminderActions = plan(
            todos: todos, items: items, markers: markers, live: live, calendarForProject: calendarForProject, onDone: options.onDone
        )

        if let selectedProject {
            let targetCalendarID = calendarForProject[.project(selectedProject.uuid)]!
            reminderActions = reminderActions.filter { action in
                if let calendarID = action.calendarID {
                    return calendarID == targetCalendarID
                }
                return stateKeyForUUID[action.uuid].flatMap { $0 } == selectedProject.uuid
            }
        }

        // Phase 4: output, the bulk-destruction gate, execution, confirmed
        // list deletions, tally summary.
        let interesting = reminderActions.filter { $0.kind != .skip }
        for action in interesting {
            output.out(describe(action))
        }
        let skipped = reminderActions.count - interesting.count

        let deletions = executedListActions.filter { $0.kind == .deleteList }
        let confirmedDeletions = options.assumeYes ? deletions : []
        if !deletions.isEmpty, !options.assumeYes {
            for action in deletions {
                output.out("  refused  \(pythonRepr(action.title)): list deletion always needs --yes")
            }
        }

        if options.dryRun {
            output.out("")
            output.out("\(interesting.count) actions, \(skipped) unchanged. Nothing written (--dry-run).")
            return 0
        }

        if let refusal = refusalForBulkDestruction(reminderActions, assumeYes: options.assumeYes) {
            output.err("")
            output.err("Refusing: \(refusal)")
            return 1
        }

        let tally = try executeSyncActions(
            reminderActions, sink: sink, states: &states, stateKeyForUUID: stateKeyForUUID,
            persist: { key, state in
                try save(state, to: key.map { projectStatePath($0) } ?? inboxStatePath())
            }
        )

        for action in confirmedDeletions {
            try calendarManager.delete(calendarID: action.calendarID!)
            try? FileManager.default.removeItem(at: projectStatePath(action.projectUUID))
            registry.projects.removeValue(forKey: action.projectUUID)
            try save(registry, to: regPath)
        }

        let summaryParts = tally.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.value) \($0.key.rawValue)" }
        let summary = summaryParts.isEmpty ? "nothing to do" : summaryParts.joined(separator: ", ")
        output.out("")
        output.out("\(summary) (\(skipped) unchanged)")
        return 0
    }
}
