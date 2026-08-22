import ApplicationServices
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

    @Test func accessibilityGeometryErrorsPreserveRetryMeaning() {
        #expect(windowGeometryAccessError(from: .success) == nil)
        #expect(windowGeometryAccessError(from: .invalidUIElement) == .elementUnavailable)
        #expect(windowGeometryAccessError(from: .attributeUnsupported) == .attributeUnsupported)
        #expect(windowGeometryAccessError(from: .notImplemented) == .attributeUnsupported)
        #expect(windowGeometryAccessError(from: .cannotComplete) == .cannotComplete)
        #expect(windowGeometryAccessError(from: .failure)
            == .apiFailure(Int32(AXError.failure.rawValue)))
    }
}
