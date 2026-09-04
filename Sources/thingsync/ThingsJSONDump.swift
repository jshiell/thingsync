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

    // The synthesized conformance uses encodeIfPresent for Optionals, which
    // omits the key entirely when nil -- dataclasses.asdict()/json.dumps()
    // on the Python side always includes the key with an explicit `null`.
    // Encoding explicitly here (rather than IfPresent) keeps the two dumps
    // diffable key-for-key.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(uuid, forKey: .uuid)
        try container.encode(title, forKey: .title)
        try container.encode(notes, forKey: .notes)
        try container.encode(area_title, forKey: .area_title)
        try container.encode(project_title, forKey: .project_title)
        try container.encode(heading_title, forKey: .heading_title)
        try container.encode(project_uuid, forKey: .project_uuid)
        try container.encode(tags, forKey: .tags)
        try container.encode(checklist, forKey: .checklist)
        try container.encode(deadline, forKey: .deadline)
        try container.encode(start_date, forKey: .start_date)
    }

    private enum CodingKeys: String, CodingKey {
        case uuid, title, notes, area_title, project_title, heading_title, project_uuid, tags, checklist, deadline, start_date
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
