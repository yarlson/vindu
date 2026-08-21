import Testing
import CoreGraphics
@testable import VinduCore

struct DwindleTests {
    let container = CGRect(x: 0, y: 0, width: 1000, height: 600)
    let configuration = DwindleConfiguration(newWindowFraction: 0.5,
                                              newWindowPosition: .after)

    @Test func insertSplitsByAspect() {
        let tree = DwindleTree()
        tree.insert(1, near: nil, container: container, configuration: configuration)
        #expect(tree.frames(in: container)[1] == container)

        // Wide leaf → horizontal (side-by-side) split.
        tree.insert(2, near: 1, container: container, configuration: configuration)
        var f = tree.frames(in: container)
        #expect(f[1] == CGRect(x: 0, y: 0, width: 500, height: 600))
        #expect(f[2] == CGRect(x: 500, y: 0, width: 500, height: 600))

        // Leaf 2 is 500x600 (tall) → vertical split.
        tree.insert(3, near: 2, container: container, configuration: configuration)
        f = tree.frames(in: container)
        #expect(f[1] == CGRect(x: 0, y: 0, width: 500, height: 600))
        #expect(f[2] == CGRect(x: 500, y: 0, width: 500, height: 300))
        #expect(f[3] == CGRect(x: 500, y: 300, width: 500, height: 300))
        #expect(tree.windowsInOrder == [1, 2, 3])
    }

    @Test func removePromotesSibling() {
        let tree = DwindleTree()
        for w: WindowID in [1, 2, 3] {
            tree.insert(w, near: w == 1 ? nil : w - 1, container: container, configuration: configuration)
            _ = tree.frames(in: container)
        }
        tree.remove(2)
        let f = tree.frames(in: container)
        #expect(f.count == 2)
        #expect(f[1] == CGRect(x: 0, y: 0, width: 500, height: 600))
        #expect(f[3] == CGRect(x: 500, y: 0, width: 500, height: 600))

        tree.remove(1)
        #expect(tree.frames(in: container)[3] == container)
        tree.remove(3)
        #expect(tree.isEmpty)
    }

    @Test func swapExchangesWindows() {
        let tree = DwindleTree()
        tree.insert(1, near: nil, container: container, configuration: configuration)
        _ = tree.frames(in: container)
        tree.insert(2, near: 1, container: container, configuration: configuration)
        tree.swap(1, 2)
        let f = tree.frames(in: container)
        #expect(f[2]?.minX == 0)
        #expect(f[1]?.minX == 500)
    }

    @Test func toggleSplitAndRatio() {
        let tree = DwindleTree()
        tree.insert(1, near: nil, container: container, configuration: configuration)
        _ = tree.frames(in: container)
        tree.insert(2, near: 1, container: container, configuration: configuration)

        tree.toggleSplit(at: 1)
        var f = tree.frames(in: container)
        #expect(f[1] == CGRect(x: 0, y: 0, width: 1000, height: 300))
        #expect(f[2] == CGRect(x: 0, y: 300, width: 1000, height: 300))

        // The public splitratio command uses 1.0 for an even split; exact 1.2 gives 60%.
        tree.setRatio(.exact(1.2), at: 1)
        f = tree.frames(in: container)
        #expect(abs(f[1]!.height - 360) < 0.01)
    }

    @Test func setSplitOrientationDoesNotDependOnCurrentOrientation() {
        let tree = DwindleTree()
        tree.insert(1, near: nil, container: container, configuration: configuration)
        _ = tree.frames(in: container)
        tree.insert(2, near: 1, container: container, configuration: configuration)

        tree.setSplitOrientation(.vertical, at: 1)
        tree.setSplitOrientation(.vertical, at: 1)
        var frames = tree.frames(in: container)
        #expect(frames[1] == CGRect(x: 0, y: 0, width: 1000, height: 300))

        tree.setSplitOrientation(.horizontal, at: 1)
        frames = tree.frames(in: container)
        #expect(frames[1] == CGRect(x: 0, y: 0, width: 500, height: 600))
    }

