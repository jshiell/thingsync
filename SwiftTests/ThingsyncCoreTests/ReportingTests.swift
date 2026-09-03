import Testing
@testable import ThingsyncCore

@Test func pythonReprUsesSingleQuotesByDefault() {
    #expect(pythonRepr("Website") == "'Website'")
}

@Test func pythonReprSwitchesToDoubleQuotesForAnApostrophe() {
    // A naive "'\(title)'" interpolation would produce 'Dave's kitchen' --
    // invalid, and not what Python's repr() actually does.
    #expect(pythonRepr("Dave's kitchen") == "\"Dave's kitchen\"")
}

@Test func pythonReprKeepsSingleQuotesForEmbeddedDoubleQuotes() {
    #expect(pythonRepr("He said \"hi\"") == "'He said \"hi\"'")
}

@Test func pythonReprEscapesASingleQuoteWhenBothQuoteCharsArePresent() {
    #expect(pythonRepr("both ' and \" here") == "'both \\' and \" here'")
}

@Test func pythonReprEscapesBackslashesAndCommonControlCharacters() {
    #expect(pythonRepr("a\\b") == "'a\\\\b'")
    #expect(pythonRepr("line\nbreak") == "'line\\nbreak'")
    #expect(pythonRepr("tab\there") == "'tab\\there'")
}

@Test func describePadsTheKindToEightColumns() {
    let todo = ThingsTodo(uuid: "U1", title: "Buy milk")
    let payload = toPayload(todo)
    let action = SyncAction(kind: .create, uuid: "U1", payload: payload, calendarID: "CAL")

    #expect(describe(action) == "  create  Buy milk")
}

@Test func describeFallsBackToTheUUIDWithNoPayload() {
    let action = SyncAction(kind: .forget, uuid: "U1")

    #expect(describe(action) == "  forget  U1")
}

@Test func describeListActionPadsTheKindToTwelveColumnsAndQuotesTheTitle() {
    let action = ListAction(kind: .createList, projectUUID: "P1", title: "Website")

    #expect(describeListAction(action) == " create_list  'Website'")
}

@Test func describeListActionReportsARefusalReasonInsteadOfTheKind() {
    let action = ListAction(kind: .keep, projectUUID: "P1", title: "Website", calendarID: "C1", reason: "a foreign reminder is here")

    #expect(describeListAction(action) == "  refused  'Website': a foreign reminder is here")
}
