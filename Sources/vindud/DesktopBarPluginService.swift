import Foundation
import VinduCore

final class DesktopBarPluginService {
    var onChange: (() -> Void)?

    private final class State {
        var config: BarPluginConfig
        var current: BarPluginValue?
        var timer: Timer?
        var run: DesktopBarPluginProcess?
        var pending: Refresh?

        init(config: BarPluginConfig) {
            self.config = config
        }
    }

    private struct Refresh {
        let reason: String
        let eventName: String
        let eventPayload: String
    }

    private var states: [String: State] = [:]

    var current: [String: BarPluginValue] {
        states.compactMapValues(\.current)
    }

    func sync(settings: BarSettings, enabled: Bool) {
        guard enabled else {
            stop()
            return
        }

        let active = Set(settings.pluginIDs)
        var changed = false
        for id in Array(states.keys) where !active.contains(id) {
            changed = stop(id: id) || changed
        }

        for id in active.sorted() {
            guard let config = settings.plugins[id],
                  !config.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
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
            scheduleTimer(id: id, state: state)
            refresh(id: id, Refresh(reason: "startup", eventName: "", eventPayload: ""))
        }

        if changed {
            onChange?()
        }
    }

    func stop() {
        let hadValues = states.values.contains { $0.current != nil }
        for id in Array(states.keys) {
            _ = stop(id: id)
        }
        if hadValues {
            onChange?()
        }
    }

    func refresh(id: String) -> Bool {
        guard states[id] != nil else { return false }
        refresh(id: id, Refresh(reason: "manual", eventName: "", eventPayload: ""))
        return true
    }

    func handle(event: WMEvent) {
        for (id, state) in states where state.config.events.contains(event.name) {
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
        let run = DesktopBarPluginProcess(request: request)
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
                        run: DesktopBarPluginProcess?) {
        guard let state = states[result.id], state.run === run else { return }
        state.run = nil

        if result.timedOut {
            log("bar plugin \(result.id): timed out")
        } else if result.exitCode != 0 {
            log("bar plugin \(result.id): exited \(result.exitCode)\(logSuffix(result.stderr))")
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
        state.run?.terminate()
        return state.current != nil
    }

    private func logSuffix(_ stderr: String) -> String {
        stderr.isEmpty ? "" : ": \(stderr)"
    }
}
