import Testing
import CoreGraphics
@testable import VinduCore

struct WorkspaceRegistryTests {
    let container = CGRect(x: 0, y: 0, width: 1000, height: 600)

    func makeRegistry() -> WorkspaceRegistry {
        WorkspaceRegistry()
    }

    @Test func createOnceAndNotify() {
        let reg = makeRegistry()
        var created: [Int] = []
        reg.onCreate = { created.append($0.id) }
        let a = reg.workspace(forID: 3, monitor: 1)
        let b = reg.workspace(forID: 3, monitor: 2)
        #expect(a === b)
        #expect(a.monitor == 1)
        #expect(created == [3])
    }

    @Test func namedAndSpecialAllocation() {
        let reg = makeRegistry()
        let web = reg.resolveID(.name("web"), currentID: 1, previousID: nil, monitor: 0, create: true)
        #expect(web == -1338)
        #expect(reg.resolveID(.name("web"), currentID: 1, previousID: nil, monitor: 0, create: false) == web)
        #expect(reg.existing(web!)?.name == "web")

        let magic = reg.resolveID(.special("magic"), currentID: 1, previousID: nil, monitor: 0, create: true)
        #expect(magic == -100)
        #expect(reg.existing(magic!)?.name == "special:magic")
        #expect(reg.existing(magic!)?.isSpecial == true)
        #expect(reg.specialName(forID: magic!) == "magic")

        #expect(reg.resolveID(.name("nope"), currentID: 1, previousID: nil, monitor: 0, create: false) == nil)
    }

    @Test func relativeAndExistingTargets() {
        let reg = makeRegistry()
        for id in [1, 3, 7] {
            _ = reg.workspace(forID: id, monitor: 0)
        }
        #expect(reg.resolveID(.relative(1), currentID: 3, previousID: nil, monitor: 0, create: true) == 4)
        #expect(reg.resolveID(.relative(-5), currentID: 3, previousID: nil, monitor: 0, create: true) == 1)
        #expect(reg.resolveID(.relativeExisting(1), currentID: 3, previousID: nil, monitor: 0, create: false) == 7)
        #expect(reg.resolveID(.relativeExisting(1), currentID: 7, previousID: nil, monitor: 0, create: false) == 1)
        #expect(reg.resolveID(.previous, currentID: 3, previousID: 1, monitor: 0, create: false) == 1)
        #expect(reg.resolveID(.previous, currentID: 3, previousID: nil, monitor: 0, create: false) == nil)
    }

    @Test func emptyTargetSkipsOccupiedWorkspaces() {
        let reg = makeRegistry()
        let ws1 = reg.workspace(forID: 1, monitor: 0)
        ws1.insertTiled(42, near: nil, container: container,
                        dwindleSettings: DwindleSettings(), masterSettings: MasterSettings())
        #expect(reg.resolveID(.empty, currentID: 1, previousID: nil, monitor: 0, create: true) == 2)
    }

    @Test func destroyRules() {
        let reg = makeRegistry()
        var destroyed: [Int] = []
        reg.onDestroy = { destroyed.append($0.id) }

        let occupied = reg.workspace(forID: 1, monitor: 0)
        occupied.floating.append(9)
        #expect(!reg.destroyIfEmpty(occupied, isVisible: false, isBound: false))

        let visible = reg.workspace(forID: 2, monitor: 0)
        #expect(!reg.destroyIfEmpty(visible, isVisible: true, isBound: false))

        let bound = reg.workspace(forID: 3, monitor: 0)
        #expect(!reg.destroyIfEmpty(bound, isVisible: false, isBound: true))

        let specialID = reg.resolveID(.special("s"), currentID: 1, previousID: nil, monitor: 0, create: true)!
        #expect(!reg.destroyIfEmpty(reg.existing(specialID)!, isVisible: false, isBound: false))

        let plain = reg.workspace(forID: 4, monitor: 0)
        #expect(reg.destroyIfEmpty(plain, isVisible: false, isBound: false))
        #expect(reg.existing(4) == nil)
        #expect(destroyed == [4])

        // A destroyed named workspace frees its name for re-allocation.
        let namedID = reg.resolveID(.name("dev"), currentID: 1, previousID: nil, monitor: 0, create: true)!
        reg.destroyIfEmpty(reg.existing(namedID)!, isVisible: false, isBound: false)
        let reallocated = reg.resolveID(.name("dev"), currentID: 1, previousID: nil, monitor: 0, create: true)!
        #expect(reallocated != namedID)
    }
}

struct WorkspaceStateMembershipTests {
    let container = CGRect(x: 0, y: 0, width: 1000, height: 600)

    func makeWorkspace(tiled: [WindowID]) -> WorkspaceState {
        let ws = WorkspaceState(id: 1, name: "1", monitor: 0)
        for id in tiled {
            ws.insertTiled(id, near: nil, container: container,
                           dwindleSettings: DwindleSettings(), masterSettings: MasterSettings())
            _ = ws.dwindle.frames(in: container)
        }
        return ws
    }

    @Test func insertKeepsStructuresInLockstep() {
        let ws = makeWorkspace(tiled: [1, 2, 3])
        #expect(ws.master.windows == [1, 2, 3])
        #expect(ws.dwindle.windowsInOrder == [1, 2, 3])
        #expect(ws.tiled == [1, 2, 3])
    }

    @Test func swapTiledSyncsBothStructures() {
        let ws = makeWorkspace(tiled: [1, 2])
        ws.swapTiled(1, 2)
        #expect(ws.master.windows == [2, 1])
        #expect(ws.dwindle.windowsInOrder == [2, 1])
    }

    @Test func removeWindowClearsEverything() {
        let ws = makeWorkspace(tiled: [1, 2])
        ws.floating.append(5)
        ws.fullscreen = 1
        ws.lastFocused = 1
        ws.removeWindow(1)
        #expect(ws.master.windows == [2])
        #expect(ws.dwindle.windowsInOrder == [2])
        #expect(ws.fullscreen == nil)
        #expect(ws.lastFocused == nil)
        ws.removeWindow(5)
        #expect(ws.floating.isEmpty)
        #expect(ws.allWindows == [2])
    }

    @Test func removeTiledKeepsFloatingMembership() {
        let ws = makeWorkspace(tiled: [1])
        ws.removeTiled(1)
        ws.floating.append(1)
        #expect(ws.tiled.isEmpty)
        #expect(ws.allWindows == [1])
    }
}
