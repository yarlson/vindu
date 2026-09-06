import AppKit
import VinduCore

extension WindowManager {
    func applyConfiguration(_ snapshot: ConfigurationSnapshot, broadcastReload: Bool = true) {
        finishScrollingGesture()
        cancelViewportAnimation()
        let previousLayout = configuration.layout.kind
        configuration = snapshot
        for workspace in registry.sorted {
            workspace.changeLayout(from: previousLayout, to: snapshot.layout.kind,
                                   container: containerRect(for: workspace),
                                   dwindleConfiguration: snapshot.layout.dwindle,
                                   scrollingConfiguration: snapshot.layout.scrolling)
        }
        tap.rebuild(configuration: snapshot.keyboard)
        let warnings = reconcileWorkspaceAssignments() + scrollingLayoutWarnings()
        runtimeWarningsChanged(warnings)
        let restartedPlugins = applyDesktopUISettings()
        arrangeAllVisible()
        refreshDesktopBar()
        if broadcastReload {
            broadcast(.configreloaded, excludingPlugins: restartedPlugins)
            log("config reloaded")
        }
    }

    func scrollingLayoutWarnings() -> [LocatedConfigDiagnostic] {
        guard configuration.layout.kind == .scrolling,
              monitorMgr.monitors.count > 1,
              !NSScreen.screensHaveSeparateSpaces else { return [] }
        return [LocatedConfigDiagnostic(
            file: configPath,
            schemaPath: "layout.kind",
            message: "scrolling layout needs Displays have separate Spaces with multiple displays; using dwindle"
        )]
    }
}
