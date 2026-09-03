import Foundation
import Testing
@testable import ThingsyncCore

private func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test func aSavedStateRoundTrips() throws {
    let dir = tempDir()
    let path = dir.appendingPathComponent("Things.json")
    let state = State(targetList: "Things", items: ["U1": StateEntry(reminderID: "R1", hash: "h1")])

    try save(state, to: path)

    #expect(try load(from: path, targetList: "Things") == state)
}

@Test func aMissingFileIsAnEmptyStateForThatList() throws {
    let dir = tempDir()
    let loaded = try load(from: dir.appendingPathComponent("absent.json"), targetList: "Things")

    #expect(loaded == State(targetList: "Things", items: [:]))
}

@Test func anUnparseableStateFileIsAHardErrorNamingTheRepair() throws {
    let dir = tempDir()
    let path = dir.appendingPathComponent("Things.json")
    try "{ this is not json".write(to: path, atomically: true, encoding: .utf8)

    #expect(throws: StateError.self) {
        try load(from: path, targetList: "Things")
    }
    do {
        _ = try load(from: path, targetList: "Things")
    } catch let error as StateError {
        #expect(error.description.contains("rebuild-state"))
    }
}

@Test func aNonUTF8StateFileIsAlsoAHardError() throws {
    let dir = tempDir()
    let path = dir.appendingPathComponent("Things.json")
    try Data([0x80, 0x81, 0x82]).write(to: path)

    do {
        _ = try load(from: path, targetList: "Things")
        Issue.record("expected StateError")
    } catch let error as StateError {
        #expect(error.description.contains("rebuild-state"))
    }
}

@Test func aStructurallyWrongStateFileIsAlsoAHardError() throws {
    let dir = tempDir()
    let path = dir.appendingPathComponent("Things.json")
    try #"{"version": 1, "target_list": "Things"}"#.write(to: path, atomically: true, encoding: .utf8)

    do {
        _ = try load(from: path, targetList: "Things")
        Issue.record("expected StateError")
    } catch let error as StateError {
        #expect(error.description.contains("rebuild-state"))
    }
}

@Test func anUnknownVersionIsRefusedRatherThanGuessed() throws {
    let dir = tempDir()
    let path = dir.appendingPathComponent("Things.json")
    try #"{"version": 99, "target_list": "Things", "items": {}}"#.write(to: path, atomically: true, encoding: .utf8)

    #expect(throws: StateError.self) {
        try load(from: path, targetList: "Things")
    }
}

@Test func stateForADifferentListIsRefused() throws {
    let dir = tempDir()
    let path = dir.appendingPathComponent("Things.json")
    try save(State(targetList: "Scratch", items: [:]), to: path)

    do {
        _ = try load(from: path, targetList: "Things")
        Issue.record("expected StateError")
    } catch let error as StateError {
        #expect(error.description.contains("Scratch"))
        #expect(error.description.contains("Things"))
    }
}

@Test func savingLeavesNoTemporaryFilesBehind() throws {
    let dir = tempDir()
    let path = dir.appendingPathComponent("Things.json")

    try save(State(targetList: "Things", items: ["U1": StateEntry(reminderID: "R1", hash: "h1")]), to: path)
    try save(State(targetList: "Things", items: ["U2": StateEntry(reminderID: "R2", hash: "h2")]), to: path)

    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    #expect(names == ["Things.json"])
    #expect(try load(from: path, targetList: "Things").items == ["U2": StateEntry(reminderID: "R2", hash: "h2")])
}

// See StateDirectoryEnvironmentTests.swift for the env-var-mutating cases
// ported from test_the_state_directory_can_be_redirected and
// test_an_explicit_root_still_wins_over_the_environment.

@Test func anAbsentRootHasNoLegacyFiles() {
    let dir = tempDir()
    #expect(legacyStateFiles(root: dir.appendingPathComponent("absent")) == [])
}

