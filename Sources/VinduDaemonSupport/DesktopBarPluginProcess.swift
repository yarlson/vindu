import Darwin
import Dispatch
import Foundation
import VinduCore

struct DesktopBarPluginRunRequest {
    let id: String
    let command: CommandSpec
    let timeoutMs: Int
    let reason: String
    let eventName: String
    let eventPayload: String

    init(id: String,
         command: CommandSpec,
         timeoutMs: Int,
         reason: String,
         eventName: String,
         eventPayload: String) {
        self.id = id
        self.command = command
        self.timeoutMs = timeoutMs
        self.reason = reason
        self.eventName = eventName
        self.eventPayload = eventPayload
    }
}

struct DesktopBarPluginRunResult {
    let id: String
    let stdout: Data
    let stderr: String
    let exitCode: Int32
    let timedOut: Bool
}

protocol DesktopBarPluginRunning: AnyObject {
    func start(completion: @escaping (DesktopBarPluginRunResult) -> Void) throws
    func terminate()
    func terminateForShutdown()
}

enum DesktopBarPluginProcessError: Error, LocalizedError {
    case pipeFailed(Int32)
    case spawnSetupFailed(Int32)
    case spawnFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .pipeFailed(let code): return "pipe failed: \(code)"
        case .spawnSetupFailed(let code): return "spawn setup failed: \(code)"
        case .spawnFailed(let code): return "spawn failed: \(code)"
        }
    }
}

final class DesktopBarPluginProcess: DesktopBarPluginRunning {
    private static let graceMs = 150

    private let request: DesktopBarPluginRunRequest
    private let completionQueue: DispatchQueue
    private let lock = NSLock()
    private var pid: pid_t = -1
    private var stdoutCapture: PipeCapture?
    private var stderrCapture: PipeCapture?
    private var processSource: DispatchSourceProcess?
    private var timeoutTimer: DispatchSourceTimer?
    private var killTimer: DispatchSourceTimer?
    private var timedOut = false
    private var completed = false
    private var completionPending = false
    private var completion: ((DesktopBarPluginRunResult) -> Void)?
    private var lifecycleOwner: DesktopBarPluginProcess?
    private let shutdownGroup = DispatchGroup()

    init(request: DesktopBarPluginRunRequest,
         completionQueue: DispatchQueue = .main) {
        self.request = request
        self.completionQueue = completionQueue
    }

    func start(completion: @escaping (DesktopBarPluginRunResult) -> Void) throws {
        var stdoutPipe = [Int32](repeating: -1, count: 2)
        var stderrPipe = [Int32](repeating: -1, count: 2)
        guard pipe(&stdoutPipe) == 0, pipe(&stderrPipe) == 0 else {
            let code = errno
            closePipe(stdoutPipe)
            closePipe(stderrPipe)
            throw DesktopBarPluginProcessError.pipeFailed(code)
        }

        do {
            try setSocketNonBlocking(stdoutPipe[0])
            try setSocketNonBlocking(stderrPipe[0])
            let childPid = try spawn(stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)
            close(stdoutPipe[1])
            close(stderrPipe[1])

            let ioQueue = DispatchQueue(label: "vindu.bar-plugin.\(request.id).io")
            let stdoutCapture = PipeCapture(fd: stdoutPipe[0], queue: ioQueue)
            let stderrCapture = PipeCapture(fd: stderrPipe[0], queue: ioQueue)
            stdoutCapture.start()
            stderrCapture.start()

            lock.lock()
            pid = childPid
            self.stdoutCapture = stdoutCapture
            self.stderrCapture = stderrCapture
            self.completion = completion
            completionPending = true
            shutdownGroup.enter()
            lifecycleOwner = self
            lock.unlock()

            startProcessSource(pid: childPid)
            startTimeout()
        } catch {
            closePipe(stdoutPipe)
            closePipe(stderrPipe)
            throw error
        }
    }

    func terminate() {
        requestTermination(markTimedOut: false)
    }

    func terminateForShutdown() {
        lock.lock()
        let childPid = pid
        let shouldWait = completionPending
        lock.unlock()
        guard shouldWait else { return }

        terminateGroup(pid: childPid, signal: SIGKILL)
        finishOnce()
        shutdownGroup.wait()
    }

