/// Establish the two permissions thingsync needs, empirically.
///
/// Both are attributed by macOS to the *responsible process* -- the
/// terminal you ran this from, not this binary -- so every diagnosis names
/// that process too. Without it, notDetermined and denied are each
/// ambiguous between two very different causes, and doctor would
/// confidently misdiagnose the one failure it exists to catch.

public struct Check: Hashable, Sendable {
    public let name: String
    public let ok: Bool
    public let detail: String
    public let remedy: String?

    public init(name: String, ok: Bool, detail: String, remedy: String? = nil) {
        self.name = name
        self.ok = ok
        self.detail = detail
        self.remedy = remedy
    }
}

public let fullDiskAccessPane =
    "System Settings → Privacy & Security → Full Disk Access (add your terminal, then restart it — macOS binds the decision at launch)"
public let remindersPane = "System Settings → Privacy & Security → Reminders"

private let notDetermined = 0
private let restricted = 1
private let denied = 2
private let fullAccess = 3
private let writeOnly = 4

/// Turn an `EKAuthorizationStatus` into a diagnosis that names the host.
///
/// Stays `Int`-typed rather than an EventKit-backed enum -- Python's
/// constants 0-4 already are the ABI -- so Core stays EventKit-free; the
/// adapter converts `EKAuthorizationStatus.rawValue`.
///
/// `notDetermined` means either "nobody has asked yet" or "the host has no
/// `NSRemindersFullAccessUsageDescription`, so TCC denies synchronously
/// with no prompt at all". `denied` means either "the user said no" or "the
/// grant is attached to a different host". The status alone cannot tell
/// these apart, which is why the host is always reported alongside it.
public func remindersCheck(status: Int, host: String) -> Check {
    let name = "Reminders access"

    if status == fullAccess {
        return Check(name: name, ok: true, detail: "full access, granted to \(host)")
    }

    if status == notDetermined {
        return Check(
            name: name, ok: false, detail: "not determined for \(host)",
            remedy:
                "Run `thingsync sync` from \(host) to trigger the prompt. If no prompt appears, that host has no NSRemindersFullAccessUsageDescription and TCC is denying synchronously — that host is missing the NSRemindersFullAccessUsageDescription usage description, so run from a terminal instead"
        )
    }

    if status == writeOnly {
        return Check(
            name: name, ok: false, detail: "write-only access for \(host); thingsync must read to avoid duplicating",
            remedy: remindersPane
        )
    }

    if status == restricted {
        return Check(name: name, ok: false, detail: "restricted for \(host) — likely a device management profile", remedy: remindersPane)
    }

    return Check(
        name: name, ok: false, detail: "denied for \(host)",
        remedy: "\(remindersPane) — enable it for \(host). If \(host) is not listed, the grant is attached to a different host process"
    )
}

/// Command names from `pid` outwards, stopping before launchd.
public func processAncestry(pid: Int32, lookup: ProcLookup) -> [String] {
    var names: [String] = []
    var seen: Set<Int32> = []
    var currentPid = pid

    while currentPid > 1, !seen.contains(currentPid) {
        seen.insert(currentPid)
        guard let found = lookup(currentPid) else { break }
        names.append(found.name)
        currentPid = found.ppid
    }

    return names
}

/// Name the process macOS attributes privacy grants to.
///
/// The ancestry walk cannot see past a root-owned `login`, which every
/// terminal spawns between itself and your shell -- so the terminal app is
/// usually absent from the visible chain. `TERM_PROGRAM` names it
/// directly, and is the better answer whenever it is set (and non-empty).
public func responsibleHost(_ ancestry: [String], termProgram: String? = nil) -> String {
    if let termProgram, !termProgram.isEmpty {
        return termProgram
    }
    return ancestry.last ?? "unknown"
}

/// Render the checks, and decide the exit code.
public func report(_ checks: [Check]) -> (lines: [String], code: Int32) {
    var lines: [String] = []

    for check in checks {
        let mark = check.ok ? "✓" : "✗"
        lines.append("\(mark) \(check.name): \(check.detail)")
        if !check.ok, let remedy = check.remedy {
            lines.append("    → \(remedy)")
        }
    }

    let failures = checks.filter { !$0.ok }
    if !failures.isEmpty {
        lines.append("")
        lines.append("\(failures.count) of \(checks.count) checks failed.")
    }

    return (lines, failures.isEmpty ? 0 : 1)
}
