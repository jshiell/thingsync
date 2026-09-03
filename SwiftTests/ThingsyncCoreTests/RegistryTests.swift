import Foundation
import Testing
@testable import ThingsyncCore

private func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test func aSavedRegistryRoundTrips() throws {
    let dir = tempDir()
    let path = dir.appendingPathComponent("_projects.json")
    let registry = Registry(projects: ["P1": RegistryEntry(calendarID: "C1", title: "Website")])

    try save(registry, to: path)

    #expect(try load(from: path) == registry)
}

@Test func aMissingFileIsAnEmptyRegistry() throws {
    let dir = tempDir()
    #expect(try load(from: dir.appendingPathComponent("absent.json")) == Registry(projects: [:]))
}

@Test func aRegistryEntryMayHaveNoCachedCalendarIDYet() throws {
    let dir = tempDir()
    let path = dir.appendingPathComponent("_projects.json")
    let registry = Registry(projects: ["P1": RegistryEntry(calendarID: nil, title: "Website")])

    try save(registry, to: path)

    #expect(try load(from: path).projects["P1"]?.calendarID == nil)
}

@Test func anUnparseableRegistryIsAHardError() throws {
    let dir = tempDir()
    let path = dir.appendingPathComponent("_projects.json")
    try "{ not json".write(to: path, atomically: true, encoding: .utf8)

    #expect(throws: RegistryError.self) {
        try load(from: path)
    }
}

@Test func aNonUTF8RegistryIsAlsoAHardError() throws {
    let dir = tempDir()
    let path = dir.appendingPathComponent("_projects.json")
    try Data([0x80, 0x81, 0x82]).write(to: path)

    #expect(throws: RegistryError.self) {
        try load(from: path)
    }
}

@Test func aStructurallyWrongRegistryIsAlsoAHardError() throws {
    let dir = tempDir()
    let path = dir.appendingPathComponent("_projects.json")
    try #"{"version": 1}"#.write(to: path, atomically: true, encoding: .utf8)

    #expect(throws: RegistryError.self) {
        try load(from: path)
    }
}

@Test func anUnknownRegistryVersionIsRefusedRatherThanGuessed() throws {
    let dir = tempDir()
    let path = dir.appendingPathComponent("_projects.json")
    try #"{"version": 99, "projects": {}}"#.write(to: path, atomically: true, encoding: .utf8)

    #expect(throws: RegistryError.self) {
        try load(from: path)
    }
}

@Test func savingTheRegistryLeavesNoTemporaryFilesBehind() throws {
    let dir = tempDir()
    let path = dir.appendingPathComponent("_projects.json")

    try save(Registry(projects: ["P1": RegistryEntry(calendarID: "C1", title: "Website")]), to: path)
    try save(Registry(projects: ["P2": RegistryEntry(calendarID: "C2", title: "Renovate")]), to: path)

    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    #expect(names == ["_projects.json"])
    #expect(try load(from: path).projects == ["P2": RegistryEntry(calendarID: "C2", title: "Renovate")])
}

// See StateDirectoryEnvironmentTests.swift for the env-var-mutating case
// ported from test_registry_path_defaults_under_the_state_root.

@Test func registryPathHonoursAnExplicitRoot() {
    let dir = tempDir()
    #expect(registryPath(root: dir) == dir.appendingPathComponent("_projects.json"))
}

@Test func theRegistryFileItselfIsNeverFlaggedAsLegacyState() throws {
    let dir = tempDir()
    try save(Registry(projects: [:]), to: registryPath(root: dir))

    #expect(legacyStateFiles(root: dir) == [])
}