    static func pluginEnvironment(for request: DesktopBarPluginRunRequest,
                                  source: [String: String] = ProcessInfo.processInfo.environment)
        -> [String: String] {
        let allowed = ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE"]
        var env: [String: String] = [:]
        for key in allowed {
            if let value = source[key], !value.isEmpty {
                env[key] = value
            }
        }
        for (key, value) in source where key.hasPrefix("LC_") && !value.isEmpty {
            env[key] = value
        }
        env["HOME"] = env["HOME"] ?? NSHomeDirectory()
        env["USER"] = env["USER"] ?? NSUserName()
        env["LOGNAME"] = env["LOGNAME"] ?? NSUserName()
        env["SHELL"] = env["SHELL"] ?? "/bin/sh"
        env["TMPDIR"] = env["TMPDIR"] ?? NSTemporaryDirectory()
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        for (key, value) in request.command.environment {
            env[key] = value
        }
        env["VINDU_BAR_PLUGIN_ID"] = request.id
        env["VINDU_BAR_PLUGIN_REASON"] = request.reason
        env["VINDU_BAR_PLUGIN_EVENT"] = request.eventName
        env["VINDU_BAR_PLUGIN_EVENT_DATA"] = request.eventPayload
        env["VINDU_COMMAND_SOCKET"] = VinduPaths.commandSocketPath
        env["VINDU_EVENT_SOCKET"] = VinduPaths.eventSocketPath
        return env
    }

    private func spawn(stdoutPipe: [Int32], stderrPipe: [Int32]) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        try checkSpawnSetup(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }

        let stdoutRead = stdoutPipe[0]
        let stdoutWrite = stdoutPipe[1]
        let stderrRead = stderrPipe[0]
        let stderrWrite = stderrPipe[1]
        try checkSpawnSetup(posix_spawn_file_actions_adddup2(&actions, stdoutWrite, STDOUT_FILENO))
        try checkSpawnSetup(posix_spawn_file_actions_adddup2(&actions, stderrWrite, STDERR_FILENO))
        try checkSpawnSetup(posix_spawn_file_actions_addclose(&actions, stdoutRead))
        try checkSpawnSetup(posix_spawn_file_actions_addclose(&actions, stderrRead))
        try checkSpawnSetup(posix_spawn_file_actions_addclose(&actions, stdoutWrite))
        try checkSpawnSetup(posix_spawn_file_actions_addclose(&actions, stderrWrite))