    @Test func resizeAdjustsNearestSplit() {
        let tree = DwindleTree()
        tree.insert(1, near: nil, container: container, configuration: configuration)
        _ = tree.frames(in: container)
        tree.insert(2, near: 1, container: container, configuration: configuration)
        _ = tree.frames(in: container)

        tree.resize(1, dx: 100, dy: 0)
        let f = tree.frames(in: container)
        #expect(abs(f[1]!.width - 600) < 0.01)
        #expect(abs(f[2]!.width - 400) < 0.01)
    }

    @Test func rebuildFromOrder() {
        let tree = DwindleTree()
        tree.rebuild(from: [5, 6, 7], container: container, configuration: configuration)
        #expect(tree.count == 3)
        #expect(tree.windowsInOrder == [5, 6, 7])
        let f = tree.frames(in: container)
        #expect(f[5] == CGRect(x: 0, y: 0, width: 500, height: 600))
    }

    @Test func deeplySkewedTreeTraversesFramesAndRebuildsIteratively() {
        let tree = DwindleTree()
        let count: WindowID = 10_000
        for window in 1...count {
            tree.insert(window, near: window == 1 ? nil : window - 1,
                        container: container, configuration: configuration)
        }

        #expect(tree.windowsInOrder == Array(1...count))
        #expect(tree.frames(in: container).count == Int(count))
        tree.rebuild(from: [], container: container, configuration: configuration)
        #expect(tree.isEmpty)
        #expect(tree.count == 0)
    }

    @Test func nativeBeforePlacesNewLeafFirstWithItsConfiguredFraction() {
        let configuration = DwindleConfiguration(newWindowFraction: 0.3,
                                                 newWindowPosition: .before)
        let tree = DwindleTree()
        tree.insert(1, near: nil, container: container, configuration: configuration)
        _ = tree.frames(in: container)
        tree.insert(2, near: 1, container: container, configuration: configuration)

        let frames = tree.frames(in: container)
        #expect(tree.windowsInOrder == [2, 1])
        #expect(frames[2] == CGRect(x: 0, y: 0, width: 300, height: 600))
        #expect(frames[1] == CGRect(x: 300, y: 0, width: 700, height: 600))
    }

    @Test func nativeAfterKeepsOldLeafFirstWithTheRemainingFraction() {
        let configuration = DwindleConfiguration(newWindowFraction: 0.3,
                                                 newWindowPosition: .after)
        let tree = DwindleTree()
        tree.insert(1, near: nil, container: container, configuration: configuration)
        _ = tree.frames(in: container)
        tree.insert(2, near: 1, container: container, configuration: configuration)

        let frames = tree.frames(in: container)
        #expect(tree.windowsInOrder == [1, 2])
        #expect(frames[1] == CGRect(x: 0, y: 0, width: 700, height: 600))
        #expect(frames[2] == CGRect(x: 700, y: 0, width: 300, height: 600))
    }
}

struct MasterTests {
    let rect = CGRect(x: 0, y: 0, width: 1000, height: 600)
    let configuration = MasterConfiguration(primaryFraction: 0.55,
                                            primaryPosition: .left,
                                            newWindowPosition: .stackEnd)

    func makeLayout(_ ids: [WindowID]) -> MasterLayout {
        let l = MasterLayout()
        for id in ids { l.insert(id, configuration: configuration) }
        return l
    }

    @Test func leftOrientation() {
        let l = makeLayout([1, 2, 3])
        let f = l.frames(in: rect, configuration: configuration)
        #expect(f[1] == CGRect(x: 0, y: 0, width: 550, height: 600))
        #expect(f[2] == CGRect(x: 550, y: 0, width: 450, height: 300))
        #expect(f[3] == CGRect(x: 550, y: 300, width: 450, height: 300))
    }

    @Test func singleWindowFillsRect() {
        let l = makeLayout([1])
        #expect(l.frames(in: rect, configuration: configuration)[1] == rect)
    }

    @Test func swapWithMaster() {
        let l = makeLayout([1, 2, 3])
        l.swapWithMaster(3, mode: "auto")
        #expect(l.windows == [3, 2, 1])
        // Focused master swaps with first slave.
        l.swapWithMaster(3, mode: "auto")
        #expect(l.windows == [2, 3, 1])
    }

