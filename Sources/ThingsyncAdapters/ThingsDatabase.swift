import Foundation
import ThingsyncCore
#if canImport(Darwin)
    import Darwin
#endif

private let thingsDBEnvironmentVariable = "THINGSDB"

/// `THINGSDB` env var first, then the Things 3.15.16+ Group Container glob,
/// then the pre-3.15.16 fallback path -- matching things.py exactly,
/// including the quirk that the glob itself needs Full Disk Access: without
/// it, `ls` on that directory returns "Operation not permitted", and this
/// function falls straight through to the (nonexistent) fallback path,
/// which is why `doctor` can misdiagnose a permissions problem as "Things
/// must have been launched at least once".
public func thingsDatabasePath(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    home: String = FileManager.default.homeDirectoryForCurrentUser.path
) -> String {
    if let override = environment[thingsDBEnvironmentVariable], !override.isEmpty {
        return override
    }

    let groupContainer = "\(home)/Library/Group Containers/JLMPQHK86H.com.culturedcode.ThingsMac"
    let modernGlob = "\(groupContainer)/ThingsData-*/Things Database.thingsdatabase/main.sqlite"
    if let match = firstGlobMatch(modernGlob) {
        return match
    }
    return "\(groupContainer)/Things Database.thingsdatabase/main.sqlite"
}

private func firstGlobMatch(_ pattern: String) -> String? {
    var result = glob_t()
    defer { globfree(&result) }
    guard glob(pattern, 0, nil, &result) == 0, result.gl_pathc > 0, let first = result.gl_pathv[0] else {
        return nil
    }
    return String(cString: first)
}

private enum TaskTypeCode: Int32 {
    case toDo = 0
    case project = 1
    case heading = 2
}

private enum TaskStatusCode: Int32 {
    case incomplete = 0
    case canceled = 2
    case completed = 3
}

extension ThingsTaskType {
    fileprivate var code: TaskTypeCode {
        switch self {
        case .toDo: .toDo
        case .heading: .heading
        case .project: .project
        }
    }
}

extension ThingsStatus {
    fileprivate var code: TaskStatusCode {
        switch self {
        case .incomplete: .incomplete
        case .cancelled: .canceled
        case .completed: .completed
        }
    }
}

/// The shared shape behind all four TMTask reads (open to-dos, headings of
/// every status, and projects with or without a status filter): only the
/// `type`/`status` predicate differs between them.
///
/// `rt1_recurrenceRule IS NULL`, `TASK.trashed = 0`, and
/// `NOT IFNULL(PROJECT.trashed, 0)` / `NOT IFNULL(PROJECT_OF_HEADING.trashed, 0)`
/// are shared by every variant -- the last two are things.py's
/// `context_trashed=False` default, easy to miss since they read like
/// project-table filters rather than part of "the tasks query", but
/// load-bearing: without them a project trashed in Things never
/// disappears from the read, so `planLists` never tears down its list.
///
/// `startDate`/`deadline` are selected as the raw packed integers and
/// decoded in Swift via `ThingsDate.decode`, not converted to a date
/// string in SQL as things.py does.
///
/// Every variant orders by `TASK."index"`, matching Things' own displayed
/// order -- row order flows straight through to `planLists`, and omitting
/// this would let SQLite's arbitrary order reach the user.
///
/// `things.py`'s `Database.__init__` additionally asserts
/// `get_version() > 21` by reading and plist-parsing a `Meta` table row
/// (`database.py:198-202, 463-468`) -- a defense against pre-2019 schema
/// generations that predate this port's only target. Deliberately not
/// ported; `Meta` is absent from the fixture schema in
/// ThingsyncAdaptersTests for the same reason.
private func taskSelectSQL(type: TaskTypeCode, status: TaskStatusCode?) -> String {
    var sql = """
        SELECT DISTINCT
            TASK.uuid,
            TASK.title,
            CASE
                WHEN TASK.status = 0 THEN 'incomplete'
                WHEN TASK.status = 2 THEN 'canceled'
                WHEN TASK.status = 3 THEN 'completed'
            END AS status,
            TASK.notes,
            CASE WHEN AREA.uuid IS NOT NULL THEN AREA.title END AS area_title,
            CASE WHEN PROJECT.uuid IS NOT NULL THEN PROJECT.uuid END AS project,
            CASE WHEN PROJECT.uuid IS NOT NULL THEN PROJECT.title END AS project_title,
            CASE WHEN HEADING.uuid IS NOT NULL THEN HEADING.uuid END AS heading,
            CASE WHEN HEADING.uuid IS NOT NULL THEN HEADING.title END AS heading_title,
            CASE WHEN TAG.uuid IS NOT NULL THEN 1 END AS tags,
            CASE WHEN CHECKLIST_ITEM.uuid IS NOT NULL THEN 1 END AS checklist,
            TASK.startDate,
            TASK.deadline
        FROM TMTask AS TASK
        LEFT OUTER JOIN TMTask PROJECT ON TASK.project = PROJECT.uuid
        LEFT OUTER JOIN TMArea AREA ON TASK.area = AREA.uuid
        LEFT OUTER JOIN TMTask HEADING ON TASK.heading = HEADING.uuid
        LEFT OUTER JOIN TMTask PROJECT_OF_HEADING ON HEADING.project = PROJECT_OF_HEADING.uuid
        LEFT OUTER JOIN TMTaskTag TAGS ON TASK.uuid = TAGS.tasks
        LEFT OUTER JOIN TMTag TAG ON TAGS.tags = TAG.uuid
        LEFT OUTER JOIN TMChecklistItem CHECKLIST_ITEM ON TASK.uuid = CHECKLIST_ITEM.task
        WHERE
            TASK.rt1_recurrenceRule IS NULL
            AND TASK.trashed = 0
            AND NOT IFNULL(PROJECT.trashed, 0)
            AND NOT IFNULL(PROJECT_OF_HEADING.trashed, 0)
            AND TASK.type = \(type.rawValue)
        """
    if let status {
        sql += "\n            AND TASK.status = \(status.rawValue)"
    }
    sql += "\n        ORDER BY TASK.\"index\""
    return sql
}

