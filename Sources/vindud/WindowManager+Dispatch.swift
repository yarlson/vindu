import AppKit
import VinduCore

// MARK: - Dispatchers

extension WindowManager {
    /// Executes one dispatcher; returns "ok" or an error string (IPC reply).
    @discardableResult
    func dispatch(_ dispatcher: Dispatcher) -> String {
        switch dispatcher {
        case .exec(let cmd):
            Exec.run(cmd)
        case .killactive:
            if let id = focusedWindow { bridge.close(id) }
        case .closewindow(let matcher):
            guard let id = findWindow(matching: matcher) else { return "err: no match" }
            bridge.close(id)
        case .exit:
            shutdown()
        case .workspace(let target):
            return switchWorkspace(to: target)
        case .movetoworkspace(let target):
            return moveActiveToWorkspace(target, silent: false)
        case .movetoworkspacesilent(let target):
            return moveActiveToWorkspace(target, silent: true)
        case .togglefloating:
            if let id = focusedWindow, let state = windows[id] { setFloating(id, !state.floating) }
        case .setfloating:
            if let id = focusedWindow { setFloating(id, true) }
        case .settiled:
            if let id = focusedWindow { setFloating(id, false) }
        case .fullscreen(let mode):
            toggleFullscreen(mode: mode)
        case .fakefullscreen:
            if let id = focusedWindow { windows[id]?.fakeFullscreen.toggle() }
        case .movefocus(let dir):
            moveFocus(dir)
        case .movewindow(let arg):
            return moveWindow(arg)
        case .swapwindow(let dir):
            swapWindow(dir)
        case .centerwindow:
            centerActive()
        case .resizeactive(let param):
            return resizeActive(param)
        case .moveactive(let param):
            return moveActive(param)
        case .splitratio(let arg):
            if let id = focusedWindow {
                currentWorkspaceOf(id)?.dwindle.setRatio(arg, at: id)
                arrangeCurrent()
            }
        case .togglesplit:
            if let id = focusedWindow {
                currentWorkspaceOf(id)?.dwindle.toggleSplit(at: id)
                arrangeCurrent()
            }
        case .swapsplit:
            if let id = focusedWindow {
                currentWorkspaceOf(id)?.dwindle.swapSplit(at: id)
                arrangeCurrent()
            }
        case .layoutmsg(let msg):
            return layoutMsg(msg)
        case .togglespecialworkspace(let name):
            return toggleSpecial(name: name)
        case .pin:
            if let id = focusedWindow, windows[id]?.floating == true {
                windows[id]?.pinned.toggle()
            }
        case .cyclenext(let prev):
            cycleFocus(prev: prev)
        case .swapnext(let prev):
            swapAdjacent(prev: prev)
        case .focuswindow(let matcher):
            guard let id = findWindow(matching: matcher), let state = windows[id] else {
                return "err: no match"
            }
            let ws = workspace(forID: state.workspace)
            if !isVisible(ws) {
                _ = switchWorkspace(to: ws.isSpecial
                    ? .special(registry.specialName(forID: ws.id) ?? "special")
                    : .id(ws.id))
            }
            focusWindow(id)
        case .bringactivetotop:
            if let id = focusedWindow { bridge.raise(id) }
        case .alterzorder(let arg):
            if arg.hasPrefix("top"), let id = focusedWindow { bridge.raise(id) }
        case .focusmonitor(let target):
            guard let m = monitorMgr.resolve(target, current: focusedMonitorID) else {
                return "err: no such monitor"
            }
            focusedMonitorID = m.id
            if let wsID = activeWS[m.id], let ws = registry.existing(wsID) {
                if let last = ws.lastFocused ?? ws.allWindows.first {
                    focusWindow(last)
                } else {
                    refreshBorder()
                }
            }
            broadcastFocusedMon()
        case .movecurrentworkspacetomonitor(let target):
            return moveWorkspaceToMonitor(currentWorkspace(), target)
        case .moveworkspacetomonitor(let wsTarget, let monTarget):
            guard let wsID = resolveWorkspaceID(wsTarget, create: false),
                  let ws = registry.existing(wsID) else { return "err: no such workspace" }
            return moveWorkspaceToMonitor(ws, monTarget)
        case .renameworkspace(let id, let name):
            guard let ws = registry.existing(id) else { return "err: no such workspace" }
            ws.name = name
            broadcast(.renameworkspace(id, name))
        case .submap(let name):
            tap.setSubmap(name)
            broadcast(.submap(name))
        case .focuscurrentorlast:
            if let last = focusHistory.dropFirst().first(where: { windows[$0] != nil }) {
                return dispatch(.focuswindow("address:\(windowAddress(last))"))
            }
        case .forcerendererreload:
            arrangeAllVisible()
        case .resizewindow:
            break // only meaningful inside a bindm drag
        }
        return "ok"
    }

