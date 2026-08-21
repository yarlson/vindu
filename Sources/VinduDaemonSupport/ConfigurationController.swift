import Foundation
import VinduCore

public enum ConfigurationActivationResult: Equatable {
    case activated(ConfigurationSnapshot)
    case configurationOnly([LocatedConfigDiagnostic])
    case rejected([LocatedConfigDiagnostic])
}

public final class ConfigurationController {
    public let path: String
    public private(set) var activeSnapshot: ConfigurationSnapshot?
    public private(set) var lastLoadWroteCanonicalDefault = false

    private let loader: NativeConfigurationFileLoader
    private var latestAttemptSucceeded = false
    private var rejectedDiagnostics: [LocatedConfigDiagnostic] = []
    private var runtimeWarnings: [LocatedConfigDiagnostic] = []

    public init(path: String, loader: NativeConfigurationFileLoader = NativeConfigurationFileLoader()) {
        self.path = path
        self.loader = loader
    }

    public func status(daemonState: ConfigDaemonState) -> ConfigStatus {
        ConfigStatus(
            path: path,
            daemonState: daemonState,
            activeSchema: activeSnapshot?.schema,
            latestAttemptSucceeded: latestAttemptSucceeded,
            rejectedDiagnostics: rejectedDiagnostics,
            runtimeWarnings: runtimeWarnings
        )
    }

    @discardableResult
    public func loadDefault(legacyPath: String,
                            canonicalDefault: Data) -> ConfigurationActivationResult {
        lastLoadWroteCanonicalDefault = false
        do {
            switch try loader.loadDefault(nativePath: path,
                                          legacyPath: legacyPath,
                                          canonicalDefault: canonicalDefault) {
            case .loaded(let loaded):
                lastLoadWroteCanonicalDefault = loaded.wroteDefault
                return activate(loaded.snapshot)
            case .legacyOnly(let nativePath, let legacyPath):
                let diagnostic = LocatedConfigDiagnostic(
                    file: legacyPath,
                    message: "legacy configuration exists at \(legacyPath); create \(nativePath) to configure vindu"
                )
                return reject([diagnostic], configurationOnly: activeSnapshot == nil)
            }
        } catch {
            return reject(diagnostics(for: error), configurationOnly: activeSnapshot == nil)
        }
    }

    @discardableResult
    public func loadExplicit() -> ConfigurationActivationResult {
        lastLoadWroteCanonicalDefault = false
        do {
            return activate(try loader.loadExplicit(path: path).snapshot)
        } catch {
            return reject(diagnostics(for: error), configurationOnly: activeSnapshot == nil)
        }
    }

    @discardableResult
    public func reload() -> ConfigurationActivationResult {
        lastLoadWroteCanonicalDefault = false
        do {
            return activate(try loader.loadExplicit(path: path).snapshot)
        } catch {
            return reject(diagnostics(for: error), configurationOnly: activeSnapshot == nil)
        }
    }

    public func replaceRuntimeWarnings(_ warnings: [LocatedConfigDiagnostic]) {
        runtimeWarnings = warnings
    }

    private func activate(_ snapshot: ConfigurationSnapshot) -> ConfigurationActivationResult {
        activeSnapshot = snapshot
        latestAttemptSucceeded = true
        rejectedDiagnostics = []
        runtimeWarnings = []
        return .activated(snapshot)
    }

    private func reject(_ diagnostics: [LocatedConfigDiagnostic],
                        configurationOnly: Bool) -> ConfigurationActivationResult {
        latestAttemptSucceeded = false
        rejectedDiagnostics = diagnostics
        return configurationOnly ? .configurationOnly(diagnostics) : .rejected(diagnostics)
    }

    private func diagnostics(for error: Error) -> [LocatedConfigDiagnostic] {
        guard let loadError = error as? NativeConfigurationLoadError else {
            return [LocatedConfigDiagnostic(file: path, message: error.localizedDescription)]
        }
        switch loadError {
        case .invalid(let file, let failure):
            return failure.diagnostics.map {
                LocatedConfigDiagnostic(file: file,
                                        line: $0.line,
                                        schemaPath: $0.keyPath,
                                        message: $0.message)
            }
        case .missing(let file):
            return [LocatedConfigDiagnostic(file: file, message: "configuration does not exist")]
        case .readFailed(let file, let reason):
            return [LocatedConfigDiagnostic(file: file, message: "cannot read configuration: \(reason)")]
        case .writeFailed(let file, let reason):
            return [LocatedConfigDiagnostic(file: file, message: "cannot write default configuration: \(reason)")]
        }
    }
}
