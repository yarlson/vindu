import Testing
import VinduCore
@testable import vindud

struct ScrollingAvailabilityTests {
    @Test func specialWorkspacesAlwaysUseDwindle() {
        #expect(resolvedLayoutKind(configured: .scrolling, specialWorkspace: true,
                                   monitorCount: 1, screensHaveSeparateSpaces: true) == .dwindle)
    }

    @Test func scrollingFallsBackWithMultipleDisplaysAndSharedSpaces() {
        #expect(resolvedLayoutKind(configured: .scrolling, specialWorkspace: false,
                                   monitorCount: 2, screensHaveSeparateSpaces: false) == .dwindle)
        #expect(resolvedLayoutKind(configured: .scrolling, specialWorkspace: false,
                                   monitorCount: 2, screensHaveSeparateSpaces: true) == .scrolling)
    }

    @Test func oneDisplayDoesNotRequireSeparateSpaces() {
        #expect(resolvedLayoutKind(configured: .scrolling, specialWorkspace: false,
                                   monitorCount: 1, screensHaveSeparateSpaces: false) == .scrolling)
        #expect(resolvedLayoutKind(configured: .master, specialWorkspace: false,
                                   monitorCount: 2, screensHaveSeparateSpaces: false) == .master)
    }
}
