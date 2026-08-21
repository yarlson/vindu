import Testing
@testable import VinduCore

struct BarZoneGeometryTests {
    @Test func centeredZoneFitsBetweenBalancedSides() {
        #expect(BarZoneGeometry.centerIsVisible(
            barWidth: 1200,
            horizontalPadding: 12,
            minimumGap: 12,
            leftWidth: 240,
            centerWidth: 120,
            rightWidth: 240,
            position: .top,
            topObstruction: nil
        ))
    }

    @Test func centeredZoneRemainsAtScreenCenterWithAsymmetricSides() {
        #expect(BarZoneGeometry.centerIsVisible(
            barWidth: 1200,
            horizontalPadding: 12,
            minimumGap: 12,
            leftWidth: 360,
            centerWidth: 120,
            rightWidth: 80,
            position: .top,
            topObstruction: nil
        ))
    }

    @Test func centeredZoneHidesWhenSideContentWouldOverlapIt() {
        #expect(!BarZoneGeometry.centerIsVisible(
            barWidth: 800,
            horizontalPadding: 12,
            minimumGap: 12,
            leftWidth: 350,
            centerWidth: 120,
            rightWidth: 80,
            position: .top,
            topObstruction: nil
        ))
    }

    @Test func centeredZoneHidesWhenTopNotchObstructsIt() {
        #expect(!BarZoneGeometry.centerIsVisible(
            barWidth: 1200,
            horizontalPadding: 12,
            minimumGap: 12,
            leftWidth: 200,
            centerWidth: 120,
            rightWidth: 200,
            position: .top,
            topObstruction: 560..<640
        ))
    }

    @Test func bottomBarIgnoresTopNotch() {
        #expect(BarZoneGeometry.centerIsVisible(
            barWidth: 1200,
            horizontalPadding: 12,
            minimumGap: 12,
            leftWidth: 200,
            centerWidth: 120,
            rightWidth: 200,
            position: .bottom,
            topObstruction: 560..<640
        ))
    }

    @Test func emptyCenteredZoneStaysHidden() {
        #expect(!BarZoneGeometry.centerIsVisible(
            barWidth: 1200,
            horizontalPadding: 12,
            minimumGap: 12,
            leftWidth: 200,
            centerWidth: 0,
            rightWidth: 200,
            position: .top,
            topObstruction: nil
        ))
    }
}
