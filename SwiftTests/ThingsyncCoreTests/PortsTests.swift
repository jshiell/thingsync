import Testing
@testable import ThingsyncCore

// Swift conformance to ReminderSinking/CalendarManaging is checked by the
// compiler, not at runtime — a stronger guarantee than the two
// issubclass(...) checks in test_protocols.py, which have no Swift
// analogue. If FakeReminderSink or FakeCalendarManager below drift out of
// sync with the protocols, the build fails.

private struct FakeReminderSink: ReminderSinking {
    func requestAccess() async throws {}
    func resolveLive(_ identifiers: [String]) -> [String: String] { [:] }
    func create(calendarID: String, payload: ReminderPayload) throws -> String { "R1" }
    func update(identifier: String, payload: ReminderPayload) throws {}
    func move(identifier: String, calendarID: String, payload: ReminderPayload) throws {}
    func complete(identifier: String) throws {}
    func delete(identifier: String) throws {}
}

private struct FakeCalendarManager: CalendarManaging {
    func allCalendars() -> [CalendarRef] { [] }
    func create(title: String) throws -> CalendarRef { CalendarRef(id: "C1", title: title) }
    func rename(calendarID: String, to title: String) throws {}
    func delete(calendarID: String) throws {}
    func scan(calendarIDs: [String]) async throws -> [CalendarScan] { [] }
}

@Test func fakeReminderSinkSatisfiesReminderSinking() async throws {
    let sink: ReminderSinking = FakeReminderSink()
    #expect(try sink.create(calendarID: "C1", payload: ReminderPayload(title: "t", notes: "n", url: "things:///show?id=U1")) == "R1")
}

@Test func fakeCalendarManagerSatisfiesCalendarManaging() async throws {
    let manager: CalendarManaging = FakeCalendarManager()
    #expect(try await manager.scan(calendarIDs: []).isEmpty)
}
