import Foundation
import VinduCore

public final class DesktopBarPluginService {
    public typealias Logger = (String) -> Void
    typealias ProcessFactory = (DesktopBarPluginRunRequest) -> DesktopBarPluginRunning

    public var onChange: (() -> Void)?

    private final class State {
        var config: NativeBarPlugin
        var current: BarPluginValue?
        var timer: Timer?
        var run: DesktopBarPluginRunning?
        var pending: Refresh?

        init(config: NativeBarPlugin) {
            self.config = config
        }
    }

    private struct Refresh {
        let reason: String
        let eventName: String
        let eventPayload: String
    }

    private let log: Logger
    private let makeProcess: ProcessFactory
    private var states: [String: State] = [:]
    private var terminatingRuns: [ObjectIdentifier: DesktopBarPluginRunning] = [:]

    public var current: [String: BarPluginValue] {
        states.compactMapValues(\.current)
    }

    public convenience init(log: @escaping Logger = { _ in }) {
        self.init(log: log, makeProcess: { DesktopBarPluginProcess(request: $0) })
    }

    init(log: @escaping Logger,
         makeProcess: @escaping ProcessFactory) {
        self.log = log
        self.makeProcess = makeProcess
    }

    @discardableResult
    public func sync(configuration: NativeBarConfiguration, enabled: Bool) -> Set<String> {
        guard enabled else {
            stop()
            return []
        }

        let active = Set(configuration.pluginIDs)
        var restarted: Set<String> = []
        var changed = false
        for id in Array(states.keys) where !active.contains(id) {
            changed = stop(id: id) || changed
        }

        for id in active.sorted() {
            guard let config = configuration.plugins[id] else {
                changed = stop(id: id) || changed
                log("bar plugin \(id): missing command")
                continue
            }
            if let state = states[id], state.config == config {
                continue
            }
            changed = stop(id: id) || changed
            let state = State(config: config)
            states[id] = state
            restarted.insert(id)
            scheduleTimer(id: id, state: state)
            refresh(id: id, Refresh(reason: "startup", eventName: "", eventPayload: ""))
        }

        if changed {
            onChange?()
        }
        return restarted
    }

    public func stop() {
        let hadValues = states.values.contains { $0.current != nil }
        for id in Array(states.keys) {
            _ = stop(id: id)
        }
        if hadValues {
            onChange?()
        }
    }

    public func shutdown() {
        let hadValues = states.values.contains { $0.current != nil }
        let activeStates = Array(states.values)
        for state in activeStates {
            state.timer?.invalidate()
            state.pending = nil
        }
        let activeRuns = activeStates.compactMap(\.run)
        let runs = activeRuns + Array(terminatingRuns.values)
        for run in runs {
            run.terminateForShutdown()
        }
        states.removeAll()
        terminatingRuns.removeAll()
        if hadValues {
            onChange?()
        }
    }

    public func refresh(id: String) -> Bool {
        guard states[id] != nil else { return false }
        refresh(id: id, Refresh(reason: "manual", eventName: "", eventPayload: ""))
        return true
    }

    public func handle(event: WMEvent, excluding excludedIDs: Set<String> = []) {
        for (id, state) in states
        where !excludedIDs.contains(id) && state.config.events.contains(event.name) {
            refresh(id: id, Refresh(reason: "event",
                                    eventName: event.name,
                                    eventPayload: event.payload))
        }
    }

    private func scheduleTimer(id: String, state: State) {
        guard state.config.refreshSeconds > 0 else { return }
        state.timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(state.config.refreshSeconds),
                                           repeats: true) { [weak self] _ in
            self?.refresh(id: id, Refresh(reason: "interval", eventName: "", eventPayload: ""))
        }
    }

    private func refresh(id: String, _ refresh: Refresh) {
        guard let state = states[id] else { return }
        guard state.run == nil else {
            state.pending = refresh
            return
        }

        let request = DesktopBarPluginRunRequest(id: id,
                                                 command: state.config.command,
                                                 timeoutMs: state.config.timeoutMs,
                                                 reason: refresh.reason,
                                                 eventName: refresh.eventName,
                                                 eventPayload: refresh.eventPayload)
        let run = makeProcess(request)
        state.run = run
        do {
            try run.start { [weak self, weak run] result in
                self?.finish(result, run: run)
            }
        } catch {
            state.run = nil
            log("bar plugin \(id): start failed: \(error.localizedDescription)")
        }
    }

    private func finish(_ result: DesktopBarPluginRunResult,
                        run: DesktopBarPluginRunning?) {
        if let run {
            terminatingRuns.removeValue(forKey: ObjectIdentifier(run))
        }
        guard let state = states[result.id], state.run === run else { return }
        state.run = nil

        if result.timedOut {
            log("bar plugin \(result.id): timed out")
        } else if result.exitCode != 0 {
            log("bar plugin \(result.id): exited \(result.exitCode)")
        } else {
            applyOutput(result.stdout, to: result.id, state: state)
        }

        if let pending = state.pending {
            state.pending = nil
            refresh(id: result.id, pending)
        }
    }

    private func applyOutput(_ data: Data, to id: String, state: State) {
        switch BarPluginOutput.parse(data) {
        case .success(let value):
            if state.current != value {
                state.current = value
                onChange?()
            }
        case .failure(let error):
            log("bar plugin \(id): \(error.message)")
        }
    }

    private func stop(id: String) -> Bool {
        guard let state = states.removeValue(forKey: id) else { return false }
        state.timer?.invalidate()
        if let run = state.run {
            terminatingRuns[ObjectIdentifier(run)] = run
            run.terminate()
        }
        return state.current != nil
    }
}
