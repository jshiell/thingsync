import ThingsyncCore

// Throwaway, for M5.14's differential check against things.py -- delete
// this file along with `--dump-things-json` once that check has passed and
// Python is deleted (plan.md M9.5). Field names are snake_case to match
// dataclasses.asdict(ThingsTodo)/asdict(ThingsProject) exactly, so the two
// dumps diff cleanly.

struct ThingsTodoDump: Encodable {
    let uuid: String
    let title: String
    let notes: String?
    let area_title: String?
    let project_title: String?
    let heading_title: String?
    let project_uuid: String?
    let tags: [String]
    let checklist: [String]
    let deadline: String?
    let start_date: String?

    init(_ todo: ThingsTodo) {
        uuid = todo.uuid
        title = todo.title
        notes = todo.notes
        area_title = todo.areaTitle
        project_title = todo.projectTitle
        heading_title = todo.headingTitle
        project_uuid = todo.projectUUID
        tags = todo.tags
        checklist = todo.checklist
        deadline = todo.deadline
        start_date = todo.startDate
    }
}

struct ThingsProjectDump: Encodable {
    let uuid: String
    let title: String
    let status: String

    init(_ project: ThingsProject) {
        uuid = project.uuid
        title = project.title
        status = project.status
    }
}

struct ThingsJSONDump: Encodable {
    let todos: [ThingsTodoDump]
    let projects: [ThingsProjectDump]
}