    func currentWorkspaceOf(_ id: WindowID) -> WorkspaceState? {
        windows[id].map { workspace(forID: $0.workspace) }
    }

    func arrangeCurrent() {
        if let id = focusedWindow, let ws = currentWorkspaceOf(id) {
            arrange(ws)
        } else {
            arrange(currentWorkspace())
        }
    }

    // MARK: Floating / fullscreen

    func setFloating(_ id: WindowID, _ floating: Bool, keepFrame: Bool = false) {
        guard let state = windows[id], state.floating != floating else { return }
        let ws = workspace(forID: state.workspace)
        state.floating = floating
        if floating {
            ws.removeTiled(id)
            ws.floating.append(id)
            state.floatFrame = keepFrame ? state.frame
                : (state.floatFrame ?? defaultFloatFrame(for: ws))
        } else {
            ws.floating.removeAll { $0 == id }
            state.pinned = false
            insertTiled(id, into: ws)
        }
        broadcast(.changefloatingmode(id, floating))
        arrange(ws)
    }

    func toggleFullscreen(mode: Int) {
        guard let id = focusedWindow, let state = windows[id] else { return }
        let ws = workspace(forID: state.workspace)
        if ws.fullscreen == id && ws.fullscreenMode == mode {
            ws.fullscreen = nil
        } else {
            ws.fullscreen = id
            ws.fullscreenMode = mode
        }
        broadcast(.fullscreen(ws.fullscreen != nil))
        arrange(ws)
    }

    func centerActive() {
        guard let id = focusedWindow, let state = windows[id], state.floating else { return }
        let usable = containerRect(for: workspace(forID: state.workspace))
        var f = state.frame
        f.origin = CGPoint(x: usable.midX - f.width / 2, y: usable.midY - f.height / 2)
        applyFloatingFrame(state, f)
    }

    // MARK: Focus movement

    func moveFocus(_ dir: Direction) {
        let candidates = candidateFrames(excluding: focusedWindow)
        let source: CGRect
        if let id = focusedWindow, let state = windows[id] {
            source = state.frame
        } else if let m = monitorMgr.byID(focusedMonitorID) {
            source = CGRect(x: m.usable.midX, y: m.usable.midY, width: 1, height: 1)
        } else {
            return
        }
        if let next = LayoutMath.neighbor(of: source, in: dir, candidates: candidates) {
            focusWindow(next)
            return
        }
        // No window in that direction on this monitor → cross to the next one.
        if let cur = monitorMgr.byID(focusedMonitorID),
           let m = monitorMgr.neighbor(of: cur, direction: dir) {
            _ = dispatch(.focusmonitor(.id(m.index)))
        }
    }

    private func candidateFrames(excluding: WindowID?) -> [(id: WindowID, rect: CGRect)] {
        visibleWindows(on: focusedMonitorID).compactMap { id in
            guard id != excluding, let state = windows[id], !state.hidden else { return nil }
            return (id, state.frame)
        }
    }