    @Test func addRemoveMaster() {
        let l = makeLayout([1, 2, 3])
        l.addMaster()
        #expect(l.masterCount == 2)
        let f = l.frames(in: rect, configuration: configuration)
        #expect(f[1] == CGRect(x: 0, y: 0, width: 550, height: 300))
        #expect(f[2] == CGRect(x: 0, y: 300, width: 550, height: 300))
        #expect(f[3] == CGRect(x: 550, y: 0, width: 450, height: 600))
        l.removeMaster()
        #expect(l.masterCount == 1)
    }

    @Test func primaryFractionAndCycle() {
        let l = makeLayout([1, 2])
        l.setPrimaryFraction(.exact(0.7), configuration: configuration)
        let f = l.frames(in: rect, configuration: configuration)
        #expect(abs(f[1]!.width - 700) < 0.01)
        #expect(l.cycle(from: 2, prev: false) == 1)
        #expect(l.cycle(from: 1, prev: true) == 2)
    }

    @Test func centerOrientation() {
        let l = makeLayout([1, 2, 3])
        l.setOrientation(.center)
        let f = l.frames(in: rect, configuration: configuration)
        // Master centered; slave 2 right, slave 3 left.
        #expect(abs(f[1]!.width - 550) < 0.01)
        #expect(abs(f[3]!.minX - 0) < 0.01)
        #expect(abs(f[2]!.maxX - 1000) < 0.01)
    }

    @Test func nativeNewWindowPositionsControlMasterOrder() {
        func order(_ position: MasterConfiguration.NewWindowPosition) -> [WindowID] {
            let configuration = MasterConfiguration(primaryFraction: 0.55,
                                                    primaryPosition: .left,
                                                    newWindowPosition: position)
            let layout = MasterLayout()
            for id: WindowID in [1, 2, 3] {
                layout.insert(id, configuration: configuration)
            }
            return layout.windows
        }

        #expect(order(.primary) == [3, 2, 1])
        #expect(order(.stackStart) == [1, 3, 2])
        #expect(order(.stackEnd) == [1, 2, 3])
    }

    @Test func nativeFallbacksChangeWithoutReplacingRuntimeOverrides() {
        let initial = MasterConfiguration(primaryFraction: 0.65,
                                          primaryPosition: .right,
                                          newWindowPosition: .stackEnd)
        let changed = MasterConfiguration(primaryFraction: 0.4,
                                          primaryPosition: .top,
                                          newWindowPosition: .stackEnd)
        let layout = MasterLayout()
        layout.insert(1, configuration: initial)
        layout.insert(2, configuration: initial)
        layout.insert(3, configuration: initial)

        var frames = layout.frames(in: rect, configuration: initial)
        #expect(frames[1] == CGRect(x: 350, y: 0, width: 650, height: 600))

        frames = layout.frames(in: rect, configuration: changed)
        #expect(frames[1] == CGRect(x: 0, y: 0, width: 1000, height: 240))

        layout.setPrimaryFraction(.exact(0.75), configuration: changed)
        layout.setOrientation(.center)
        frames = layout.frames(in: rect, configuration: initial)
        #expect(frames[1]?.width == 750)
        #expect(frames[1]?.minX == 125)
    }

    @Test func orientationCycleStartsFromTheConfiguredFallback() {
        let configuration = MasterConfiguration(primaryFraction: 0.55,
                                                primaryPosition: .top,
                                                newWindowPosition: .stackEnd)
        let layout = MasterLayout()
        layout.cycleOrientation(prev: false, configuration: configuration)
        #expect(layout.orientationOverride == .right)
    }
}

struct LayoutMathTests {
    @Test func gapsEdgeVsInterior() {
        let container = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let left = LayoutMath.applyGaps(to: CGRect(x: 0, y: 0, width: 500, height: 600),
                                        within: container, gapsIn: 5, gapsOut: 10)
        let right = LayoutMath.applyGaps(to: CGRect(x: 500, y: 0, width: 500, height: 600),
                                         within: container, gapsIn: 5, gapsOut: 10)
        #expect(left == CGRect(x: 10, y: 10, width: 485, height: 580))
        #expect(right == CGRect(x: 505, y: 10, width: 485, height: 580))
        // Adjacent tiles each contribute an inner gap; outer edges use the outer gap.
        #expect(right.minX - left.maxX == 10)
    }

