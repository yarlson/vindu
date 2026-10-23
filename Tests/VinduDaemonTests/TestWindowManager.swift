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

func testWindowSnapshot(_ id: WindowID,
                        resizeCapability: WindowResizeCapability = .resizable) -> WindowSnapshot {
    WindowSnapshot(id: id,
                   pid: 1,
                   bundleID: "com.example.app",
                   clazz: "Example",
                   title: "Window",
                   frame: testWindowFrame,
                   kind: .standard,
                   resizeCapability: resizeCapability,
                   windowLevel: nil,
                   isMinimized: false)
}
