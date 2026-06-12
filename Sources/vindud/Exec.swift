import Foundation

enum Exec {
    /// Runs a shell command detached, like Hyprland's `exec` dispatcher.
    /// Login shell so PATH additions from the user's profile apply. Children
    /// inherit the daemon environment, including config `env =` entries
    /// applied via setenv.
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
