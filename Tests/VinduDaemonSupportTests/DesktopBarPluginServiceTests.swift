import Foundation
import Testing
@testable import VinduCore
@testable import VinduDaemonSupport

struct DesktopBarPluginServiceTests {
    @Test func timeoutCompletionClearsRunAndStartsPendingRefresh() throws {
        let harness = PluginServiceHarness()
        harness.service.sync(configuration: configuration(), enabled: true)
        #expect(harness.runs.count == 1)

        #expect(harness.service.refresh(id: "mail"))
        harness.runs[0].complete(timedOut: true)

        #expect(harness.logs == ["bar plugin mail: timed out"])
        #expect(harness.runs.count == 2)
    }

    @Test func nonzeroExitDoesNotLogStderr() throws {
        let harness = PluginServiceHarness()
        harness.service.sync(configuration: configuration(), enabled: true)
        harness.runs[0].complete(stderr: "TOKEN=secret-value", exitCode: 2)

        #expect(harness.logs == ["bar plugin mail: exited 2"])
        #expect(!harness.logs.joined(separator: "\n").contains("secret-value"))
    }

    @Test func shutdownUsesCompletionGuaranteedTerminationForEveryActiveRun() {
        let harness = PluginServiceHarness()
        let configured = configuration(
            items: [.plugin("mail"), .plugin("clock")],
            plugins: [
                "mail": plugin(command: .run(["/usr/bin/true"])),
                "clock": plugin(command: .run(["/usr/bin/true"])),
            ]
        )
        harness.service.sync(configuration: configured, enabled: true)

        harness.service.shutdown()

        #expect(harness.runs.count == 2)
        #expect(harness.runs.allSatisfy { $0.terminatedForShutdown })
        #expect(harness.runs.allSatisfy { !$0.terminated })
    }

    @Test func ordinaryStopKeepsGracefulTerminationPath() {
        let harness = PluginServiceHarness()
        harness.service.sync(configuration: configuration(), enabled: true)

        harness.service.stop()

        #expect(harness.runs[0].terminated)
        #expect(!harness.runs[0].terminatedForShutdown)
    }

    @Test func shutdownForceTerminatesRunStillExitingAfterOrdinaryStop() {
        let harness = PluginServiceHarness()
        harness.service.sync(configuration: configuration(), enabled: true)

        harness.service.stop()
        harness.service.shutdown()

        #expect(harness.runs[0].terminated)
        #expect(harness.runs[0].terminatedForShutdown)
    }

    @Test func shutdownDoesNotForceTerminateStoppedRunAfterItCompletes() {
        let harness = PluginServiceHarness()
        harness.service.sync(configuration: configuration(), enabled: true)

        harness.service.stop()
        harness.runs[0].complete()
        harness.service.shutdown()

        #expect(harness.runs[0].terminated)
        #expect(!harness.runs[0].terminatedForShutdown)
    }

    @Test func changedPluginIsNotRefreshedTwiceByItsConfigurationEvent() {
        let harness = PluginServiceHarness()
        harness.service.sync(configuration: configuration(events: ["configreloaded"]),
                             enabled: true)
        harness.runs[0].complete()

        let restarted = harness.service.sync(
            configuration: configuration(events: ["configreloaded"], timeoutMs: 600),
            enabled: true
        )

        harness.service.handle(event: .configreloaded, excluding: restarted)
        harness.runs[1].complete()

        #expect(restarted == Set(["mail"]))
        #expect(harness.runs.count == 2)
    }

    @Test func unchangedPluginReceivesOneConfigurationEventRefresh() {
        let harness = PluginServiceHarness()
        let configured = configuration(events: ["configreloaded"])
        harness.service.sync(configuration: configured, enabled: true)
        harness.runs[0].complete()

        let restarted = harness.service.sync(configuration: configured, enabled: true)
        harness.service.handle(event: .configreloaded, excluding: restarted)

        #expect(restarted.isEmpty)
        #expect(harness.runs.count == 2)
        #expect(harness.runs[1].request.reason == "event")
    }

    private func configuration(events: [String] = [],
                               timeoutMs: Int = 500) -> NativeBarConfiguration {
        configuration(items: [.plugin("mail")],
                      plugins: ["mail": plugin(command: .run(["/usr/bin/true"]),
                                                events: events,
                                                timeoutMs: timeoutMs)])
    }

    private func configuration(items: [NativeBarItem],
                               plugins: [String: NativeBarPlugin]) -> NativeBarConfiguration {
        NativeBarConfiguration(
            enabled: true,
            position: .top,
            height: .automatic,
            left: [],
            center: [],
            right: items,
            colors: NativeBarColors(
                background: color,
                foreground: color,
                inactive: color,
                active: color
            ),
            weather: nil,
            plugins: plugins
        )
    }

    private func plugin(command: CommandSpec.Execution,
                        events: [String] = [],
                        timeoutMs: Int = 500) -> NativeBarPlugin {
        NativeBarPlugin(
            command: CommandSpec(execution: command, environment: [:]),
            refreshSeconds: 0,
            events: events,
            timeoutMs: timeoutMs
        )
    }

    private var color: ConfigurationColor {
        ConfigurationColor(red: 0, green: 0, blue: 0, alpha: 1)
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
