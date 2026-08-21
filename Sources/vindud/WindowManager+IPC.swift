import AppKit
import VinduCore

// MARK: - Public IPC

extension WindowManager {
    func handleIPC(_ raw: String) -> String {
        var request = raw
        var json = false
        if let stripped = request.removingPrefix("j/") {
            request = stripped
            json = true
        }
        let parts = request.split(separator: " ", maxSplits: 1).map(String.init)
        guard let cmd = parts.first, !cmd.isEmpty else { return "err: empty request" }
        let arg = parts.count > 1 ? parts[1] : ""

        switch cmd {
        case "dispatch":
            let dparts = arg.split(separator: " ", maxSplits: 1).map(String.init)
            guard let name = dparts.first, !name.isEmpty else {
                return "err: dispatch needs a dispatcher"
            }
            switch Dispatcher.parse(name: name, args: dparts.count > 1 ? dparts[1] : "") {
            case .success(let d): return dispatch(d)
            case .failure(let e): return "err: \(e.message)"
            }
        case "barplugin":
            return handleBarPluginIPC(arg)
        case "clients":
            let infos = clientInfos()
            return json ? encodeJSON(infos) : infos.map(clientText).joined(separator: "\n")
        case "workspaces":
            let infos = workspaceInfos()
            return json ? encodeJSON(infos) : infos.map(workspaceText).joined(separator: "\n")
        case "activeworkspace":
            let ws = currentWorkspace()
            let info = workspaceInfo(ws)
            return json ? encodeJSON(info) : workspaceText(info)
        case "monitors":
            let infos = monitorInfos()
            return json ? encodeJSON(infos) : infos.map(monitorText).joined(separator: "\n")
        case "activewindow":
            guard let id = focusedWindow, let info = clientInfo(id) else {
                return json ? "{}" : "no active window"
            }
            return json ? encodeJSON(info) : clientText(info)
        case "binds":
            let infos = BindDisplay.bindInfoProjection(
                configuration.keyboard.bindings,
                pointerBindings: configuration.keyboard.pointerBindings
            )
            return json ? encodeJSON(infos) : infos.map(bindText).joined(separator: "\n")
        case "version":
            let info = VersionInfo(version: VinduVersion.string,
                                   system: "macOS " + ProcessInfo.processInfo.operatingSystemVersionString)
            return json ? encodeJSON(info) : "vindu \(info.version) (\(info.system))"
        case "cursorpos":
            let p = NSEvent.mouseLocation
            let y = monitorMgr.primaryHeight - p.y
            guard let x = checkedGeometryInt(p.x), let y = checkedGeometryInt(y) else {
                return "err: invalid cursor position"
            }
            return json ? "{\"x\": \(x), \"y\": \(y)}" : "\(x), \(y)"
        case "splash":
            return "vindu — from Old Norse vindauga: the wind-eye"
        case "notify":
            Exec.notify(arg.isEmpty ? "ping" : arg)
            return "ok"
        case "dismissnotify":
            return "ok"
        case "kill":
            return "err: kill (click-to-close picker) is not possible on macOS"
        case "reloadshaders", "setcursor", "output", "switchxkblayout", "setprop", "plugin",
             "globalshortcuts", "instances", "layers", "devices", "decorations", "rollinglog",
             "systeminfo":
            return "err: \(cmd) has no macOS equivalent"
        default:
            return "err: unknown request: \(cmd)"
        }
    }

    private func handleBarPluginIPC(_ arg: String) -> String {
        let parts = arg.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.first == "refresh" else {
            return "err: barplugin needs: refresh <id>"
        }
        guard parts.count == 2, !parts[1].isEmpty else {
            return "err: bar plugin id required"
        }
        guard desktopBarRefresh.refreshPlugin(id: parts[1]) else {
            return "err: unknown bar plugin: \(parts[1])"
        }
        return "ok"
    }

    // MARK: Info builders

    func clientInfo(_ id: WindowID) -> ClientInfo? {
        guard let s = windows[id], let frame = windowFrameValues(s.frame) else { return nil }
        let ws = workspace(forID: s.workspace)
        let monitorIndex = monitorMgr.byID(ws.monitor)?.index ?? 0
        let fullscreen = ws.fullscreen == id ? (ws.fullscreenMode == 0 ? 2 : 1) : 0
        return ClientInfo(
            address: windowAddress(id),
            mapped: !s.minimized,
            hidden: s.hidden,
            at: [frame.x, frame.y],
            size: [frame.width, frame.height],
            workspace: WorkspaceRef(id: ws.id, name: ws.name),
            floating: s.floating,
            pinned: s.pinned,
            fullscreen: fullscreen,
            fakeFullscreen: s.fakeFullscreen,
            monitor: monitorIndex,
            clazz: s.clazz,
            title: s.title,
            initialClass: s.initialClass,
            initialTitle: s.initialTitle,
            pid: Int(s.pid),
            focusHistoryID: focusHistory.firstIndex(of: id) ?? -1
        )
    }

