import Foundation
import Testing
@testable import ThingsyncCore

private final class FakeCalendarManager: CalendarManaging {
    private(set) var calendars: [CalendarRef]
    private var scansByID: [String: CalendarScan]
    private(set) var created: [String] = []
    private(set) var renamed: [(String, String)] = []
    private(set) var deleted: [String] = []
    private var nextID = 0

    init(calendars: [CalendarRef] = [], scans: [CalendarScan] = []) {
        self.calendars = calendars
        scansByID = Dictionary(uniqueKeysWithValues: scans.map { ($0.calendarID, $0) })
    }

    func allCalendars() -> [CalendarRef] { calendars }

    func create(title: String) throws -> CalendarRef {
        nextID += 1
        let calendar = CalendarRef(id: "NEW-\(nextID)", title: title)
        calendars.append(calendar)
        scansByID[calendar.id] = CalendarScan(calendarID: calendar.id, title: title, marked: [:], hasForeignReminder: false)
        created.append(title)
        return calendar
    }

    func rename(calendarID: String, to title: String) throws {
        if let index = calendars.firstIndex(where: { $0.id == calendarID }) {
            calendars[index] = CalendarRef(id: calendarID, title: title)
        }
        renamed.append((calendarID, title))
    }

    func delete(calendarID: String) throws {
        calendars.removeAll { $0.id == calendarID }
        deleted.append(calendarID)
    }

    func scan(calendarIDs: [String]) async throws -> [CalendarScan] {
        calendarIDs.map { id in
            scansByID[id] ?? CalendarScan(calendarID: id, title: calendars.first { $0.id == id }?.title ?? "", marked: [:], hasForeignReminder: false)
        }
    }
}

private final class FakeSyncSink: ReminderSinking {
    var live: [String: String]
    private(set) var calls: [String] = []
    private var nextID = 0
    var requestAccessError: Error?

    init(live: [String: String] = [:]) {
        self.live = live
    }

    func requestAccess() async throws {
        if let requestAccessError { throw requestAccessError }
    }

    func resolveLive(_ identifiers: [String]) -> [String: String] {
        let wanted = Set(identifiers)
        return live.filter { wanted.contains($0.key) }
    }

