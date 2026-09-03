import Testing

/// Marks a test that touches the real Things database or Reminders store.
/// Deselected by default; opt in with `THINGSYNC_LIVE=1 swift test`.
extension Tag {
    @Tag static var live: Self
}
