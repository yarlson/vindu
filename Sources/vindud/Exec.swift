import Foundation

enum Exec {
    /// `env =` entries from the config, layered over the daemon's environment
    /// for every spawned command.
    static var extraEnv: [String: String] = [:]

    /// Runs a shell command detached, like Hyprland's `exec` dispatcher.
    /// Login shell so PATH additions from the user's profile apply.
    static func run(_ command: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-lc", command]
        var env = ProcessInfo.processInfo.environment
        for (k, v) in extraEnv { env[k] = v }
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            log("exec failed: \(command): \(error.localizedDescription)")
        }
    }

    /// Best-effort user notification. The daemon is a bare executable (no app
    /// bundle), so UserNotifications is unavailable; osascript does the job.
    /// Invoked with argv directly — no shell, so message content can't escape
    /// into a command line. Only AppleScript string escaping applies.
    static func notify(_ message: String) {
        let esc = message
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "display notification \"\(esc)\" with title \"vindu\""]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("[vindu] \(message)\n".utf8))
}
