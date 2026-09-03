import Foundation
import Testing
@testable import ThingsyncCore

private final class FakeCalendarManager: CalendarManaging {
    private(set) var calendars: [CalendarRef]
    private var scansByID: [String: CalendarScan]

    init(calendars: [CalendarRef], scans: [CalendarScan] = []) {
        self.calendars = calendars
        scansByID = Dictionary(uniqueKeysWithValues: scans.map { ($0.calendarID, $0) })
    }

    func allCalendars() -> [CalendarRef] { calendars }
    func create(title: String) throws -> CalendarRef { CalendarRef(id: "NEW", title: title) }
    func rename(calendarID: String, to title: String) throws {}
    func delete(calendarID: String) throws {}

    func scan(calendarIDs: [String]) async throws -> [CalendarScan] {
        calendarIDs.map { id in
            scansByID[id] ?? CalendarScan(calendarID: id, title: calendars.first { $0.id == id }?.title ?? "", marked: [:], hasForeignReminder: false)
        }
    }
}

private final class FakeSink: ReminderSinking {
    func requestAccess() async throws {}
    func resolveLive(_ identifiers: [String]) -> [String: String] { [:] }
    func create(calendarID: String, payload: ReminderPayload) throws -> String { "" }
    func update(identifier: String, payload: ReminderPayload) throws {}
    func move(identifier: String, calendarID: String, payload: ReminderPayload) throws {}
    func complete(identifier: String) throws {}
    func delete(identifier: String) throws {}
}

private final class FakeOutput: Output {
    private(set) var outLines: [String] = []
    private(set) var errLines: [String] = []
    func out(_ line: String) { outLines.append(line) }
    func err(_ line: String) { errLines.append(line) }
}

private func fallbackCalendar() -> CalendarRef {
    CalendarRef(id: "INBOX", title: fallbackListTitle)
}

private func tempStateDir() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    setenv(stateDirEnvironmentVariable, dir.path, 1)
    return dir
}

extension StateDirectoryEnvironmentTests {
    @Test func aProjectsMarkersRecoverItsStateAndRegistryEntry() async throws {
        let dir = tempStateDir()
        defer { unsetenv(stateDirEnvironmentVariable) }
        let website = CalendarRef(id: "CAL-P1", title: "Website")
        let manager = FakeCalendarManager(
            calendars: [website, fallbackCalendar()],
            scans: [
                CalendarScan(calendarID: "CAL-P1", title: "Website", marked: ["U1": "R1"], hasForeignReminder: false),
                CalendarScan(calendarID: "INBOX", title: fallbackListTitle, marked: [:], hasForeignReminder: false),
            ]
        )
        let runner = RebuildStateRunner(sink: FakeSink(), calendarManager: manager, output: FakeOutput())

        let code = try await runner.run(
            loadTodos: { [ThingsTodo(uuid: "U1", title: "Buy tiles", projectUUID: "P1")] },
            loadProjects: { [ThingsProject(uuid: "P1", title: "Website", status: "incomplete")] }
        )

        #expect(code == 0)
        let recovered = try load(from: projectStatePath("P1", root: dir), targetList: "Website", projectUUID: "P1")
        #expect(recovered.items == ["U1": StateEntry(reminderID: "R1", hash: "")])
        #expect(try load(from: registryPath(root: dir)).projects["P1"] == RegistryEntry(calendarID: "CAL-P1", title: "Website"))
    }

    @Test func anOrphanMarkerIsReportedAndExcluded() async throws {
        let dir = tempStateDir()
        defer { unsetenv(stateDirEnvironmentVariable) }
        let website = CalendarRef(id: "CAL-P1", title: "Website")
        let manager = FakeCalendarManager(
            calendars: [website, fallbackCalendar()],
            scans: [
                CalendarScan(calendarID: "CAL-P1", title: "Website", marked: ["U1": "R1", "GONE": "R9"], hasForeignReminder: false),
                CalendarScan(calendarID: "INBOX", title: fallbackListTitle, marked: [:], hasForeignReminder: false),
            ]
        )
        let output = FakeOutput()
        let runner = RebuildStateRunner(sink: FakeSink(), calendarManager: manager, output: output)

        let code = try await runner.run(
            loadTodos: { [ThingsTodo(uuid: "U1", title: "Buy tiles", projectUUID: "P1")] },
            loadProjects: { [ThingsProject(uuid: "P1", title: "Website", status: "incomplete")] }
        )

        #expect(code == 0)
        let recovered = try load(from: projectStatePath("P1", root: dir), targetList: "Website", projectUUID: "P1")
        #expect(recovered.items == ["U1": StateEntry(reminderID: "R1", hash: "")])
        #expect(output.outLines.contains { $0.contains("GONE") })
    }