        var attrs: posix_spawnattr_t?
        try checkSpawnSetup(posix_spawnattr_init(&attrs))
        defer { posix_spawnattr_destroy(&attrs) }
        let flags = Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)
        try checkSpawnSetup(posix_spawnattr_setflags(&attrs, flags))

        let invocation = Self.invocation(for: request.command)
        let env = Self.pluginEnvironment(for: request)
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
        var childPid: pid_t = -1
        let status = withCStringArray(invocation.arguments) { argvPtr in
            withCStringArray(env) { envPtr in
                posix_spawn(&childPid, invocation.executable, &actions, &attrs, argvPtr, envPtr)
            }
        }
        guard status == 0 else {
            throw DesktopBarPluginProcessError.spawnFailed(status)
        }
        return childPid
    }

    private static func invocation(for command: CommandSpec)
        -> (executable: String, arguments: [String]) {
        switch command.execution {
        case .run(let arguments):
            var arguments = arguments
            if arguments[0].hasPrefix("~/") {
                arguments[0] = NSString(string: arguments[0]).expandingTildeInPath
            }
            return (arguments[0], arguments)
        case .shell(let script):
            return ("/bin/sh", ["/bin/sh", "-lc", script])
        }
    }

    private func checkSpawnSetup(_ status: Int32) throws {
        guard status == 0 else {
            throw DesktopBarPluginProcessError.spawnSetupFailed(status)
        }
    }

    private func startProcessSource(pid: pid_t) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit,
                                                      queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            self?.finishOnce()
        }
        lock.lock()
        processSource = source
        lock.unlock()
        source.resume()
    }

    private func startTimeout() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + .milliseconds(request.timeoutMs))
        timer.setEventHandler { [weak self] in
            self?.requestTermination(markTimedOut: true)
        }
        lock.lock()
        timeoutTimer = timer
        let shouldStart = !completed
        lock.unlock()
        if shouldStart {
            timer.resume()
        } else {
            timer.cancel()
        }
    }

    private func requestTermination(markTimedOut: Bool) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        if markTimedOut {
            timedOut = true
        }
        let childPid = pid
        let needsKillTimer = killTimer == nil
        lock.unlock()

        terminateGroup(pid: childPid, signal: SIGTERM)
        if needsKillTimer {
            scheduleKill(pid: childPid)
        }
    }

    private func scheduleKill(pid: pid_t) {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + .milliseconds(Self.graceMs))
        timer.setEventHandler { [weak self] in
            self?.terminateGroup(pid: pid, signal: SIGKILL)
        }

        lock.lock()
        if completed || killTimer != nil {
            lock.unlock()
            timer.cancel()
            return
        }
        killTimer = timer
        lock.unlock()
        timer.resume()
    }

    private func finishOnce() {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let childPid = pid
        let timeoutTimer = timeoutTimer
        let killTimer = killTimer
        let processSource = processSource
        let stdoutCapture = stdoutCapture
        let stderrCapture = stderrCapture
        let didTimeOut = timedOut
        let completion = completion
        self.timeoutTimer = nil
        self.killTimer = nil
        self.processSource = nil
        self.stdoutCapture = nil
        self.stderrCapture = nil
        self.completion = nil
        lock.unlock()

        timeoutTimer?.cancel()
        killTimer?.cancel()
        processSource?.cancel()
        terminateGroup(pid: childPid, signal: SIGTERM)
        terminateGroup(pid: childPid, signal: SIGKILL)
        let exitCode = reap(pid: childPid)
        let out = stdoutCapture?.finish() ?? Data()
        let err = stderrCapture?.finishString() ?? ""

        if let completion {
            completionQueue.async {
                completion(DesktopBarPluginRunResult(id: self.request.id,
                                                     stdout: out,
                                                     stderr: err,
                                                     exitCode: exitCode,
                                                     timedOut: didTimeOut))
            }
        }

        lock.lock()
        lifecycleOwner = nil
        let shouldLeave = completionPending
        completionPending = false
        lock.unlock()
        if shouldLeave {
            shutdownGroup.leave()
        }
    }

    private func terminateGroup(pid: pid_t, signal: Int32) {
        guard pid > 1 else { return }
        _ = kill(-pid, signal)
    }

    private func reap(pid: pid_t) -> Int32 {
        guard pid > 0 else { return -1 }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            if errno == EINTR { continue }
            return -1
        }
        if status & 0x7f == 0 {
            return (status >> 8) & 0xff
        }
        return -(status & 0x7f)
    }
}

private final class PipeCapture {
    private let fd: Int32
    private let queue: DispatchQueue
    private let source: DispatchSourceRead
    private var data = Data()
    private var closed = false

    init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
        self.source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    }

    func start() {
        source.setEventHandler { [weak self] in
            self?.drain()
        }
        source.resume()
    }

    func finish() -> Data {
        source.cancel()
        return queue.sync {
            drain()
            if !closed {
                close(fd)
                closed = true
            }
            return data
        }
    }

    func finishString() -> String {
        String(data: finish(), encoding: .utf8) ?? ""
    }

    private func drain() {
        guard !closed else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n > 0 {
                let remaining = max(0, BarPluginOutput.maxBytes + 1 - data.count)
                if remaining > 0 {
                    data.append(contentsOf: buffer.prefix(min(n, remaining)))
                }
                continue
            }
            if n == 0 { return }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            return
        }
    }
}

private func closePipe(_ pipe: [Int32]) {
    for fd in pipe where fd >= 0 {
        close(fd)
    }
}

private func withCStringArray<R>(_ strings: [String],
                                 _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?)
                                     -> R) -> R {
    var cStrings = strings.map { strdup($0) }
    cStrings.append(nil)
    defer {
        for ptr in cStrings {
            free(ptr)
        }
    }
    return cStrings.withUnsafeMutableBufferPointer { buffer in
        body(buffer.baseAddress)
    }
}