    @Test func neighborSelection() {
        let source = CGRect(x: 0, y: 0, width: 500, height: 600)
        let candidates: [(id: WindowID, rect: CGRect)] = [
            (2, CGRect(x: 500, y: 0, width: 500, height: 300)),
            (3, CGRect(x: 500, y: 300, width: 500, height: 300)),
        ]
        #expect(LayoutMath.neighbor(of: source, in: .right, candidates: candidates) == 2)
        #expect(LayoutMath.neighbor(of: source, in: .left, candidates: candidates) == nil)
        // Top-left origin: down = larger y.
        #expect(LayoutMath.neighbor(of: candidates[0].rect, in: .down,
                                    candidates: [(3, candidates[1].rect)]) == 3)
    }

    @Test func stackRectsEvenSplit() {
        let rects = LayoutMath.stackRects(CGRect(x: 0, y: 0, width: 300, height: 900), count: 3, vertical: true)
        #expect(rects.count == 3)
        #expect(rects[1] == CGRect(x: 0, y: 300, width: 300, height: 300))
    }
}

struct BarGeometryTests {
    let display = CGRect(x: 100, y: 0, width: 1200, height: 900)
    let usable = CGRect(x: 100, y: 50, width: 1200, height: 800)

    @Test func disabledBarDoesNotReserveSpace() {
        #expect(BarGeometry.contentRect(displayFrame: display, usable: usable,
                                        configuration: bar(enabled: false)) == usable)
    }

    @Test func topBarUsesPhysicalDisplayTopWithoutReservingHiddenMenuStrip() {
        let configuration = bar(position: .top, height: .automatic)

        #expect(BarGeometry.barRect(displayFrame: display, usable: usable,
                                    configuration: configuration)
                == CGRect(x: 100, y: 0, width: 1200, height: 50))
        #expect(BarGeometry.contentRect(displayFrame: display, usable: usable,
                                        configuration: configuration) == usable)
    }

    @Test func autoTopBarFallsBackWhenThereIsNoTopStrip() {
        let full = CGRect(x: 100, y: 0, width: 1200, height: 900)

        #expect(BarGeometry.barRect(displayFrame: full, usable: full,
                                    configuration: bar(position: .top,
                                                       height: .automatic)).height == 28)
    }

    @Test func topBarReservesOnlyThePartOverlappingUsableRect() {
        let configuration = bar(position: .top, height: .points(60))

        #expect(BarGeometry.barRect(displayFrame: display, usable: usable,
                                    configuration: configuration)
                == CGRect(x: 100, y: 0, width: 1200, height: 60))
        #expect(BarGeometry.contentRect(displayFrame: display, usable: usable,
                                        configuration: configuration)
                == CGRect(x: 100, y: 60, width: 1200, height: 790))
    }

    @Test func bottomBarReservesFromBottomOfUsableRect() {
        let configuration = bar(position: .bottom, height: .points(32))

        #expect(BarGeometry.barRect(displayFrame: display, usable: usable,
                                    configuration: configuration)
                == CGRect(x: 100, y: 818, width: 1200, height: 32))
        #expect(BarGeometry.contentRect(displayFrame: display, usable: usable,
                                        configuration: configuration)
                == CGRect(x: 100, y: 50, width: 1200, height: 768))
    }

    @Test func oversizedTopBarCanConsumeUsableArea() {
        let configuration = bar(height: .points(900))

        #expect(BarGeometry.barRect(displayFrame: display, usable: usable,
                                    configuration: configuration).height == 899)
        #expect(BarGeometry.contentRect(displayFrame: display, usable: usable,
                                        configuration: configuration).height == 0)
    }

    private func bar(enabled: Bool = true,
                     position: BarPosition = .top,
                     height: BarHeight = .automatic) -> NativeBarConfiguration {
        let color = ConfigurationColor(red: 0, green: 0, blue: 0, alpha: 1)
        return NativeBarConfiguration(
            enabled: enabled,
            position: position,
            height: height,
            left: [],
            center: [],
            right: [],
            colors: NativeBarColors(background: color, foreground: color,
                                    inactive: color, active: color),
            weather: nil,
            plugins: [:]
        )
    }
}
