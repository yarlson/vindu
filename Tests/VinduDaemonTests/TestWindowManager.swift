import CoreGraphics
import Foundation
import Testing
import VinduCore
@testable import vindud

func compileConfiguration(_ text: String) throws -> ConfigurationSnapshot {
    switch ConfigurationCompiler().compile(Data(text.utf8)) {
    case .success(let configuration):
        return configuration
    case .failure(let failure):
        Issue.record("test configuration failed: \(failure.diagnostics)")
        throw failure
    }
}

func makeTestWindowManager(configuration: ConfigurationSnapshot? = nil,
                           monitors: [Monitor] = [],
                           geometryBackend: WindowGeometryBackend? = nil) throws -> WindowManager {
    WindowManager(configuration: try configuration ?? compileConfiguration("schema = 1\n"),
                  configPath: "/tmp/vindu-test.toml",
                  wroteCanonicalDefault: false,
                  broadcastEvent: { _ in },
                  runtimeWarningsChanged: { _ in },
                  quit: {},
                  monitorMgr: MonitorManager(monitors: monitors),
                  geometryBackend: geometryBackend)
}

let testWindowFrame = CGRect(x: 100, y: 100, width: 800, height: 600)

@MainActor
func startedTestWindowManager(configuration: String,
                              monitors: [Monitor],
                              backend: GeometryBackendStub) throws -> WindowManager {
    let manager = try makeTestWindowManager(configuration: compileConfiguration(configuration),
                                            monitors: monitors,
                                            geometryBackend: backend)
    manager.ensureWorkspacesForMonitors()
    manager.focusedMonitorID = monitors[0].id
    return manager
}

func testDesktopBarSnapshot(monitors: [Monitor] = [],
                            workspaces: [DesktopBarWorkspace],
                            activeWorkspaces: [CGDirectDisplayID: Int] = [:],
                            appProcessIdentifier: pid_t?) -> DesktopBarSnapshot {
    DesktopBarSnapshot(monitors: monitors,
                       workspaces: workspaces,
                       activeWorkspaces: activeWorkspaces,
                       appProcessIdentifier: appProcessIdentifier,
                       appName: "",
                       windowTitle: "",
                       layout: .dwindle,
                       submap: "",
                       paused: false,
                       system: DesktopBarSystemInfo(date: "", battery: nil, network: nil, keyboard: nil,
                                                    volume: nil, weather: nil),
                       plugins: [:])
}

func testWindowSnapshot(_ id: WindowID,
                        pid: pid_t = 1,
                        clazz: String = "Example",
                        resizeCapability: WindowResizeCapability = .resizable) -> WindowSnapshot {
    WindowSnapshot(id: id,
                   pid: pid,
                   bundleID: "com.example.app",
                   clazz: clazz,
                   title: "Window",
                   frame: testWindowFrame,
                   kind: .standard,
                   resizeCapability: resizeCapability,
                   windowLevel: nil,
                   isMinimized: false)
}