@Test func anEmptyRootHasNoLegacyFiles() {
    let dir = tempDir()
    #expect(legacyStateFiles(root: dir) == [])
}

@Test func aTopLevelStateFileIsLegacy() throws {
    let dir = tempDir()
    try "{}".write(to: dir.appendingPathComponent("Things.json"), atomically: true, encoding: .utf8)

    #expect(legacyStateFiles(root: dir).map(\.lastPathComponent) == ["Things.json"])
}

@Test func checkForLegacyStatePassesWhenNoneIsFound() throws {
    let dir = tempDir()
    try checkForLegacyState(root: dir)
}

@Test func checkForLegacyStateNamesTheFileAndTheMigrationSteps() throws {
    let dir = tempDir()
    try "{}".write(to: dir.appendingPathComponent("Things.json"), atomically: true, encoding: .utf8)

    do {
        try checkForLegacyState(root: dir)
        Issue.record("expected LegacyStateError")
    } catch let error as LegacyStateError {
        #expect(error.description.contains("Things.json"))
        #expect(error.description.contains("Reminders"))
        #expect(error.description.lowercased().contains("delete"))
    }
}

@Test func theInboxStateFileIsNeverFlaggedAsLegacy() throws {
    let dir = tempDir()
    try "{}".write(to: dir.appendingPathComponent("inbox.json"), atomically: true, encoding: .utf8)

    #expect(legacyStateFiles(root: dir) == [])
}

@Test func projectStateLivesUnderAProjectsSubdirectory() {
    let dir = tempDir()
    #expect(projectStatePath("P1", root: dir) == dir.appendingPathComponent("projects").appendingPathComponent("P1.json"))
}

@Test func eachProjectGetsItsOwnStateFile() {
    let dir = tempDir()
    #expect(projectStatePath("P1", root: dir) != projectStatePath("P2", root: dir))
}

@Test func inboxStateHasOneFixedPath() {
    let dir = tempDir()
    #expect(inboxStatePath(root: dir) == dir.appendingPathComponent("inbox.json"))
}

@Test func stateDefaultsToNoProjectUUID() {
    #expect(State(targetList: "Things", items: [:]).projectUUID == nil)
}

@Test func stateRoundTripsItsProjectUUID() throws {
    let dir = tempDir()
    let path = dir.appendingPathComponent("p.json")
    let state = State(targetList: "Website", items: [:], projectUUID: "P1")

    try save(state, to: path)

    #expect(try load(from: path, targetList: "Website", projectUUID: "P1") == state)
}

@Test func aRenamedProjectDoesNotRaiseWhenTheProjectUUIDStillMatches() throws {
    let dir = tempDir()
    let path = dir.appendingPathComponent("p.json")
    try save(
        State(targetList: "Old Name", items: ["U1": StateEntry(reminderID: "R1", hash: "h1")], projectUUID: "P1"),
        to: path
    )

    let loaded = try load(from: path, targetList: "New Name", projectUUID: "P1")

    #expect(loaded.items == ["U1": StateEntry(reminderID: "R1", hash: "h1")])
}

@Test func stateForADifferentProjectIsRefusedEvenWithAMatchingTitle() throws {
    let dir = tempDir()
    let path = dir.appendingPathComponent("p.json")
    try save(State(targetList: "Website", items: [:], projectUUID: "P1"), to: path)

    do {
        _ = try load(from: path, targetList: "Website", projectUUID: "P2")
        Issue.record("expected StateError")
    } catch let error as StateError {
        #expect(error.description.contains("P1"))
        #expect(error.description.contains("P2"))
    }
}

@Test func titleOnlyMismatchIsStillRefusedWhenNoProjectUUIDIsInvolved() throws {
    let dir = tempDir()
    let path = dir.appendingPathComponent("p.json")
    try save(State(targetList: "Scratch", items: [:]), to: path)

    #expect(throws: StateError.self) {
        try load(from: path, targetList: "Things")
    }
}
