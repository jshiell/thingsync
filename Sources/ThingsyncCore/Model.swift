/// One open to-do, as read from the Things database.
///
/// `areaTitle`/`projectTitle`/`headingTitle` are the human-readable names;
/// the bare area/project UUIDs from Things are of no use on their own.
public struct ThingsTodo: Hashable, Sendable {
    public let uuid: String
    public let title: String
    public let notes: String?
    public let areaTitle: String?
    public let projectTitle: String?
    public let headingTitle: String?
    public let projectUUID: String?
    public let tags: [String]
    public let checklist: [String]
    public let deadline: String?
    public let startDate: String?

    public init(
        uuid: String,
        title: String,
        notes: String? = nil,
        areaTitle: String? = nil,
        projectTitle: String? = nil,
        headingTitle: String? = nil,
        projectUUID: String? = nil,
        tags: [String] = [],
        checklist: [String] = [],
        deadline: String? = nil,
        startDate: String? = nil
    ) {
        self.uuid = uuid
        self.title = title
        self.notes = notes
        self.areaTitle = areaTitle
        self.projectTitle = projectTitle
        self.headingTitle = headingTitle
        self.projectUUID = projectUUID
        self.tags = tags
        self.checklist = checklist
        self.deadline = deadline
        self.startDate = startDate
    }
}

/// One Things project, open or not — the per-project Reminders list source.
public struct ThingsProject: Hashable, Sendable {
    public let uuid: String
    public let title: String
    public let status: String

    public init(uuid: String, title: String, status: String) {
        self.uuid = uuid
        self.title = title
        self.status = status
    }
}
