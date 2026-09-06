import Testing
@testable import vindud

struct ScrollingGestureTests {
    @Test func locksToHorizontalAfterSixPointsAndIncludesPendingDelta() {
        var gesture = ScrollingGestureSession(monitorID: 1, workspaceID: 2)

        #expect(gesture.update(deltaX: 3, deltaY: 1) == .pending)
        #expect(gesture.update(deltaX: 4, deltaY: 1) == .horizontal(7))
        #expect(gesture.update(deltaX: 2, deltaY: 20) == .horizontal(2))
    }

    @Test func verticalGestureSwitchesOnlyOnceAtEightyPoints() {
        var gesture = ScrollingGestureSession(monitorID: 1, workspaceID: 2)

        #expect(gesture.update(deltaX: 0, deltaY: 40) == .pending)
        #expect(gesture.update(deltaX: 0, deltaY: 39) == .pending)
        #expect(gesture.update(deltaX: 0, deltaY: 1) == .workspace(-1))
        #expect(gesture.update(deltaX: 0, deltaY: 100) == .consumed)
    }

    @Test func dominantAxisIsLockedForTheWholeGesture() {
        var gesture = ScrollingGestureSession(monitorID: 1, workspaceID: 2)

        #expect(gesture.update(deltaX: 2, deltaY: -5) == .pending)
        #expect(gesture.update(deltaX: 1, deltaY: -2) == .pending)
        #expect(gesture.update(deltaX: 100, deltaY: -74) == .workspace(1))
    }

    @Test func cubicEaseOutHasStableEndpoints() {
        #expect(cubicEaseOut(0) == 0)
        #expect(cubicEaseOut(1) == 1)
        #expect(abs(cubicEaseOut(0.5) - 0.875) < 0.0001)
    }
}
