import Foundation
import Testing
@testable import ThingsyncAdapters

private func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test func aReadableDatabaseProbesClean() throws {
    let path = tempDir().appendingPathComponent("main.sqlite").path
    let db = try SQLiteConnection(path: path, flags: [.readWrite, .create])
    try db.execute("create table t (x); insert into t values (1);")

    #expect(probeThingsDatabase(path: path).ok)
}

@Test func aMissingDatabaseIsReportedAsMissingNotAsAPermissionProblem() {
    let path = tempDir().appendingPathComponent("absent.sqlite").path

    let check = probeThingsDatabase(path: path)

    #expect(!check.ok)
    #expect(check.detail.lowercased().contains("launched"))
}

@Test func anUnreadableDatabaseNamesFullDiskAccess() throws {
    let path = tempDir().appendingPathComponent("main.sqlite").path
    let db = try SQLiteConnection(path: path, flags: [.readWrite, .create])
    try db.execute("create table t (x);")
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path) }

    let check = probeThingsDatabase(path: path)

    #expect(!check.ok)
    #expect(check.remedy?.contains("Full Disk Access") == true)
}
