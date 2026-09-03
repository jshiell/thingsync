import Foundation

private let markerScheme = "things"
private let markerPath = "/show"

private let breadcrumbSeparator = " › "
private let checklistBullet = "☐ "

/// The Reminders list title for a Things project with no Reminders list yet.
public let fallbackListTitle = "Things — Inbox"

/// The durable, in-band identity marker written onto every mirrored
/// reminder. Doubles as a working deep link back into Things.
public func markerURL(_ uuid: String) -> String {
    "things:///show?id=\(uuid)"
}

/// Recover the Things UUID from a marker URL, or nil if it is not one.
public func uuidFromMarker(_ url: String?) -> String? {
    guard let url, let components = URLComponents(string: url) else { return nil }
    guard components.scheme == markerScheme, components.path == markerPath else { return nil }
    guard let value = components.queryItems?.first(where: { $0.name == "id" })?.value,
        !value.isEmpty
    else { return nil }
    return value
}

/// The Reminders list title for a Things project.
public func listTitle(for project: ThingsProject) -> String {
    project.title
}

/// `Area › Project › Heading`, skipping the levels the to-do does not have.
///
/// Inside a project's own list the project level is dropped: the list
/// itself already conveys it, so repeating it in every note would just be
/// noise.
public func breadcrumb(todo: ThingsTodo, inProjectList: Bool = false) -> String {
    let levels = [
        todo.areaTitle,
        inProjectList ? nil : todo.projectTitle,
        todo.headingTitle,
    ]
    return levels.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: breadcrumbSeparator)
}

/// Build the reminder's notes body.
///
/// EventKit has no public API for tags or nested reminders, so the
/// breadcrumb, checklist and tags are all flattened into this one text field.
public func composeNotes(todo: ThingsTodo, inProjectList: Bool = false) -> String {
    let blocks = [
        breadcrumb(todo: todo, inProjectList: inProjectList),
        (todo.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
        todo.checklist.map { checklistBullet + $0 }.joined(separator: "\n"),
        todo.tags.map { "#" + $0 }.joined(separator: " "),
    ]
    return blocks.filter { !$0.isEmpty }.joined(separator: "\n\n")
}

/// Decodes a Things date integer: `YYYYYYYYYYYMMMMDDDDD0000000` packed into
/// the low bits, per `things.py`'s
/// `convert_thingsdate_sql_expression_to_isodate`. `0`/absent decodes to nil.
public enum ThingsDate {
    public static func decode(_ raw: Int) -> YearMonthDay? {
        guard raw != 0 else { return nil }
        let year = (raw & 0x07FF_0000) >> 16
        let month = (raw & 0x0000_F000) >> 12
        let day = (raw & 0x0000_0F80) >> 7
        return YearMonthDay(year: year, month: month, day: day)
    }
}

/// Map a Things to-do onto the payload written to its mirrored reminder.
public func toPayload(_ todo: ThingsTodo, inProjectList: Bool = false) -> ReminderPayload {
    ReminderPayload(
        title: todo.title,
        notes: composeNotes(todo: todo, inProjectList: inProjectList),
        url: markerURL(todo.uuid),
        dueDate: todo.deadline.flatMap(YearMonthDay.init(iso:)),
        startDate: todo.startDate.flatMap(YearMonthDay.init(iso:))
    )
}
