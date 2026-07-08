import Darwin
import Foundation
import Testing
@testable import VinduDaemonSupport

struct DesktopBarPluginProcessTests {
    @Test func pluginEnvironmentUsesMinimalAllowlist() {
        let request = DesktopBarPluginRunRequest(id: "mail",
                                                 command: "env",
                                                 timeoutMs: 500,
                                                 reason: "event",
                                                 eventName: "workspace",
                                                 eventPayload: "1")
        let env = DesktopBarPluginProcess.pluginEnvironment(for: request, source: [
            "HOME": "/Users/test",
            "USER": "test",
            "PATH": "/private/bin",
            "AWS_SECRET_ACCESS_KEY": "secret",
            "PRIVATE_TOKEN": "secret",
            "LC_TIME": "en_US.UTF-8",
        ])

        #expect(env["HOME"] == "/Users/test")
        #expect(env["USER"] == "test")
        #expect(env["PATH"] == "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(env["AWS_SECRET_ACCESS_KEY"] == nil)
        #expect(env["PRIVATE_TOKEN"] == nil)
        #expect(env["LC_TIME"] == "en_US.UTF-8")
        #expect(env["VINDU_BAR_PLUGIN_ID"] == "mail")
        #expect(env["VINDU_BAR_PLUGIN_REASON"] == "event")
        #expect(env["VINDU_BAR_PLUGIN_EVENT"] == "workspace")
        #expect(env["VINDU_BAR_PLUGIN_EVENT_DATA"] == "1")
    }

    @Test func timeoutEscalatesPastTermIgnoringPlugin() throws {
        let result = try runPlugin(
            command: "trap '' TERM; while :; do sleep 1; done",
            timeoutMs: 250
        )

        #expect(result.timedOut)
        #expect(result.exitCode == -SIGKILL)
    }

    @Test func backgroundChildIsKilledWhenShellExits() throws {
        let result = try runPlugin(command: "sleep 30 & printf '%s\\n' \"$!\"", timeoutMs: 1000)
        let childPID = pid_t(String(decoding: result.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines))

        #expect(childPID != nil)
        guard let childPID else { return }
        waitForPhase3Condition {
            Darwin.kill(childPID, 0) != 0 && errno == ESRCH
        }
        #expect(Darwin.kill(childPID, 0) != 0 && errno == ESRCH)
    }

    @Test func fastStdoutAndStderrAreDrainedBeforeCompletion() throws {
        for _ in 0..<25 {
            let result = try runPlugin(command: """
            i=0
            while [ "$i" -lt 200 ]; do printf x; i=$((i + 1)); done
            printf 'secret-on-stderr\\n' 1>&2
            """, timeoutMs: 1000)
            #expect(result.exitCode == 0)
            #expect(result.stdout.count == 200)
            #expect(result.stderr.contains("secret-on-stderr"))
        }
    }

    private func runPlugin(command: String, timeoutMs: Int) throws -> DesktopBarPluginRunResult {
        let request = DesktopBarPluginRunRequest(id: "test",
                                                 command: command,
                                                 timeoutMs: timeoutMs,
                                                 reason: "manual",
                                                 eventName: "",
                                                 eventPayload: "")
        let process = DesktopBarPluginProcess(request: request)
        var result: DesktopBarPluginRunResult?
        try process.start { result = $0 }
        waitForPhase3Condition { result != nil }
        return try #require(result)
    }
}

func waitForPhase3Condition(timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}
