import Testing
@testable import ThingsyncAdapters

private func openMemoryDB() throws -> SQLiteConnection {
    try SQLiteConnection(path: ":memory:", flags: [.readWrite, .create])
}

@Test func aStatementCanInsertAndReadBackARow() throws {
    let db = try openMemoryDB()
    try db.execute("CREATE TABLE t (id INTEGER, name TEXT)")
    try db.execute("INSERT INTO t VALUES (1, 'hello')")

    let statement = try db.prepare("SELECT id, name FROM t")
    #expect(try statement.step() == true)
    #expect(statement.columnInt(0) == 1)
    #expect(statement.columnText(1) == "hello")
    #expect(try statement.step() == false)
}

@Test func columnTextIsNilForASQLNull() throws {
    let db = try openMemoryDB()
    try db.execute("CREATE TABLE t (name TEXT)")
    try db.execute("INSERT INTO t VALUES (NULL)")

    let statement = try db.prepare("SELECT name FROM t")
    #expect(try statement.step() == true)
    #expect(statement.columnText(0) == nil)
}

@Test func columnIntIsNilForASQLNull() throws {
    let db = try openMemoryDB()
    try db.execute("CREATE TABLE t (n INTEGER)")
    try db.execute("INSERT INTO t VALUES (NULL)")

    let statement = try db.prepare("SELECT n FROM t")
    #expect(try statement.step() == true)
    #expect(statement.columnInt(0) == nil)
}

@Test func bindSubstitutesAParameter() throws {
    let db = try openMemoryDB()
    try db.execute("CREATE TABLE t (name TEXT)")
    try db.execute("INSERT INTO t VALUES ('alice')")
    try db.execute("INSERT INTO t VALUES ('bob')")

    let statement = try db.prepare("SELECT name FROM t WHERE name = ?")
    statement.bind("bob", at: 1)
    #expect(try statement.step() == true)
    #expect(statement.columnText(0) == "bob")
    #expect(try statement.step() == false)
}

@Test func openingAMissingReadOnlyPathFails() {
    #expect(throws: SQLiteError.self) {
        _ = try SQLiteConnection(path: "/nonexistent/path/nowhere.sqlite", flags: [.readOnly])
    }
}

@Test func aMalformedStatementFailsToPrepare() throws {
    let db = try openMemoryDB()
    #expect(throws: SQLiteError.self) {
        _ = try db.prepare("SELECT this is not sql")
    }
}
