import Testing
@testable import ThingsyncCore

// Stands in for a real SQLite-backed ThingsReading, holding rows directly.
private struct FakeThingsReader: ThingsReading {
    var todos: [ThingsRow] = []
    var headings: [ThingsRow] = []
    var projectRows: [ThingsProjectRow] = []

    func projects(status: ThingsStatus?) -> [ThingsProjectRow] { projectRows }

    func tasks(type: ThingsTaskType, status: ThingsStatus?) -> [ThingsRow] {
        type == .heading ? headings : todos
    }
}

private let projects = [ThingsProjectRow(uuid: "P1", title: "Website", areaTitle: "Work")]
private let headings = [ThingsRow(uuid: "H1", title: "Launch", project: "P1", projectTitle: "Website")]

@Test func scalarFieldsComeStraightAcross() throws {
    let reader = FakeThingsReader(todos: [
        ThingsRow(uuid: "U1", title: "Buy milk", notes: "2 pints", deadline: "2026-08-25", startDate: "2026-08-20")
    ])

    let todos = try loadTodos(reader: reader)

    #expect(todos.count == 1)
    #expect(todos[0].uuid == "U1")
    #expect(todos[0].title == "Buy milk")
    #expect(todos[0].notes == "2 pints")
    #expect(todos[0].deadline == "2026-08-25")
    #expect(todos[0].startDate == "2026-08-20")
}

// things.py sets heading_title OR project_title on a to-do, never both, and
// never sets area_title on a to-do that lives in a project. Taken literally
// the three _title fields therefore cannot produce "Area > Project >
// Heading", so the chain is resolved here instead.

@Test func aTodoUnderAHeadingRecoversItsProjectAndArea() throws {
    let reader = FakeThingsReader(
        todos: [ThingsRow(uuid: "U1", title: "t", heading: "H1", headingTitle: "Launch")],
        headings: headings, projectRows: projects
    )

    let todos = try loadTodos(reader: reader)

    #expect(todos[0].areaTitle == "Work")
    #expect(todos[0].projectTitle == "Website")
    #expect(todos[0].headingTitle == "Launch")
}

@Test func aTodoDirectlyInAProjectRecoversItsArea() throws {
    let reader = FakeThingsReader(
        todos: [ThingsRow(uuid: "U1", title: "t", project: "P1", projectTitle: "Website")],
        headings: headings, projectRows: projects
    )

    let todos = try loadTodos(reader: reader)

    #expect(todos[0].areaTitle == "Work")
    #expect(todos[0].projectTitle == "Website")
    #expect(todos[0].headingTitle == nil)
}

@Test func aTodoSittingStraightInAnAreaKeepsThatArea() throws {
    let reader = FakeThingsReader(
        todos: [ThingsRow(uuid: "U1", title: "t", areaTitle: "Home")],
        projectRows: projects
    )

    let todos = try loadTodos(reader: reader)

    #expect(todos[0].areaTitle == "Home")
    #expect(todos[0].projectTitle == nil)
    #expect(todos[0].headingTitle == nil)
}

@Test func anUnfiledTodoHasNoBreadcrumbAtAll() throws {
    let reader = FakeThingsReader(todos: [ThingsRow(uuid: "U1", title: "t")])

    let todos = try loadTodos(reader: reader)

    #expect(todos[0].areaTitle == nil)
    #expect(todos[0].projectTitle == nil)
    #expect(todos[0].headingTitle == nil)
}

@Test func tagsBecomeAnArray() throws {
    let reader = FakeThingsReader(todos: [ThingsRow(uuid: "U1", title: "t", tags: ["errand", "urgent"])])

    let todos = try loadTodos(reader: reader)

    #expect(todos[0].tags == ["errand", "urgent"])
}

@Test func onlyOutstandingChecklistItemsAreMirrored() throws {
    // A completed item rendered as "☐ item" would misrepresent it as outstanding.
    let reader = FakeThingsReader(todos: [
        ThingsRow(
            uuid: "U1", title: "t",
            checklist: [
                ThingsChecklistItemRow(title: "pack bags", status: "incomplete"),
                ThingsChecklistItemRow(title: "book taxi", status: "completed"),
                ThingsChecklistItemRow(title: "print tickets", status: "incomplete"),
            ]
        )
    ])

    let todos = try loadTodos(reader: reader)

    #expect(todos[0].checklist == ["pack bags", "print tickets"])
}

@Test func aTodoWithNoChecklistOrTagsYieldsEmptyArrays() throws {
    let reader = FakeThingsReader(todos: [ThingsRow(uuid: "U1", title: "t")])

    let todos = try loadTodos(reader: reader)

    #expect(todos[0].tags == [])
    #expect(todos[0].checklist == [])
}

@Test func loadProjectsYieldsThingsProjectRecords() throws {
    let reader = FakeThingsReader(projectRows: [ThingsProjectRow(uuid: "P1", title: "Website", status: "incomplete")])

    let result = try loadProjects(reader: reader)

    #expect(result.count == 1)
    #expect(result[0].uuid == "P1")
    #expect(result[0].title == "Website")
    #expect(result[0].status == "incomplete")
}

@Test func aTodoUnderAHeadingCarriesItsProjectUUID() throws {
    let reader = FakeThingsReader(
        todos: [ThingsRow(uuid: "U1", title: "t", heading: "H1", headingTitle: "Launch")],
        headings: headings, projectRows: projects
    )

    #expect(try loadTodos(reader: reader)[0].projectUUID == "P1")
}

@Test func aTodoDirectlyInAProjectCarriesItsProjectUUID() throws {
    let reader = FakeThingsReader(
        todos: [ThingsRow(uuid: "U1", title: "t", project: "P1", projectTitle: "Website")],
        headings: headings, projectRows: projects
    )

    #expect(try loadTodos(reader: reader)[0].projectUUID == "P1")
}

@Test func anUnfiledTodoHasNoProjectUUID() throws {
    let reader = FakeThingsReader(todos: [ThingsRow(uuid: "U1", title: "t")])

    #expect(try loadTodos(reader: reader)[0].projectUUID == nil)
}

@Test func aTodoUnderACompletedHeadingStillRecoversItsProjectAndArea() throws {
    // A heading query filtered to status="incomplete" would drop this
    // heading entirely, and the to-do beneath it would misroute into the
    // fallback list.
    let completedHeadings = [ThingsRow(uuid: "H1", title: "Launch", project: "P1", projectTitle: "Website")]
    let reader = FakeThingsReader(
        todos: [ThingsRow(uuid: "U1", title: "t", heading: "H1", headingTitle: "Launch")],
        headings: completedHeadings, projectRows: projects
    )

    let todos = try loadTodos(reader: reader)

    #expect(todos[0].areaTitle == "Work")
    #expect(todos[0].projectTitle == "Website")
    #expect(todos[0].headingTitle == "Launch")
    #expect(todos[0].projectUUID == "P1")
}
