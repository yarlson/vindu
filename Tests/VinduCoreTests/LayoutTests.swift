import Testing
import CoreGraphics
@testable import VinduCore

struct DwindleTests {
    let container = CGRect(x: 0, y: 0, width: 1000, height: 600)
    let settings = DwindleSettings()

    @Test func insertSplitsByAspect() {
        let tree = DwindleTree()
        tree.insert(1, near: nil, container: container, settings: settings)
        #expect(tree.frames(in: container)[1] == container)

        // Wide leaf → horizontal (side-by-side) split.
        tree.insert(2, near: 1, container: container, settings: settings)
        var f = tree.frames(in: container)
        #expect(f[1] == CGRect(x: 0, y: 0, width: 500, height: 600))
        #expect(f[2] == CGRect(x: 500, y: 0, width: 500, height: 600))

        // Leaf 2 is 500x600 (tall) → vertical split.
        tree.insert(3, near: 2, container: container, settings: settings)
        f = tree.frames(in: container)
        #expect(f[1] == CGRect(x: 0, y: 0, width: 500, height: 600))
        #expect(f[2] == CGRect(x: 500, y: 0, width: 500, height: 300))
        #expect(f[3] == CGRect(x: 500, y: 300, width: 500, height: 300))
        #expect(tree.windowsInOrder == [1, 2, 3])
    }

    @Test func removePromotesSibling() {
        let tree = DwindleTree()
        for w: WindowID in [1, 2, 3] {
            tree.insert(w, near: w == 1 ? nil : w - 1, container: container, settings: settings)
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
        tree.insert(1, near: nil, container: container, settings: settings)
        _ = tree.frames(in: container)
        tree.insert(2, near: 1, container: container, settings: settings)
        tree.swap(1, 2)
        let f = tree.frames(in: container)
        #expect(f[2]?.minX == 0)
        #expect(f[1]?.minX == 500)
    }

    @Test func toggleSplitAndRatio() {
        let tree = DwindleTree()
        tree.insert(1, near: nil, container: container, settings: settings)
        _ = tree.frames(in: container)
        tree.insert(2, near: 1, container: container, settings: settings)

        tree.toggleSplit(at: 1)
        var f = tree.frames(in: container)
        #expect(f[1] == CGRect(x: 0, y: 0, width: 1000, height: 300))
        #expect(f[2] == CGRect(x: 0, y: 300, width: 1000, height: 300))

        // splitratio uses Hyprland's 0.1–1.9 scale; exact 1.2 → 60%.
        tree.setRatio(.exact(1.2), at: 1)
        f = tree.frames(in: container)
        #expect(abs(f[1]!.height - 360) < 0.01)
    }

    @Test func resizeAdjustsNearestSplit() {
        let tree = DwindleTree()
        tree.insert(1, near: nil, container: container, settings: settings)
        _ = tree.frames(in: container)
        tree.insert(2, near: 1, container: container, settings: settings)
        _ = tree.frames(in: container)

        tree.resize(1, dx: 100, dy: 0)
        let f = tree.frames(in: container)
        #expect(abs(f[1]!.width - 600) < 0.01)
        #expect(abs(f[2]!.width - 400) < 0.01)
    }

    @Test func rebuildFromOrder() {
        let tree = DwindleTree()
        tree.rebuild(from: [5, 6, 7], container: container, settings: settings)
        #expect(tree.count == 3)
        #expect(tree.windowsInOrder == [5, 6, 7])
        let f = tree.frames(in: container)
        #expect(f[5] == CGRect(x: 0, y: 0, width: 500, height: 600))
    }

    @Test func defaultSplitRatioApplied() {
        var s = DwindleSettings()
        s.defaultSplitRatio = 1.2
        let tree = DwindleTree()
        tree.insert(1, near: nil, container: container, settings: s)
        _ = tree.frames(in: container)
        tree.insert(2, near: 1, container: container, settings: s)
        let f = tree.frames(in: container)
        #expect(abs(f[1]!.width - 600) < 0.01)
    }
}

struct MasterTests {
    let rect = CGRect(x: 0, y: 0, width: 1000, height: 600)
    let settings = MasterSettings() // mfact 0.55, left, slave, not on top

    func makeLayout(_ ids: [WindowID]) -> MasterLayout {
        let l = MasterLayout()
        for id in ids { l.insert(id, settings: settings) }
        return l
    }

