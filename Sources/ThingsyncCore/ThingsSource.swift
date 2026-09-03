/// Adapter: SQLite rows in, `ThingsTodo`/`ThingsProject` out.
///
/// The reader is injected so the whole transformation -- including
/// breadcrumb resolution -- is testable without a Things database. Unlike
/// the Python original, which delegated all Things schema knowledge to the
/// third-party things.py library, this port owns that knowledge outright
/// (see ThingsyncAdapters/ThingsDatabase.swift for the SQL half).

public enum ThingsTaskType: String, Sendable {
    case toDo = "to-do"
    case heading
    case project
}

public enum ThingsStatus: String, Sendable {
    case incomplete
    case completed
    case cancelled
}

public struct ThingsChecklistItemRow: Hashable, Sendable {
    public let title: String
    public let status: String

    public init(title: String, status: String) {
        self.title = title
        self.status = status
    }
}

/// One task row (a to-do or a heading), as read from the database. A
/// struct with optional fields, not an untyped dict, so the "heading_title
/// or project_title, never both" precedence logic in `breadcrumbFields`
/// stays a 1:1 port independent of SQLite.
public struct ThingsRow: Hashable, Sendable {
    public let uuid: String
    public let title: String
    public let notes: String?
    public let areaTitle: String?
    public let project: String?
    public let projectTitle: String?
    public let heading: String?
    public let headingTitle: String?
    public let tags: [String]
    public let checklist: [ThingsChecklistItemRow]
    public let deadline: String?
    public let startDate: String?

    public init(
        uuid: String,
        title: String,
        notes: String? = nil,
        areaTitle: String? = nil,
        project: String? = nil,
        projectTitle: String? = nil,
        heading: String? = nil,
        headingTitle: String? = nil,
        tags: [String] = [],
        checklist: [ThingsChecklistItemRow] = [],
        deadline: String? = nil,
        startDate: String? = nil
    ) {
        self.uuid = uuid
        self.title = title
        self.notes = notes
        self.areaTitle = areaTitle
        self.project = project
        self.projectTitle = projectTitle
        self.heading = heading
        self.headingTitle = headingTitle
        self.tags = tags
        self.checklist = checklist
        self.deadline = deadline
        self.startDate = startDate
    }
}

public struct ThingsProjectRow: Hashable, Sendable {
    public let uuid: String
    public let title: String?
    public let status: String?
    public let areaTitle: String?

    public init(uuid: String, title: String? = nil, status: String? = nil, areaTitle: String? = nil) {
        self.uuid = uuid
        self.title = title
        self.status = status
        self.areaTitle = areaTitle
    }
}

/// The seam things_source.py injected as bare `things.tasks`/`things.projects`
/// callables. The real implementation always resolves checklist items, so
/// unlike things.py there is no cheaper "don't bother with items" mode to
/// request -- `ThingsRow.checklist` is simply always populated.
public protocol ThingsReading {
    func projects(status: ThingsStatus?) throws -> [ThingsProjectRow]
    func tasks(type: ThingsTaskType, status: ThingsStatus?) throws -> [ThingsRow]
}

private struct HeadingParent {
    let projectUUID: String?
    let projectTitle: String?
    let areaTitle: String?
}

/// Resolve `(area, project, heading, project_uuid)` for one to-do.
///
/// Things sets `headingTitle` *or* `projectTitle` on a to-do, never both,
/// and never sets `areaTitle` on a to-do owned by a project. So the upper
/// levels are looked up rather than read off the row.
private func breadcrumbFields(
    row: ThingsRow,
    headingParents: [String: HeadingParent],
    areaOfProject: [String: String?]
) -> (areaTitle: String?, projectTitle: String?, headingTitle: String?, projectUUID: String?) {
    if let headingTitle = row.headingTitle, !headingTitle.isEmpty {
        let parent = row.heading.flatMap { headingParents[$0] }
        return (parent?.areaTitle, parent?.projectTitle, headingTitle, parent?.projectUUID)
    }

    if let projectTitle = row.projectTitle, !projectTitle.isEmpty {
        let projectUUID = row.project
        let areaTitle = projectUUID.flatMap { areaOfProject[$0] }.flatMap { $0 }
        return (areaTitle, projectTitle, nil, projectUUID)
    }

    return (row.areaTitle, nil, nil, nil)
}

/// The checklist items still to do.
///
/// Completed items are dropped rather than mirrored: they would render as
/// "☐ item", showing finished work as outstanding.
private func outstandingChecklist(row: ThingsRow) -> [String] {
    row.checklist.filter { $0.status != "completed" }.map(\.title)
}

private func toTodo(row: ThingsRow, headingParents: [String: HeadingParent], areaOfProject: [String: String?]) -> ThingsTodo {
    let fields = breadcrumbFields(row: row, headingParents: headingParents, areaOfProject: areaOfProject)
    return ThingsTodo(
        uuid: row.uuid,
        title: row.title,
        notes: row.notes,
        areaTitle: fields.areaTitle,
        projectTitle: fields.projectTitle,
        headingTitle: fields.headingTitle,
        projectUUID: fields.projectUUID,
        tags: row.tags,
        checklist: outstandingChecklist(row: row),
        deadline: row.deadline,
        startDate: row.startDate
    )
}

/// Every Things project, regardless of status.
///
/// A `nil` status filter is deliberate: things.py's own default of
/// `status="incomplete"` would silently drop completed and cancelled
/// projects -- exactly the ones whose Reminders list needs tearing down.
public func loadProjects(reader: ThingsReading) throws -> [ThingsProject] {
    try reader.projects(status: nil).map { row in
        ThingsProject(uuid: row.uuid, title: row.title ?? "", status: row.status ?? "incomplete")
    }
}

/// Every open to-do, with its breadcrumb resolved.
public func loadTodos(reader: ThingsReading) throws -> [ThingsTodo] {
    // Incomplete projects only: this is what makes areaOfProject only know
    // about incomplete projects' areas -- a to-do under a heading in a
    // completed project resolves areaTitle to nil. Preserved quirk, not a
    // bug to fix.
    var areaOfProject: [String: String?] = [:]
    for row in try reader.projects(status: .incomplete) {
        areaOfProject[row.uuid] = row.areaTitle
    }

    // status: nil -- a heading marked complete/cancelled must still resolve
    // the breadcrumb for any of its to-dos that are themselves still open,
    // or they would silently misroute into the fallback list.
    var headingParents: [String: HeadingParent] = [:]
    for heading in try reader.tasks(type: .heading, status: nil) {
        let areaTitle = heading.project.flatMap { areaOfProject[$0] }.flatMap { $0 }
        headingParents[heading.uuid] = HeadingParent(projectUUID: heading.project, projectTitle: heading.projectTitle, areaTitle: areaTitle)
    }

    let rows = try reader.tasks(type: .toDo, status: .incomplete)
    return rows.map { toTodo(row: $0, headingParents: headingParents, areaOfProject: areaOfProject) }
}
