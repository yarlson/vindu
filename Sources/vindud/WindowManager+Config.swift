import VinduCore

extension WindowManager {
    func applyConfiguration(_ snapshot: ConfigurationSnapshot, broadcastReload: Bool = true) {
        configuration = snapshot
        tap.rebuild(configuration: snapshot.keyboard)
        let warnings = reconcileWorkspaceAssignments()
        runtimeWarningsChanged(warnings)
        let restartedPlugins = applyDesktopUISettings()
        arrangeAllVisible()
        refreshDesktopBar()
        if broadcastReload {
            broadcast(.configreloaded, excludingPlugins: restartedPlugins)
            log("config reloaded")
        }
    }
}
