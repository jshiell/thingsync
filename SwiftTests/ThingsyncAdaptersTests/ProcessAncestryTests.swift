import Foundation
import Testing
@testable import ThingsyncAdapters

// Confirms proc_pidinfo/proc_bsdinfo are actually exposed by the Darwin
// module on this toolchain (verified once, live, in this increment) --
// the plan's explicit fallback (a tiny C target wrapping <libproc.h>, or
// sysctl/KERN_PROC_PID) is not needed.
@Test func nativeProcLookupResolvesTheCurrentProcesssParent() {
    let found = nativeProcLookup(ProcessInfo.processInfo.processIdentifier)

    #expect(found != nil)
    #expect(found?.ppid ?? 0 > 0)
    #expect(found?.name.isEmpty == false)
}
