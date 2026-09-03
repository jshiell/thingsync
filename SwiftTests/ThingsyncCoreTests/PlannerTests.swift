import Testing
@testable import ThingsyncCore

private let cal = "C1"

private func todo(uuid: String = "U1", title: String = "Buy milk", projectUUID: String? = nil) -> ThingsTodo {
    ThingsTodo(uuid: uuid, title: title, projectUUID: projectUUID)
}

private struct Kind: Equatable {
    let kind: ActionKind
    let uuid: String
}

private func kinds(_ actions: [SyncAction]) -> [Kind] {
    actions.map { Kind(kind: $0.kind, uuid: $0.uuid) }
}

private func itemsFor(_ t: ThingsTodo, reminderID: String = "R1", stale: Bool = false) -> [String: StateEntry] {
    let digest = stale ? "stale" : toPayload(t).contentHash()
    return [t.uuid: StateEntry(reminderID: reminderID, hash: digest)]
}

@Test func anUnknownTodoWithNoMarkerIsCreated() {
    let actions = plan(todos: [todo()], items: [:], markers: [:], live: [:], calendarForProject: [.inbox: cal])

    #expect(kinds(actions).map(\.kind) == [.create])
    #expect(actions[0].payload?.title == "Buy milk")
    #expect(actions[0].calendarID == cal)
}

@Test func anUnknownTodoThatAlreadyHasAMarkerIsAdoptedNotDuplicated() {
    let actions = plan(
        todos: [todo()], items: [:], markers: ["U1": ReminderLocation(calendarID: cal, reminderID: "R1")],
        live: ["R1": cal], calendarForProject: [.inbox: cal]
    )

    #expect(kinds(actions) == [Kind(kind: .adopt, uuid: "U1")])
    #expect(actions[0].reminderID == "R1")
    #expect(actions[0].calendarID == cal)
}

@Test func aKnownUnchangedTodoIsSkipped() {
    let t = todo()
    let actions = plan(todos: [t], items: itemsFor(t), markers: [:], live: ["R1": cal], calendarForProject: [.inbox: cal])

    #expect(kinds(actions) == [Kind(kind: .skip, uuid: "U1")])
}

@Test func aKnownChangedTodoIsUpdatedInPlace() {
    let t = todo()
    let actions = plan(
        todos: [t], items: itemsFor(t, stale: true), markers: [:], live: ["R1": cal], calendarForProject: [.inbox: cal]
    )

    #expect(kinds(actions) == [Kind(kind: .update, uuid: "U1")])
    #expect(actions[0].reminderID == "R1")
}

@Test func aRotatedIdentifierIsRecoveredThroughTheMarkerNotRecreated() {
    let t = todo()
    let actions = plan(
        todos: [t], items: itemsFor(t), markers: ["U1": ReminderLocation(calendarID: cal, reminderID: "R2")],
        live: [:], calendarForProject: [.inbox: cal]
    )

    #expect(kinds(actions) == [Kind(kind: .adopt, uuid: "U1")])
    #expect(actions[0].reminderID == "R2")
}

@Test func aGenuinelyDeletedReminderIsRecreated() {
    let t = todo()
    let actions = plan(todos: [t], items: itemsFor(t), markers: [:], live: [:], calendarForProject: [.inbox: cal])

    #expect(kinds(actions) == [Kind(kind: .create, uuid: "U1")])
}

@Test func aTodoNoLongerOpenHasItsReminderCompleted() {
    let gone = todo()
    let actions = plan(
        todos: [ThingsTodo](), items: itemsFor(gone), markers: [:], live: ["R1": cal], calendarForProject: [.inbox: cal]
    )

    #expect(kinds(actions) == [Kind(kind: .complete, uuid: "U1")])
    #expect(actions[0].reminderID == "R1")
}

@Test func onDoneDeleteRemovesTheReminderInstead() {
    let gone = todo()
    let actions = plan(
        todos: [ThingsTodo](), items: itemsFor(gone), markers: [:], live: ["R1": cal],
        calendarForProject: [.inbox: cal], onDone: .delete
    )

    #expect(kinds(actions) == [Kind(kind: .delete, uuid: "U1")])
}

@Test func aVanishedTodoWhoseReminderIsAlsoGoneOnlyDropsTheMapping() {
    let gone = todo()
    let actions = plan(todos: [ThingsTodo](), items: itemsFor(gone), markers: [:], live: [:], calendarForProject: [.inbox: cal])

    #expect(kinds(actions) == [Kind(kind: .forget, uuid: "U1")])
    #expect(actions[0].reminderID == nil)
}

