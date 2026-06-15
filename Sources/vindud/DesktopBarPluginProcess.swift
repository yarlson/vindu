import Foundation
import VinduCore

struct DesktopBarPluginRunRequest {
    let id: String
    let command: String
    let timeoutMs: Int
    let reason: String
    let eventName: String
    let eventPayload: String
}

struct DesktopBarPluginRunResult {
    let id: String
    let stdout: Data
    let stderr: String
    let exitCode: Int32
    let timedOut: Bool
}

final class DesktopBarPluginProcess {
    private let request: DesktopBarPluginRunRequest
    private let process = Process()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let lock = NSLock()
    private var stdoutData = Data()
    private var stderrData = Data()
    private var timer: DispatchSourceTimer?
    private var timedOut = false
    private var completed = false

    init(request: DesktopBarPluginRunRequest) {
        self.request = request
    }

    func start(completion: @escaping (DesktopBarPluginRunResult) -> Void) throws {
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-lc", request.command]
        process.environment = environment()
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.append(handle.availableData, to: \.stdoutData)
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.append(handle.availableData, to: \.stderrData)
        }

        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.finishOnce(process: process, completion: completion)
        }

        do {
            try process.run()
        } catch {
            cleanupAfterStartFailure()
            throw error
        }
        startTimeout()
    }

    func terminate() {
        if process.isRunning {
            process.terminate()
        }
    }

    private func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["VINDU_BAR_PLUGIN_ID"] = request.id
        env["VINDU_BAR_PLUGIN_REASON"] = request.reason
        env["VINDU_BAR_PLUGIN_EVENT"] = request.eventName
        env["VINDU_BAR_PLUGIN_EVENT_DATA"] = request.eventPayload
        env["VINDU_COMMAND_SOCKET"] = VinduPaths.commandSocketPath
        env["VINDU_EVENT_SOCKET"] = VinduPaths.eventSocketPath
        return env
    }

    private func startTimeout() {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        self.timer = timer
        lock.unlock()

        timer.schedule(deadline: .now() + .milliseconds(request.timeoutMs))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard !self.completed else {
                self.lock.unlock()
                return
            }
            self.timedOut = true
            self.lock.unlock()
            if self.process.isRunning {
                self.process.terminate()
            }
        }
        timer.resume()
    }

    private func append(_ data: Data, to keyPath: ReferenceWritableKeyPath<DesktopBarPluginProcess, Data>) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var current = self[keyPath: keyPath]
        let remaining = max(0, BarPluginOutput.maxBytes + 1 - current.count)
        if remaining > 0 {
            current.append(data.prefix(remaining))
            self[keyPath: keyPath] = current
        }
    }

    private func finishOnce(process: Process,
                            completion: @escaping (DesktopBarPluginRunResult) -> Void) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let timer = timer
        self.timer = nil
        let out = stdoutData
        let err = String(data: stderrData, encoding: .utf8) ?? ""
        let didTimeOut = timedOut
        lock.unlock()

        timer?.cancel()
        process.terminationHandler = nil
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil

        DispatchQueue.main.async {
            completion(DesktopBarPluginRunResult(
                id: self.request.id,
                stdout: out,
                stderr: Self.firstLogLine(err),
                exitCode: process.terminationStatus,
                timedOut: didTimeOut
            ))
        }
    }

    private func cleanupAfterStartFailure() {
        lock.lock()
        completed = true
        let timer = timer
        self.timer = nil
        lock.unlock()

        timer?.cancel()
        process.terminationHandler = nil
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
    }

    private static func firstLogLine(_ text: String) -> String {
        let line = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? ""
        return String(line.prefix(200))
    }
}
