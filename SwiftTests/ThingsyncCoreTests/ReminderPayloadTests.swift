import Testing
@testable import ThingsyncCore

private func payload(
    title: String = "t",
    notes: String = "n",
    url: String = "things:///show?id=U1",
    dueDate: YearMonthDay? = nil,
    startDate: YearMonthDay? = nil
) -> ReminderPayload {
    ReminderPayload(title: title, notes: notes, url: url, dueDate: dueDate, startDate: startDate)
}

@Test func identicalPayloadsHashAlike() {
    #expect(payload().contentHash() == payload().contentHash())
}

@Test func everyMirroredFieldChangesTheHash() {
    let baseline = payload().contentHash()

    #expect(payload(title: "other").contentHash() != baseline)
    #expect(payload(notes: "other").contentHash() != baseline)
    #expect(payload(url: "things:///show?id=U2").contentHash() != baseline)
    #expect(payload(dueDate: YearMonthDay(iso: "2026-08-25")).contentHash() != baseline)
    #expect(payload(startDate: YearMonthDay(iso: "2026-08-25")).contentHash() != baseline)
}

@Test func dueAndStartDatesAreNotInterchangeableInTheHash() {
    let onDue = payload(dueDate: YearMonthDay(iso: "2026-08-25")).contentHash()
    let onStart = payload(startDate: YearMonthDay(iso: "2026-08-25")).contentHash()

    #expect(onDue != onStart)
}

/// Golden digests captured directly from the running Python implementation
/// (`uv run python -c "..."`), not derived — a mismatch here means the two
/// binaries would disagree about which reminders need writing.
@Test(arguments: [
    (
        payload(),
        "94ca904b404f7826a354a739265f9c789baec9ef3cc01bf2b1b812786c75a048"
    ),
    (
        payload(dueDate: YearMonthDay(iso: "2026-08-25"), startDate: YearMonthDay(iso: "2026-08-20")),
        "eb4d1be48d4c14a3aee1455ee3fae49ed3ec8064b073fee301416bd6ab613d2a"
    ),
    (
        payload(title: "café ☐", notes: "Work › Website\n\n☐ pack", url: "things:///show?id=U2"),
        "08d96d567c278a007cfd58ac5102a729030ca011cbf9cb1492af9b2fb0a8589c"
    ),
    (
        payload(title: "say \"hi\" \\ bye", notes: "tab\there", url: "things:///show?id=U3"),
        "7e7718f331a81eac71dfdf6b5117c4338c8f6d927b17c1b309082c6a93c5c3fb"
    ),
    (
        payload(title: "x\u{01}y"),
        "a9b2f161fad59e8fde9feb6cfa709108521ae647b01d9f4b3c01031ec23a93e4"
    ),
] as [(ReminderPayload, String)])
func contentHashMatchesPython(_ payload: ReminderPayload, _ expected: String) {
    #expect(payload.contentHash() == expected)
}
