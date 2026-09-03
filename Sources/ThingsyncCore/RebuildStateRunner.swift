import Foundation

/// Reconstructs the registry and every state file from calendar contents.
///
/// Attribution is contents-first, same as the rest of the identity model:
/// a calendar is a project's list because its markers say so, not because
/// its title happens to match. Title is only the last resort, for a list
/// with no markers at all. Every case this cannot resolve on its own -- an
/// orphaned marker, an empty unattributable list, one project's markers
/// split across two lists -- is named and reported rather than silently
/// guessed at.
public final class RebuildStateRunner {
    private let sink: ReminderSinking
    private let calendarManager: CalendarManaging
    private let output: Output

    public init(sink: ReminderSinking, calendarManager: CalendarManaging, output: Output) {
        self.sink = sink
        self.calendarManager = calendarManager
        self.output = output
    }

    public func run(
        loadTodos: () throws -> [ThingsTodo],
        loadProjects: () throws -> [ThingsProject]
    ) async throws -> Int32 {
        try await sink.requestAccess()

        let projects = try loadProjects()
        let todos = try loadTodos()
        let todoByUUID = Dictionary(uniqueKeysWithValues: todos.map { ($0.uuid, $0) })
        let projectByUUID = Dictionary(uniqueKeysWithValues: projects.map { ($0.uuid, $0) })

        let existingCalendars = calendarManager.allCalendars()
        let scans = try await calendarManager.scan(calendarIDs: existingCalendars.map(\.id))

        var byProject: [String: [(CalendarRef, CalendarScan)]] = [:]
        var inboxCandidates: [(CalendarRef, CalendarScan)] = []
        var unattributed: [(CalendarRef, CalendarScan)] = []
        var orphansByTitle: [String: [String]] = [:]

        for (calendar, scan) in zip(existingCalendars, scans) {
            var foundProjects: Set<String> = []
            var foundInbox = false
            var orphans: [String] = []

            for uuid in scan.marked.keys {
                if let todo = todoByUUID[uuid] {
                    if let projectUUID = todo.projectUUID {
                        foundProjects.insert(projectUUID)
                    } else {
                        foundInbox = true
                    }
                } else {
                    orphans.append(uuid)
                }
            }

            if !orphans.isEmpty {
                orphansByTitle[scan.title] = orphans
            }

            if foundProjects.count > 1 {
                output.out("  ambiguous  \(pythonRepr(scan.title)) carries markers for \(foundProjects.count) different projects; left as-is")
                unattributed.append((calendar, scan))
            } else if let onlyProjectUUID = foundProjects.first, foundProjects.count == 1 {
                byProject[onlyProjectUUID, default: []].append((calendar, scan))
            } else if foundInbox {
                inboxCandidates.append((calendar, scan))
            } else {
                // No markers at all (or only orphans): title is the only signal left.
                let titleMatches = projects.filter { listTitle(for: $0) == scan.title }
                if titleMatches.count == 1 {
                    byProject[titleMatches[0].uuid, default: []].append((calendar, scan))
                } else if scan.title == fallbackListTitle {
                    inboxCandidates.append((calendar, scan))
                } else {
                    unattributed.append((calendar, scan))
                }
            }
        }

        let regPath = registryPath()
        var registry = Registry()
        var recovered = 0

        for projectUUID in byProject.keys.sorted() {
            let entries = byProject[projectUUID]!
            let project = projectByUUID[projectUUID]
            let name = project?.title ?? projectUUID

            if entries.count > 1 {
                let names = entries.sorted { $0.1.title < $1.1.title }.map { pythonRepr($0.1.title) }.joined(separator: ", ")
                output.out(
                    "      split  project \(pythonRepr(name))'s markers are split across \(entries.count) lists (\(names)); resolve by hand, then rebuild-state again"
                )
                continue
            }

            let (calendar, scan) = entries[0]
            var items: [String: StateEntry] = [:]
            for (uuid, identifier) in scan.marked where todoByUUID[uuid]?.projectUUID == projectUUID {
                items[uuid] = StateEntry(reminderID: identifier, hash: "")
            }
            let title = project.map(listTitle(for:)) ?? scan.title
            try save(State(targetList: title, items: items, projectUUID: projectUUID), to: projectStatePath(projectUUID))
            registry.projects[projectUUID] = RegistryEntry(calendarID: calendar.id, title: scan.title)
            recovered += items.count
        }

        if inboxCandidates.count > 1 {
            let sorted = inboxCandidates.sorted { $0.1.title < $1.1.title }
            let names = sorted.map { pythonRepr($0.1.title) }.joined(separator: ", ")
            output.out(
                "      split  to-dos with no project are marked across \(inboxCandidates.count) lists (\(names)); resolve by hand, then rebuild-state again"
            )
        } else if let (_, scan) = inboxCandidates.first {
            var items: [String: StateEntry] = [:]
            for (uuid, identifier) in scan.marked {
                guard let todo = todoByUUID[uuid], todo.projectUUID == nil else { continue }
                items[uuid] = StateEntry(reminderID: identifier, hash: "")
            }
            try save(State(targetList: fallbackListTitle, items: items, projectUUID: nil), to: inboxStatePath())
            recovered += items.count
        }

        for title in orphansByTitle.keys.sorted() {
            let uuids = orphansByTitle[title]!.sorted()
            output.out("     orphan  \(pythonRepr(title)) has marker(s) for to-do(s) no longer in Things: \(uuids.joined(separator: ", ")) (left as-is)")
        }

        for (_, scan) in unattributed.sorted(by: { $0.1.title < $1.1.title }) {
            output.out("unattributed  \(pythonRepr(scan.title)): no markers and no matching project title; left as-is")
        }

        try save(registry, to: regPath)
        output.out("")
        output.out("Recovered \(recovered) mappings across \(existingCalendars.count) lists into \(regPath.deletingLastPathComponent().path)")
        return 0
    }
}