    func cycleFocus(prev: Bool) {
        let visible = visibleWindows(on: focusedMonitorID)
        guard !visible.isEmpty else { return }
        guard let id = focusedWindow, let idx = visible.firstIndex(of: id) else {
            focusWindow(visible[0])
            return
        }
        let n = visible.count
        focusWindow(visible[((idx + (prev ? -1 : 1)) % n + n) % n])
    }

    // MARK: Window movement

    func moveWindow(_ arg: MoveWindowArg) -> String {
        switch arg {
        case .mouse:
            return "ok" // only meaningful inside a bindm drag
        case .monitor(let target):
            guard let id = focusedWindow,
                  let m = monitorMgr.resolve(target, current: focusedMonitorID) else {
                return "err: no such monitor"
            }
            let wsID = activeWS[m.id] ?? 1
            let result = moveWindowToWorkspace(id, target: .id(wsID), silent: true)
            focusedMonitorID = m.id
            focusWindow(id)
            return result
        case .direction(let dir):
            guard let id = focusedWindow, let state = windows[id] else { return "ok" }
            if state.floating {
                snapFloating(id, dir)
                return "ok"
            }
            let ws = workspace(forID: state.workspace)
            if let other = tiledNeighbor(of: id, in: dir) {
                ws.swapTiled(id, other)
                arrange(ws)
                broadcast(.movewindow(id, workspace: ws.name))
                return "ok"
            }
            // At the workspace edge → push to the neighboring monitor.
            if let cur = monitorMgr.byID(focusedMonitorID),
               let m = monitorMgr.neighbor(of: cur, direction: dir) {
                return moveWindow(.monitor(.id(m.index)))
            }
            return "ok"
        }
    }

    private func tiledNeighbor(of id: WindowID, in dir: Direction) -> WindowID? {
        guard let state = windows[id] else { return nil }
        let tiled = candidateFrames(excluding: id).filter {
            windows[$0.id]?.floating == false && windows[$0.id]?.workspace == state.workspace
        }
        return LayoutMath.neighbor(of: state.frame, in: dir, candidates: tiled)
    }

    private func snapFloating(_ id: WindowID, _ dir: Direction) {
        guard let state = windows[id] else { return }
        let usable = containerRect(for: workspace(forID: state.workspace))
        let g = settings.general.gapsOut
        var f = state.frame
        switch dir {
        case .left: f.origin.x = usable.minX + g
        case .right: f.origin.x = usable.maxX - f.width - g
        case .up: f.origin.y = usable.minY + g
        case .down: f.origin.y = usable.maxY - f.height - g
        }
        applyFloatingFrame(state, f)
    }

    func swapWindow(_ dir: Direction) {
        guard let id = focusedWindow, let state = windows[id], !state.floating else { return }
        guard let other = tiledNeighbor(of: id, in: dir) else { return }
        let ws = workspace(forID: state.workspace)
        ws.swapTiled(id, other)
        arrange(ws)
    }

    func swapAdjacent(prev: Bool) {
        guard let id = focusedWindow, let state = windows[id], !state.floating else { return }
        let ws = workspace(forID: state.workspace)
        guard let other = ws.master.cycle(from: id, prev: prev) else { return }
        ws.swapTiled(id, other)
        arrange(ws)
    }

    // MARK: Resize / move active

    /// Pixel deltas → layout-appropriate resize for a tiled window: dwindle
    /// drags the nearest split edges, master adjusts mfact.
    func resizeTiledBy(_ id: WindowID, dx: Double, dy: Double) {
        guard let state = windows[id], !state.floating else { return }
        let ws = workspace(forID: state.workspace)
        switch settings.general.layout {
        case .dwindle:
            ws.dwindle.resize(id, dx: dx, dy: dy)
        case .master:
            let usable = containerRect(for: ws)
            guard usable.width > 1 else { return }
            ws.master.setMfact(.delta(dx / usable.width), settings: settings.master)
        }
    }

