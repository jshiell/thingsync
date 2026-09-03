import Testing
@testable import ThingsyncCore

private final class FakeSink: ReminderSinking {
    var live: [String: String]
    private(set) var calls: [String] = []
    private var nextID = 0

    init(live: [String: String] = [:]) {
        self.live = live
    }

    func requestAccess() async throws {}

    func resolveLive(_ identifiers: [String]) -> [String: String] {
        let wanted = Set(identifiers)
        return live.filter { wanted.contains($0.key) }
    }

    func create(calendarID: String, payload: ReminderPayload) throws -> String {
        nextID += 1
        let identifier = "R-NEW-\(nextID)"
        calls.append("create \(calendarID) \(payload.title)")
        return identifier
    }

    func update(identifier: String, payload: ReminderPayload) throws {
        calls.append("update \(identifier)")
    }

    func move(identifier: String, calendarID: String, payload: ReminderPayload) throws {
        calls.append("move \(identifier) \(calendarID)")
    }

    func complete(identifier: String) throws {
        calls.append("complete \(identifier)")
    }

    func delete(identifier: String) throws {
        calls.append("delete \(identifier)")
    }
}

private let payload = toPayload(ThingsTodo(uuid: "U1", title: "Buy milk"))

@Test func aCreationRecordsTheNewMapping() throws {
    var states: [String?: State] = [nil: State(targetList: "Things")]
    let keys: [String: String?] = ["U1": nil]
    let sink = FakeSink()

    _ = try executeSyncActions(
        [SyncAction(kind: .create, uuid: "U1", payload: payload, calendarID: "CAL")],
        sink: sink, states: &states, stateKeyForUUID: keys, persist: { _, _ in }
    )

    #expect(sink.calls == ["create CAL Buy milk"])
    #expect(states[nil]?.items["U1"] == StateEntry(reminderID: "R-NEW-1", hash: payload.contentHash()))
}

@Test func stateIsPersistedAfterEachActionNotOnceAtTheEnd() throws {
    var states: [String?: State] = [nil: State(targetList: "Things")]
    let keys: [String: String?] = ["U1": nil, "U2": nil]
    var saves: [Set<String>] = []

    _ = try executeSyncActions(
        [
            SyncAction(kind: .create, uuid: "U1", payload: payload, calendarID: "CAL"),
            SyncAction(kind: .create, uuid: "U2", payload: payload, calendarID: "CAL"),
        ],
        sink: FakeSink(), states: &states, stateKeyForUUID: keys,
        persist: { _, state in saves.append(Set(state.items.keys)) }
    )

    #expect(saves == [["U1"], ["U1", "U2"]])
}

@Test func completingAReminderDropsItsMapping() throws {
    var states: [String?: State] = ["P1": State(targetList: "Website", items: ["U1": StateEntry(reminderID: "R1", hash: "h")])]
    let keys: [String: String?] = ["U1": "P1"]
    let sink = FakeSink()

    _ = try executeSyncActions(
        [SyncAction(kind: .complete, uuid: "U1", reminderID: "R1")],
        sink: sink, states: &states, stateKeyForUUID: keys, persist: { _, _ in }
    )

    #expect(sink.calls == ["complete R1"])
    #expect(states["P1"]?.items == [:])
}

@Test func forgettingTouchesNoReminderAtAll() throws {
    var states: [String?: State] = ["P1": State(targetList: "Website", items: ["U1": StateEntry(reminderID: "R1", hash: "h")])]
    let keys: [String: String?] = ["U1": "P1"]
    let sink = FakeSink()

    _ = try executeSyncActions(
        [SyncAction(kind: .forget, uuid: "U1")],
        sink: sink, states: &states, stateKeyForUUID: keys, persist: { _, _ in }
    )

    #expect(sink.calls == [])
    #expect(states["P1"]?.items == [:])
}

@Test func skippingWritesNothing() throws {
    var states: [String?: State] = ["P1": State(targetList: "Website", items: ["U1": StateEntry(reminderID: "R1", hash: "h")])]
    let keys: [String: String?] = ["U1": "P1"]
    let sink = FakeSink()

    _ = try executeSyncActions(
        [SyncAction(kind: .skip, uuid: "U1", reminderID: "R1")],
        sink: sink, states: &states, stateKeyForUUID: keys, persist: { _, _ in }
    )

    #expect(sink.calls == [])
    #expect(states["P1"]?.items == ["U1": StateEntry(reminderID: "R1", hash: "h")])
}

@Test func adoptingUpdatesInPlaceAndRecordsTheFoundIdentifier() throws {
    var states: [String?: State] = ["P1": State(targetList: "Website")]
    let keys: [String: String?] = ["U1": "P1"]
    let sink = FakeSink()

    _ = try executeSyncActions(
        [SyncAction(kind: .adopt, uuid: "U1", payload: payload, reminderID: "R7", calendarID: "CAL")],
        sink: sink, states: &states, stateKeyForUUID: keys, persist: { _, _ in }
    )

    #expect(sink.calls == ["update R7"])
    #expect(states["P1"]?.items["U1"] == StateEntry(reminderID: "R7", hash: payload.contentHash()))
}

@Test func aMoveRelocatesTheReminderAndRecordsItUnderTheNewProject() throws {
    var states: [String?: State] = [
        "A": State(targetList: "A", items: ["U1": StateEntry(reminderID: "R1", hash: "old")]),
        "B": State(targetList: "B"),
    ]
    let keys: [String: String?] = ["U1": "B"] // the to-do's *current* project, per the key resolution
    let sink = FakeSink()

    _ = try executeSyncActions(
        [SyncAction(kind: .move, uuid: "U1", payload: payload, reminderID: "R1", calendarID: "CAL-B")],
        sink: sink, states: &states, stateKeyForUUID: keys, persist: { _, _ in }
    )

    #expect(sink.calls == ["move R1 CAL-B"])
    #expect(states["B"]?.items["U1"] == StateEntry(reminderID: "R1", hash: payload.contentHash()))
    #expect(states["A"]?.items["U1"] == nil)
}

private func manyCompletions(_ count: Int) -> [SyncAction] {
    (0..<count).map { SyncAction(kind: .complete, uuid: "U\($0)", reminderID: "R\($0)") }
}

@Test func aHandfulOfCompletionsNeedsNoConfirmation() {
    #expect(refusalForBulkDestruction(manyCompletions(10), assumeYes: false) == nil)
}

@Test func wholesaleDestructionIsRefusedWithoutYes() {
    let refusal = refusalForBulkDestruction(manyCompletions(11), assumeYes: false)

    #expect(refusal?.contains("--yes") == true)
}

@Test func yesAuthorisesIt() {
    #expect(refusalForBulkDestruction(manyCompletions(500), assumeYes: true) == nil)
}
