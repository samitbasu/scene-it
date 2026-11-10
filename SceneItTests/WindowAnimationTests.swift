import Foundation
import Testing

/// A window's open and close animations each run on a dispatch thread of their own, and for the
/// test host's offscreen windows they never end: every test window kept one or two of the
/// process's 64 worker threads for good. Once they were gone, nothing queued on a global queue
/// ran (a web view's load, a save), so a test hung until its time allowance, and Xcode killed
/// the host with the tests running beside it ("signal kill"). The scheme turns them off.
@Test func theSchemeTurnsWindowAnimationsOffInTheTestHost() throws {
    let key = "NSAutomaticWindowAnimationsEnabled"
    let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    try #require(arguments[key] != nil, "the scheme's test action passes -\(key) NO")
    #expect(!UserDefaults.standard.bool(forKey: key))
}
