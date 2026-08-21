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

    @Test func spawnSetupFailureHasSpecificDiagnostic() {
        let error = DesktopBarPluginProcessError.spawnSetupFailed(EINVAL)

        #expect(error.localizedDescription == "spawn setup failed: \(EINVAL)")
    }

    @Test func pluginDoesNotInheritUnrelatedDescriptors() throws {
        let sourceFD = Darwin.open("/dev/null", O_RDONLY)
        guard sourceFD >= 0 else {
            Issue.record("could not open /dev/null")
            return
        }
        let inheritedFD = fcntl(sourceFD, F_DUPFD, 100)
        defer {
            if inheritedFD >= 0 { Darwin.close(inheritedFD) }
            Darwin.close(sourceFD)
        }
        guard inheritedFD >= 100 else {
            Issue.record("could not duplicate a high-numbered descriptor")
            return
        }

        let result = try runPlugin(
            command: "if [ -e /dev/fd/\(inheritedFD) ]; then printf inherited; else printf closed; fi",
            timeoutMs: 500
        )

        #expect(result.exitCode == 0)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "closed")
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

    @Test func terminatedProcessCompletesAfterOwnerReleasesIt() throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("vindu-plugin-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }

        let request = DesktopBarPluginRunRequest(
            id: "released",
            command: "printf '%s' $$ > '\(pidFile.path)'; trap '' TERM; while :; do sleep 1; done",
            timeoutMs: 5_000,
            reason: "manual",
            eventName: "",
            eventPayload: ""
        )
        var process: DesktopBarPluginProcess? = DesktopBarPluginProcess(request: request)
        let processReference = WeakPluginProcessReference(process)
        var result: DesktopBarPluginRunResult?
        try process?.start { result = $0 }
        waitForPhase3Condition {
            (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap(pid_t.init) != nil
        }
        let pid = try #require(pid_t(try String(contentsOf: pidFile, encoding: .utf8)))
        defer {
            _ = Darwin.kill(-pid, SIGKILL)
            var status: Int32 = 0
            _ = waitpid(pid, &status, 0)
        }

        process?.terminate()
        process = nil

        #expect(processReference.process != nil)
        waitForPhase3Condition { result != nil }
        #expect(try #require(result).exitCode == -SIGKILL)
        waitForPhase3Condition { processReference.process == nil }
        #expect(processReference.process == nil)
    }

    @Test func shutdownKillsReapsAndDrainsBeforeReturning() throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("vindu-plugin-shutdown-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }

        let request = DesktopBarPluginRunRequest(
            id: "shutdown",
            command: "printf ready; printf '%s' $$ > '\(pidFile.path)'; trap '' TERM; while :; do sleep 1; done",
            timeoutMs: 5_000,
            reason: "manual",
            eventName: "",
            eventPayload: ""
        )
        let process = DesktopBarPluginProcess(request: request)
        var result: DesktopBarPluginRunResult?
        try process.start { result = $0 }
        waitForPhase3Condition {
            (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap(pid_t.init) != nil
        }
        let pid = try #require(pid_t(try String(contentsOf: pidFile, encoding: .utf8)))

        process.terminateForShutdown()

        #expect(Darwin.kill(pid, 0) != 0 && errno == ESRCH)
        waitForPhase3Condition { result != nil }
        let completed = try #require(result)
        #expect(completed.exitCode == -SIGKILL)
        #expect(String(decoding: completed.stdout, as: UTF8.self) == "ready")
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

private final class WeakPluginProcessReference {
    weak var process: DesktopBarPluginProcess?

    init(_ process: DesktopBarPluginProcess?) {
        self.process = process
    }
}

func waitForPhase3Condition(timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}
