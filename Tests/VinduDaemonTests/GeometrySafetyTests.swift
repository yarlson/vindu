import CoreGraphics
import Testing
@testable import vindud

struct GeometrySafetyTests {
    @Test func checkedGeometryIntegerRejectsUnsafeValues() {
        #expect(checkedGeometryInt(.nan) == nil)
        #expect(checkedGeometryInt(.infinity) == nil)
        #expect(checkedGeometryInt(-.infinity) == nil)
        #expect(checkedGeometryInt(.greatestFiniteMagnitude) == nil)
        #expect(checkedGeometryInt(-.greatestFiniteMagnitude) == nil)
    }

    @Test func checkedGeometryIntegerTruncatesFiniteFractionsTowardZero() {
        #expect(checkedGeometryInt(12.9) == 12)
        #expect(checkedGeometryInt(-12.9) == -12)
    }

    @Test func windowFrameValuesAcceptsValidGeometry() throws {
        let values = try #require(windowFrameValues(
            CGRect(x: -12.9, y: 4.8, width: 800.7, height: 600.2)
        ))

        #expect(values.x == -12)
        #expect(values.y == 4)
        #expect(values.width == 800)
        #expect(values.height == 600)
    }

    @Test func windowFrameValuesRejectsInvalidGeometry() {
        #expect(windowFrameValues(CGRect(x: 0, y: 0, width: 0, height: 10)) == nil)
        #expect(windowFrameValues(CGRect(x: 0, y: 0, width: -1, height: 10)) == nil)
        #expect(windowFrameValues(CGRect(x: 0, y: 0, width: 10, height: -1)) == nil)
        #expect(windowFrameValues(CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10)) == nil)
        #expect(windowFrameValues(CGRect(x: 0, y: CGFloat.infinity, width: 10, height: 10)) == nil)
        let representableComponent = CGFloat(5.0e18)
        #expect(checkedGeometryInt(representableComponent) != nil)
        #expect(windowFrameValues(CGRect(x: representableComponent,
                                        y: 0,
                                        width: representableComponent,
                                        height: 10)) == nil)
        #expect(windowFrameValues(CGRect(x: 0,
                                        y: representableComponent,
                                        width: 10,
                                        height: representableComponent)) == nil)
    }

    @Test func windowPointValidationRejectsEitherInvalidCoordinate() {
        #expect(isValidWindowPoint(CGPoint(x: 10, y: -20)))
        #expect(!isValidWindowPoint(CGPoint(x: CGFloat.nan, y: 0)))
        #expect(!isValidWindowPoint(CGPoint(x: 0, y: CGFloat.infinity)))
        #expect(!isValidWindowPoint(CGPoint(x: CGFloat.greatestFiniteMagnitude, y: 0)))
    }

    @Test func relativeMonitorIndexWrapsExtremeOffsets() {
        #expect(relativeMonitorIndex(currentIndex: 0, offset: -1, count: 3) == 2)
        #expect(relativeMonitorIndex(currentIndex: 2, offset: 1, count: 3) == 0)
        #expect(relativeMonitorIndex(currentIndex: 1, offset: Int.min, count: 3) == 2)
        #expect(relativeMonitorIndex(currentIndex: 1, offset: Int.max, count: 3) == 2)
    }

    @Test func relativeMonitorIndexRejectsInvalidCountOrCurrentIndex() {
        #expect(relativeMonitorIndex(currentIndex: 0, offset: 1, count: 0) == nil)
        #expect(relativeMonitorIndex(currentIndex: -1, offset: 1, count: 3) == nil)
        #expect(relativeMonitorIndex(currentIndex: 3, offset: 1, count: 3) == nil)
    }

    @Test func monitorWorkspaceSelectionNeverDuplicatesVisibleWorkspace() {
        #expect(nextAvailableWorkspaceID(preferred: 2, activeIDs: [2]) == 1)
        #expect(nextAvailableWorkspaceID(preferred: 2, activeIDs: [1]) == 2)
        #expect(nextAvailableWorkspaceID(preferred: 0, activeIDs: [1, 2]) == 3)
    }

    @Test func removedMonitorsIdentifyWorkspacesThatNeedStashing() {
        let removed = workspaceIDsVisibleOnlyOnRemovedMonitors(
            activeWorkspaces: [10: 1, 20: 2],
            specialWorkspaces: [20: -100],
            aliveMonitors: [10]
        )

        #expect(removed == [2, -100])
    }

    @Test func explicitStateActionsAreIdempotent() {
        #expect(requestedStateChange(.on, current: false) == true)
        #expect(requestedStateChange(.on, current: true) == nil)
        #expect(requestedStateChange(.off, current: true) == false)
        #expect(requestedStateChange(.off, current: false) == nil)
        #expect(requestedStateChange(.toggle, current: true) == false)
        #expect(requestedStateChange(.toggle, current: false) == true)
    }
}
