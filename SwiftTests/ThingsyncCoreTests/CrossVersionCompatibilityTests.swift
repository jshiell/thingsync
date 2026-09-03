import Foundation
import Testing
@testable import ThingsyncCore

private func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// A literal state.json produced by the real Python implementation
/// (`uv run python -c "... state.save(...)"`), embedded verbatim rather
/// than round-tripped through Swift's own encoder -- the point is pinning
/// this against the actual artefact a Python-run thingsync would leave
/// behind, so a user switching mid-flight gets SKIP, not duplication.
private let pythonStateJSON = """
    {
      "items": {
        "U1": {
          "hash": "h1",
          "reminder_id": "R1"
        }
      },
      "project_uuid": "P1",
      "target_list": "Website",
      "version": 1
    }
    """

private let pythonRegistryJSON = """
    {
      "projects": {
        "P1": {
          "calendar_id": "C1",
          "title": "Website"
        }
      },
      "version": 1
    }
    """

@Test func decodesAPythonProducedStateFile() throws {
    let dir = tempDir()
    let path = dir.appendingPathComponent("p.json")
    try pythonStateJSON.write(to: path, atomically: true, encoding: .utf8)

    let state = try load(from: path, targetList: "Website", projectUUID: "P1")

    #expect(state.targetList == "Website")
    #expect(state.projectUUID == "P1")
    #expect(state.items == ["U1": StateEntry(reminderID: "R1", hash: "h1")])

    // Re-encoding and decoding it back must be lossless.
    try save(state, to: path)
    #expect(try load(from: path, targetList: "Website", projectUUID: "P1") == state)
}

@Test func decodesAPythonProducedRegistryFile() throws {
    let dir = tempDir()
    let path = dir.appendingPathComponent("_projects.json")
    try pythonRegistryJSON.write(to: path, atomically: true, encoding: .utf8)

    let registry = try load(from: path)

    #expect(registry.projects == ["P1": RegistryEntry(calendarID: "C1", title: "Website")])

    try save(registry, to: path)
    #expect(try load(from: path) == registry)
}
