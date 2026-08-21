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
        #expect(windowFrameValues(CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10)) == nil)
        #expect(windowFrameValues(CGRect(x: 0, y: CGFloat.infinity, width: 10, height: 10)) == nil)
        #expect(windowFrameValues(CGRect(x: CGFloat.greatestFiniteMagnitude,
                                        y: 0,
                                        width: CGFloat.greatestFiniteMagnitude,
                                        height: 10)) == nil)
        #expect(windowFrameValues(CGRect(x: 0,
                                        y: CGFloat.greatestFiniteMagnitude,
                                        width: 10,
                                        height: CGFloat.greatestFiniteMagnitude)) == nil)
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

    @Test func relativeMonitorIndexRejectsInvalidState() {
        #expect(relativeMonitorIndex(currentIndex: 0, offset: 1, count: 0) == nil)
        #expect(relativeMonitorIndex(currentIndex: -1, offset: 1, count: 3) == nil)
        #expect(relativeMonitorIndex(currentIndex: 3, offset: 1, count: 3) == nil)
    }
}
