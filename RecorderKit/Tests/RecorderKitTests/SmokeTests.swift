import Testing
@testable import RecorderKit

@Test func bundleExtensionIsStable() {
    #expect(RecorderKit.bundleExtension == "bsrec")
}
