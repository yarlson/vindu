import CoreGraphics
import Testing
import VinduCore
@testable import vindud

struct WorkspaceTransitionTests {
    private static let main = Monitor(id: 1, index: 0, name: "Main",
                                      frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                      usable: CGRect(x: 0, y: 25, width: 1920, height: 1055),
                                      scale: 2, topObstruction: nil)
    private static let second = Monitor(id: 2, index: 1, name: "Second",
                                        frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
                                        usable: CGRect(x: 1920, y: 25, width: 1920, height: 1055),
                                        scale: 2, topObstruction: nil)

    @Test @MainActor func switchingWorkspaceStashesTheOldWindowsAndRecordsThePrevious() throws {
        let backend = GeometryBackendStub(frame: windowFrame)
        let manager = try started(configuration: "schema = 1\n", monitors: [Self.main], backend: backend)
        manager.windowAppeared(window(42))

        #expect(manager.switchWorkspace(to: .id(2)) == "ok")

        #expect(manager.activeWS[Self.main.id] == 2)
        #expect(manager.prevWS[Self.main.id] == 1)
        #expect(manager.windows[42]?.hidden == true)
        #expect(backend.writes.last == .position(CGPoint(x: 1918, y: 1078)))
    }

    @Test @MainActor func reselectingTheCurrentWorkspaceReturnsToThePrevious() throws {
        let manager = try started(configuration: """
        schema = 1
        [workspaces]
        back_and_forth = true
        """, monitors: [Self.main], backend: GeometryBackendStub(frame: windowFrame))
        manager.windowAppeared(window(42))
        _ = manager.switchWorkspace(to: .id(2))

        #expect(manager.switchWorkspace(to: .id(2)) == "ok")

        #expect(manager.activeWS[Self.main.id] == 1)
        #expect(manager.windows[42]?.hidden == false)
    }

    @Test @MainActor func pinnedFloatingWindowFollowsTheSwitch() throws {
        let manager = try started(configuration: "schema = 1\n", monitors: [Self.main],
                                  backend: GeometryBackendStub(frame: windowFrame))
        manager.windowAppeared(window(42, resizeCapability: .fixed))
        #expect(manager.dispatch(ConfiguredAction.window(.pin)) == "ok")
        try #require(manager.windows[42]?.pinned == true)

        _ = manager.switchWorkspace(to: .id(2))

        #expect(manager.windows[42]?.workspace == 2)
        #expect(manager.windows[42]?.hidden == false)
    }

    @Test @MainActor func hiddenWorkspaceAssignedWhilePausedMovesOnlyAfterResume() throws {
        let backend = GeometryBackendStub(frame: windowFrame)
        let manager = try started(configuration: "schema = 1\n",
                                  monitors: [Self.main, Self.second], backend: backend)
        manager.windowAppeared(window(42))
        #expect(manager.dispatch(Dispatcher.movetoworkspacesilent(.id(3))) == "ok")
        try #require(manager.windows[42]?.hidden == true)
        manager.setPaused(true)
        let writesWhilePaused = backend.writes.count

        manager.applyConfiguration(try compileConfiguration("""
        schema = 1
        [[workspaces.assignments]]
        id = 3
        monitor = "Second"
        """))

        #expect(manager.workspace(forID: 3).monitor == Self.second.id)
        #expect(backend.writes.count == writesWhilePaused)

        manager.setPaused(false)

        #expect(backend.writes.last == .position(CGPoint(x: 3838, y: 1078)))
    }

    private var windowFrame: CGRect { CGRect(x: 100, y: 100, width: 800, height: 600) }

    @MainActor
    private func started(configuration: String,
                         monitors: [Monitor],
                         backend: GeometryBackendStub) throws -> WindowManager {
        let manager = try makeDefaultWindowManager(configuration: compileConfiguration(configuration),
                                                   monitors: monitors,
                                                   geometryBackend: backend)
        manager.ensureWorkspacesForMonitors()
        manager.focusedMonitorID = Self.main.id
        return manager
    }

    private func window(_ id: WindowID,
                        resizeCapability: WindowResizeCapability = .resizable) -> WindowSnapshot {
        WindowSnapshot(id: id,
                       pid: 1,
                       bundleID: "com.example.app",
                       clazz: "Example",
                       title: "Window",
                       frame: windowFrame,
                       kind: .standard,
                       resizeCapability: resizeCapability,
                       windowLevel: nil,
                       isMinimized: false)
    }
}
