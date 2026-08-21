import Foundation
import Testing
@testable import VinduCore

struct ConfigurationStatusTests {
    @Test func typedStatusRoundTripsJSON() throws {
        let status = ConfigStatus(
            path: "/tmp/vindu.toml",
            daemonState: .configurationOnly,
            activeSchema: nil,
            latestAttemptSucceeded: false,
            rejectedDiagnostics: [
                LocatedConfigDiagnostic(file: "/tmp/vindu.toml",
                                        line: 4,
                                        schemaPath: "ui.bar.left",
                                        message: "unknown bar item"),
            ],
            runtimeWarnings: []
        )

        let data = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(ConfigStatus.self, from: data)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(decoded == status)
        #expect(object["daemon_state"] as? String == "configuration_only")
        #expect(object["latest_attempt_succeeded"] as? Bool == false)
        #expect(object["rejected_diagnostics"] != nil)
        #expect(ConfigDaemonState.waitingForAccessibility.rawValue == "waiting_for_accessibility")
    }
}
