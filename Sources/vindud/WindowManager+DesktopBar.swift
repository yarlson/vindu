import AppKit
import VinduCore

extension WindowManager {
    // MARK: - Cheat sheet

    func toggleCheatSheet() {
        guard let monitor = monitorMgr.byID(focusedMonitorID) ?? monitorMgr.primary else { return }
        cheatSheet.toggle(rows: BindDisplay.rows(doc.binds),
                          monitorFrame: monitor.usable,
                          primaryHeight: monitorMgr.primaryHeight)
    }

    func showCheatSheetIfHidden() {
        guard let monitor = monitorMgr.byID(focusedMonitorID) ?? monitorMgr.primary else { return }
        cheatSheet.showIfHidden(rows: BindDisplay.rows(doc.binds),
                                monitorFrame: monitor.usable,
                                primaryHeight: monitorMgr.primaryHeight)
    }

    // MARK: - Desktop bar

    func refreshDesktopBar() {
        guard !shutdownRequested, settings.bar.enabled else {
            desktopBarRefreshQueued = false
            desktopBar.hide()
            return
        }
        guard !desktopBarRefreshQueued else { return }
        desktopBarRefreshQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.desktopBarRefreshQueued = false
            self.renderDesktopBar()
        }
    }

    private func renderDesktopBar() {
        guard !shutdownRequested, settings.bar.enabled else {
            desktopBar.hide()
            return
        }
        desktopBar.update(settings: settings.bar,
                          snapshot: desktopBarSnapshot(),
                          primaryHeight: monitorMgr.primaryHeight)
    }

    private func desktopBarSnapshot() -> DesktopBarSnapshot {
        let existing = registry.sorted.filter { !$0.isSpecial }
        let positiveIDs = Set(Array(1...9) + existing.map(\.id).filter { $0 > 0 }).sorted()
        let namedIDs = existing.map(\.id).filter { $0 <= 0 }
        let workspaces = (positiveIDs + namedIDs).map { id -> DesktopBarWorkspace in
            if let ws = registry.existing(id) {
                return DesktopBarWorkspace(id: id, name: ws.name, windows: ws.allWindows.count)
            }
            return DesktopBarWorkspace(id: id, name: String(id), windows: 0)
        }

        let active = focusedWindow.flatMap { windows[$0] }
        let frontmost = NSWorkspace.shared.frontmostApplication
        let requests = DesktopBarSystemInfoRequests(settings: settings.bar)
        return DesktopBarSnapshot(
            monitors: monitorMgr.monitors,
            workspaces: workspaces,
            activeWorkspaces: activeWS,
            appProcessIdentifier: active?.pid ?? frontmost?.processIdentifier,
            appName: active?.clazz ?? frontmost?.localizedName ?? "",
            windowTitle: active?.title ?? "",
            layout: settings.general.layout,
            submap: tap.activeSubmap,
            paused: paused,
            system: DesktopBarSystemInfo.current(requests: requests,
                                                 weather: desktopBarRefresh.currentWeather),
            plugins: desktopBarRefresh.currentPlugins
        )
    }
}
