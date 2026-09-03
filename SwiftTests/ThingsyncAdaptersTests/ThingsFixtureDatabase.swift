import Foundation
@testable import ThingsyncAdapters

/// A minimal on-disk TMTask/TMArea/TMTag/TMTaskTag/TMChecklistItem schema,
/// built fresh per test -- fast, deterministic, permission-free. Columns
/// are limited to what this port's SQL touches; `Meta` is deliberately
/// absent (see the comment on `taskSelectSQL`).
final class ThingsFixtureDatabase {
    let path: String
    private let write: SQLiteConnection

    init() throws {
        path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite").path
        write = try SQLiteConnection(path: path, flags: [.readWrite, .create])
        try write.execute(
            """
            CREATE TABLE TMTask (
                uuid TEXT PRIMARY KEY,
                title TEXT,
                type INTEGER,
                status INTEGER,
                trashed INTEGER DEFAULT 0,
                notes TEXT,
                area TEXT,
                project TEXT,
                heading TEXT,
                startDate INTEGER,
                deadline INTEGER,
                "index" INTEGER,
                rt1_recurrenceRule TEXT
            )
            """
        )
        try write.execute("CREATE TABLE TMArea (uuid TEXT PRIMARY KEY, title TEXT)")
        try write.execute("CREATE TABLE TMTag (uuid TEXT PRIMARY KEY, title TEXT, \"index\" INTEGER)")
        try write.execute("CREATE TABLE TMTaskTag (tasks TEXT, tags TEXT)")
        try write.execute(
            "CREATE TABLE TMChecklistItem (uuid TEXT PRIMARY KEY, task TEXT, title TEXT, status INTEGER, \"index\" INTEGER)"
        )
    }

    func openForReading() throws -> ThingsDatabase {
        try ThingsDatabase(path: path)
    }

    func insertTask(
        uuid: String,
        title: String,
        type: Int,
        status: Int = 0,
        trashed: Int = 0,
        notes: String? = nil,
        area: String? = nil,
        project: String? = nil,
        heading: String? = nil,
        startDate: Int? = nil,
        deadline: Int? = nil,
        index: Int = 0,
        recurring: Bool = false
    ) throws {
        let statement = try write.prepare(
            """
            INSERT INTO TMTask
                (uuid, title, type, status, trashed, notes, area, project, heading, startDate, deadline, "index", rt1_recurrenceRule)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        )
        statement.bind(uuid, at: 1)
        statement.bind(title, at: 2)
        statement.bind(type, at: 3)
        statement.bind(status, at: 4)
        statement.bind(trashed, at: 5)
        bindOptional(statement, notes, at: 6)
        bindOptional(statement, area, at: 7)
        bindOptional(statement, project, at: 8)
        bindOptional(statement, heading, at: 9)
        bindOptional(statement, startDate, at: 10)
        bindOptional(statement, deadline, at: 11)
        statement.bind(index, at: 12)
        if recurring {
            statement.bind("FREQ=DAILY", at: 13)
        } else {
            statement.bindNull(at: 13)
        }
        _ = try statement.step()
    }

    func insertArea(uuid: String, title: String) throws {
        let statement = try write.prepare("INSERT INTO TMArea (uuid, title) VALUES (?, ?)")
        statement.bind(uuid, at: 1)
        statement.bind(title, at: 2)
        _ = try statement.step()
    }

    func insertTag(uuid: String, title: String, index: Int) throws {
        let statement = try write.prepare("INSERT INTO TMTag (uuid, title, \"index\") VALUES (?, ?, ?)")
        statement.bind(uuid, at: 1)
        statement.bind(title, at: 2)
        statement.bind(index, at: 3)
        _ = try statement.step()
    }

    func insertTaskTag(task: String, tag: String) throws {
        let statement = try write.prepare("INSERT INTO TMTaskTag (tasks, tags) VALUES (?, ?)")
        statement.bind(task, at: 1)
        statement.bind(tag, at: 2)
        _ = try statement.step()
    }

    func insertChecklistItem(uuid: String, task: String, title: String, status: Int, index: Int) throws {
        let statement = try write.prepare(
            "INSERT INTO TMChecklistItem (uuid, task, title, status, \"index\") VALUES (?, ?, ?, ?, ?)"
        )
        statement.bind(uuid, at: 1)
        statement.bind(task, at: 2)
        statement.bind(title, at: 3)
        statement.bind(status, at: 4)
        statement.bind(index, at: 5)
        _ = try statement.step()
    }

    private func bindOptional(_ statement: SQLiteStatement, _ value: String?, at index: Int32) {
        if let value {
            statement.bind(value, at: index)
        } else {
            statement.bindNull(at: index)
        }
    }

    private func bindOptional(_ statement: SQLiteStatement, _ value: Int?, at index: Int32) {
        if let value {
            statement.bind(value, at: index)
        } else {
            statement.bindNull(at: index)
        }
    }
}
