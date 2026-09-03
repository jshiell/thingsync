import Testing
@testable import ThingsyncCore

@Test func packageExposesAVersion() {
    #expect(!Thingsync.version.isEmpty)
}
