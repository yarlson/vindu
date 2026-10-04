import Testing
import VinduCore
@testable import vindud

struct IPCTextFormatTests {
    @Test @MainActor func clientTextKeepsPublishedLayout() throws {
        let manager = try makeTestWindowManager()
        let client = ClientInfo(address: "0x2a", mapped: true, hidden: true,
                                at: [10, 20], size: [800, 600],
                                workspace: WorkspaceRef(id: 2, name: "web"),
                                floating: true, pinned: false, fullscreen: 0,
                                fakeFullscreen: false, monitor: 1, clazz: "Safari",
                                title: "Docs", initialClass: "Safari", initialTitle: "Start",
                                pid: 501, focusHistoryID: 3)

        #expect(manager.clientText(client) == """
        Window 0x2a -> Safari: Docs
            at: 10,20
            size: 800,600
            workspace: 2 (web)
            floating: 1
            pinned: 0
            fullscreen: 0
            monitor: 1
            pid: 501
            hidden: 1
        """)
    }

    @Test @MainActor func bindTextKeepsPublishedLayout() throws {
        let manager = try makeTestWindowManager()
        let bind = BindInfo(locked: false, mouse: false, release: false, repeats: true,
                            modmask: (1 << 3) | (1 << 0), submap: "resize", key: "l",
                            dispatcher: "resizeactive", arg: "30 0", description: "Grow right")

        #expect(manager.bindText(bind) == "binde: SUPER SHIFT + l -> resizeactive 30 0 [submap: resize]")
    }
}
