import Foundation
import Testing
@testable import ThingsyncAdapters

private func tempDir() -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.path
}

@Test func thingsDBEnvironmentVariableWinsOverEverything() {
    let path = thingsDatabasePath(environment: ["THINGSDB": "/custom/path.sqlite"], home: tempDir())

    #expect(path == "/custom/path.sqlite")
}

@Test func resolvesTheModernGroupContainerGlob() throws {
    let home = tempDir()
    let dataDir = "\(home)/Library/Group Containers/JLMPQHK86H.com.culturedcode.ThingsMac/ThingsData-ABC123/Things Database.thingsdatabase"
    try FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
    let dbPath = "\(dataDir)/main.sqlite"
    FileManager.default.createFile(atPath: dbPath, contents: Data())

    let path = thingsDatabasePath(environment: [:], home: home)

    #expect(path == dbPath)
}

@Test func fallsBackToThePre31516PathWhenNoModernGlobMatches() {
    let home = tempDir()

    let path = thingsDatabasePath(environment: [:], home: home)

    #expect(path == "\(home)/Library/Group Containers/JLMPQHK86H.com.culturedcode.ThingsMac/Things Database.thingsdatabase/main.sqlite")
}
