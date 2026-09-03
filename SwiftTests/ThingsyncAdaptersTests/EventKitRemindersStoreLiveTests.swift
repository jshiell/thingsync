import EventKit
import Foundation
import Testing
import ThingsyncCore
@testable import ThingsyncAdapters

/// A throwaway list, and the sink/manager pair to work on it, removed
/// again afterwards.
@MainActor
private struct LiveCalendar {
    let store: EKEventStore
    let sink: EventKitRemindersStore
    let manager: EventKitCalendarManager
    let calendar: CalendarRef

    static func make(title: String = "thingsync-test") async throws -> LiveCalendar {
        let store = EKEventStore()
        let sink = EventKitRemindersStore(store: store)
        try await sink.requestAccess()
        let manager = EventKitCalendarManager(store: store)
        let calendar = try manager.create(title: title)
        return LiveCalendar(store: store, sink: sink, manager: manager, calendar: calendar)
    }

    func tearDown() {
        try? manager.delete(calendarID: calendar.id)
    }
}

private func liveEnabled() -> Bool {
    ProcessInfo.processInfo.environment["THINGSYNC_LIVE"] != nil
}

@Test(.tags(.live), .enabled(if: liveEnabled()))
@MainActor
func aReminderRoundTripsThroughCreateScanUpdateAndComplete() async throws {
    let live = try await LiveCalendar.make()
    defer { live.tearDown() }

    let payload = ReminderPayload(
        title: "live round trip", notes: "Area › Project", url: markerURL("LIVE-UUID"),
        dueDate: YearMonthDay(iso: "2026-08-25")
    )

    let identifier = try live.sink.create(calendarID: live.calendar.id, payload: payload)
    #expect(!identifier.isEmpty)

    // the marker is what makes the reminder findable without the state file
    let scans = try await live.manager.scan(calendarIDs: [live.calendar.id])
    #expect(scans[0].marked == ["LIVE-UUID": identifier])
    #expect(live.sink.resolveLive([identifier]) == [identifier: live.calendar.id])

    try live.sink.update(identifier: identifier, payload: ReminderPayload(title: "renamed", notes: "", url: markerURL("LIVE-UUID")))
    let renamed = live.store.calendarItem(withIdentifier: identifier) as? EKReminder
    #expect(renamed?.title == "renamed")

    try live.sink.complete(identifier: identifier)
    let completed = live.store.calendarItem(withIdentifier: identifier) as? EKReminder
    #expect(completed?.isCompleted == true)

    // completed reminders drop out of the incomplete-only marker scan...
    let afterComplete = try await live.manager.scan(calendarIDs: [live.calendar.id])
    #expect(afterComplete[0].marked == [:])
    // ...but still count against the foreign-reminder safety check, since
    // deleting the calendar would delete them too. This one has a marker,
    // so it is not foreign.
    #expect(afterComplete[0].hasForeignReminder == false)
}

@Test(.tags(.live), .enabled(if: liveEnabled()))
@MainActor
func aReminderWithoutAMarkerIsForeignAndInvisibleToTheMarkerScan() async throws {
    let live = try await LiveCalendar.make()
    defer { live.tearDown() }

    let stranger = EKReminder(eventStore: live.store)
    stranger.calendar = live.store.calendar(withIdentifier: live.calendar.id)
    stranger.title = "hand made"
    try live.store.save(stranger, commit: true)

    let scan = try await live.manager.scan(calendarIDs: [live.calendar.id])[0]
    #expect(scan.marked == [:])
    #expect(scan.hasForeignReminder == true)
}

@Test(.tags(.live), .enabled(if: liveEnabled()))
@MainActor
func aCompletedReminderWithoutAMarkerIsForeign() async throws {
    // The exact case the deletion guard exists for: a hand-made reminder
    // that was later completed. It drops out of the incomplete fetch
    // entirely, so only the completed-reminders half of the scan can catch it.
    let live = try await LiveCalendar.make()
    defer { live.tearDown() }

    let stranger = EKReminder(eventStore: live.store)
    stranger.calendar = live.store.calendar(withIdentifier: live.calendar.id)
    stranger.title = "hand made, then completed"
    try live.store.save(stranger, commit: true)
    stranger.isCompleted = true
    try live.store.save(stranger, commit: true)

    let scan = try await live.manager.scan(calendarIDs: [live.calendar.id])[0]
    #expect(scan.marked == [:])
    #expect(scan.hasForeignReminder == true)
}

@Test(.tags(.live), .enabled(if: liveEnabled()))
@MainActor
func movingAReminderPreservesItsIdentifierAndMarker() async throws {
    let live = try await LiveCalendar.make()
    defer { live.tearDown() }

    let calendarB = try live.manager.create(title: "thingsync-test-b")
    defer { try? live.manager.delete(calendarID: calendarB.id) }

    let payload = ReminderPayload(title: "move me", notes: "", url: markerURL("MOVE-UUID"))
    let identifier = try live.sink.create(calendarID: live.calendar.id, payload: payload)

    try live.sink.move(identifier: identifier, calendarID: calendarB.id, payload: payload)

    #expect(live.sink.resolveLive([identifier]) == [identifier: calendarB.id])
    let scanA = try await live.manager.scan(calendarIDs: [live.calendar.id])
    #expect(scanA[0].marked == [:])
    let scanB = try await live.manager.scan(calendarIDs: [calendarB.id])
    #expect(scanB[0].marked == ["MOVE-UUID": identifier])
}

@Test(.tags(.live), .enabled(if: liveEnabled()))
@MainActor
func creatingAListDoesNotRequireScanningItFirst() async throws {
    // --dry-run must never create a list as a side effect of looking at
    // it; this just proves creation and a fresh scan compose without
    // surprises.
    let store = EKEventStore()
    let sink = EventKitRemindersStore(store: store)
    try await sink.requestAccess()
    let manager = EventKitCalendarManager(store: store)

    let titlesBefore = manager.allCalendars().map(\.title)
    #expect(!titlesBefore.contains("thingsync-absent-list"))
}
