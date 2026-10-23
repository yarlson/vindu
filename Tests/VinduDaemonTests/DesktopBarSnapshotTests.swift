import CoreGraphics
import Testing
import VinduCore
@testable import vindud

struct DesktopBarSnapshotTests {
    private static let main = Monitor(id: 1, index: 0, name: "Main",
                                      frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                      usable: CGRect(x: 0, y: 25, width: 1920, height: 1055),
                                      scale: 2, topObstruction: nil)

    @Test @MainActor func visibleWorkspaceReportsTheAppOfItsFocusedWindow() throws {
        let manager = try startedTestWindowManager(configuration: "schema = 1\n", monitors: [Self.main],
                                                   backend: GeometryBackendStub(frame: testWindowFrame))
        manager.windowAppeared(testWindowSnapshot(42, pid: 7, clazz: "Notes"))

        let workspaces = manager.desktopBarSnapshot().workspaces
        let first = try #require(workspaces.first { $0.id == 1 })
        let second = try #require(workspaces.first { $0.id == 2 })

        #expect(first.appProcessIdentifier == 7)
        #expect(first.appName == "Notes")
        #expect(second.appProcessIdentifier == nil)
        #expect(second.appName == "")
    }

    @Test @MainActor func hiddenWorkspaceReportsTheAppMovedToIt() throws {
        let manager = try startedTestWindowManager(configuration: "schema = 1\n", monitors: [Self.main],
                                                   backend: GeometryBackendStub(frame: testWindowFrame))
        manager.windowAppeared(testWindowSnapshot(42, pid: 7, clazz: "Notes"))
        try #require(manager.dispatch(Dispatcher.movetoworkspacesilent(.id(3))) == "ok")

        let workspaces = manager.desktopBarSnapshot().workspaces
        let first = try #require(workspaces.first { $0.id == 1 })
        let third = try #require(workspaces.first { $0.id == 3 })

        #expect(third.appProcessIdentifier == 7)
        #expect(third.appName == "Notes")
        #expect(first.appProcessIdentifier == nil)
        #expect(first.appName == "")
    }

    @Test(arguments: [
        ("[ui.bar]\nleft = [\"workspaces\", \"application\"]\n[ui.bar.workspaces]\napp_icon = true",
         Set<pid_t>([7, 8, 9])),
        ("[ui.bar]\nleft = [\"workspaces\", \"application\"]", Set<pid_t>([9])),
        ("[ui.bar]\nleft = [\"workspaces\"]\n[ui.bar.workspaces]\napp_icon = true", Set<pid_t>([7, 8])),
    ])
    func barLoadsIconsOnlyForAppsItShows(bar: String, expected: Set<pid_t>) throws {
        let configuration = try compileConfiguration("schema = 1\n" + bar).ui.bar
        let snapshot = DesktopBarSnapshot(
            monitors: [],
            workspaces: [
                DesktopBarWorkspace(id: 1, name: "1", windows: 1, appProcessIdentifier: 7, appName: "Notes"),
                DesktopBarWorkspace(id: 2, name: "2", windows: 1, appProcessIdentifier: 8, appName: "Mail"),
                DesktopBarWorkspace(id: 3, name: "3", windows: 0, appProcessIdentifier: nil, appName: ""),
            ],
            activeWorkspaces: [:],
            appProcessIdentifier: 9,
            appName: "Terminal",
            windowTitle: "",
            layout: .dwindle,
            submap: "",
            paused: false,
            system: DesktopBarSystemInfo(date: "", battery: nil, network: nil, keyboard: nil,
                                         volume: nil, weather: nil),
            plugins: [:]
        )

        #expect(DesktopBar.appIconProcessIdentifiers(configuration: configuration, snapshot: snapshot)
                == expected)
    }
}