private let tagsForTaskSQL = """
    SELECT TAG.title
    FROM TMTaskTag AS TASK_TAG
    LEFT OUTER JOIN TMTag TAG ON TAG.uuid = TASK_TAG.tags
    WHERE TASK_TAG.tasks = ?
    ORDER BY TAG."index"
    """

private let checklistItemsForTaskSQL = """
    SELECT
        CHECKLIST_ITEM.title,
        CASE
            WHEN CHECKLIST_ITEM.status = 0 THEN 'incomplete'
            WHEN CHECKLIST_ITEM.status = 2 THEN 'canceled'
            WHEN CHECKLIST_ITEM.status = 3 THEN 'completed'
        END AS status
    FROM TMChecklistItem AS CHECKLIST_ITEM
    WHERE CHECKLIST_ITEM.task = ?
    ORDER BY CHECKLIST_ITEM."index"
    """

/// One connection per instance, opened lazily; each query its own implicit
/// transaction, matching things.py exactly -- multi-query reads are *not*
/// a single consistent snapshot.
/// `@unchecked Sendable`: a CLI has one thread of control, so this is never
/// actually accessed concurrently -- only ever captured across the
/// MainActor/nonisolated boundary between the executable's command and
/// `SyncRunner`/`RebuildStateRunner`.
public final class ThingsDatabase: ThingsReading, @unchecked Sendable {
    private let connection: SQLiteConnection

    public init(path: String) throws {
        connection = try SQLiteConnection(path: "file:\(path)?mode=ro", flags: [.readOnly, .uri])
    }

    public func projects(status: ThingsStatus?) throws -> [ThingsProjectRow] {
        try taskRows(type: .project, status: status?.code).map { row in
            ThingsProjectRow(uuid: row.uuid, title: row.title, status: row.status, areaTitle: row.areaTitle)
        }
    }

    public func tasks(type: ThingsTaskType, status: ThingsStatus?) throws -> [ThingsRow] {
        try taskRows(type: type.code, status: status?.code).map { row in
            ThingsRow(
                uuid: row.uuid,
                title: row.title,
                notes: row.notes,
                areaTitle: row.areaTitle,
                project: row.project,
                projectTitle: row.projectTitle,
                heading: row.heading,
                headingTitle: row.headingTitle,
                tags: row.hasTags ? try tags(forTask: row.uuid) : [],
                checklist: row.hasChecklist ? try checklistItems(forTask: row.uuid) : [],
                deadline: ThingsDate.decode(row.deadline ?? 0)?.iso,
                startDate: ThingsDate.decode(row.startDate ?? 0)?.iso
            )
        }
    }

    private struct RawTaskRow {
        let uuid: String
        let title: String
        let status: String?
        let notes: String?
        let areaTitle: String?
        let project: String?
        let projectTitle: String?
        let heading: String?
        let headingTitle: String?
        let hasTags: Bool
        let hasChecklist: Bool
        let startDate: Int?
        let deadline: Int?
    }

    private func taskRows(type: TaskTypeCode, status: TaskStatusCode?) throws -> [RawTaskRow] {
        let statement = try connection.prepare(taskSelectSQL(type: type, status: status))
        var rows: [RawTaskRow] = []
        while try statement.step() {
            rows.append(
                RawTaskRow(
                    uuid: statement.columnText(0) ?? "",
                    title: statement.columnText(1) ?? "",
                    status: statement.columnText(2),
                    notes: statement.columnText(3),
                    areaTitle: statement.columnText(4),
                    project: statement.columnText(5),
                    projectTitle: statement.columnText(6),
                    heading: statement.columnText(7),
                    headingTitle: statement.columnText(8),
                    hasTags: statement.columnInt(9) != nil,
                    hasChecklist: statement.columnInt(10) != nil,
                    startDate: statement.columnInt(11),
                    deadline: statement.columnInt(12)
                )
            )
        }
        return rows
    }

    private func tags(forTask uuid: String) throws -> [String] {
        let statement = try connection.prepare(tagsForTaskSQL)
        statement.bind(uuid, at: 1)
        var titles: [String] = []
        while try statement.step() {
            if let title = statement.columnText(0) {
                titles.append(title)
            }
        }
        return titles
    }

    private func checklistItems(forTask uuid: String) throws -> [ThingsChecklistItemRow] {
        let statement = try connection.prepare(checklistItemsForTaskSQL)
        statement.bind(uuid, at: 1)
        var items: [ThingsChecklistItemRow] = []
        while try statement.step() {
            items.append(ThingsChecklistItemRow(title: statement.columnText(0) ?? "", status: statement.columnText(1) ?? ""))
        }
        return items
    }
}
