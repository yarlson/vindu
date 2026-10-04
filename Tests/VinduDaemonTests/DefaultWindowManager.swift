import Foundation
import Testing
import VinduCore
@testable import vindud

func makeDefaultWindowManager() throws -> WindowManager {
    let configuration: ConfigurationSnapshot
    switch ConfigurationCompiler().compile(Data(defaultConfigTemplate.utf8)) {
    case .success(let value):
        configuration = value
    case .failure(let failure):
        Issue.record("default configuration failed: \(failure.diagnostics)")
        throw failure
    }
    return WindowManager(configuration: configuration,
                         configPath: "/tmp/vindu-test.toml",
                         wroteCanonicalDefault: false,
                         broadcastEvent: { _ in },
                         runtimeWarningsChanged: { _ in },
                         quit: {})
}
