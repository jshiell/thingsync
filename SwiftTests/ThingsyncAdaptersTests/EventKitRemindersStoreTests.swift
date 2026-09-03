import Testing
import ThingsyncCore
@testable import ThingsyncAdapters

@Test func aDateBecomesDateOnlyComponents() {
    let components = dateComponents(for: YearMonthDay(iso: "2026-08-25"))

    #expect(components?.year == 2026)
    #expect(components?.month == 8)
    #expect(components?.day == 25)
}

@Test func noTimeOfDayIsSet() {
    // A time would turn an all-day due date into a timed one, and timed
    // reminders behave differently in the Reminders app.
    let components = dateComponents(for: YearMonthDay(iso: "2026-08-25"))

    #expect(components?.hour == nil)
    #expect(components?.minute == nil)
}

@Test func noDateYieldsNoComponents() {
    #expect(dateComponents(for: nil) == nil)
}
