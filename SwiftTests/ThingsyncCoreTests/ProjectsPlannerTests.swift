import Testing
@testable import ThingsyncCore

private func project(uuid: String = "P1", title: String = "Website", status: String = "incomplete") -> ThingsProject {
    ThingsProject(uuid: uuid, title: title, status: status)
}

private func calendar(
    calendarID: String = "C1",
    title: String = "Website",
    attested: Set<String> = [],
    foreign: Bool = false
) -> CalendarInfo {
    CalendarInfo(calendarID: calendarID, title: title, attestedProjectUUIDs: attested, hasForeignReminder: foreign)
}

private struct Kind: Equatable {
    let kind: ListActionKind
    let projectUUID: String
}

private func kinds(_ actions: [ListAction]) -> [Kind] {
    actions.map { Kind(kind: $0.kind, projectUUID: $0.projectUUID) }
}

@Test func aNewProjectWithNoListAndNoCacheCreatesOne() {
    let actions = planLists(projects: [project()], registry: Registry(), calendars: [])

    #expect(kinds(actions) == [Kind(kind: .createList, projectUUID: "P1")])
    #expect(actions[0].title == "Website")
}

@Test func emptyProjectsStillGetAList() {
    // Zero open to-dos is not a reason to withhold the list.
    let actions = planLists(projects: [project()], registry: Registry(), calendars: [])

    #expect(kinds(actions) == [Kind(kind: .createList, projectUUID: "P1")])
}

@Test func anUpToDateProjectIsKept() {
    let reg = Registry(projects: ["P1": RegistryEntry(calendarID: "C1", title: "Website")])

    let actions = planLists(projects: [project()], registry: reg, calendars: [calendar()])

    #expect(kinds(actions) == [Kind(kind: .keep, projectUUID: "P1")])
}

@Test func aRenamedProjectRenamesItsListInPlace() {
    let reg = Registry(projects: ["P1": RegistryEntry(calendarID: "C1", title: "Old Name")])
    let cal = calendar(title: "Old Name")

    let actions = planLists(projects: [project(title: "New Name")], registry: reg, calendars: [cal])

    #expect(kinds(actions) == [Kind(kind: .renameList, projectUUID: "P1")])
    #expect(actions[0].title == "New Name")
    #expect(actions[0].calendarID == "C1")
}

@Test func recoveryByContentsWhenTheCachedIDIsStale() {
    // The registry's calendar id no longer resolves (e.g. after a full
    // iCloud resync), but a live calendar's markers still attest to this
    // project.
    let reg = Registry(projects: ["P1": RegistryEntry(calendarID: "STALE-ID", title: "Website")])
    let cal = calendar(calendarID: "NEW-ID", attested: ["P1"])

    let actions = planLists(projects: [project()], registry: reg, calendars: [cal])

    #expect(kinds(actions) == [Kind(kind: .adoptList, projectUUID: "P1")])
    #expect(actions[0].calendarID == "NEW-ID")
}

@Test func aHandMadeListAlreadyHoldingTheProjectsTitleIsAdopted() {
    // No marker, no cache: title is the only remaining signal for a
    // never-before-mirrored (or fully empty) project.
    let cal = calendar(calendarID: "HAND-MADE", title: "Website")

    let actions = planLists(projects: [project()], registry: Registry(), calendars: [cal])

    #expect(kinds(actions) == [Kind(kind: .adoptList, projectUUID: "P1")])
    #expect(actions[0].calendarID == "HAND-MADE")
}

@Test func duplicateProjectTitlesDoNotCrossAdoptTheSameList() {
    let cal = calendar(calendarID: "ONE-LIST", title: "Errands")
    let projects = [project(uuid: "P1", title: "Errands"), project(uuid: "P2", title: "Errands")]

    let actions = planLists(projects: projects, registry: Registry(), calendars: [cal])

    #expect(kinds(actions) == [Kind(kind: .adoptList, projectUUID: "P1"), Kind(kind: .createList, projectUUID: "P2")])
    #expect(actions[0].calendarID == "ONE-LIST")
}

@Test func aClosedProjectWithACleanListIsDeleted() {
    let reg = Registry(projects: ["P1": RegistryEntry(calendarID: "C1", title: "Website")])
    let cal = calendar(foreign: false)

    let actions = planLists(projects: [project(status: "completed")], registry: reg, calendars: [cal])

    #expect(kinds(actions) == [Kind(kind: .deleteList, projectUUID: "P1")])
}

@Test func aForeignReminderRefusesTheDeletion() {
    let reg = Registry(projects: ["P1": RegistryEntry(calendarID: "C1", title: "Website")])
    let cal = calendar(foreign: true)

    let actions = planLists(projects: [project(status: "completed")], registry: reg, calendars: [cal])

    #expect(kinds(actions) == [Kind(kind: .keep, projectUUID: "P1")])
    #expect(actions[0].reason?.lowercased().contains("foreign") == true)
}

@Test func aDeclinedDeletionIsReportedEveryRunNotJustTheFirst() {
    let reg = Registry(projects: ["P1": RegistryEntry(calendarID: "C1", title: "Website")])
    let cal = calendar(foreign: true)

    let firstRun = planLists(projects: [project(status: "completed")], registry: reg, calendars: [cal])
    let secondRun = planLists(projects: [project(status: "completed")], registry: reg, calendars: [cal])

    #expect(kinds(firstRun) == [Kind(kind: .keep, projectUUID: "P1")])
    #expect(kinds(secondRun) == [Kind(kind: .keep, projectUUID: "P1")])
    #expect(firstRun[0].reason == secondRun[0].reason)
}

@Test func anImplausibleProjectReadRefusesAllDeletions() {
    // The registry knows about several projects, but the read came back
    // with almost none of them at all: treat that as a bad read, not a
    // mass project closure.
    let reg = Registry(projects: [
        "P1": RegistryEntry(calendarID: "C1", title: "One"),
        "P2": RegistryEntry(calendarID: "C2", title: "Two"),
        "P3": RegistryEntry(calendarID: "C3", title: "Three"),
        "P4": RegistryEntry(calendarID: "C4", title: "Four"),
    ])
    let calendars = (1...4).map { calendar(calendarID: "C\($0)", title: "list \($0)") }

    let actions = planLists(projects: [], registry: reg, calendars: calendars)

    #expect(actions.count == 4)
    #expect(actions.allSatisfy { $0.kind == .keep })
    #expect(actions.allSatisfy { $0.reason?.lowercased().contains("implausib") == true })
}

@Test func aPlausiblePartialProjectReadStillDeletesTheRest() {
    let reg = Registry(projects: [
        "P1": RegistryEntry(calendarID: "C1", title: "One"),
        "P2": RegistryEntry(calendarID: "C2", title: "Two"),
    ])
    let calendars = [calendar(calendarID: "C1", title: "One"), calendar(calendarID: "C2", title: "Two")]

    let actions = planLists(projects: [project(uuid: "P1", title: "One")], registry: reg, calendars: calendars)

    #expect(kinds(actions) == [Kind(kind: .keep, projectUUID: "P1"), Kind(kind: .deleteList, projectUUID: "P2")])
}
