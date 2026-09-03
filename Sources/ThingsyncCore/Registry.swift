import Foundation

/// The project registry exists but cannot be trusted.
///
/// Never downgraded to "start fresh": a blank registry next to a Reminders
/// list still full of markered reminders is the same mass-duplication path
/// `StateError` exists to avoid.
public struct RegistryError: Error, Equatable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

private let registryRepairHint = "run `thingsync rebuild-state` to reconstruct it from your Reminders lists"

public let registryVersion = 1
private let registryFilename = "_projects.json"

/// What we recorded about one project's list.
///
/// `calendarID` is a fast path only, never the key: it is cross-checked (or
/// recovered) by scanning calendar contents for the project's markers.
public struct RegistryEntry: Hashable, Sendable {
    public let calendarID: String?
    public let title: String

    public init(calendarID: String?, title: String) {
        self.calendarID = calendarID
        self.title = title
    }
}

public struct Registry: Hashable, Sendable {
    public var projects: [String: RegistryEntry]

    public init(projects: [String: RegistryEntry] = [:]) {
        self.projects = projects
    }
}

public func registryPath(root: URL? = nil) -> URL {
    (root ?? stateRoot()).appendingPathComponent(registryFilename)
}

private struct RegistryEntryDocument: Codable {
    let calendarID: String?
    let title: String

    enum CodingKeys: String, CodingKey {
        case calendarID = "calendar_id"
        case title
    }
}

private struct RegistryDocument: Codable {
    let version: Int
    let projects: [String: RegistryEntryDocument]
}

/// Write the registry atomically: temp file alongside, then a POSIX rename.
public func save(_ registry: Registry, to path: URL) throws {
    let document = RegistryDocument(
        version: registryVersion,
        projects: registry.projects.mapValues { RegistryEntryDocument(calendarID: $0.calendarID, title: $0.title) }
    )
    try atomicWriteJSON(document, to: path)
}

/// Read the project registry, or an empty one if none exists yet.
public func load(from path: URL) throws -> Registry {
    guard FileManager.default.fileExists(atPath: path.path) else {
        return Registry(projects: [:])
    }

    let document: RegistryDocument
    do {
        let data = try Data(contentsOf: path)
        document = try JSONDecoder().decode(RegistryDocument.self, from: data)
    } catch {
        throw RegistryError("\(path.path) is not a readable thingsync project registry (\(error)); \(registryRepairHint)")
    }

    guard document.version == registryVersion else {
        throw RegistryError(
            "\(path.path) is registry version \(document.version), but this thingsync understands version \(registryVersion); \(registryRepairHint)"
        )
    }

    return Registry(
        projects: document.projects.mapValues { RegistryEntry(calendarID: $0.calendarID, title: $0.title) }
    )
}
