import AppKit
import VinduCore

// MARK: - IPC (hyprctl-compatible verbs)

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
        case "keyword":
            let kparts = arg.split(separator: " ", maxSplits: 1).map(String.init)
            guard kparts.count == 2 else { return "err: keyword needs: <name> <value>" }
            if let err = ConfigParser.applyKeyword(kparts[0], kparts[1], to: &doc) {
                return "err: \(err)"
            }
            tap.rebuild(binds: doc.binds)
            arrangeAllVisible()
            return "ok"
        case "reload":
            reloadConfig()
            return "ok"
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
            let infos = doc.binds.map { BindInfo($0, arg: bindArg($0)) }
            return json ? encodeJSON(infos) : infos.map(bindText).joined(separator: "\n")
        case "version":
            let info = VersionInfo(version: VinduVersion.string,
                                   system: "macOS " + ProcessInfo.processInfo.operatingSystemVersionString)
            return json ? encodeJSON(info) : "vindu \(info.version) (\(info.system))"
        case "getoption":
            guard !arg.isEmpty else { return "err: getoption needs a keyword" }
            return settings.get(arg) ?? "err: unknown option \(arg)"
        case "cursorpos":
            let p = NSEvent.mouseLocation
            let y = monitorMgr.primaryHeight - p.y
            return json ? "{\"x\": \(Int(p.x)), \"y\": \(Int(y))}" : "\(Int(p.x)), \(Int(y))"
        case "configerrors":
            if doc.errors.isEmpty { return json ? "[]" : "no errors" }
            return doc.errors.map { "line \($0.line): \($0.message)" }.joined(separator: "\n")
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

    // MARK: Info builders

    func clientInfo(_ id: WindowID) -> ClientInfo? {
        guard let s = windows[id] else { return nil }
        let ws = workspace(forID: s.workspace)
        let monitorIndex = monitorMgr.byID(ws.monitor)?.index ?? 0
        let fullscreen = ws.fullscreen == id ? (ws.fullscreenMode == 0 ? 2 : 1) : 0
        return ClientInfo(
            address: windowAddress(id),
            mapped: !s.minimized,
            hidden: s.hidden,
            at: [Int(s.frame.minX), Int(s.frame.minY)],
            size: [Int(s.frame.width), Int(s.frame.height)],
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
        monitorMgr.monitors.map { m in
            let activeID = activeWS[m.id] ?? 1
            let active = registry.existing(activeID)
            let specialID = shownSpecial[m.id]
            let special = specialID.flatMap { registry.existing($0) }
            return MonitorInfo(
                id: m.index,
                name: m.name,
                width: Int(m.frame.width),
                height: Int(m.frame.height),
                x: Int(m.frame.minX),
                y: Int(m.frame.minY),
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

    private func bindArg(_ b: Bind) -> String {
        switch b.dispatcher {
        case .exec(let c): return c
        case .layoutmsg(let m): return m
        case .closewindow(let m), .focuswindow(let m): return m
        case .submap(let s): return s
        case .togglespecialworkspace(let s): return s
        default: return ""
        }
    }

    func bindText(_ b: BindInfo) -> String {
        let flags = [b.repeats ? "e" : "", b.mouse ? "m" : "", b.release ? "r" : "",
                     b.locked ? "l" : ""].joined()
        let submap = b.submap.isEmpty ? "" : " [submap: \(b.submap)]"
        return "bind\(flags): \(Modifiers(rawValue: UInt8(b.modmask)).described) + \(b.key) -> \(b.dispatcher) \(b.arg)\(submap)"
    }
}

/// Written to ~/.config/vindu/vindu.conf on first launch. ALT is the
/// default mod: SUPER (⌘) works too — bound chords are swallowed before apps
/// see them — but ⌘ collides with too much muscle memory to be a good default.
let defaultConfigTemplate = """
###############################################################################
# vindu — tiling window manager for macOS
# Syntax: section { key = value }, $variables, bind/binde/bindm, windowrulev2.
###############################################################################

$mainMod = ALT

general {
    gaps_in = 5
    gaps_out = 12
    border_size = 2
    col.active_border = rgba(33ccffee) rgba(00ff99ee) 45deg
    col.inactive_border = rgba(595959aa)
    layout = dwindle
}

decoration {
    rounding = 10
}

dwindle {
    preserve_split = true
    default_split_ratio = 1.0
}

master {
    new_status = slave
    mfact = 0.55
    orientation = left
}

input {
    # 1 = focus follows mouse. Best effort on macOS: focusing another app
    # activates it, which can also raise its window. Off by default.
    follow_mouse = 0
}

binds {
    workspace_back_and_forth = true
}

# --- programs --------------------------------------------------------------
bind = $mainMod, return, exec, open -a Terminal
bind = $mainMod, E, exec, open -a Finder
bind = $mainMod SHIFT, Q, killactive,
bind = $mainMod SHIFT, M, exit,

# --- focus / move / swap ----------------------------------------------------
bind = $mainMod, H, movefocus, l
bind = $mainMod, L, movefocus, r
bind = $mainMod, K, movefocus, u
bind = $mainMod, J, movefocus, d
bind = $mainMod SHIFT, H, movewindow, l
bind = $mainMod SHIFT, L, movewindow, r
bind = $mainMod SHIFT, K, movewindow, u
bind = $mainMod SHIFT, J, movewindow, d
bind = $mainMod, tab, cyclenext,
bind = $mainMod SHIFT, tab, cyclenext, prev

# --- layout ------------------------------------------------------------------
bind = $mainMod, V, togglefloating,
bind = $mainMod, F, fullscreen, 1
bind = $mainMod SHIFT, F, fullscreen, 0
bind = $mainMod, T, togglesplit,
bind = $mainMod, P, pin,
bind = $mainMod, C, centerwindow,
bind = $mainMod, M, layoutmsg, swapwithmaster auto

# --- workspaces ---------------------------------------------------------------
bind = $mainMod, 1, workspace, 1
bind = $mainMod, 2, workspace, 2
bind = $mainMod, 3, workspace, 3
bind = $mainMod, 4, workspace, 4
bind = $mainMod, 5, workspace, 5
bind = $mainMod, 6, workspace, 6
bind = $mainMod, 7, workspace, 7
bind = $mainMod, 8, workspace, 8
bind = $mainMod, 9, workspace, 9
bind = $mainMod SHIFT, 1, movetoworkspace, 1
bind = $mainMod SHIFT, 2, movetoworkspace, 2
bind = $mainMod SHIFT, 3, movetoworkspace, 3
bind = $mainMod SHIFT, 4, movetoworkspace, 4
bind = $mainMod SHIFT, 5, movetoworkspace, 5
bind = $mainMod SHIFT, 6, movetoworkspace, 6
bind = $mainMod SHIFT, 7, movetoworkspace, 7
bind = $mainMod SHIFT, 8, movetoworkspace, 8
bind = $mainMod SHIFT, 9, movetoworkspace, 9
bind = $mainMod, bracketleft, workspace, -1
bind = $mainMod, bracketright, workspace, +1

# --- scratchpad ----------------------------------------------------------------
bind = $mainMod, S, togglespecialworkspace, magic
bind = $mainMod SHIFT, S, movetoworkspacesilent, special:magic

# --- resize submap ---------------------------------------------------------------
bind = $mainMod, R, submap, resize
submap = resize
binde = , L, resizeactive, 30 0
binde = , H, resizeactive, -30 0
binde = , K, resizeactive, 0 -30
binde = , J, resizeactive, 0 30
bind = , escape, submap, reset
submap = reset

# --- mouse ------------------------------------------------------------------------
bindm = $mainMod, mouse:272, movewindow
bindm = $mainMod, mouse:273, resizewindow

# --- rules ---------------------------------------------------------------------------
windowrulev2 = float, class:^(System Settings)$
windowrulev2 = float, class:^(Calculator)$
windowrulev2 = float, class:^(Finder)$, title:^(Copy|Move|Info)
"""
