import CoreGraphics
import Testing
@testable import VinduCore

struct ScrollingLayoutTests {
    let container = CGRect(x: 100, y: 50, width: 900, height: 600)

    @Test func newWindowsBecomeColumnsAfterTheFocusedColumn() {
        let layout = ScrollingLayout()

        layout.insert(1, after: nil, defaultColumnWidth: 0.5)
        layout.insert(2, after: 1, defaultColumnWidth: 0.5)
        layout.insert(3, after: 1, defaultColumnWidth: 0.5)

        #expect(layout.columns.map(\.windows) == [[1], [3], [2]])
        #expect(layout.windowsInOrder == [1, 3, 2])
    }

    @Test func consumeAndExpelPreserveColumnOrder() {
        let layout = makeLayout([1, 2, 3])

        #expect(layout.consumeNextColumn(into: 1) == 2)
        #expect(layout.columns.map(\.windows) == [[1, 2], [3]])
        #expect(layout.expel(2))
        #expect(layout.columns.map(\.windows) == [[1], [2], [3]])
    }

    @Test func consumePullsOnlyTheRememberedWindowFromAStackedColumn() {
        let layout = makeLayout([1, 2, 3])
        _ = layout.consumeNextColumn(into: 2)
        layout.noteFocus(3)

        #expect(layout.consumeNextColumn(into: 1) == 3)
        #expect(layout.columns.map(\.windows) == [[1, 3], [2]])
    }

    @Test func consumePlacesTheRememberedWindowBelowTheFocusedWindow() {
        let layout = makeLayout([1, 2, 3, 4])
        _ = layout.consumeNextColumn(into: 1)
        _ = layout.consumeNextColumn(into: 2)

        #expect(layout.consumeNextColumn(into: 2) == 4)
        #expect(layout.columns.map(\.windows) == [[1, 2, 4, 3]])
    }

    @Test func directionalFocusUsesColumnsAndVerticalStacks() {
        let layout = makeLayout([1, 2, 3])
        _ = layout.consumeNextColumn(into: 1)
        layout.noteFocus(2)

        #expect(layout.focusTarget(from: 2, direction: .up) == 1)
        #expect(layout.focusTarget(from: 1, direction: .down) == 2)
        #expect(layout.focusTarget(from: 1, direction: .right) == 3)
        #expect(layout.focusTarget(from: 3, direction: .left) == 2)
    }

    @Test func horizontalMoveReordersColumnsAndVerticalMoveReordersWindows() {
        let layout = makeLayout([1, 2, 3])
        _ = layout.consumeNextColumn(into: 1)

        #expect(layout.move(2, direction: .up))
        #expect(layout.columns.map(\.windows) == [[2, 1], [3]])
        #expect(layout.move(2, direction: .right))
        #expect(layout.columns.map(\.windows) == [[3], [2, 1]])
    }

    @Test func directionalSwapExchangesWindowsWithoutMovingTheirColumns() {
        let layout = makeLayout([1, 2, 3])
        _ = layout.consumeNextColumn(into: 1)
        layout.noteFocus(2)

        #expect(layout.swap(3, direction: .left))
        #expect(layout.columns.map(\.windows) == [[1, 3], [2]])
        #expect(layout.swap(3, direction: .up))
        #expect(layout.columns.map(\.windows) == [[3, 1], [2]])
    }

    @Test func widthCycleAndFullWidthRestoreThePreviousPreset() {
        let layout = makeLayout([1])

        #expect(layout.cycleWidth(of: 1, previous: false))
        #expect(layout.columns[0].widthFraction == 2.0 / 3.0)
        #expect(layout.toggleFullWidth(of: 1))
        #expect(layout.columns[0].widthFraction == 1)
        #expect(layout.toggleFullWidth(of: 1))
        #expect(layout.columns[0].widthFraction == 2.0 / 3.0)
        #expect(layout.cycleWidth(of: 1, previous: true))
        #expect(layout.columns[0].widthFraction == 0.5)
    }

    @Test func widthCycleMovesFromACustomDefaultToTheNextPreset() {
        let layout = ScrollingLayout()
        layout.insert(1, after: nil, defaultColumnWidth: 0.4)

        #expect(layout.cycleWidth(of: 1, previous: false))
        #expect(layout.columns[0].widthFraction == 0.5)
        layout.rebuildSingletons(from: [1], defaultColumnWidth: 0.4)
        #expect(layout.cycleWidth(of: 1, previous: true))
        #expect(layout.columns[0].widthFraction == 1.0 / 3.0)
    }

    @Test func resizeChangesOnlyTheFocusedColumnWidth() {
        let layout = makeLayout([1, 2])

        #expect(layout.resizeColumn(containing: 1, by: 0.1))
        #expect(abs(layout.columns[0].widthFraction - 0.6) < 0.0001)
        #expect(layout.columns[1].widthFraction == 0.5)
    }

    @Test func verticalResizePreservesAColumnHeightSplit() {
        let layout = makeLayout([1, 2])
        _ = layout.consumeNextColumn(into: 1)

        #expect(layout.resizeWindow(1, by: 0.2))
        let frames = layout.frames(in: container)
        #expect(abs(frames[1]!.height - 420) < 0.01)
        #expect(abs(frames[2]!.height - 180) < 0.01)
    }

    @Test func framesUsePreservedColumnWidthsAndEqualVerticalStacks() {
        let layout = makeLayout([1, 2, 3])
        _ = layout.consumeNextColumn(into: 1)
        _ = layout.cycleWidth(of: 3, previous: false)

        let frames = layout.frames(in: container)

        #expect(frames[1] == CGRect(x: 100, y: 50, width: 450, height: 300))
        #expect(frames[2] == CGRect(x: 100, y: 350, width: 450, height: 300))
        #expect(frames[3] == CGRect(x: 550, y: 50, width: 600, height: 600))
    }

    @Test func revealMovesOnlyEnoughAndClampsToContent() {
        let layout = makeLayout([1, 2, 3])

        #expect(layout.reveal(3, in: container) == 450)
        #expect(layout.viewportOffset == 450)
        #expect(layout.scroll(by: 1000, in: container) == 0)
        #expect(layout.scroll(by: -1000, in: container) == -450)
        #expect(layout.viewportOffset == 0)
    }

    @Test func centerAndOversizedRevealHaveDeterministicAlignment() {
        let layout = makeLayout([1, 2])
        _ = layout.toggleFullWidth(of: 2)

        #expect(layout.center(2, in: container) == 450)
        #expect(layout.viewportOffset == 450)
        #expect(layout.reveal(2, in: container) == 0)
    }

    @Test func rebuildCreatesSingletonsAndRemoveDropsEmptyColumns() {
        let layout = ScrollingLayout()
        layout.rebuildSingletons(from: [4, 5, 6], defaultColumnWidth: 0.5)
        #expect(layout.columns.map(\.windows) == [[4], [5], [6]])

        _ = layout.scroll(by: 1000, in: container)
        layout.remove(6)
        _ = layout.frames(in: container)
        #expect(layout.columns.map(\.windows) == [[4], [5]])
        #expect(layout.viewportOffset == 0)
    }

    private func makeLayout(_ windows: [WindowID]) -> ScrollingLayout {
        let layout = ScrollingLayout()
        for window in windows {
            layout.insert(window, after: windows.firstIndex(of: window).flatMap { $0 == 0 ? nil : windows[$0 - 1] },
                          defaultColumnWidth: 0.5)
        }
        return layout
    }
}
