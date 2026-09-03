import Foundation
import Testing
@testable import ThingsyncCore

private func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// setenv/unsetenv are process-global and swift-testing parallelizes by
/// default, so every test that touches THINGSYNC_STATE_DIR -- for both
/// State and Registry -- lives in this one serialized suite rather than
/// racing across files.
@Suite(.serialized) struct StateDirectoryEnvironmentTests {
    @Test func theStateDirectoryCanBeRedirected() throws {
        let dir = tempDir()
        setenv(stateDirEnvironmentVariable, dir.appendingPathComponent("elsewhere").path, 1)
        defer { unsetenv(stateDirEnvironmentVariable) }

        #expect(projectStatePath("P1").deletingLastPathComponent().path == dir.appendingPathComponent("elsewhere").appendingPathComponent("projects").path)
    }

    @Test func anExplicitRootStillWinsOverTheEnvironment() throws {
        let dir = tempDir()
        setenv(stateDirEnvironmentVariable, dir.appendingPathComponent("ignored").path, 1)
        defer { unsetenv(stateDirEnvironmentVariable) }

        #expect(projectStatePath("P1", root: dir).deletingLastPathComponent().path == dir.appendingPathComponent("projects").path)
    }

    @Test func registryPathDefaultsUnderTheStateRoot() throws {
        let dir = tempDir()
        setenv(stateDirEnvironmentVariable, dir.path, 1)
        defer { unsetenv(stateDirEnvironmentVariable) }

        #expect(registryPath().path == dir.appendingPathComponent("_projects.json").path)
    }
}
