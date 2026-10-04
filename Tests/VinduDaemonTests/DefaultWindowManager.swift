import Foundation
import Testing
import VinduCore
@testable import vindud

func defaultConfiguration() throws -> ConfigurationSnapshot {
    switch ConfigurationCompiler().compile(Data(defaultConfigTemplate.utf8)) {
    case .success(let configuration):
        return configuration
    case .failure(let failure):
        Issue.record("default configuration failed: \(failure.diagnostics)")
        throw failure
    }
}

func makeDefaultWindowManager() throws -> WindowManager {
    WindowManager(configuration: try defaultConfiguration(),
                  configPath: "/tmp/vindu-test.toml",
                  wroteCanonicalDefault: false,
                  broadcastEvent: { _ in },
                  runtimeWarningsChanged: { _ in },
                  quit: {})
}
