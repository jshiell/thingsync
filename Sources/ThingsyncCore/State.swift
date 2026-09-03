import Foundation
#if canImport(Darwin)
    import Darwin
#endif

/// The state file exists but cannot be trusted.
///
/// Never downgraded to "start fresh": an empty state plus a present list is
/// the mass-duplication path this whole design exists to avoid.
public struct StateError: Error, Equatable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

/// State from the single-list build is present.
///
/// Adopting it silently would mean the per-project scans never look at the
/// old calendar, so every to-do gets recreated fresh in its project list
/// while the old markered copies sit there untouched: permanent duplication
/// delivered by the upgrade itself. Refused until the operator migrates by
/// hand.
public struct LegacyStateError: Error, Equatable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

private let legacyMigrationHint = """
    thingsync now mirrors one Reminders list per Things project instead of one shared \
    list. To migrate: (1) in the Reminders app, delete the list thingsync used to write \
    into; (2) delete the state file(s) named above; (3) re-run `thingsync sync` to build \
    fresh per-project lists.
    """

private let stateRepairHint = "run `thingsync rebuild-state` to reconstruct it from the target list"

public let stateVersion = 1

public let knownRootFiles: Set<String> = ["_projects.json", "inbox.json"]

/// What we recorded about one mirrored to-do.
///
/// `reminderID` is a `calendarItemIdentifier`, which Apple documents as
/// *local* — a full iCloud sync discards it. It is a fast path, never the key.
public struct StateEntry: Hashable, Sendable {
    public let reminderID: String
    public let hash: String

    public init(reminderID: String, hash: String) {
        self.reminderID = reminderID
        self.hash = hash
    }
}

public struct State: Hashable, Sendable {
    public var targetList: String
    public var items: [String: StateEntry]
    public var projectUUID: String?

    public init(targetList: String, items: [String: StateEntry] = [:], projectUUID: String? = nil) {
        self.targetList = targetList
        self.items = items
        self.projectUUID = projectUUID
    }
}

public let stateDirEnvironmentVariable = "THINGSYNC_STATE_DIR"
private let projectsSubdirectory = "projects"
private let inboxStateFilename = "inbox.json"

/// Where state files live, overridable for sandboxes and tests.
public func stateRoot() -> URL {
    if let override = ProcessInfo.processInfo.environment[stateDirEnvironmentVariable], !override.isEmpty {
        return URL(fileURLWithPath: override)
    }
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local", isDirectory: true)
        .appendingPathComponent("state", isDirectory: true)
        .appendingPathComponent("thingsync", isDirectory: true)
}

/// One state file per Things project, keyed by UUID rather than its
/// (mutable) title, under its own subdirectory so it is never mistaken for a
/// leftover single-list state file.
public func projectStatePath(_ projectUUID: String, root: URL? = nil) -> URL {
    (root ?? stateRoot())
        .appendingPathComponent(projectsSubdirectory, isDirectory: true)
        .appendingPathComponent("\(projectUUID).json")
}

/// The one fixed state file for to-dos with no project.
public func inboxStatePath(root: URL? = nil) -> URL {
    (root ?? stateRoot()).appendingPathComponent(inboxStateFilename)
}

private struct StateEntryDocument: Codable {
    let reminderID: String
    let hash: String

    enum CodingKeys: String, CodingKey {
        case reminderID = "reminder_id"
        case hash
    }
}

private struct StateDocument: Codable {
    let version: Int
    let targetList: String
    let projectUUID: String?
    let items: [String: StateEntryDocument]

    enum CodingKeys: String, CodingKey {
        case version
        case targetList = "target_list"
        case projectUUID = "project_uuid"
        case items
    }
}

/// Write the state atomically: temp file alongside, then a POSIX rename.
public func save(_ state: State, to path: URL) throws {
    let document = StateDocument(
        version: stateVersion,
        targetList: state.targetList,
        projectUUID: state.projectUUID,
        items: state.items.mapValues { StateEntryDocument(reminderID: $0.reminderID, hash: $0.hash) }
    )
    try atomicWriteJSON(document, to: path)
}

/// Read the state for `targetList`, or an empty state if none exists yet.
///
/// The mismatch guard keys on `projectUUID` whenever either side has one,
/// since a project's title can be renamed in Things at any time; only when
/// neither side carries a project UUID does it fall back to the older,
/// title-based guard.
public func load(from path: URL, targetList: String, projectUUID: String? = nil) throws -> State {
    guard FileManager.default.fileExists(atPath: path.path) else {
        return State(targetList: targetList, items: [:], projectUUID: projectUUID)
    }

    let document: StateDocument
    do {
        let data = try Data(contentsOf: path)
        document = try JSONDecoder().decode(StateDocument.self, from: data)
    } catch {
        throw StateError("\(path.path) is not a readable thingsync state file (\(error)); \(stateRepairHint)")
    }

    guard document.version == stateVersion else {
        throw StateError(
            "\(path.path) is state version \(document.version), but this thingsync understands version \(stateVersion); \(stateRepairHint)"
        )
    }

    if projectUUID != nil || document.projectUUID != nil {
        guard document.projectUUID == projectUUID else {
            throw StateError(
                "\(path.path) holds state for project \(document.projectUUID as Any), but project \(projectUUID as Any) was requested; refusing to apply one project's mappings to another"
            )
        }
    } else if document.targetList != targetList {
        throw StateError(
            "\(path.path) holds state for list \(document.targetList), but list \(targetList) was requested; refusing to apply one list's mappings to another"
        )
    }

    return State(
        targetList: document.targetList,
        items: document.items.mapValues { StateEntry(reminderID: $0.reminderID, hash: $0.hash) },
        projectUUID: document.projectUUID
    )
}

/// State files left over from the single-list build.
///
/// The per-project layout keeps every state file either under a `projects/`
/// subdirectory or under one of `knownRootFiles`; anything else sitting as
/// JSON directly in the state root predates that and is not eligible for
/// silent adoption.
public func legacyStateFiles(root: URL? = nil) -> [URL] {
    let root = root ?? stateRoot()
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue,
        let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    else { return [] }

    return
        entries
        .filter { $0.pathExtension == "json" && !knownRootFiles.contains($0.lastPathComponent) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

/// Refuse to run against a single-list state layout.
///
/// Called before anything else in a sync run, so no per-project code can
/// ever run against state it would silently duplicate.
public func checkForLegacyState(root: URL? = nil) throws {
    let files = legacyStateFiles(root: root)
    guard !files.isEmpty else { return }
    let names = files.map(\.lastPathComponent).joined(separator: ", ")
    throw LegacyStateError(
        "found old single-list state file(s) in \((root ?? stateRoot()).path): \(names). \(legacyMigrationHint)"
    )
}

/// Write `document` to `path` atomically: a `.tmp` sibling, then a POSIX
/// `rename()` — not `FileManager.moveItem` (fails if the destination
/// exists) and not `replaceItemAt` (a different mechanism that can leave
/// residue).
func atomicWriteJSON(_ document: some Encodable, to path: URL) throws {
    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(document)

    let tempPath = path.appendingPathExtension("tmp")
    try data.write(to: tempPath)

    let result = tempPath.path.withCString { tempCString in
        path.path.withCString { pathCString in
            rename(tempCString, pathCString)
        }
    }
    guard result == 0 else {
        let message = String(cString: strerror(errno))
        throw StateError("failed to rename \(tempPath.path) to \(path.path): \(message)")
    }
}
