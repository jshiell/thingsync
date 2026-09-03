import Testing
import ThingsyncCore
@testable import ThingsyncAdapters

private let toDo = 0
private let project = 1
private let heading = 2

private let incomplete = 0
private let canceled = 2
private let completed = 3

@Test func openToDosReturnBasicScalarFields() throws {
    let fixture = try ThingsFixtureDatabase()
    try fixture.insertTask(uuid: "U1", title: "Buy milk", type: toDo, notes: "2 pints")

    let rows = try fixture.openForReading().tasks(type: .toDo, status: .incomplete)

    #expect(rows.count == 1)
    #expect(rows[0].uuid == "U1")
    #expect(rows[0].title == "Buy milk")
    #expect(rows[0].notes == "2 pints")
}

@Test func deadlineAndStartDateDecodeFromPackedIntegers() throws {
    // 2026-08-25 packed via things.py's own YYYYYYYYYYYMMMMDDDDD0000000 scheme.
    let deadline = (2026 << 16) | (8 << 12) | (25 << 7)
    let startDate = (2026 << 16) | (8 << 12) | (20 << 7)
    let fixture = try ThingsFixtureDatabase()
    try fixture.insertTask(uuid: "U1", title: "t", type: toDo, startDate: startDate, deadline: deadline)

    let rows = try fixture.openForReading().tasks(type: .toDo, status: .incomplete)

    #expect(rows[0].deadline == "2026-08-25")
    #expect(rows[0].startDate == "2026-08-20")
}

@Test func aTaskWithNoDatesHasNilDeadlineAndStartDate() throws {
    let fixture = try ThingsFixtureDatabase()
    try fixture.insertTask(uuid: "U1", title: "t", type: toDo)

    let rows = try fixture.openForReading().tasks(type: .toDo, status: .incomplete)

    #expect(rows[0].deadline == nil)
    #expect(rows[0].startDate == nil)
}

@Test func aTrashedTodoIsExcluded() throws {
    let fixture = try ThingsFixtureDatabase()
    try fixture.insertTask(uuid: "U1", title: "t", type: toDo, trashed: 1)

    #expect(try fixture.openForReading().tasks(type: .toDo, status: .incomplete) == [])
}

@Test func aRecurringTodoIsExcluded() throws {
    let fixture = try ThingsFixtureDatabase()
    try fixture.insertTask(uuid: "U1", title: "t", type: toDo, recurring: true)

    #expect(try fixture.openForReading().tasks(type: .toDo, status: .incomplete) == [])
}

@Test func aTodoUnderATrashedProjectIsExcluded() throws {
    // context_trashed=False: a to-do not itself trashed, but whose project
    // is, must still disappear from the read (things.py database.py:267-274).
    let fixture = try ThingsFixtureDatabase()
    try fixture.insertTask(uuid: "P1", title: "Project", type: project, trashed: 1)
    try fixture.insertTask(uuid: "U1", title: "t", type: toDo, project: "P1")

    #expect(try fixture.openForReading().tasks(type: .toDo, status: .incomplete) == [])
}

@Test func aTodoUnderAHeadingWhoseProjectIsTrashedIsExcluded() throws {
    let fixture = try ThingsFixtureDatabase()
    try fixture.insertTask(uuid: "P1", title: "Project", type: project, trashed: 1)
    try fixture.insertTask(uuid: "H1", title: "Heading", type: heading, project: "P1")
    try fixture.insertTask(uuid: "U1", title: "t", type: toDo, heading: "H1")

    #expect(try fixture.openForReading().tasks(type: .toDo, status: .incomplete) == [])
}

@Test func aTodoDirectlyInAnAreaCarriesItsAreaTitle() throws {
    let fixture = try ThingsFixtureDatabase()
    try fixture.insertArea(uuid: "A1", title: "Home")
    try fixture.insertTask(uuid: "U1", title: "t", type: toDo, area: "A1")

    let rows = try fixture.openForReading().tasks(type: .toDo, status: .incomplete)

    #expect(rows[0].areaTitle == "Home")
}

@Test func tagsAreResolvedViaTheJoinOrderedByTagIndex() throws {
    let fixture = try ThingsFixtureDatabase()
    try fixture.insertTask(uuid: "U1", title: "t", type: toDo)
    try fixture.insertTag(uuid: "T1", title: "zzz-last", index: 1)
    try fixture.insertTag(uuid: "T2", title: "aaa-first", index: 0)
    try fixture.insertTaskTag(task: "U1", tag: "T1")
    try fixture.insertTaskTag(task: "U1", tag: "T2")

    let rows = try fixture.openForReading().tasks(type: .toDo, status: .incomplete)

    #expect(rows[0].tags == ["aaa-first", "zzz-last"])
}

@Test func aTaskWithNoTagsHasAnEmptyTagsArray() throws {
    let fixture = try ThingsFixtureDatabase()
    try fixture.insertTask(uuid: "U1", title: "t", type: toDo)

    #expect(try fixture.openForReading().tasks(type: .toDo, status: .incomplete)[0].tags == [])
}