    func create(calendarID: String, payload: ReminderPayload) throws -> String {
        nextID += 1
        let identifier = "NEW-\(nextID)"
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

// Every test here mutates THINGSYNC_STATE_DIR, a process-global. Added as
// an extension on StateDirectoryEnvironmentTests (declared
// @Suite(.serialized) in StateDirectoryEnvironmentTests.swift) rather than
// a second serialized suite of its own: .serialized only constrains a
// suite's own children against each other, not two independent serialized
// suites against each other, so a second suite here would still race the
// first (confirmed: it did, the first time this was tried).
extension StateDirectoryEnvironmentTests {
    @Test func aBrandNewProjectGetsAListAndItsTodoIsCreated() async throws {
        _ = tempStateDir()
        defer { unsetenv(stateDirEnvironmentVariable) }
        let manager = FakeCalendarManager(calendars: [fallbackCalendar()])
        let sink = FakeSyncSink()
        let runner = SyncRunner(sink: sink, calendarManager: manager, output: FakeOutput())

        let code = try await runner.run(
            SyncOptions(),
            loadTodos: { [ThingsTodo(uuid: "U1", title: "Buy tiles", projectUUID: "P1")] },
            loadProjects: { [ThingsProject(uuid: "P1", title: "Website", status: "incomplete")] }
        )

        #expect(code == 0)
        #expect(manager.created == ["Website"])
        #expect(sink.calls.contains("create NEW-1 Buy tiles"))
    }

    @Test func dryRunWritesNoRemindersAndCreatesNoLists() async throws {
        let dir = tempStateDir()
        defer { unsetenv(stateDirEnvironmentVariable) }
        let manager = FakeCalendarManager(calendars: [fallbackCalendar()])
        let sink = FakeSyncSink()
        let runner = SyncRunner(sink: sink, calendarManager: manager, output: FakeOutput())

        let code = try await runner.run(
            SyncOptions(dryRun: true),
            loadTodos: { [ThingsTodo(uuid: "U1", title: "Buy tiles", projectUUID: "P1")] },
            loadProjects: { [ThingsProject(uuid: "P1", title: "Website", status: "incomplete")] }
        )

        #expect(code == 0)
        #expect(manager.created == [])
        #expect(sink.calls == [])
        #expect(!FileManager.default.fileExists(atPath: projectStatePath("P1", root: dir).path))
    }

    @Test func bulkDestructionRefusalStopsBeforeAnySinkWrite() async throws {
        let dir = tempStateDir()
        defer { unsetenv(stateDirEnvironmentVariable) }

        var gone: [String: StateEntry] = [:]
        for i in 0...10 {
            gone["U\(i)"] = StateEntry(reminderID: "R\(i)", hash: "h")
        }
        try save(State(targetList: "Website", items: gone, projectUUID: "P1"), to: projectStatePath("P1", root: dir))
        try save(Registry(projects: ["P1": RegistryEntry(calendarID: "CAL-P1", title: "Website")]), to: registryPath(root: dir))

        let manager = FakeCalendarManager(calendars: [CalendarRef(id: "CAL-P1", title: "Website"), fallbackCalendar()])
        let sink = FakeSyncSink(live: Dictionary(uniqueKeysWithValues: gone.values.map { ($0.reminderID, "CAL-P1") }))
        let runner = SyncRunner(sink: sink, calendarManager: manager, output: FakeOutput())

        let code = try await runner.run(
            SyncOptions(),
            loadTodos: { [] },
            loadProjects: { [ThingsProject(uuid: "P1", title: "Website", status: "completed")] }
        )

        #expect(code == 1)
        #expect(sink.calls == [])
    }

    @Test func projectScopingSelectsOnlyTheNamedProject() async throws {
        _ = tempStateDir()
        defer { unsetenv(stateDirEnvironmentVariable) }
        let manager = FakeCalendarManager(calendars: [fallbackCalendar()])
        let sink = FakeSyncSink()
        let runner = SyncRunner(sink: sink, calendarManager: manager, output: FakeOutput())

        let code = try await runner.run(
            SyncOptions(project: "Website"),
            loadTodos: {
                [
                    ThingsTodo(uuid: "U1", title: "Buy tiles", projectUUID: "P1"),
                    ThingsTodo(uuid: "U2", title: "Book flight", projectUUID: "P2"),
                ]
            },
            loadProjects: {
                [
                    ThingsProject(uuid: "P1", title: "Website", status: "incomplete"),
                    ThingsProject(uuid: "P2", title: "Travel", status: "incomplete"),
                ]
            }
        )

        #expect(code == 0)
        #expect(manager.created == ["Website"])
        let titlesCreatedFor = sink.calls.filter { $0.hasPrefix("create") }.map { $0.split(separator: " ").dropFirst(2).joined(separator: " ") }
        #expect(titlesCreatedFor == ["Buy tiles"])
    }

    @Test func anUnknownProjectNameIsAHardError() async throws {
        _ = tempStateDir()
        defer { unsetenv(stateDirEnvironmentVariable) }
        let manager = FakeCalendarManager(calendars: [fallbackCalendar()])
        let sink = FakeSyncSink()
        let output = FakeOutput()
        let runner = SyncRunner(sink: sink, calendarManager: manager, output: output)

        let code = try await runner.run(
            SyncOptions(project: "Nonexistent"),
            loadTodos: { [] },
            loadProjects: { [ThingsProject(uuid: "P1", title: "Website", status: "incomplete")] }
        )

        #expect(code == 1)
        #expect(output.errLines.contains { $0.contains("Nonexistent") })
        #expect(manager.created == [])
    }

    @Test func anAmbiguousProjectNameIsAHardErrorNotAFirstMatch() async throws {
        _ = tempStateDir()
        defer { unsetenv(stateDirEnvironmentVariable) }
        let manager = FakeCalendarManager(calendars: [fallbackCalendar()])
        let sink = FakeSyncSink()
        let output = FakeOutput()
        let runner = SyncRunner(sink: sink, calendarManager: manager, output: output)

        let code = try await runner.run(
            SyncOptions(project: "Errands"),
            loadTodos: { [] },
            loadProjects: {
                [
                    ThingsProject(uuid: "P1", title: "Errands", status: "incomplete"),
                    ThingsProject(uuid: "P2", title: "Errands", status: "incomplete"),
                ]
            }
        )

        #expect(code == 1)
        #expect(output.errLines.contains { $0.contains("Errands") && $0.contains("matches") })
        #expect(manager.created == [])
    }

    @Test func namingAClosedProjectIsAHardErrorNotACrash() async throws {
        _ = tempStateDir()
        defer { unsetenv(stateDirEnvironmentVariable) }
        let manager = FakeCalendarManager(calendars: [fallbackCalendar()])
        let sink = FakeSyncSink()
        let output = FakeOutput()
        let runner = SyncRunner(sink: sink, calendarManager: manager, output: output)

        let code = try await runner.run(
            SyncOptions(project: "Website"),
            loadTodos: { [] },
            loadProjects: { [ThingsProject(uuid: "P1", title: "Website", status: "completed")] }
        )

        #expect(code == 1)
        #expect(output.errLines.contains { $0.contains("no open project named") })
        #expect(manager.created == [])
    }

    @Test func aListDeletionIsRefusedAndReportedWithoutYes() async throws {
        let dir = tempStateDir()
        defer { unsetenv(stateDirEnvironmentVariable) }
        try save(Registry(projects: ["P1": RegistryEntry(calendarID: "CAL-P1", title: "Website")]), to: registryPath(root: dir))

        let manager = FakeCalendarManager(calendars: [CalendarRef(id: "CAL-P1", title: "Website"), fallbackCalendar()])
        let sink = FakeSyncSink()
        let output = FakeOutput()
        let runner = SyncRunner(sink: sink, calendarManager: manager, output: output)

        let code = try await runner.run(
            SyncOptions(),
            loadTodos: { [] },
            loadProjects: { [ThingsProject(uuid: "P1", title: "Website", status: "completed")] }
        )

        #expect(code == 0)
        #expect(manager.deleted == [])
        #expect(output.outLines.contains { $0.contains("--yes") })
    }

    @Test func aConfirmedListDeletionRemovesTheListAndItsState() async throws {
        let dir = tempStateDir()
        defer { unsetenv(stateDirEnvironmentVariable) }
        try save(Registry(projects: ["P1": RegistryEntry(calendarID: "CAL-P1", title: "Website")]), to: registryPath(root: dir))
        try save(State(targetList: "Website", items: [:], projectUUID: "P1"), to: projectStatePath("P1", root: dir))

        let manager = FakeCalendarManager(calendars: [CalendarRef(id: "CAL-P1", title: "Website"), fallbackCalendar()])
        let sink = FakeSyncSink()
        let runner = SyncRunner(sink: sink, calendarManager: manager, output: FakeOutput())

        let code = try await runner.run(
            SyncOptions(assumeYes: true),
            loadTodos: { [] },
            loadProjects: { [ThingsProject(uuid: "P1", title: "Website", status: "completed")] }
        )

        #expect(code == 0)
        #expect(manager.deleted == ["CAL-P1"])
        #expect(!FileManager.default.fileExists(atPath: projectStatePath("P1", root: dir).path))
        #expect(try load(from: registryPath(root: dir)).projects["P1"] == nil)
    }

    @Test func syncHardErrorsOnLegacyStateBeforeTouchingThingsOrReminders() async throws {
        let dir = tempStateDir()
        defer { unsetenv(stateDirEnvironmentVariable) }
        try "{\"version\": 1, \"target_list\": \"Scratch\", \"items\": {}}".write(
            to: dir.appendingPathComponent("Scratch.json"), atomically: true, encoding: .utf8
        )

        let sink = FakeSyncSink()
        let manager = FakeCalendarManager()
        let runner = SyncRunner(sink: sink, calendarManager: manager, output: FakeOutput())

        do {
            _ = try await runner.run(
                SyncOptions(),
                loadTodos: { Issue.record("Things must not be read once legacy state is found"); return [] },
                loadProjects: { Issue.record("Things must not be read once legacy state is found"); return [] }
            )
            Issue.record("expected LegacyStateError")
        } catch let error as LegacyStateError {
            let report = errorReport(for: error)
            #expect(report?.message.contains("Scratch.json") == true)
            #expect(report?.message.lowercased().contains("migrate") == true)
            #expect(report?.code == 1)
        }
        #expect(sink.calls == [])
    }
}

@Test func mainReportsADeniedRemindersGrantWithoutATraceback() {
    let error = RemindersError("Reminders access was not granted; run `thingsync doctor`")

    let report = errorReport(for: error)

    #expect(report?.code == 1)
    #expect(report?.message.contains("thingsync doctor") == true)
}
