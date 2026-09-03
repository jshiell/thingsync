import Testing
@testable import ThingsyncCore

@Test func thingsProjectIsAPlainUUIDTitleStatusRecord() {
    let project = ThingsProject(uuid: "P1", title: "Renovate", status: "incomplete")

    #expect(project.uuid == "P1")
    #expect(project.title == "Renovate")
    #expect(project.status == "incomplete")
}

@Test func thingsTodoCarriesItsProjectUUID() {
    let todo = ThingsTodo(uuid: "U1", title: "Buy tiles", projectUUID: "P1")

    #expect(todo.projectUUID == "P1")
}

@Test func thingsTodoProjectUUIDDefaultsToNilForAProjectlessTodo() {
    let todo = ThingsTodo(uuid: "U1", title: "Buy milk")

    #expect(todo.projectUUID == nil)
}

@Test func thingsTodoDefaultsTagsAndChecklistToEmpty() {
    let todo = ThingsTodo(uuid: "U1", title: "Buy milk")

    #expect(todo.tags == [])
    #expect(todo.checklist == [])
}

@Test func yearMonthDayRoundTripsThroughISO() {
    let day = YearMonthDay(iso: "2026-08-25")

    #expect(day?.iso == "2026-08-25")
}

@Test(arguments: ["2026-13-01", "2026-02-30", "not-a-date", "", "2026-8-25"])
func yearMonthDayRejectsInvalidISO(_ raw: String) {
    #expect(YearMonthDay(iso: raw) == nil)
}
