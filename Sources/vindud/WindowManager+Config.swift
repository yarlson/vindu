import Foundation
import VinduCore
import VinduDaemonSupport

extension WindowManager {
    func loadInitialConfig() -> Bool {
        do {
            let loaded = try ConfigFileLoader().load(path: configPath, defaultText: defaultConfigTemplate)
            applyLoadedConfig(loaded, runExecOnce: true)
            if loaded.wroteDefault {
                wroteDefaultConfig = true
                log("wrote default config to \(configPath)")
            }
            return true
        } catch {
            log("\(error)")
            return false
        }
    }

    @discardableResult
    func reloadConfig() -> Bool {
        switch ConfigFileLoader().reload(path: configPath,
                                         defaultText: defaultConfigTemplate,
                                         previous: doc) {
        case .loaded(let loaded):
            applyLoadedConfig(loaded, runExecOnce: false)
            ensureWorkspacesForMonitors()
            applyDesktopUISettings()
            arrangeAllVisible()
            refreshDesktopBar()
            broadcast(.configreloaded)
            log("config reloaded")
            return true
        case .keptPrevious(let previous, let error):
            doc = previous
            log("\(error)")
            Exec.notify("config reload failed — see configerrors")
            return false
        }
    }

    private func applyLoadedConfig(_ loaded: ConfigFileLoad, runExecOnce: Bool) {
        doc = loaded.document
        for (k, v) in doc.envs {
            setenv(k, v, 1)
        }
        tap.rebuild(binds: doc.binds)
        if !doc.errors.isEmpty {
            for e in doc.errors.prefix(5) {
                log("config:\(e.line): \(e.message)")
            }
            Exec.notify("config has \(doc.errors.count) error(s) — see configerrors")
        }
        if runExecOnce {
            for cmd in doc.execOnce { Exec.run(cmd) }
        }
        for cmd in doc.exec { Exec.run(cmd) }
    }
}
