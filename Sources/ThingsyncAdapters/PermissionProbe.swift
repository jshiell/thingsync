import EventKit
import Foundation
import ThingsyncCore

/// Open the database the way things.py does, and actually read from it.
///
/// `FileManager.fileExists` alone is not enough: things.py opens
/// `file:...?mode=ro` *without* `immutable`, so a WAL database also needs
/// readable `-shm`/`-wal` sidecars or a writable containing directory.
/// Only a real query proves it.
public func probeThingsDatabase(path: String) -> Check {
    guard FileManager.default.fileExists(atPath: path) else {
        return Check(
            name: "Things database", ok: false,
            detail: "no database at \(path) — Things must have been launched at least once on this Mac",
            remedy: "Launch Things 3 once, then re-run thingsync doctor"
        )
    }

    do {
        let connection = try SQLiteConnection(path: "file:\(path)?mode=ro", flags: [.readOnly, .uri])
        let statement = try connection.prepare("select 1 from sqlite_master limit 1")
        _ = try statement.step()
    } catch {
        return Check(name: "Things database", ok: false, detail: "cannot read \(path): \(error)", remedy: fullDiskAccessPane)
    }

    return Check(name: "Things database", ok: true, detail: "readable at \(path)")
}

/// Read the current status. This never prompts.
public func remindersAuthorizationStatus() -> Int {
    EKEventStore.authorizationStatus(for: .reminder).rawValue
}
