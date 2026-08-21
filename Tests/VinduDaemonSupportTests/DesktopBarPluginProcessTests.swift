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

    @Test func pluginDoesNotInheritUnrelatedDescriptors() async throws {
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

        let result = try await runPlugin(
            command: "if [ -e /dev/fd/\(inheritedFD) ]; then printf inherited; else printf closed; fi",
            timeoutMs: 500
        )

        #expect(result.exitCode == 0)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "closed")
    }

    @Test func timeoutEscalatesPastTermIgnoringPlugin() async throws {
        let result = try await runPlugin(
            command: "trap '' TERM; while :; do sleep 1; done",
            timeoutMs: 250
        )

        #expect(result.timedOut)
        #expect(result.exitCode == -SIGKILL)
    }

    @Test func backgroundChildIsKilledWhenShellExits() async throws {
        let result = try await runPlugin(command: "sleep 30 & printf '%s\\n' \"$!\"",
                                         timeoutMs: 1000)
        let childPID = pid_t(String(decoding: result.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines))

        #expect(childPID != nil)
        guard let childPID else { return }
        try await waitForPluginCondition {
            Darwin.kill(childPID, 0) != 0 && errno == ESRCH
        }
        #expect(Darwin.kill(childPID, 0) != 0 && errno == ESRCH)
    }

    @Test func fastStdoutAndStderrAreDrainedBeforeCompletion() async throws {
        for _ in 0..<25 {
            let result = try await runPlugin(command: """
            i=0
            while [ "$i" -lt 200 ]; do printf x; i=$((i + 1)); done
            printf 'secret-on-stderr\\n' 1>&2
            """, timeoutMs: 1000)
            #expect(result.exitCode == 0)
            #expect(result.stdout.count == 200)
            #expect(result.stderr.contains("secret-on-stderr"))
        }
    }

    @Test func terminatedProcessCompletesAfterOwnerReleasesIt() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("vindu-plugin-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }

        let request = DesktopBarPluginRunRequest(
            id: "released",
            command: "trap '' TERM; printf '%s' $$ > '\(pidFile.path)'; while :; do sleep 1; done",
            timeoutMs: 5_000,
            reason: "manual",
            eventName: "",
            eventPayload: ""
        )
        let resultWaiter = PluginResultWaiter()
        var process: DesktopBarPluginProcess? = DesktopBarPluginProcess(
            request: request,
            completionQueue: resultWaiter.queue
        )
        let processReference = WeakPluginProcessReference(process)
        try process?.start { resultWaiter.complete(with: $0) }
        try await waitForPluginCondition {
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
        let completed = try await resultWaiter.wait()
        #expect(completed.exitCode == -SIGKILL)
        try await waitForPluginCondition { processReference.process == nil }
        #expect(processReference.process == nil)
    }

    @Test func shutdownKillsReapsAndDrainsBeforeReturning() async throws {
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
        let resultWaiter = PluginResultWaiter()
        let process = DesktopBarPluginProcess(request: request,
                                              completionQueue: resultWaiter.queue)
        try process.start { resultWaiter.complete(with: $0) }
        try await waitForPluginCondition {
            (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap(pid_t.init) != nil
        }
        let pid = try #require(pid_t(try String(contentsOf: pidFile, encoding: .utf8)))

        process.terminateForShutdown()

        #expect(Darwin.kill(pid, 0) != 0 && errno == ESRCH)
        let completed = try await resultWaiter.wait()
        #expect(completed.exitCode == -SIGKILL)
        #expect(String(decoding: completed.stdout, as: UTF8.self) == "ready")
    }

    private func runPlugin(command: String,
                           timeoutMs: Int) async throws -> DesktopBarPluginRunResult {
        let request = DesktopBarPluginRunRequest(id: "test",
                                                 command: command,
                                                 timeoutMs: timeoutMs,
                                                 reason: "manual",
                                                 eventName: "",
                                                 eventPayload: "")
        let resultWaiter = PluginResultWaiter()
        let process = DesktopBarPluginProcess(request: request,
                                              completionQueue: resultWaiter.queue)
        try process.start { resultWaiter.complete(with: $0) }
        return try await resultWaiter.wait()
    }
}

private final class PluginResultWaiter {
    let queue = DispatchQueue(label: "vindu.plugin-test.completion")
    private let lock = NSLock()
    private var result: DesktopBarPluginRunResult?

    func complete(with result: DesktopBarPluginRunResult) {
        lock.withLock { self.result = result }
    }

    func wait() async throws -> DesktopBarPluginRunResult {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while true {
            if let result = lock.withLock({ result }) {
                queue.sync {}
                return result
            }
            guard clock.now < deadline else {
                throw PluginTestError.resultTimedOut
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private final class WeakPluginProcessReference {
    weak var process: DesktopBarPluginProcess?

    init(_ process: DesktopBarPluginProcess?) {
        self.process = process
    }
}

private enum PluginTestError: Error {
    case conditionTimedOut
    case resultTimedOut
}

private func waitForPluginCondition(_ condition: @escaping () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while true {
        if condition() { return }
        guard clock.now < deadline else {
            throw PluginTestError.conditionTimedOut
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}
