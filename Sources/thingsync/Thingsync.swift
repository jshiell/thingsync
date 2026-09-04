import ArgumentParser
import EventKit
import Foundation
import ThingsyncAdapters
import ThingsyncCore

extension OnDone: ExpressibleByArgument {}

@main
struct Thingsync: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "thingsync",
        abstract: "One-way mirror from Things 3 to Apple Reminders.",
        subcommands: [DoctorCommand.self, SyncCommand.self, RebuildStateCommand.self]
    )

    // Temporary, for M5.14's differential check against things.py -- remove
    // once that check has passed and Python is deleted (plan.md M9.5).
    @Flag(name: .customLong("dump-things-json"), help: .hidden)
    var dumpThingsJSON = false

    func run() async throws {
        guard dumpThingsJSON else {
            throw CleanExit.helpRequest(self)
        }
        let database = try ThingsDatabase(path: thingsDatabasePath())
        let dump = ThingsJSONDump(
            todos: try loadTodos(reader: database).map(ThingsTodoDump.init),
            projects: try loadProjects(reader: database).map(ThingsProjectDump.init)
        )
        let data = try JSONEncoder().encode(dump)
        print(String(decoding: data, as: UTF8.self))
    }
}

struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "doctor", abstract: "check the permissions thingsync needs")

    func run() async throws {
        let ancestry = processAncestry(pid: ProcessInfo.processInfo.processIdentifier, lookup: nativeProcLookup)
        let host = responsibleHost(ancestry, termProgram: ProcessInfo.processInfo.environment["TERM_PROGRAM"])
        let header = [
            "Responsible host process: \(host)",
            "  process chain: \(ancestry.isEmpty ? "unavailable" : ancestry.joined(separator: " ← "))",
            "  (privacy grants attach to this host, and so to everything you run from it)",
            "",
        ]
        let checks = [
            probeThingsDatabase(path: thingsDatabasePath()),
            remindersCheck(status: remindersAuthorizationStatus(), host: host),
        ]
        let (lines, code) = report(checks)
        print((header + lines).joined(separator: "\n"))
        throw ExitCode(code)
    }
}

struct SyncCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "sync", abstract: "mirror open Things to-dos into one Reminders list per project")

    @Option(name: .long, help: "restrict this run to one project's list, by title")
    var project: String?

    @Flag(name: .long, help: "print the plan and write nothing")
    var dryRun = false

    @Option(name: .long, help: "what to do with reminders whose to-do is no longer open")
    var onDone: OnDone = .complete

    @Flag(name: .long, help: "authorise bulk completion/deletion of reminders, or any list deletion")
    var yes = false

    @MainActor
    func run() async throws {
        let store = EKEventStore()
        let sink = EventKitRemindersStore(store: store)
        let manager = EventKitCalendarManager(store: store)
        let runner = SyncRunner(sink: sink, calendarManager: manager, output: StandardOutput())
        let options = SyncOptions(project: project, dryRun: dryRun, onDone: onDone, assumeYes: yes)
        let database = try ThingsDatabase(path: thingsDatabasePath())

        do {
            let code = try await runner.run(
                options,
                loadTodos: { @Sendable in try ThingsyncCore.loadTodos(reader: database) },
                loadProjects: { @Sendable in try ThingsyncCore.loadProjects(reader: database) }
            )
            throw ExitCode(code)
        } catch let error as ExitCode {
            throw error
        } catch {
            if let (message, code) = errorReport(for: error) {
                FileHandle.standardError.write(Data((message + "\n").utf8))
                throw ExitCode(code)
            }
            throw error
        }
    }
}

struct RebuildStateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rebuild-state",
        abstract: "reconstruct state by scanning every thingsync Reminders list for markers"
    )

    @MainActor
    func run() async throws {
        let store = EKEventStore()
        let sink = EventKitRemindersStore(store: store)
        let manager = EventKitCalendarManager(store: store)
        let runner = RebuildStateRunner(sink: sink, calendarManager: manager, output: StandardOutput())
        let database = try ThingsDatabase(path: thingsDatabasePath())

        do {
            let code = try await runner.run(
                loadTodos: { @Sendable in try ThingsyncCore.loadTodos(reader: database) },
                loadProjects: { @Sendable in try ThingsyncCore.loadProjects(reader: database) }
            )
            throw ExitCode(code)
        } catch let error as ExitCode {
            throw error
        } catch {
            if let (message, code) = errorReport(for: error) {
                FileHandle.standardError.write(Data((message + "\n").utf8))
                throw ExitCode(code)
            }
            throw error
        }
    }
}