    @Test func anEmptyUnattributableListIsReportedNotSilentlyDropped() async throws {
        let dir = tempStateDir()
        defer { unsetenv(stateDirEnvironmentVariable) }
        let mystery = CalendarRef(id: "CAL-X", title: "Mystery List")
        let manager = FakeCalendarManager(
            calendars: [mystery, fallbackCalendar()],
            scans: [
                CalendarScan(calendarID: "CAL-X", title: "Mystery List", marked: [:], hasForeignReminder: false),
                CalendarScan(calendarID: "INBOX", title: fallbackListTitle, marked: [:], hasForeignReminder: false),
            ]
        )
        let output = FakeOutput()
        let runner = RebuildStateRunner(sink: FakeSink(), calendarManager: manager, output: output)

        let code = try await runner.run(
            loadTodos: { [] },
            loadProjects: { [ThingsProject(uuid: "P1", title: "Website", status: "incomplete")] }
        )

        #expect(code == 0)
        #expect(output.outLines.contains { $0.contains("Mystery List") })
        #expect(try load(from: registryPath(root: dir)).projects["P1"] == nil)
    }

    @Test func aProjectsMarkersSplitAcrossTwoListsIsReportedNotSilentlyPicked() async throws {
        let dir = tempStateDir()
        defer { unsetenv(stateDirEnvironmentVariable) }
        let first = CalendarRef(id: "CAL-1", title: "Website")
        let second = CalendarRef(id: "CAL-2", title: "Website Copy")
        let manager = FakeCalendarManager(
            calendars: [first, second, fallbackCalendar()],
            scans: [
                CalendarScan(calendarID: "CAL-1", title: "Website", marked: ["U1": "R1"], hasForeignReminder: false),
                CalendarScan(calendarID: "CAL-2", title: "Website Copy", marked: ["U2": "R2"], hasForeignReminder: false),
                CalendarScan(calendarID: "INBOX", title: fallbackListTitle, marked: [:], hasForeignReminder: false),
            ]
        )
        let output = FakeOutput()
        let runner = RebuildStateRunner(sink: FakeSink(), calendarManager: manager, output: output)

        let code = try await runner.run(
            loadTodos: {
                [
                    ThingsTodo(uuid: "U1", title: "a", projectUUID: "P1"),
                    ThingsTodo(uuid: "U2", title: "b", projectUUID: "P1"),
                ]
            },
            loadProjects: { [ThingsProject(uuid: "P1", title: "Website", status: "incomplete")] }
        )

        #expect(code == 0)
        let allOutput = output.outLines.joined(separator: "\n")
        #expect(allOutput.contains("Website") && allOutput.contains("Website Copy"))
        #expect(try load(from: registryPath(root: dir)).projects["P1"] == nil)
        #expect(!FileManager.default.fileExists(atPath: projectStatePath("P1", root: dir).path))
    }

    @Test func markersForTodosWithNoProjectRecoverIntoTheInbox() async throws {
        let dir = tempStateDir()
        defer { unsetenv(stateDirEnvironmentVariable) }
        let manager = FakeCalendarManager(
            calendars: [fallbackCalendar()],
            scans: [CalendarScan(calendarID: "INBOX", title: fallbackListTitle, marked: ["U1": "R1"], hasForeignReminder: false)]
        )
        let runner = RebuildStateRunner(sink: FakeSink(), calendarManager: manager, output: FakeOutput())

        let code = try await runner.run(
            loadTodos: { [ThingsTodo(uuid: "U1", title: "Buy milk")] },
            loadProjects: { [] }
        )

        #expect(code == 0)
        let recovered = try load(from: inboxStatePath(root: dir), targetList: fallbackListTitle, projectUUID: nil)
        #expect(recovered.items == ["U1": StateEntry(reminderID: "R1", hash: "")])
    }
}
