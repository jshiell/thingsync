import Testing
@testable import ThingsyncCore

@Test func fullAccessPassesAndStillNamesTheResponsibleProcess() {
    let check = remindersCheck(status: 3, host: "iTerm2")

    #expect(check.ok)
    #expect(check.detail.contains("iTerm2"))
}

@Test func notDeterminedDistinguishesNeverAskedFromAHostThatCannotAsk() {
    let check = remindersCheck(status: 0, host: "launchd")

    #expect(!check.ok)
    #expect(check.detail.contains("launchd"))
    #expect(check.remedy?.lowercased().contains("usage description") == true)
}

@Test func deniedPointsAtTheRemindersPaneAndNamesTheHost() {
    let check = remindersCheck(status: 2, host: "iTerm2")

    #expect(!check.ok)
    #expect(check.remedy?.contains("Reminders") == true)
    #expect(check.detail.contains("iTerm2"))
}

@Test func writeOnlyIsNotGoodEnough() {
    #expect(!remindersCheck(status: 4, host: "iTerm2").ok)
}

@Test func restrictedIsNotGoodEnough() {
    let check = remindersCheck(status: 1, host: "iTerm2")

    #expect(!check.ok)
    #expect(check.remedy?.contains("Reminders") == true)
}

private let chain: [Int32: (ppid: Int32, name: String)] = [
    100: (99, "python3.12"),
    99: (98, "zsh"),
    98: (1, "Ghostty"),
    1: (0, "launchd"),
]

@Test func theProcessChainIsWalkedUpToLaunchd() {
    #expect(processAncestry(pid: 100, lookup: { chain[$0] }) == ["python3.12", "zsh", "Ghostty"])
}

@Test func theResponsibleHostIsTheOutermostAppNotTheScript() {
    #expect(responsibleHost(["python3.12", "zsh", "Ghostty"]) == "Ghostty")
}

@Test func anUnwalkableChainStillYieldsAUsableAnswer() {
    #expect(responsibleHost([]) == "unknown")
}

@Test func theTerminalAppIsPreferredOverTheVisibleChain() {
    // The chain truncates at a root-owned login, so the terminal app that
    // actually owns the grant is usually not visible in the ancestry at all.
    #expect(responsibleHost(["python3.12", "zsh"], termProgram: "ghostty") == "ghostty")
}

@Test func theChainIsTheFallbackWhenTheTerminalIsUnnamed() {
    #expect(responsibleHost(["python3.12", "zsh"], termProgram: nil) == "zsh")
    #expect(responsibleHost(["python3.12", "zsh"], termProgram: "") == "zsh")
}

@Test func allGreenReportsSuccessAndExitsZero() {
    let (lines, code) = report([Check(name: "A", ok: true, detail: "fine"), Check(name: "B", ok: true, detail: "fine")])

    #expect(code == 0)
    #expect(lines.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty || $0.contains("✓") || $0.contains("fine") })
}

@Test func anyFailureExitsNonZeroAndPrintsItsRemedy() {
    let (lines, code) = report([
        Check(name: "A", ok: true, detail: "fine"),
        Check(name: "B", ok: false, detail: "broken", remedy: "do the thing"),
    ])

    #expect(code != 0)
    #expect(lines.contains { $0.contains("do the thing") })
}