    @Test func leftOrientation() {
        let l = makeLayout([1, 2, 3])
        let f = l.frames(in: rect, settings: settings)
        #expect(f[1] == CGRect(x: 0, y: 0, width: 550, height: 600))
        #expect(f[2] == CGRect(x: 550, y: 0, width: 450, height: 300))
        #expect(f[3] == CGRect(x: 550, y: 300, width: 450, height: 300))
    }

    @Test func singleWindowFillsRect() {
        let l = makeLayout([1])
        #expect(l.frames(in: rect, settings: settings)[1] == rect)
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
        let f = l.frames(in: rect, settings: settings)
        #expect(f[1] == CGRect(x: 0, y: 0, width: 550, height: 300))
        #expect(f[2] == CGRect(x: 0, y: 300, width: 550, height: 300))
        #expect(f[3] == CGRect(x: 550, y: 0, width: 450, height: 600))
        l.removeMaster()
        #expect(l.masterCount == 1)
    }

    @Test func newStatusMasterInsertsFirst() {
        var s = MasterSettings()
        s.newStatus = "master"
        let l = MasterLayout()
        l.insert(1, settings: s)
        l.insert(2, settings: s)
        #expect(l.windows == [2, 1])
    }

    @Test func mfactAndCycle() {
        let l = makeLayout([1, 2])
        l.setMfact(.exact(0.7), settings: settings)
        let f = l.frames(in: rect, settings: settings)
        #expect(abs(f[1]!.width - 700) < 0.01)
        #expect(l.cycle(from: 2, prev: false) == 1)
        #expect(l.cycle(from: 1, prev: true) == 2)
    }

    @Test func centerOrientation() {
        let l = makeLayout([1, 2, 3])
        l.setOrientation(.center)
        let f = l.frames(in: rect, settings: settings)
        // Master centered; slave 2 right, slave 3 left.
        #expect(abs(f[1]!.width - 550) < 0.01)
        #expect(abs(f[3]!.minX - 0) < 0.01)
        #expect(abs(f[2]!.maxX - 1000) < 0.01)
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
        // Visual gap between tiles is 2 × gapsIn, edges get gapsOut — Hyprland semantics.
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
        var settings = BarSettings()
        settings.enabled = false

        #expect(BarGeometry.contentRect(displayFrame: display, usable: usable,
                                        settings: settings) == usable)
    }

    @Test func topBarUsesPhysicalDisplayTopWithoutReservingHiddenMenuStrip() {
        var settings = BarSettings()
        settings.enabled = true
        settings.position = .top
        settings.height = 0

        #expect(BarGeometry.barRect(displayFrame: display, usable: usable,
                                    settings: settings)
                == CGRect(x: 100, y: 0, width: 1200, height: 50))
        #expect(BarGeometry.contentRect(displayFrame: display, usable: usable,
                                        settings: settings) == usable)
    }

    @Test func autoTopBarFallsBackWhenThereIsNoTopStrip() {
        var settings = BarSettings()
        settings.enabled = true
        settings.position = .top
        settings.height = 0
        let full = CGRect(x: 100, y: 0, width: 1200, height: 900)

        #expect(BarGeometry.barRect(displayFrame: full, usable: full,
                                    settings: settings).height == 28)
    }

    @Test func topBarReservesOnlyThePartOverlappingUsableRect() {
        var settings = BarSettings()
        settings.enabled = true
        settings.position = .top
        settings.height = 60

        #expect(BarGeometry.barRect(displayFrame: display, usable: usable,
                                    settings: settings)
                == CGRect(x: 100, y: 0, width: 1200, height: 60))
        #expect(BarGeometry.contentRect(displayFrame: display, usable: usable,
                                        settings: settings)
                == CGRect(x: 100, y: 60, width: 1200, height: 790))
    }

    @Test func bottomBarReservesFromBottomOfUsableRect() {
        var settings = BarSettings()
        settings.enabled = true
        settings.position = .bottom
        settings.height = 32

        #expect(BarGeometry.barRect(displayFrame: display, usable: usable,
                                    settings: settings)
                == CGRect(x: 100, y: 818, width: 1200, height: 32))
        #expect(BarGeometry.contentRect(displayFrame: display, usable: usable,
                                        settings: settings)
                == CGRect(x: 100, y: 50, width: 1200, height: 768))
    }

    @Test func oversizedTopBarCanConsumeUsableArea() {
        var settings = BarSettings()
        settings.enabled = true
        settings.height = 900

        #expect(BarGeometry.barRect(displayFrame: display, usable: usable,
                                    settings: settings).height == 899)
        #expect(BarGeometry.contentRect(displayFrame: display, usable: usable,
                                        settings: settings).height == 0)
    }
}