    func resizeActive(_ param: ResizeParam) -> String {
        guard let id = focusedWindow, let state = windows[id] else { return "ok" }
        let ws = workspace(forID: state.workspace)
        let usable = containerRect(for: ws)
        switch param {
        case .relative(let dw, let dh):
            let dx = dw.resolved(against: usable.width)
            let dy = dh.resolved(against: usable.height)
            if state.floating {
                var f = state.frame
                f.size.width = max(120, f.width + dx)
                f.size.height = max(90, f.height + dy)
                applyFloatingFrame(state, f)
            } else {
                resizeTiledBy(id, dx: dx, dy: dy)
                arrange(ws)
            }
        case .exact(let w, let h):
            guard state.floating else {
                return "err: resizeactive exact applies to floating windows"
            }
            var f = state.frame
            f.size = CGSize(width: max(120, w.resolved(against: usable.width)),
                            height: max(90, h.resolved(against: usable.height)))
            applyFloatingFrame(state, f)
        }
        return "ok"
    }

    func moveActive(_ param: ResizeParam) -> String {
        guard let id = focusedWindow, let state = windows[id], state.floating else {
            return "err: moveactive applies to floating windows"
        }
        let usable = containerRect(for: workspace(forID: state.workspace))
        var f = state.frame
        switch param {
        case .relative(let dx, let dy):
            f.origin.x += dx.resolved(against: usable.width)
            f.origin.y += dy.resolved(against: usable.height)
        case .exact(let x, let y):
            f.origin = CGPoint(x: usable.minX + x.resolved(against: usable.width),
                               y: usable.minY + y.resolved(against: usable.height))
        }
        applyFloatingFrame(state, f)
        return "ok"
    }

    // MARK: Move to workspace

    func moveActiveToWorkspace(_ target: WorkspaceTarget, silent: Bool) -> String {
        guard let id = focusedWindow else { return "err: no active window" }
        return moveWindowToWorkspace(id, target: target, silent: silent)
    }

    func moveWindowToWorkspace(_ id: WindowID, target: WorkspaceTarget, silent: Bool) -> String {
        guard let state = windows[id] else { return "err: no such window" }
        guard let wsID = resolveWorkspaceID(target, create: true), wsID != state.workspace else {
            return "ok"
        }
        let from = workspace(forID: state.workspace)
        let to = workspace(forID: wsID)
        from.removeWindow(id)
        if state.floating {
            to.floating.append(id)
        } else {
            insertTiled(id, into: to)
        }
        state.workspace = wsID
        to.lastFocused = id
        broadcast(.movewindow(id, workspace: to.name))

        if isVisible(from) { arrange(from) }
        if isVisible(to) {
            arrange(to)
        } else {
            stash(id)
        }
        if !silent {
            _ = switchWorkspace(to: target)
            focusWindow(id)
        } else if isVisible(from), focusedWindow == id {
            focusNextAfterClose(in: from)
        }
        garbageCollect(from)
        return "ok"
    }

    func moveWorkspaceToMonitor(_ ws: WorkspaceState, _ target: MonitorTarget) -> String {
        guard let m = monitorMgr.resolve(target, current: focusedMonitorID) else {
            return "err: no such monitor"
        }
        guard ws.monitor != m.id else { return "ok" }
        let oldMonitor = ws.monitor
        if activeWS[oldMonitor] == ws.id {
            let replacement = replacementWorkspace(for: ws, on: oldMonitor)
            activeWS[oldMonitor] = replacement.id
            arrange(replacement)
        }
        ws.monitor = m.id
        if let displaced = activeWS[m.id], let d = registry.existing(displaced), displaced != ws.id {
            hideWorkspace(d)
            prevWS[m.id] = displaced
        }
        activeWS[m.id] = ws.id
        arrange(ws)
        broadcastFocusedMon()
        return "ok"
    }

