import AppKit
import VinduCore

let usage = """
vindud — the vindu tiling window manager daemon

USAGE: vindud [-c|--config <path>] [--version] [--help]
       vindud --install-service     run now and at every login (LaunchAgent)
       vindud --uninstall-service   stop starting at login

Config default: \(VinduPaths.defaultConfigPath)
Control it with `vinductl`.
Requires the Accessibility permission (System Settings → Privacy & Security).
"""

var configPath = VinduPaths.defaultConfigPath
var argIndex = 1
let argv = CommandLine.arguments
while argIndex < argv.count {
    switch argv[argIndex] {
    case "-c", "--config":
        argIndex += 1
        guard argIndex < argv.count else {
            log("missing path after \(argv[argIndex - 1])")
            exit(2)
        }
        configPath = (argv[argIndex] as NSString).expandingTildeInPath
    case "--version":
        print("vindu \(VinduVersion.string)")
        exit(0)
    case "--install-service":
        exit(Service.install())
    case "--uninstall-service":
        exit(Service.uninstall())
    case "-h", "--help":
        print(usage)
        exit(0)
    default:
        log("unknown argument: \(argv[argIndex])")
        print(usage)
        exit(2)
    }
    argIndex += 1
}

// Event-socket clients that vanish must not kill the daemon.
signal(SIGPIPE, SIG_IGN)

final class AppDelegate: NSObject, NSApplicationDelegate {
    let wm: WindowManager

    init(configPath: String) {
        self.wm = WindowManager(configPath: configPath)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        waitForAccessibility()
    }

    /// AX and event taps are dead without the Accessibility grant; prompt once
    /// and poll so first-run users can flip the toggle without restarting.
    private func waitForAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            wm.bootstrap()
            return
        }
        log("waiting for Accessibility permission (System Settings → Privacy & Security → Accessibility)")
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            if AXIsProcessTrusted() {
                timer.invalidate()
                self?.wm.bootstrap()
            }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate(configPath: configPath)
app.delegate = delegate
app.run()