    func clientInfos() -> [ClientInfo] {
        windows.keys.sorted().compactMap(clientInfo)
    }

    func clientText(_ c: ClientInfo) -> String {
        """
        Window \(c.address) -> \(c.clazz): \(c.title)
            at: \(c.at[0]),\(c.at[1])
            size: \(c.size[0]),\(c.size[1])
            workspace: \(c.workspace.id) (\(c.workspace.name))
            floating: \(c.floating ? 1 : 0)
            pinned: \(c.pinned ? 1 : 0)
            fullscreen: \(c.fullscreen)
            monitor: \(c.monitor)
            pid: \(c.pid)
            hidden: \(c.hidden ? 1 : 0)
        """
    }

    func workspaceInfo(_ ws: WorkspaceState) -> WorkspaceInfo {
        let monitor = monitorMgr.byID(ws.monitor)
        let last = ws.lastFocused
        return WorkspaceInfo(
            id: ws.id,
            name: ws.name,
            monitor: monitor?.name ?? "",
            monitorID: monitor?.index ?? 0,
            windows: ws.allWindows.count,
            hasfullscreen: ws.fullscreen != nil,
            lastwindow: last.map(windowAddress) ?? "0x0",
            lastwindowtitle: last.flatMap { windows[$0]?.title } ?? ""
        )
    }

    func workspaceInfos() -> [WorkspaceInfo] {
        registry.sorted.map(workspaceInfo)
    }

    func workspaceText(_ w: WorkspaceInfo) -> String {
        """
        workspace ID \(w.id) (\(w.name)) on monitor \(w.monitor):
            windows: \(w.windows)
            hasfullscreen: \(w.hasfullscreen ? 1 : 0)
            lastwindow: \(w.lastwindow)
            lastwindowtitle: \(w.lastwindowtitle)
        """
    }

    func monitorInfos() -> [MonitorInfo] {
        monitorMgr.monitors.compactMap { m in
            guard let frame = windowFrameValues(m.frame), m.scale.isFinite, m.scale > 0 else {
                return nil
            }
            let activeID = activeWS[m.id] ?? 1
            let active = registry.existing(activeID)
            let specialID = shownSpecial[m.id]
            let special = specialID.flatMap { registry.existing($0) }
            return MonitorInfo(
                id: m.index,
                name: m.name,
                width: frame.width,
                height: frame.height,
                x: frame.x,
                y: frame.y,
                activeWorkspace: WorkspaceRef(id: activeID, name: active?.name ?? String(activeID)),
                specialWorkspace: WorkspaceRef(id: specialID ?? 0, name: special?.name ?? ""),
                scale: m.scale,
                focused: m.id == focusedMonitorID
            )
        }
    }

    func monitorText(_ m: MonitorInfo) -> String {
        """
        Monitor \(m.name) (ID \(m.id)):
            \(m.width)x\(m.height) at \(m.x),\(m.y), scale \(m.scale)
            active workspace: \(m.activeWorkspace.id) (\(m.activeWorkspace.name))
            special workspace: \(m.specialWorkspace.id) (\(m.specialWorkspace.name))
            focused: \(m.focused ? "yes" : "no")
        """
    }

    func bindText(_ b: BindInfo) -> String {
        let flags = [b.repeats ? "e" : "", b.mouse ? "m" : "", b.release ? "r" : "",
                     b.locked ? "l" : ""].joined()
        let submap = b.submap.isEmpty ? "" : " [submap: \(b.submap)]"
        var modifiers: [String] = []
        if b.modmask & (1 << 3) != 0 { modifiers.append("SUPER") }
        if b.modmask & (1 << 2) != 0 { modifiers.append("ALT") }
        if b.modmask & (1 << 1) != 0 { modifiers.append("CTRL") }
        if b.modmask & (1 << 0) != 0 { modifiers.append("SHIFT") }
        return "bind\(flags): \(modifiers.joined(separator: " ")) + \(b.key) -> \(b.dispatcher) \(b.arg)\(submap)"
    }
}
