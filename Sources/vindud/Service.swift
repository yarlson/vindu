import Foundation
import VinduDaemonSupport

/// Self-service launchd management: writes a LaunchAgent pointing at the
/// current binary and (un)registers it with launchctl, so "start at login"
/// is one command instead of a plist-copying ritual.
enum Service {
    static let label = "com.vindu.daemon"

    static var plistPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist"
    }

    static func install(configPath: String?) -> Int32 {
        guard let binary = Bundle.main.executableURL?.resolvingSymlinksInPath().path else {
            log("cannot resolve own binary path")
            return 1
        }
        let logPath = VinduLogPaths.daemonLogPath()
        do {
            try LaunchAgentPlist.write(binaryPath: binary,
                                       configPath: configPath,
                                       logPath: logPath,
                                       to: plistPath)
        } catch {
            log("cannot write \(plistPath): \(error.localizedDescription)")
            return 1
        }
        // Re-installs must not fail because the service is already loaded.
        _ = launchctl("bootout", "gui/\(getuid())/\(label)")
        let status = launchctl("bootstrap", "gui/\(getuid())", plistPath)
        if status == 0 {
            print("service installed: \(plistPath)")
            print("vindu is running and will start at login (logs: \(logPath))")
        } else {
            log("launchctl bootstrap failed (\(status))")
        }
        return status
    }

    static func uninstall() -> Int32 {
        _ = launchctl("bootout", "gui/\(getuid())/\(label)")
        try? FileManager.default.removeItem(atPath: plistPath)
        print("service removed; vindu will no longer start at login")
        return 0
    }

    private static func launchctl(_ args: String...) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return 1
        }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
