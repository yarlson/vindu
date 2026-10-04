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
