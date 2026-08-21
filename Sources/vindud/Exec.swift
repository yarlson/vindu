import Foundation
import VinduCore

enum Exec {
    static func run(_ command: CommandSpec) {
        let process = Process()
        let label: String
        switch command.execution {
        case .run(let arguments):
            guard let executable = arguments.first else { return }
            let expanded = (executable as NSString).expandingTildeInPath
            process.executableURL = URL(fileURLWithPath: expanded)
            process.arguments = Array(arguments.dropFirst())
            label = expanded
        case .shell(let script):
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-lc", script]
            label = "/bin/sh"
        }
        process.environment = ProcessInfo.processInfo.environment.merging(command.environment) {
            _, configured in configured
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            log("exec failed: \(label): \(error.localizedDescription)")
        }
    }

    /// Runs a retained public dispatcher command through the user's login shell.
    /// Children inherit the daemon environment.
    static func run(_ command: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-lc", command]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            log("exec failed: \(command): \(error.localizedDescription)")
        }
    }

    /// Runs an executable with argv directly — no shell, so arguments (paths
    /// with quotes or spaces, user-supplied text) cannot escape into a
    /// command line.
    static func run(_ executable: String, args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            log("exec failed: \(executable): \(error.localizedDescription)")
        }
    }

    /// Best-effort user notification. The daemon is a bare executable (no app
    /// bundle), so UserNotifications is unavailable; osascript does the job.
    /// Argv invocation means only AppleScript string escaping applies.
    static func notify(_ message: String) {
        let esc = message
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        run("/usr/bin/osascript",
            args: ["-e", "display notification \"\(esc)\" with title \"vindu\""])
    }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("[vindu] \(message)\n".utf8))
}