@Test func checklistItemsAreResolvedRegardlessOfStatusOrderedByIndex() throws {
    // Confirms the checklist lookup genuinely happens for every to-do (the
    // real guarantee behind the dropped test_checklists_are_requested_
    // explicitly) -- SQL returns every item regardless of status; Core's
    // outstandingChecklist is what drops completed ones.
    let fixture = try ThingsFixtureDatabase()
    try fixture.insertTask(uuid: "U1", title: "t", type: toDo)
    try fixture.insertChecklistItem(uuid: "C1", task: "U1", title: "second", status: incomplete, index: 1)
    try fixture.insertChecklistItem(uuid: "C2", task: "U1", title: "first", status: completed, index: 0)

    let rows = try fixture.openForReading().tasks(type: .toDo, status: .incomplete)

    #expect(rows[0].checklist == [
        ThingsChecklistItemRow(title: "first", status: "completed"),
        ThingsChecklistItemRow(title: "second", status: "incomplete"),
    ])
}

@Test func aTaskWithNoChecklistHasAnEmptyChecklistArray() throws {
    let fixture = try ThingsFixtureDatabase()
    try fixture.insertTask(uuid: "U1", title: "t", type: toDo)

    #expect(try fixture.openForReading().tasks(type: .toDo, status: .incomplete)[0].checklist == [])
}

@Test func theHeadingQueryIncludesACompletedHeading() throws {
    // The real guarantee behind the dropped test_the_heading_query_asks_
    // for_every_status: a heading query filtered to status=incomplete
    // would drop a completed heading entirely, misrouting its still-open
    // children into the fallback list.
    let fixture = try ThingsFixtureDatabase()
    try fixture.insertTask(uuid: "P1", title: "Project", type: project)
    try fixture.insertTask(uuid: "H1", title: "Launch", type: heading, status: completed, project: "P1")

    let rows = try fixture.openForReading().tasks(type: .heading, status: nil)

    #expect(rows.map(\.uuid) == ["H1"])
}

@Test func projectsWithNoStatusFilterIncludesAClosedProject() throws {
    // The real guarantee behind the dropped test_load_projects_asks_for_
    // every_status: these are exactly the projects whose list needs
    // tearing down, so the read must not silently drop them.
    let fixture = try ThingsFixtureDatabase()
    try fixture.insertTask(uuid: "P1", title: "Done", type: project, status: completed)

    let rows = try fixture.openForReading().projects(status: nil)

    #expect(rows.map(\.uuid) == ["P1"])
    #expect(rows[0].status == "completed")
}

@Test func projectsFilteredToIncompleteExcludesAClosedProject() throws {
    let fixture = try ThingsFixtureDatabase()
    try fixture.insertTask(uuid: "P1", title: "Done", type: project, status: completed)
    try fixture.insertTask(uuid: "P2", title: "Open", type: project, status: incomplete)

    let rows = try fixture.openForReading().projects(status: .incomplete)

    #expect(rows.map(\.uuid) == ["P2"])
}

@Test func aProjectCarriesItsAreaTitle() throws {
    let fixture = try ThingsFixtureDatabase()
    try fixture.insertArea(uuid: "A1", title: "Work")
    try fixture.insertTask(uuid: "P1", title: "Website", type: project, area: "A1")

    let rows = try fixture.openForReading().projects(status: nil)

    #expect(rows[0].areaTitle == "Work")
}

@Test func rowsAreOrderedByTheTasksIndexColumn() throws {
    let fixture = try ThingsFixtureDatabase()
    try fixture.insertTask(uuid: "U3", title: "third", type: toDo, index: 2)
    try fixture.insertTask(uuid: "U1", title: "first", type: toDo, index: 0)
    try fixture.insertTask(uuid: "U2", title: "second", type: toDo, index: 1)

    let rows = try fixture.openForReading().tasks(type: .toDo, status: .incomplete)

    #expect(rows.map(\.uuid) == ["U1", "U2", "U3"])
}

@Test func aTodoUnderAHeadingResolvesItsProjectFieldsFromTheHeadingRow() throws {
    let fixture = try ThingsFixtureDatabase()
    try fixture.insertTask(uuid: "P1", title: "Website", type: project)
    try fixture.insertTask(uuid: "H1", title: "Launch", type: heading, project: "P1")
    try fixture.insertTask(uuid: "U1", title: "t", type: toDo, heading: "H1")

    let rows = try fixture.openForReading().tasks(type: .toDo, status: .incomplete)

    #expect(rows[0].heading == "H1")
    #expect(rows[0].headingTitle == "Launch")
    #expect(rows[0].project == nil)
}

@Test func aTodoDirectlyInAProjectResolvesItsProjectFields() throws {
    let fixture = try ThingsFixtureDatabase()
    try fixture.insertTask(uuid: "P1", title: "Website", type: project)
    try fixture.insertTask(uuid: "U1", title: "t", type: toDo, project: "P1")

    let rows = try fixture.openForReading().tasks(type: .toDo, status: .incomplete)

    #expect(rows[0].project == "P1")
    #expect(rows[0].projectTitle == "Website")
    #expect(rows[0].heading == nil)
}
