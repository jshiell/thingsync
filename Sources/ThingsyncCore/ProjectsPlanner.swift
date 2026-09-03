/// The core decision for list identity: given Things' projects, the
/// registry and a picture of what Reminders already has, what should
/// happen to each project's list?
///
/// Pure by construction, same as `Planner.swift` is for reminders. Every
/// fact about the outside world is passed in as a `CalendarInfo`: which
/// calendars exist, which project UUIDs their contents attest to (the
/// global marker scan, joined against each to-do's project UUID by the
/// caller), and whether any reminder in them cannot be proven to be
/// thingsync's own.

/// How far a project read can fall short of the registry's known projects
/// before it looks like a failed or partial read rather than genuine
/// project closure. A registry with no entries yet is never implausible.
private let implausibleReadRatio = 0.5

public enum ListActionKind: String, Hashable, Sendable {
    case createList = "create_list"
    case renameList = "rename_list"
    case adoptList = "adopt_list"
    case deleteList = "delete_list"
    case keep
}

public struct ListAction: Hashable, Sendable {
    public let kind: ListActionKind
    public let projectUUID: String
    public let title: String
    public let calendarID: String?
    /// Set only on a KEEP that stands in for a refused deletion: reported
    /// every run so a safety refusal is never silently swallowed.
    public let reason: String?

    public init(kind: ListActionKind, projectUUID: String, title: String, calendarID: String? = nil, reason: String? = nil) {
        self.kind = kind
        self.projectUUID = projectUUID
        self.title = title
        self.calendarID = calendarID
        self.reason = reason
    }
}

/// One Reminders calendar, as seen from EventKit — pure data.
public struct CalendarInfo: Hashable, Sendable {
    public let calendarID: String
    public let title: String
    public let attestedProjectUUIDs: Set<String>
    public let hasForeignReminder: Bool

    public init(calendarID: String, title: String, attestedProjectUUIDs: Set<String> = [], hasForeignReminder: Bool = false) {
        self.calendarID = calendarID
        self.title = title
        self.attestedProjectUUIDs = attestedProjectUUIDs
        self.hasForeignReminder = hasForeignReminder
    }
}

private func readLooksImplausible(projects: [ThingsProject], registry: Registry) -> Bool {
    let known = registry.projects.count
    guard known > 0 else { return false }
    let seen = Set(projects.map(\.uuid)).count
    return Double(seen) < Double(known) * implausibleReadRatio
}

/// Recover the calendar mirroring `projectUUID`, contents first.
///
/// 1. an unambiguous marker match, from the global scan grouped by calendar;
/// 2. the cached calendar id, but only once contents evidence is absent —
///    it is a fast path, never sole truth;
/// 3. an unambiguous title match among calendars not already claimed this
///    run — the last, weakest resort, since Things allows duplicate
///    project titles.
private func resolveCalendar(
    projectUUID: String,
    entry: RegistryEntry?,
    title: String,
    calendars: [CalendarInfo],
    claimed: Set<String>
) -> CalendarInfo? {
    let attested = calendars.filter { $0.attestedProjectUUIDs.contains(projectUUID) }
    if attested.count == 1 {
        return attested[0]
    }
    if attested.count > 1 {
        if let entry, let cached = attested.first(where: { $0.calendarID == entry.calendarID }) {
            return cached
        }
        return attested.min { $0.calendarID < $1.calendarID }
    }

    if let entry, let cached = calendars.first(where: { $0.calendarID == entry.calendarID }) {
        return cached
    }

    let titleMatches = calendars.filter { $0.title == title && !claimed.contains($0.calendarID) }
    if titleMatches.count == 1 {
        return titleMatches[0]
    }

    return nil
}

/// Decide what to do about every project's list, and every registered list
/// whose project is no longer open.
public func planLists(
    projects: some Sequence<ThingsProject>,
    registry: Registry,
    calendars: some Sequence<CalendarInfo>
) -> [ListAction] {
    let projectsArray = Array(projects)
    let calendarsArray = Array(calendars)
    let byID = Dictionary(uniqueKeysWithValues: calendarsArray.map { ($0.calendarID, $0) })
    let implausible = readLooksImplausible(projects: projectsArray, registry: registry)

    // Every calendar this run already knows the owner of, so a
    // title-fallback never hands one project's registered list to another.
    var claimed = Set(registry.projects.values.compactMap(\.calendarID))

    // Preserves the caller's project order, deliberately not keyed by a
    // Swift Dictionary: two same-titled projects must resolve their lists
    // in the order they were given, or duplicate-title cross-adoption
    // becomes nondeterministic instead of first-one-wins.
    let openProjects = projectsArray.filter { $0.status == "incomplete" }
    let openProjectUUIDs = Set(openProjects.map(\.uuid))
    var actions: [ListAction] = []

    for project in openProjects {
        let entry = registry.projects[project.uuid]
        let title = listTitle(for: project)

        guard let calendar = resolveCalendar(projectUUID: project.uuid, entry: entry, title: title, calendars: calendarsArray, claimed: claimed)
        else {
            actions.append(ListAction(kind: .createList, projectUUID: project.uuid, title: title))
            continue
        }

        claimed.insert(calendar.calendarID)
        let knownID = entry?.calendarID

        if knownID != calendar.calendarID {
            actions.append(ListAction(kind: .adoptList, projectUUID: project.uuid, title: title, calendarID: calendar.calendarID))
        } else if calendar.title != title {
            actions.append(ListAction(kind: .renameList, projectUUID: project.uuid, title: title, calendarID: calendar.calendarID))
        } else {
            actions.append(ListAction(kind: .keep, projectUUID: project.uuid, title: title, calendarID: calendar.calendarID))
        }
    }

    for projectUUID in registry.projects.keys.sorted() {
        if openProjectUUIDs.contains(projectUUID) { continue }
        let entry = registry.projects[projectUUID]!
        guard let calendarID = entry.calendarID, let calendar = byID[calendarID] else {
            // No live calendar to delete or refuse on; nothing to act on.
            continue
        }

        if implausible {
            actions.append(
                ListAction(
                    kind: .keep, projectUUID: projectUUID, title: calendar.title, calendarID: calendar.calendarID,
                    reason: "the Things project read looks implausibly empty; refusing all list deletions this run"
                )
            )
        } else if calendar.hasForeignReminder {
            actions.append(
                ListAction(
                    kind: .keep, projectUUID: projectUUID, title: calendar.title, calendarID: calendar.calendarID,
                    reason: "a foreign (hand-made) reminder is in this list; refusing to delete it"
                )
            )
        } else {
            actions.append(ListAction(kind: .deleteList, projectUUID: projectUUID, title: calendar.title, calendarID: calendar.calendarID))
        }
    }

    return actions
}
