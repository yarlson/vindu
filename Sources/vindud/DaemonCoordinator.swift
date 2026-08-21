import Foundation
import VinduCore
import VinduDaemonSupport

final class DaemonCoordinator {
    private let controller: ConfigurationController
    private let usesDefaultPath: Bool
    private let requestAccessibility: () -> Void
    private let terminateApplication: () -> Void
    private var ipc: IPCServer?
    private var events: EventBroadcaster?
    private var watcher: ConfigWatcher?
    private var windowManager: WindowManager?
    private var accessibilityRequested = false
    private var accessibilityGranted = false
    private var shuttingDown = false
    private var wroteCanonicalDefault = false

    init(configPath: String,
         usesDefaultPath: Bool,
         requestAccessibility: @escaping () -> Void,
         terminateApplication: @escaping () -> Void) {
        controller = ConfigurationController(path: configPath)
        self.usesDefaultPath = usesDefaultPath
        self.requestAccessibility = requestAccessibility
        self.terminateApplication = terminateApplication
    }

    var configPath: String { controller.path }

    @discardableResult
    func start() -> Bool {
        do {
            let eventBroadcaster = EventBroadcaster(path: VinduPaths.eventSocketPath)
            try eventBroadcaster.start()
            events = eventBroadcaster

            let server = IPCServer(path: VinduPaths.commandSocketPath) { [weak self] request in
                self?.handleIPC(request) ?? "err: shutting down"
            }
            try server.start()
            ipc = server
        } catch {
            log("\(error)")
            stopControlPlane()
            return false
        }

        let result = usesDefaultPath
            ? controller.loadDefault(legacyPath: VinduPaths.legacyConfigPath,
                                     canonicalDefault: Data(defaultConfigTemplate.utf8))
            : controller.loadExplicit()
        wroteCanonicalDefault = controller.lastLoadWroteCanonicalDefault

        let configWatcher = ConfigWatcher(path: controller.path) { [weak self] in
            self?.reloadConfiguration()
        }
        configWatcher.start()
        watcher = configWatcher

        handleActivation(result)
        return true
    }

    func accessibilityDidBecomeAvailable() {
        guard !shuttingDown else { return }
        accessibilityGranted = true
        startWindowManagerIfReady()
    }

    func shutdown() {
        guard !shuttingDown else { return }
        shuttingDown = true
        windowManager?.shutdownRuntime()
        windowManager = nil
        stopControlPlane()
        log("exiting")
        terminateApplication()
    }

    private func stopControlPlane() {
        watcher?.stop()
        watcher = nil
        ipc?.stop()
        ipc = nil
        events?.stop()
        events = nil
    }

    private func handleActivation(_ result: ConfigurationActivationResult) {
        switch result {
        case .activated(let snapshot):
            if let windowManager {
                windowManager.applyConfiguration(snapshot)
            } else {
                requestAccessibilityIfNeeded()
                startWindowManagerIfReady()
            }
        case .configurationOnly(let diagnostics):
            report(diagnostics)
        case .rejected(let diagnostics):
            report(diagnostics)
        }
    }

    private func requestAccessibilityIfNeeded() {
        guard !accessibilityGranted, !accessibilityRequested else { return }
        accessibilityRequested = true
        requestAccessibility()
    }

    private func startWindowManagerIfReady() {
        guard accessibilityGranted,
              windowManager == nil,
              let snapshot = controller.activeSnapshot else { return }
        let manager = WindowManager(
            configuration: snapshot,
            configPath: controller.path,
            wroteCanonicalDefault: wroteCanonicalDefault,
            broadcastEvent: { [weak self] event in self?.events?.broadcast(event) },
            runtimeWarningsChanged: { [weak self] warnings in
                self?.controller.replaceRuntimeWarnings(warnings)
            },
            quit: { [weak self] in self?.shutdown() }
        )
        windowManager = manager
        manager.bootstrap()
    }

    @discardableResult
    private func reloadConfiguration() -> Bool {
        let result = controller.reload()
        handleActivation(result)
        if case .activated = result {
            return true
        }
        return false
    }

    private func handleIPC(_ raw: String) -> String {
        var request = raw
        var json = false
        if let stripped = request.removingPrefix("j/") {
            request = stripped
            json = true
        }
        switch request {
        case "config status":
            return renderStatus(json: json)
        case "config reload":
            return reloadConfiguration() ? "ok" : "err: config reload failed"
        default:
            guard let windowManager else {
                return "err: vindu has no active configuration"
            }
            return windowManager.handleIPC(raw)
        }
    }

    private func renderStatus(json: Bool) -> String {
        let status = controller.status(daemonState: daemonState)
        if json {
            return encodeJSON(status)
        }
        var lines = [
            "path: \(status.path)",
            "daemon state: \(status.daemonState.rawValue)",
            "active schema: \(status.activeSchema.map(String.init) ?? "none")",
            "latest attempt: \(status.latestAttemptSucceeded ? "success" : "rejected")",
        ]
        lines.append(contentsOf: status.rejectedDiagnostics.map { "error: \(format($0))" })
        lines.append(contentsOf: status.runtimeWarnings.map { "warning: \(format($0))" })
        return lines.joined(separator: "\n")
    }

    private var daemonState: ConfigDaemonState {
        if windowManager != nil { return .running }
        if controller.activeSnapshot != nil { return .waitingForAccessibility }
        return .configurationOnly
    }

    private func report(_ diagnostics: [LocatedConfigDiagnostic]) {
        for diagnostic in diagnostics.prefix(5) {
            log(format(diagnostic))
        }
    }

    private func format(_ diagnostic: LocatedConfigDiagnostic) -> String {
        var location = diagnostic.file
        if let line = diagnostic.line { location += ":\(line)" }
        if let schemaPath = diagnostic.schemaPath { location += " [\(schemaPath)]" }
        return "\(location): \(diagnostic.message)"
    }
}