    /// The old monitor needs something to show when its visible workspace
    /// leaves: the previous workspace if it still lives there, else the first
    /// id that is free or already homed on that monitor.
    private func replacementWorkspace(for leaving: WorkspaceState,
                                      on monitor: CGDirectDisplayID) -> WorkspaceState {
        if let prevID = prevWS[monitor], prevID != leaving.id,
           let prev = registry.existing(prevID), prev.monitor == monitor {
            return prev
        }
        let freeID = (1...1000).first { id in
            if id == leaving.id { return false }
            guard let existing = registry.existing(id) else { return true }
            return existing.monitor == monitor
        } ?? 1
        return workspace(forID: freeID, createOn: monitor)
    }

    // MARK: layoutmsg

    func layoutMsg(_ msg: String) -> String {
        let parts = msg.split(separator: " ").map(String.init)
        guard let cmd = parts.first else { return "err: empty layoutmsg" }
        let arg = parts.count > 1 ? parts[1] : ""
        guard let id = focusedWindow, let ws = currentWorkspaceOf(id) else {
            return "err: no active window"
        }
        switch cmd {
        case "swapwithmaster":
            ws.master.swapWithMaster(id, mode: arg.isEmpty ? "auto" : arg)
            ws.dwindle.rebuild(from: ws.master.windows,
                               container: containerRect(for: ws), settings: settings.dwindle)
        case "focusmaster":
            if let master = ws.master.windows.first {
                focusWindow(master)
                return "ok"
            }
        case "cyclenext", "cycleprev":
            if let next = ws.master.cycle(from: id, prev: cmd == "cycleprev") {
                focusWindow(next)
                return "ok"
            }
        case "swapnext", "swapprev":
            swapAdjacent(prev: cmd == "swapprev")
            return "ok"
        case "addmaster":
            ws.master.addMaster()
        case "removemaster":
            ws.master.removeMaster()
        case "mfact":
            guard let ratio = SplitRatioArg.parse(arg.isEmpty ? msg : String(msg.dropFirst(cmd.count + 1))) else {
                return "err: mfact needs a value"
            }
            ws.master.setMfact(ratio, settings: settings.master)
        case "orientationleft": ws.master.setOrientation(.left)
        case "orientationright": ws.master.setOrientation(.right)
        case "orientationtop": ws.master.setOrientation(.top)
        case "orientationbottom": ws.master.setOrientation(.bottom)
        case "orientationcenter": ws.master.setOrientation(.center)
        case "orientationnext": ws.master.cycleOrientation(prev: false)
        case "orientationprev": ws.master.cycleOrientation(prev: true)
        case "togglesplit": ws.dwindle.toggleSplit(at: id)
        case "swapsplit": ws.dwindle.swapSplit(at: id)
        default:
            return "err: unknown layoutmsg: \(cmd)"
        }
        arrange(ws)
        return "ok"
    }

    // MARK: Matching

    func findWindow(matching raw: String) -> WindowID? {
        guard let matcher = RuleMatcher.parse(raw) else { return nil }
        // Prefer the focused monitor's visible windows, then everything.
        let visible = visibleWindows(on: focusedMonitorID)
        let ordered = visible + windows.keys.filter { !visible.contains($0) }
        for id in ordered {
            guard let state = windows[id] else { continue }
            let target = MatchTarget(clazz: state.clazz, title: state.title,
                                     initialClass: state.initialClass,
                                     initialTitle: state.initialTitle,
                                     floating: state.floating,
                                     workspaceName: workspace(forID: state.workspace).name,
                                     pid: Int(state.pid))
            if matcher.matches(target, address: id) {
                return id
            }
        }
        return nil
    }

    // MARK: Shutdown

    func shutdown() {
        // Bring every stashed window back where a human can reach it.
        for (id, state) in windows where state.hidden {
            let ws = workspace(forID: state.workspace)
            let container = containerRect(for: ws)
            bridge.setPosition(id, CGPoint(x: container.minX + 40, y: container.minY + 40))
        }
        border.hide()
        ipc?.stop()
        events?.stop()
        watcher?.stop()
        log("exiting")
        exit(0)
    }
}