@Test func anOrphanedMarkerWithNoStateEntryAndNoOpenTodoProducesNoAction() {
    let actions = plan(
        todos: [ThingsTodo](), items: [:], markers: ["HAND-MADE": ReminderLocation(calendarID: cal, reminderID: "R9")],
        live: ["R9": cal], calendarForProject: [.inbox: cal]
    )

    #expect(actions == [])
}

@Test func remindersThingsyncCannotProveAreItsOwnAreNeverTouched() {
    // The cached identifier R1 no longer resolves (rotated or hand-deleted),
    // and no marker recovers it. A hand-made reminder is live on the list,
    // but thingsync has no evidence it owns it, so it must never be guessed
    // at -- the mapping must simply be forgotten.
    let items = ["U1": StateEntry(reminderID: "R1", hash: "h1")]

    let actions = plan(
        todos: [ThingsTodo](), items: items, markers: [:], live: ["R-HANDMADE": cal],
        calendarForProject: [.inbox: cal], onDone: .delete
    )

    #expect(kinds(actions) == [Kind(kind: .forget, uuid: "U1")])
    #expect(actions[0].reminderID == nil)
}

@Test func aTodoMovedBetweenProjectsProducesOneMoveNotCompleteAndCreate() {
    // A store-wide "does this identifier still resolve?" would say yes and
    // silently leave the reminder, in place, in the wrong list.
    // Calendar-aware resolution is what turns that into a MOVE instead.
    let moved = todo(projectUUID: "B")
    let items = ["U1": StateEntry(reminderID: "R1", hash: "whatever-it-was-before")]
    let live = ["R1": "CAL-A"] // still sitting in project A's old list

    let actions = plan(
        todos: [moved], items: items, markers: [:], live: live,
        calendarForProject: [.project("A"): "CAL-A", .project("B"): "CAL-B"]
    )

    #expect(kinds(actions) == [Kind(kind: .move, uuid: "U1")])
    #expect(actions[0].reminderID == "R1")
    #expect(actions[0].calendarID == "CAL-B")
    #expect(actions[0].payload != nil)
}

@Test func aMovedTodoRecoveredOnlyByMarkerIsAlsoAMoveNotAnAdopt() {
    // No cached identifier at all; the global scan finds the marker sitting
    // in A's calendar, which still disagrees with B's target calendar.
    let moved = todo(projectUUID: "B")
    let actions = plan(
        todos: [moved], items: [:], markers: ["U1": ReminderLocation(calendarID: "CAL-A", reminderID: "R1")],
        live: [:], calendarForProject: [.project("A"): "CAL-A", .project("B"): "CAL-B"]
    )

    #expect(kinds(actions) == [Kind(kind: .move, uuid: "U1")])
    #expect(actions[0].calendarID == "CAL-B")
}

@Test func resolvePrefersTheCachedIdentifierWhenItStillResolves() {
    let found = resolve(
        uuid: "U1", cached: StateEntry(reminderID: "R1", hash: "h"),
        markers: ["U1": ReminderLocation(calendarID: cal, reminderID: "R2")], live: ["R1": cal]
    )

    #expect(found == ReminderLocation(calendarID: cal, reminderID: "R1"))
}

@Test func resolveFallsBackToTheMarkerWhenTheCachedIdentifierIsGone() {
    let found = resolve(
        uuid: "U1", cached: StateEntry(reminderID: "R1", hash: "h"),
        markers: ["U1": ReminderLocation(calendarID: cal, reminderID: "R2")], live: [:]
    )

    #expect(found == ReminderLocation(calendarID: cal, reminderID: "R2"))
}

@Test func resolveFindsNothingForATrulyUnknownTodo() {
    #expect(resolve(uuid: "U1", cached: nil, markers: [:], live: [:]) == nil)
}

@Test func completionsAndDeletionsAreTheDestructiveOnes() {
    let actions = [
        SyncAction(kind: .create, uuid: "A"),
        SyncAction(kind: .update, uuid: "B"),
        SyncAction(kind: .skip, uuid: "C"),
        SyncAction(kind: .forget, uuid: "D"),
        SyncAction(kind: .complete, uuid: "E"),
        SyncAction(kind: .delete, uuid: "F"),
        SyncAction(kind: .move, uuid: "G"),
    ]

    #expect(destructiveActions(actions).map(\.uuid) == ["E", "F"])
}
