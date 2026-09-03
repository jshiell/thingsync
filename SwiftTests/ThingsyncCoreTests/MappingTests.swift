import Testing
@testable import ThingsyncCore

@Test func markerURLIsAThingsDeepLink() {
    #expect(markerURL("ABC-123") == "things:///show?id=ABC-123")
}

@Test func uuidIsRecoveredFromAMarkerURL() {
    #expect(uuidFromMarker("things:///show?id=ABC-123") == "ABC-123")
}

@Test func aForeignURLCarriesNoUUID() {
    #expect(uuidFromMarker("https://example.com/") == nil)
    #expect(uuidFromMarker(nil) == nil)
}

@Test func aMarkerURLWithABlankIDCarriesNoUUID() {
    #expect(uuidFromMarker("things:///show?id=") == nil)
}

@Test func aBareTodoMapsTitleAndMarkerAndNoDates() {
    let payload = toPayload(ThingsTodo(uuid: "U1", title: "Buy milk"))

    #expect(payload.title == "Buy milk")
    #expect(payload.url == "things:///show?id=U1")
    #expect(payload.notes == "")
    #expect(payload.dueDate == nil)
    #expect(payload.startDate == nil)
}

@Test func thingsDateStringsParseToDates() {
    let payload = toPayload(ThingsTodo(uuid: "U1", title: "t", deadline: "2026-08-25", startDate: "2026-08-20"))

    #expect(payload.dueDate == YearMonthDay(iso: "2026-08-25"))
    #expect(payload.startDate == YearMonthDay(iso: "2026-08-20"))
}

@Test func breadcrumbIsPrependedUsingTheTitleFields() {
    let todo = ThingsTodo(
        uuid: "U1", title: "t", notes: "the body",
        areaTitle: "Work", projectTitle: "Website", headingTitle: "Launch"
    )

    #expect(toPayload(todo).notes == "Work › Website › Launch\n\nthe body")
}

@Test func breadcrumbOmitsMissingLevels() {
    let todo = ThingsTodo(uuid: "U1", title: "t", areaTitle: "Work", headingTitle: "Launch")

    #expect(toPayload(todo).notes == "Work › Launch")
}

@Test func checklistAndTagsAreAppendedAsText() {
    let todo = ThingsTodo(
        uuid: "U1", title: "t", notes: "the body",
        tags: ["errand", "urgent"], checklist: ["pack bags", "book taxi"]
    )

    #expect(toPayload(todo).notes == "the body\n\n☐ pack bags\n☐ book taxi\n\n#errand #urgent")
}

@Test func insideAProjectsOwnListTheProjectLevelIsDropped() {
    let todo = ThingsTodo(
        uuid: "U1", title: "t", areaTitle: "Work", projectTitle: "Website", headingTitle: "Launch"
    )

    #expect(toPayload(todo, inProjectList: true).notes == "Work › Launch")
}

@Test func outsideAProjectListTheProjectLevelIsKept() {
    let todo = ThingsTodo(
        uuid: "U1", title: "t", areaTitle: "Work", projectTitle: "Website", headingTitle: "Launch"
    )

    #expect(toPayload(todo, inProjectList: false).notes == "Work › Website › Launch")
}

@Test func aProjectMapsOntoItsOwnListTitle() {
    let project = ThingsProject(uuid: "P1", title: "Website", status: "incomplete")

    #expect(listTitle(for: project) == "Website")
}

@Test func fallbackListTitleIsAStableConstant() {
    #expect(fallbackListTitle == "Things — Inbox")
}

// things.py's own docstring worked example for convert_thingsdate_sql_expression_to_isodate.
@Test func thingsDateDecodesTheDocumentedWorkedExample() {
    #expect(ThingsDate.decode(132_464_128) == YearMonthDay(iso: "2021-03-28"))
}

@Test func thingsDateRoundTripsAnEncodedDate() {
    let raw = (2026 << 16) | (8 << 12) | (25 << 7)
    #expect(ThingsDate.decode(raw) == YearMonthDay(iso: "2026-08-25"))
}

@Test func thingsDateDecodesZeroToNil() {
    #expect(ThingsDate.decode(0) == nil)
}
