import Foundation
import Testing
@testable import VinduCore
@testable import VinduDaemonSupport

struct DesktopBarPluginServiceTests {
    @Test func timeoutCompletionClearsRunAndStartsPendingRefresh() throws {
        let harness = PluginServiceHarness()
        harness.service.sync(settings: settings(), enabled: true)
        #expect(harness.runs.count == 1)

        #expect(harness.service.refresh(id: "mail"))
        harness.runs[0].complete(timedOut: true)

        #expect(harness.logs == ["bar plugin mail: timed out"])
        #expect(harness.runs.count == 2)
    }

    @Test func nonzeroExitDoesNotLogStderr() throws {
        let harness = PluginServiceHarness()
        harness.service.sync(settings: settings(), enabled: true)
        harness.runs[0].complete(stderr: "TOKEN=secret-value", exitCode: 2)

        #expect(harness.logs == ["bar plugin mail: exited 2"])
        #expect(!harness.logs.joined(separator: "\n").contains("secret-value"))
    }

    @Test func shutdownUsesCompletionGuaranteedTerminationForEveryActiveRun() {
        let harness = PluginServiceHarness()
        var configured = settings()
        configured.items.append(.plugin("clock"))
        configured.plugins["clock"] = BarPluginConfig(command: "clock",
                                                       refreshSeconds: 0,
                                                       events: [],
                                                       timeoutMs: 500)
        harness.service.sync(settings: configured, enabled: true)

        harness.service.shutdown()

        #expect(harness.runs.count == 2)
        #expect(harness.runs.allSatisfy { $0.terminatedForShutdown })
        #expect(harness.runs.allSatisfy { !$0.terminated })
    }

    @Test func ordinaryStopKeepsGracefulTerminationPath() {
        let harness = PluginServiceHarness()
        harness.service.sync(settings: settings(), enabled: true)

        harness.service.stop()

        #expect(harness.runs[0].terminated)
        #expect(!harness.runs[0].terminatedForShutdown)
    }

    @Test func shutdownForceTerminatesRunDetachedByOrdinaryStop() {
        let harness = PluginServiceHarness()
        harness.service.sync(settings: settings(), enabled: true)

        harness.service.stop()
        harness.service.shutdown()

        #expect(harness.runs[0].terminated)
        #expect(harness.runs[0].terminatedForShutdown)
    }

    @Test func completedDetachedRunIsNotTerminatedAgainAtShutdown() {
        let harness = PluginServiceHarness()
        harness.service.sync(settings: settings(), enabled: true)

        harness.service.stop()
        harness.runs[0].complete()
        harness.service.shutdown()

        #expect(harness.runs[0].terminated)
        #expect(!harness.runs[0].terminatedForShutdown)
    }

    private func settings() -> BarSettings {
        var settings = BarSettings()
        settings.items = [.plugin("mail")]
        settings.plugins["mail"] = BarPluginConfig(command: "mail-count",
                                                   refreshSeconds: 0,
                                                   events: [],
                                                   timeoutMs: 500)
        return settings
    }
}

private final class PluginServiceHarness {
    var logs: [String] = []
    var runs: [FakePluginRun] = []
    lazy var service = DesktopBarPluginService(log: { [weak self] in self?.logs.append($0) },
                                               makeProcess: { [weak self] request in
        let run = FakePluginRun(request: request)
        self?.runs.append(run)
        return run
    })
}

private final class FakePluginRun: DesktopBarPluginRunning {
    let request: DesktopBarPluginRunRequest
    var completion: ((DesktopBarPluginRunResult) -> Void)?
    private(set) var terminated = false
    private(set) var terminatedForShutdown = false

    init(request: DesktopBarPluginRunRequest) {
        self.request = request
    }

    func start(completion: @escaping (DesktopBarPluginRunResult) -> Void) throws {
        self.completion = completion
    }

    func terminate() {
        terminated = true
    }

    func terminateForShutdown() {
        terminatedForShutdown = true
    }

    func complete(stdout: Data = Data(),
                  stderr: String = "",
                  exitCode: Int32 = 0,
                  timedOut: Bool = false) {
        completion?(DesktopBarPluginRunResult(id: request.id,
                                              stdout: stdout,
                                              stderr: stderr,
                                              exitCode: exitCode,
                                              timedOut: timedOut))
    }
}
