import AppKit
import VinduCore
import VinduDaemonSupport

let usage = """
vindud — the vindu tiling window manager daemon

USAGE: vindud [-c|--config <path>] [--version] [--help]
       vindud [-c|--config <path>] --install-service
       vindud --uninstall-service   stop starting at login

Config default: \(VinduPaths.defaultConfigPath)
Control it with `vinductl`.
Requires the Accessibility permission (System Settings → Privacy & Security).
"""

enum StartupAction {
    case run
    case installService
    case uninstallService
}

var configPath = VinduPaths.defaultConfigPath
var usesDefaultConfigPath = true
var action = StartupAction.run
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
        configPath = ConfigurationPathResolver.resolve(argv[argIndex])
        usesDefaultConfigPath = false
    case "--version":
        print("vindu \(VinduVersion.string)")
        exit(0)
    case "--install-service":
        action = .installService
    case "--uninstall-service":
        action = .uninstallService
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

switch action {
case .run:
    break
case .installService:
    exit(Service.install(configPath: usesDefaultConfigPath ? nil : configPath))
case .uninstallService:
    exit(Service.uninstall())
}

// Event-socket clients that vanish must not kill the daemon.
signal(SIGPIPE, SIG_IGN)

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: DaemonCoordinator!
    private var accessibilityTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []
    private var shuttingDown = false

    init(configPath: String, usesDefaultConfigPath: Bool) {
        super.init()
        coordinator = DaemonCoordinator(
            configPath: configPath,
            usesDefaultPath: usesDefaultConfigPath,
            requestAccessibility: { [weak self] in self?.waitForAccessibility() },
            terminateApplication: { NSApplication.shared.terminate(nil) }
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSignalHandlers()
        if !coordinator.start() {
            shutdown()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        shutdown()
    }

    private func waitForAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            coordinator.accessibilityDidBecomeAvailable()
            return
        }
        log("waiting for Accessibility permission (System Settings → Privacy & Security → Accessibility)")
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            if AXIsProcessTrusted() {
                timer.invalidate()
                self?.accessibilityTimer = nil
                self?.coordinator.accessibilityDidBecomeAvailable()
            }
        }
    }

    private func installSignalHandlers() {
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        for sig in [SIGTERM, SIGINT] {
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in self?.shutdown() }
            source.resume()
            signalSources.append(source)
        }
    }

    private func shutdown() {
        guard !shuttingDown else { return }
        shuttingDown = true
        accessibilityTimer?.invalidate()
        accessibilityTimer = nil
        signalSources.removeAll()
        coordinator.shutdown()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate(configPath: configPath, usesDefaultConfigPath: usesDefaultConfigPath)
app.delegate = delegate
app.run()
