import Darwin
import Testing
@testable import vindud

struct AXBridgeLifecycleTests {
    @Test func frontmostRegisteredAppRefreshesSystemFocus() {
        #expect(shouldRefreshSystemFocus(registeredPID: 42, frontmostPID: 42))
    }

    @Test func backgroundRegisteredAppDoesNotRefreshSystemFocus() {
        #expect(!shouldRefreshSystemFocus(registeredPID: 42, frontmostPID: 43))
    }

    @Test func missingFrontmostAppDoesNotRefreshSystemFocus() {
        #expect(!shouldRefreshSystemFocus(registeredPID: 42, frontmostPID: nil))
    }
}
