import Testing
@testable import VinduCore

struct IPCShapeTests {
    @Test func clientJSONKeepsPublishedKeys() {
        let client = ClientInfo(address: "0x2a", mapped: true, hidden: false,
                                at: [10, 20], size: [800, 600],
                                workspace: WorkspaceRef(id: 2, name: "web"),
                                floating: false, pinned: true, fullscreen: 0,
                                fakeFullscreen: false, monitor: 1, clazz: "Safari",
                                title: "Docs", initialClass: "Safari", initialTitle: "Start",
                                pid: 501, focusHistoryID: 3)

        #expect(encodeJSON(client) == """
        {
          "address" : "0x2a",
          "at" : [
            10,
            20
          ],
          "class" : "Safari",
          "fakeFullscreen" : false,
          "floating" : false,
          "focusHistoryID" : 3,
          "fullscreen" : 0,
          "hidden" : false,
          "initialClass" : "Safari",
          "initialTitle" : "Start",
          "mapped" : true,
          "monitor" : 1,
          "pid" : 501,
          "pinned" : true,
          "size" : [
            800,
            600
          ],
          "title" : "Docs",
          "workspace" : {
            "id" : 2,
            "name" : "web"
          }
        }
        """)
    }

    @Test func workspaceJSONKeepsPublishedKeys() {
        let workspace = WorkspaceInfo(id: 2, name: "web", monitor: "Built-in", monitorID: 0,
                                      windows: 3, hasfullscreen: true, lastwindow: "0x2a",
                                      lastwindowtitle: "Docs")

        #expect(encodeJSON(workspace) == """
        {
          "hasfullscreen" : true,
          "id" : 2,
          "lastwindow" : "0x2a",
          "lastwindowtitle" : "Docs",
          "monitor" : "Built-in",
          "monitorID" : 0,
          "name" : "web",
          "windows" : 3
        }
        """)
    }

    @Test func monitorJSONKeepsPublishedKeys() {
        let monitor = MonitorInfo(id: 0, name: "Built-in", width: 1728, height: 1117,
                                  x: 0, y: 0, activeWorkspace: WorkspaceRef(id: 1, name: "1"),
                                  specialWorkspace: WorkspaceRef(id: 0, name: ""),
                                  scale: 2, focused: true)

        #expect(encodeJSON(monitor) == """
        {
          "activeWorkspace" : {
            "id" : 1,
            "name" : "1"
          },
          "focused" : true,
          "height" : 1117,
          "id" : 0,
          "name" : "Built-in",
          "scale" : 2,
          "specialWorkspace" : {
            "id" : 0,
            "name" : ""
          },
          "width" : 1728,
          "x" : 0,
          "y" : 0
        }
        """)
    }

    @Test func bindJSONKeepsPublishedKeys() {
        let bind = BindInfo(locked: false, mouse: false, release: false, repeats: true,
                            modmask: 8, submap: "resize", key: "l", dispatcher: "resizeactive",
                            arg: "30 0", description: "Grow right")

        #expect(encodeJSON(bind) == """
        {
          "arg" : "30 0",
          "description" : "Grow right",
          "dispatcher" : "resizeactive",
          "key" : "l",
          "locked" : false,
          "modmask" : 8,
          "mouse" : false,
          "release" : false,
          "repeats" : true,
          "submap" : "resize"
        }
        """)
    }

    @Test func versionJSONKeepsPublishedKeys() {
        let version = VersionInfo(version: "1.2.3", system: "macOS 26.0")

        #expect(encodeJSON(version) == """
        {
          "branch" : "main",
          "system" : "macOS 26.0",
          "version" : "1.2.3"
        }
        """)
    }
}
