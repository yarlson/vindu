import AppKit
import VinduCore

/// Per-window state the WM owns; geometry lives in top-left-origin coords.
final class WindowState {
    let id: WindowID
    let pid: pid_t
    let initialClass: String
    let initialTitle: String
    var clazz: String
    var title: String
    var workspace: Int
    /// Desired frame for tiled windows; live frame for floating ones.
    var frame: CGRect
    var floating = false
    var pinned = false
    var fakeFullscreen = false
    var minimized = false
    /// In native macOS fullscreen: the window lives on its own Space, outside
    /// the layout, until it comes back.
    var nativeFullscreen = false
    /// Stashed off-screen because its workspace is not visible.
    var hidden = false
    var floatFrame: CGRect?

    init(id: WindowID, pid: pid_t, clazz: String, title: String, workspace: Int, frame: CGRect) {
        self.id = id
        self.pid = pid
        self.clazz = clazz
        self.title = title
        self.initialClass = clazz
        self.initialTitle = title
        self.workspace = workspace
        self.frame = frame
    }
}

/// The window manager. Single-threaded on the main queue: AX events, hotkey
/// dispatch, and IPC requests all funnel here.
final class WindowManager {
    let bridge = AXBridge()
    let monitorMgr = MonitorManager()
    let tap = HotkeyTap()
    let border = BorderOverlay()
    let statusItem = StatusItem()
    let desktopBar = DesktopBar()
    let desktopBarRefresh = DesktopBarRefreshCoordinator()
    let cheatSheet = CheatSheet()
    let registry = WorkspaceRegistry()
    var ipc: IPCServer?
    var events: EventBroadcaster?
    var watcher: ConfigWatcher?

    let configPath: String
    var doc = ConfigDocument()
    var settings: Settings { doc.settings }
    /// Tiling suspended (`pause` dispatcher): no frame enforcement, non-pause
    /// chords pass through. Resume reasserts the grid.
    private(set) var paused = false
    /// True when this launch wrote the default config — i.e. a first run.
    private var wroteDefaultConfig = false

    var windows: [WindowID: WindowState] = [:]
    /// Visible (non-special) workspace per monitor.
    var activeWS: [CGDirectDisplayID: Int] = [:]
    var prevWS: [CGDirectDisplayID: Int] = [:]
    /// Special workspace currently overlaid per monitor.
    var shownSpecial: [CGDirectDisplayID: Int] = [:]
    var focusedWindow: WindowID?
    var focusedMonitorID: CGDirectDisplayID = 0
    var focusHistory: [WindowID] = []

    var drag: DragSession?
    var lastDragApply = 0.0
    private var lastReassert: [WindowID: Double] = [:]
    private var lastFullscreenPoll: [WindowID: Double] = [:]
    private var settleWork: [WindowID: DispatchWorkItem] = [:]
    /// Last explicit switch gesture (⌘Tab, Dock click). Activations that
    /// follow one are user intent and may switch workspaces.
    private var lastUserGesture = 0.0

    init(configPath: String) {
        self.configPath = configPath
        registry.onCreate = { [weak self] ws in self?.broadcast(.createworkspace(ws.name)) }
        registry.onDestroy = { [weak self] ws in self?.broadcast(.destroyworkspace(ws.name)) }
    }

    // MARK: - Bootstrap

    func bootstrap() {
        loadConfig(runExecOnce: true)
        monitorMgr.start()
        monitorMgr.onChange = { [weak self] in self?.monitorsChanged() }
        ensureWorkspacesForMonitors()
        focusedMonitorID = monitorMgr.primary?.id ?? 0

        bridge.delegate = self
        bridge.start()

        tap.onDispatcher = { [weak self] dispatcher in _ = self?.dispatch(dispatcher) }
        tap.onMouseDrag = { [weak self] dispatcher, point, phase in
            self?.handleDrag(dispatcher: dispatcher, point: point, phase: phase)
        }
        tap.onRawLeftMouse = { [weak self] point, phase in
            self?.handleRawLeftMouse(point, phase)
        }
        tap.onUserGesture = { [weak self] in self?.lastUserGesture = CFAbsoluteTimeGetCurrent() }
        tap.onMouseMoved = { [weak self] point in self?.followMouse(point) }
        if !tap.start() {
            log("event tap unavailable — check Accessibility permission; binds disabled")
        }

        do {
            ipc = IPCServer(path: VinduPaths.commandSocketPath) { [weak self] req in
                self?.handleIPC(req) ?? "err: shutting down"
            }
            try ipc?.start()
            events = EventBroadcaster(path: VinduPaths.eventSocketPath)
            try events?.start()
        } catch {
            log("\(error)")
            if case IPCError.alreadyRunning = error {
                exit(1)
            }
        }

        watcher = ConfigWatcher(path: configPath) { [weak self] in self?.reloadConfig() }
        watcher?.start()

        statusItem.onPauseToggle = { [weak self] in _ = self?.dispatch(.pause(.toggle)) }
        statusItem.onShowKeybindings = { [weak self] in self?.toggleCheatSheet() }
        statusItem.onOpenConfig = { [weak self] in
            guard let self else { return }
            Exec.run("/usr/bin/open", args: ["-t", self.configPath])
        }
        statusItem.onQuit = { [weak self] in self?.shutdown() }
        desktopBar.onWorkspaceSelected = { [weak self] workspaceID, monitorID in
            guard let self else { return }
            self.focusedMonitorID = monitorID
            _ = self.dispatch(.workspace(.id(workspaceID)))
        }
        desktopBarRefresh.onChange = { [weak self] in self?.refreshDesktopBar() }
        applyDesktopUISettings()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.activeSpaceChanged()
        }

        arrangeAllVisible()
        refreshDesktopBar()
        if let focused = bridge.systemFocusedWindowID() {
            windowFocused(focused)
        }
        // First run: nobody knows the chords yet — show the cheat sheet once
        // the initial tiling has settled.
        if wroteDefaultConfig {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.toggleCheatSheet()
            }
        }
        log("ready — \(monitorMgr.monitors.count) monitor(s), socket \(VinduPaths.commandSocketPath)")
    }

    func loadConfig(runExecOnce: Bool) {
        let parser = ConfigParser()
        let text = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? defaultConfigTemplate
        if !FileManager.default.fileExists(atPath: configPath) {
            try? FileManager.default.createDirectory(
                atPath: (configPath as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            try? defaultConfigTemplate.write(toFile: configPath, atomically: true, encoding: .utf8)
            wroteDefaultConfig = true
            log("wrote default config to \(configPath)")
        }
        doc = parser.parse(text: text, baseDir: (configPath as NSString).deletingLastPathComponent)
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

    func reloadConfig() {
        loadConfig(runExecOnce: false)
        ensureWorkspacesForMonitors()
        applyDesktopUISettings()
        arrangeAllVisible()
        refreshDesktopBar()
        broadcast(.configreloaded)
        log("config reloaded")
    }

    func applyDesktopUISettings() {
        statusItem.setVisible(settings.misc.menuBar)
        desktopBarRefresh.sync(settings: settings.bar)
        refreshDesktopBar()
    }

    // MARK: - Workspace bookkeeping

    /// Default workspace ids 1…N map onto monitors in order, unless a
    /// `workspace = N, monitor:Name` rule pins them elsewhere.
    func ensureWorkspacesForMonitors() {
        for (i, m) in monitorMgr.monitors.enumerated() where activeWS[m.id] == nil {
            let ws = workspace(forID: i + 1, createOn: m.id)
            ws.monitor = m.id
            activeWS[m.id] = ws.id
        }
    }

    func workspace(forID id: Int, createOn monitor: CGDirectDisplayID? = nil) -> WorkspaceState {
        registry.workspace(forID: id,
                           monitor: monitor ?? boundMonitor(forWorkspace: id) ?? focusedMonitorID)
    }

    private func boundMonitor(forWorkspace id: Int) -> CGDirectDisplayID? {
        for rule in doc.workspaceRules {
            if case .id(let n) = rule.target, n == id, let name = rule.monitorName {
                return monitorMgr.monitors.first {
                    $0.name.localizedCaseInsensitiveContains(name)
                }?.id
            }
        }
        return nil
    }

    func resolveWorkspaceID(_ target: WorkspaceTarget, create: Bool) -> Int? {
        registry.resolveID(target,
                           currentID: activeWS[focusedMonitorID] ?? 1,
                           previousID: prevWS[focusedMonitorID],
                           monitor: focusedMonitorID,
                           create: create)
    }

    func currentWorkspace() -> WorkspaceState {
        workspace(forID: activeWS[focusedMonitorID] ?? 1)
    }

    func isVisible(_ ws: WorkspaceState) -> Bool {
        if ws.isSpecial {
            return shownSpecial[ws.monitor] == ws.id
        }
        return activeWS[ws.monitor] == ws.id
    }

    func garbageCollect(_ ws: WorkspaceState) {
        let isBound = doc.workspaceRules.contains {
            if case .id(let n) = $0.target { return n == ws.id }
            return false
        }
        registry.destroyIfEmpty(ws, isVisible: isVisible(ws), isBound: isBound)
    }

    // MARK: - Arrange

    func containerRect(for ws: WorkspaceState) -> CGRect {
        guard let monitor = monitorMgr.byID(ws.monitor) ?? monitorMgr.primary else { return .zero }
        let usable = DesktopBar.contentRect(for: monitor, settings: settings.bar)
        if ws.isSpecial {
            // Scratchpad overlay floats inside the monitor like Hyprland's
            // special workspace.
            return usable.insetBy(dx: usable.width * 0.08,
                                  dy: usable.height * 0.08)
        }
        return usable
    }

    /// `excluding` skips one window's frame (a tile mid-drag follows the mouse
    /// while the rest of the workspace re-flows around it).
    func arrange(_ ws: WorkspaceState, excluding: WindowID? = nil) {
        guard isVisible(ws), !paused else { return }
        let container = containerRect(for: ws)
        let g = settings.general

        let raw: [WindowID: CGRect]
        switch g.layout {
        case .dwindle:
            raw = ws.dwindle.frames(in: container)
        case .master:
            raw = ws.master.frames(in: container, settings: settings.master)
        }

        for (id, rect) in raw {
            guard id != excluding, let state = windows[id], !state.minimized else { continue }
            var frame = LayoutMath.applyGaps(to: rect, within: container,
                                             gapsIn: g.gapsIn, gapsOut: g.gapsOut)
            frame = frame.insetBy(dx: g.borderSize, dy: g.borderSize)
            if ws.fullscreen == id {
                frame = fullscreenFrame(for: ws)
            }
            state.frame = frame
            state.hidden = false
            bridge.setFrame(id, frame)
        }

        for id in ws.floating {
            guard let state = windows[id], !state.minimized, !state.nativeFullscreen else { continue }
            var frame = state.floatFrame ?? defaultFloatFrame(for: ws)
            if ws.fullscreen == id {
                frame = fullscreenFrame(for: ws)
            }
            state.frame = frame
            state.hidden = false
            bridge.setFrame(id, frame)
        }

        if let fs = ws.fullscreen {
            bridge.raise(fs)
        }
        if ws.isSpecial {
            for id in ws.allWindows { bridge.raise(id) }
        }
        refreshBorder()
    }

    func arrangeAllVisible() {
        for m in monitorMgr.monitors {
            if let id = activeWS[m.id], let ws = registry.existing(id) {
                arrange(ws)
            }
            if let id = shownSpecial[m.id], let ws = registry.existing(id) {
                arrange(ws)
            }
        }
    }

    func fullscreenFrame(for ws: WorkspaceState) -> CGRect {
        guard let monitor = monitorMgr.byID(ws.monitor) ?? monitorMgr.primary else { return .zero }
        // Mode 0: the whole display (the OS clamps below the menu bar — the
        // window server owns that strip). Mode 1: maximize, respecting gaps.
        if ws.fullscreenMode == 0 {
            return monitor.frame
        }
        let g = settings.general
        return monitor.usable.insetBy(dx: g.gapsOut, dy: g.gapsOut)
    }

    func defaultFloatFrame(for ws: WorkspaceState) -> CGRect {
        let usable = containerRect(for: ws)
        return CGRect(x: usable.midX - usable.width * 0.3,
                      y: usable.midY - usable.height * 0.35,
                      width: usable.width * 0.6,
                      height: usable.height * 0.7)
    }

    // MARK: - Hide/show (virtual workspaces)

    /// macOS has no per-space window membership we can drive without disabling
    /// SIP, so invisible workspaces stash windows in the monitor's bottom-right
    /// corner and restore frames on show.
    func stash(_ id: WindowID) {
        // Repositioning a native-fullscreen window would rip it out of its
        // Space; it isn't on our screen anyway.
        guard !paused, let state = windows[id], !state.hidden, !state.nativeFullscreen else { return }
        guard let monitor = monitorMgr.byID(workspace(forID: state.workspace).monitor)
                ?? monitorMgr.primary else { return }
        state.hidden = true
        bridge.setPosition(id, CGPoint(x: monitor.frame.maxX - 2, y: monitor.frame.maxY - 2))
    }

    func hideWorkspace(_ ws: WorkspaceState) {
        for id in ws.allWindows where windows[id]?.pinned != true {
            stash(id)
        }
    }

    func showWorkspace(_ ws: WorkspaceState) {
        arrange(ws)
        let candidate = ws.lastFocused.flatMap { windows[$0] != nil ? $0 : nil }
            ?? ws.allWindows.first
        if let id = candidate {
            focusWindow(id)
        } else {
            clearFocus()
        }
    }

    func switchWorkspace(to target: WorkspaceTarget) -> String {
        var resolved = target
        let mon = focusedMonitorID
        let currentID = activeWS[mon] ?? 1
        if case .id(let n) = target, n == currentID, settings.binds.workspaceBackAndForth,
           let prev = prevWS[mon] {
            resolved = .id(prev)
        }
        guard let wsID = resolveWorkspaceID(resolved, create: true) else { return "ok" }
        if wsID == currentID, let ws = registry.existing(wsID), isVisible(ws) {
            return "ok"
        }
        let ws = workspace(forID: wsID)
        if ws.isSpecial {
            return toggleSpecial(name: registry.specialName(forID: wsID) ?? "special")
        }

        if ws.monitor != mon, isVisible(ws) {
            // Visible on another monitor → focus that monitor instead.
            focusedMonitorID = ws.monitor
            showWorkspace(ws)
            broadcastFocusedMon()
            return "ok"
        }
        if ws.monitor != mon {
            focusedMonitorID = ws.monitor
        }
        let targetMon = ws.monitor
        let oldID = activeWS[targetMon]
        if let oldID, let old = registry.existing(oldID), oldID != wsID {
            hideWorkspace(old)
            prevWS[targetMon] = oldID
            migratePinned(from: old, to: ws)
        }
        activeWS[targetMon] = wsID
        showWorkspace(ws)
        broadcast(.workspace(ws.name))
        broadcast(.workspacev2(ws.id, ws.name))
        if let oldID, let old = registry.existing(oldID) {
            garbageCollect(old)
        }
        return "ok"
    }

    private func migratePinned(from old: WorkspaceState, to new: WorkspaceState) {
        for id in old.floating where windows[id]?.pinned == true {
            old.floating.removeAll { $0 == id }
            new.floating.append(id)
            windows[id]?.workspace = new.id
        }
    }

    func toggleSpecial(name: String) -> String {
        let mon = focusedMonitorID
        guard let wsID = resolveWorkspaceID(.special(name), create: true) else { return "err" }
        let ws = workspace(forID: wsID)
        if shownSpecial[mon] == wsID {
            shownSpecial.removeValue(forKey: mon)
            hideWorkspace(ws)
            if let id = activeWS[mon], let under = registry.existing(id) {
                showWorkspace(under)
            }
            broadcast(.workspace(registry.existing(activeWS[mon] ?? 1)?.name ?? "1"))
            return "ok"
        }
        if let elsewhere = shownSpecial.first(where: { $0.value == wsID })?.key {
            shownSpecial.removeValue(forKey: elsewhere)
        }
        ws.monitor = mon
        shownSpecial[mon] = wsID
        showWorkspace(ws)
        broadcast(.workspace(ws.name))
        return "ok"
    }

    // MARK: - Membership

    func insertTiled(_ id: WindowID, into ws: WorkspaceState) {
        ws.insertTiled(id, near: ws.lastFocused, container: containerRect(for: ws),
                       dwindleSettings: settings.dwindle, masterSettings: settings.master)
    }

    /// Windows visible on a monitor right now: active workspace + overlaid
    /// special. Used for directional focus and cycling.
    func visibleWindows(on monitorID: CGDirectDisplayID) -> [WindowID] {
        var out: [WindowID] = []
        if let id = activeWS[monitorID], let ws = registry.existing(id) {
            out += ws.allWindows
        }
        if let id = shownSpecial[monitorID], let ws = registry.existing(id) {
            out += ws.allWindows
        }
        return out.filter {
            guard let state = windows[$0] else { return false }
            return !state.minimized && !state.nativeFullscreen
        }
    }

    // MARK: - Focus

    func focusWindow(_ id: WindowID) {
        guard let state = windows[id] else { return }
        bridge.focus(id)
        noteFocus(state)
    }

    /// Shared focus bookkeeping for both directions: focus we initiate
    /// (`focusWindow`) and focus the OS reports (`windowFocused`).
    private func noteFocus(_ state: WindowState) {
        focusedWindow = state.id
        let ws = workspace(forID: state.workspace)
        ws.lastFocused = state.id
        focusedMonitorID = ws.monitor
        pushFocusHistory(state.id)
        refreshBorder()
        broadcast(.activewindow(clazz: state.clazz, title: state.title))
        broadcast(.activewindowv2(state.id))
    }

    func clearFocus() {
        focusedWindow = nil
        refreshBorder()
        broadcast(.activewindow(clazz: "", title: ""))
        broadcast(.activewindowv2(nil))
    }

    private func pushFocusHistory(_ id: WindowID) {
        focusHistory.removeAll { $0 == id }
        focusHistory.insert(id, at: 0)
        if focusHistory.count > 64 {
            focusHistory.removeLast(focusHistory.count - 64)
        }
    }

    func focusNextAfterClose(in ws: WorkspaceState) {
        let visible = Set(visibleWindows(on: ws.monitor))
        if let next = focusHistory.first(where: { visible.contains($0) }) ?? ws.allWindows.first {
            focusWindow(next)
        } else {
            clearFocus()
        }
    }

    func refreshBorder() {
        guard !paused, let id = focusedWindow, let state = windows[id], !state.hidden, !state.minimized,
              !state.nativeFullscreen,
              workspace(forID: state.workspace).fullscreen != id else {
            border.hide()
            return
        }
        let gradient = tap.activeSubmap.isEmpty
            ? settings.general.activeBorder
            : settings.general.submapBorder
        border.show(around: state.frame,
                    gradient: gradient,
                    width: settings.general.borderSize,
                    rounding: settings.decoration.rounding,
                    primaryHeight: monitorMgr.primaryHeight)
    }

    /// Applies a frame to a floating window and keeps every dependent in sync.
    func applyFloatingFrame(_ state: WindowState, _ frame: CGRect) {
        state.frame = frame
        state.floatFrame = frame
        bridge.setFrame(state.id, frame)
        refreshBorder()
    }

    func followMouse(_ point: CGPoint) {
        guard settings.input.followMouse == 1, !paused else { return }
        if let m = monitorMgr.containing(point) {
            focusedMonitorID = m.id
        }
        guard let id = bridge.windowID(at: point), id != focusedWindow,
              windows[id] != nil else { return }
        focusWindow(id)
    }

    // MARK: - Monitors changed

    func monitorsChanged() {
        let alive = Set(monitorMgr.monitors.map(\.id))
        let fallback = monitorMgr.primary?.id ?? 0
        for ws in registry.byID.values where !alive.contains(ws.monitor) {
            ws.monitor = fallback
        }
        activeWS = activeWS.filter { alive.contains($0.key) }
        shownSpecial = shownSpecial.filter { alive.contains($0.key) }
        if !alive.contains(focusedMonitorID) {
            focusedMonitorID = fallback
        }
        ensureWorkspacesForMonitors()
        arrangeAllVisible()
        refreshDesktopBar()
    }

    // MARK: - Pause

    /// Suspends or resumes all tiling enforcement. While paused: frames are
    /// not asserted, chords (except `pause` binds) pass through to apps, and
    /// windows move freely. Resume re-stashes hidden workspaces and reasserts
    /// the grid — the grid owns tiled windows; pause is a timeout, not a mode.
    func setPaused(_ on: Bool) {
        guard paused != on else { return }
        paused = on
        tap.paused = on
        drag = nil
        statusItem.update(paused: on)
        broadcast(.pause(on))
        if on {
            border.hide()
            log("tiling paused")
        } else {
            for ws in registry.byID.values where !isVisible(ws) {
                hideWorkspace(ws)
            }
            arrangeAllVisible()
            refreshBorder()
            log("tiling resumed")
        }
    }

    // MARK: - Cheat sheet

    func toggleCheatSheet() {
        guard let monitor = monitorMgr.byID(focusedMonitorID) ?? monitorMgr.primary else { return }
        cheatSheet.toggle(rows: BindDisplay.rows(doc.binds),
                          monitorFrame: monitor.usable,
                          primaryHeight: monitorMgr.primaryHeight)
    }

    func refreshDesktopBar() {
        guard settings.bar.enabled else {
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
        let frontmostName = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        return DesktopBarSnapshot(
            monitors: monitorMgr.monitors,
            workspaces: workspaces,
            activeWorkspaces: activeWS,
            appName: active?.clazz ?? frontmostName,
            windowTitle: active?.title ?? "",
            layout: settings.general.layout,
            submap: tap.activeSubmap,
            paused: paused,
            system: DesktopBarSystemInfo.current()
        )
    }
}

// MARK: - AXBridgeDelegate

extension WindowManager: AXBridgeDelegate {
    func windowAppeared(_ snap: WindowSnapshot) {
        guard windows[snap.id] == nil else { return }

        let center = CGPoint(x: snap.frame.midX, y: snap.frame.midY)
        let monitor = monitorMgr.containing(center) ?? monitorMgr.primary
        let match = MatchTarget(clazz: snap.clazz, title: snap.title,
                                floating: snap.kind == .dialog, pid: Int(snap.pid))
        let placement = InitialPlacement.evaluate(rules: doc.rules, target: match,
                                                  defaultFloating: snap.kind == .dialog,
                                                  windowFrame: snap.frame,
                                                  usable: monitor?.usable ?? .zero)

        var wsID = activeWS[monitor?.id ?? focusedMonitorID] ?? 1
        if let target = placement.workspaceTarget,
           let resolved = resolveWorkspaceID(target, create: true) {
            wsID = resolved
        } else if let name = placement.monitorName,
                  let m = monitorMgr.resolve(.name(name), current: focusedMonitorID) {
            wsID = activeWS[m.id] ?? wsID
        }

        let state = WindowState(id: snap.id, pid: snap.pid, clazz: snap.clazz,
                                title: snap.title, workspace: wsID, frame: snap.frame)
        state.floating = placement.floating
        state.pinned = placement.pinned
        state.minimized = snap.isMinimized
        state.floatFrame = placement.floatFrame
        windows[snap.id] = state

        let ws = workspace(forID: wsID)
        if state.minimized {
            // Tracked but not laid out until deminiaturized.
        } else if state.floating {
            ws.floating.append(snap.id)
            if state.floatFrame == nil {
                state.floatFrame = snap.frame.isEmpty ? defaultFloatFrame(for: ws) : snap.frame
            }
        } else {
            insertTiled(snap.id, into: ws)
        }
        if placement.wantsFullscreen {
            ws.fullscreen = snap.id
            ws.fullscreenMode = 0
        }

        broadcast(.openwindow(snap.id, workspace: ws.name, clazz: snap.clazz, title: snap.title))
        if isVisible(ws) {
            arrange(ws)
            // Focus follows a new window only when the user is driving: its
            // app is frontmost (they just opened it) or nothing holds focus.
            // Explicit non-silent workspace rules also follow: use `silent`
            // when a window should move there without changing what you see.
            let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let userDriven = snap.pid == frontmost || focusedWindow == nil
            if !placement.silent && !state.minimized && (userDriven || placement.followsWorkspace) {
                focusWindow(snap.id)
            }
        } else if placement.followsWorkspace, !state.minimized,
                  let target = placement.workspaceTarget {
            ws.lastFocused = snap.id
            _ = switchWorkspace(to: target)
        } else {
            stash(snap.id)
        }
    }

    func windowDestroyed(_ id: WindowID) {
        guard let state = windows.removeValue(forKey: id) else { return }
        let ws = workspace(forID: state.workspace)
        ws.removeWindow(id)
        focusHistory.removeAll { $0 == id }
        lastReassert.removeValue(forKey: id)
        lastFullscreenPoll.removeValue(forKey: id)
        settleWork.removeValue(forKey: id)?.cancel()
        broadcast(.closewindow(id))
        if isVisible(ws) {
            arrange(ws)
            if focusedWindow == id {
                focusNextAfterClose(in: ws)
            }
        }
        garbageCollect(ws)
    }

    func windowFocused(_ id: WindowID) {
        guard let state = windows[id], focusedWindow != id else { return }
        // The OS can focus a window on a hidden workspace. Two causes:
        // a user switch gesture (⌘Tab, Dock) — always follow it to that
        // workspace, the OS already committed the activation — or an
        // app-initiated focus steal, which follows Hyprland's
        // focus_on_activate (default: stay put).
        let ws = workspace(forID: state.workspace)
        if !isVisible(ws), !paused {
            let isUserGesture = CFAbsoluteTimeGetCurrent() - lastUserGesture < 3.0
            guard isUserGesture || settings.misc.focusOnActivate else { return }
            _ = switchWorkspace(to: ws.isSpecial
                ? .special(registry.specialName(forID: ws.id) ?? "special")
                : .id(ws.id))
        }
        noteFocus(state)
    }

    func windowMovedOrResized(_ id: WindowID, frame: CGRect) {
        guard let state = windows[id], !frame.isEmpty else { return }
        if handleFullscreenTransition(state, frame) { return }
        if state.nativeFullscreen { return } // the system owns its frame
        if paused {
            // Track floating frames so they stay where the user left them;
            // tiled frames keep their tile assignment for the resume snap.
            if state.floating { trackFloatingFrame(state, frame) }
            return
        }
        if handleDragEcho(state, frame) { return }
        guard !state.hidden else { return }
        if state.floating {
            trackFloatingFrame(state, frame)
        } else {
            holdTile(state, frame)
        }
    }

    /// Native fullscreen (the green button) moves the window to its own Space.
    /// Release its tile while it's away; re-adopt it when it returns. The AX
    /// poll is gated: only when the flag is already set (to catch the exit) or
    /// the event frame is monitor-sized (the only shape an enter produces).
    private func handleFullscreenTransition(_ state: WindowState, _ frame: CGRect) -> Bool {
        guard drag?.id != state.id else { return false }
        let now = CFAbsoluteTimeGetCurrent()
        let monitorSized = monitorMgr.containing(CGPoint(x: frame.midX, y: frame.midY))
            .map { abs(frame.width - $0.frame.width) < 2 && abs(frame.height - $0.frame.height) < 2 }
            ?? false
        // App-internal fullscreen binds (Ghostty's ⌘↩ etc.) animate through
        // intermediate frames, so monitor-sized alone misses the start;
        // AXFullScreen flips when the animation begins, and a rate-limited
        // poll catches it on the first event of the burst.
        let pollDue = now - (lastFullscreenPoll[state.id] ?? 0) > 0.1
        guard state.nativeFullscreen || monitorSized || pollDue else { return false }
        lastFullscreenPoll[state.id] = now

        let native = bridge.isNativeFullscreen(state.id)
        guard native != state.nativeFullscreen else { return false }
        applyNativeFullscreen(state, native)
        return true
    }

    private func applyNativeFullscreen(_ state: WindowState, _ native: Bool) {
        state.nativeFullscreen = native
        let ws = workspace(forID: state.workspace)
        if native {
            if !state.floating { ws.removeTiled(state.id) }
            if isVisible(ws) { arrange(ws) }
            refreshBorder()
        } else {
            state.hidden = false
            if !state.floating, !ws.master.contains(state.id) { insertTiled(state.id, into: ws) }
            if isVisible(ws) {
                arrange(ws)
            } else {
                stash(state.id)
            }
        }
    }

    /// Entering or leaving native fullscreen always switches the active Space,
    /// and the Space transition itself often delivers no AX move event — this
    /// notification is the reliable trigger. Sweep for flag drift and apply.
    func activeSpaceChanged() {
        for state in windows.values where !state.minimized && drag?.id != state.id {
            let native = bridge.isNativeFullscreen(state.id)
            if native != state.nativeFullscreen {
                applyNativeFullscreen(state, native)
            }
        }
        refreshBorder()
    }

    /// Move events for the window we're dragging: bindm echoes of our own
    /// setFrame are swallowed; native drags engage the session and track the
    /// OS-driven frame so the border rides along.
    private func handleDragEcho(_ state: WindowState, _ frame: CGRect) -> Bool {
        guard var session = drag, session.id == state.id else { return false }
        guard session.source == .native else { return true }
        let movedDist = abs(frame.minX - session.startFrame.minX)
            + abs(frame.minY - session.startFrame.minY)
        let sizeDist = abs(frame.width - session.startFrame.width)
            + abs(frame.height - session.startFrame.height)
        if sizeDist > 4 {
            session.sawResize = true
            session.engaged = true
        } else if movedDist > 4 {
            session.engaged = true
        }
        drag = session
        if session.engaged {
            state.frame = frame
            if state.id == focusedWindow { refreshBorder() }
        }
        return true
    }

    private func trackFloatingFrame(_ state: WindowState, _ frame: CGRect) {
        state.frame = frame
        state.floatFrame = frame
        if state.id == focusedWindow { refreshBorder() }
    }

    /// Tiled windows stick to their tile. Re-assert promptly (cooldown
    /// prevents fight loops with stubborn apps), and always settle back to
    /// the exact tile once the event burst quiets down.
    private func holdTile(_ state: WindowState, _ frame: CGRect) {
        let desired = state.frame
        let drift = abs(frame.minX - desired.minX) + abs(frame.minY - desired.minY)
            + abs(frame.width - desired.width) + abs(frame.height - desired.height)
        guard drift > 4 else {
            if state.id == focusedWindow { refreshBorder() }
            return
        }
        let now = CFAbsoluteTimeGetCurrent()
        if now - (lastReassert[state.id] ?? 0) > 0.4 {
            lastReassert[state.id] = now
            bridge.setFrame(state.id, desired)
        }
        scheduleSettle(state.id)
        if state.id == focusedWindow { refreshBorder() }
    }

    /// Debounced snap-back: after any external move/resize burst, a tiled
    /// window returns to its assigned tile (exact coordinates and size).
    private func scheduleSettle(_ id: WindowID) {
        settleWork[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.settleWork.removeValue(forKey: id)
            guard self.drag?.id != id,
                  let state = self.windows[id],
                  !state.floating, !state.hidden, !state.minimized,
                  self.isVisible(self.workspace(forID: state.workspace)) else { return }
            self.bridge.setFrame(id, state.frame)
            if id == self.focusedWindow { self.refreshBorder() }
        }
        settleWork[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func windowTitleChanged(_ id: WindowID, title: String) {
        windows[id]?.title = title
        if id == focusedWindow, let state = windows[id] {
            broadcast(.activewindow(clazz: state.clazz, title: state.title))
        } else {
            refreshDesktopBar()
        }
    }

    func windowMinimized(_ id: WindowID) {
        guard let state = windows[id] else { return }
        state.minimized = true
        let ws = workspace(forID: state.workspace)
        if !state.floating {
            ws.removeTiled(id)
        }
        if isVisible(ws) {
            arrange(ws)
            if focusedWindow == id { focusNextAfterClose(in: ws) }
        }
    }

    func windowDeminimized(_ id: WindowID) {
        guard let state = windows[id] else { return }
        state.minimized = false
        state.hidden = false
        let ws = workspace(forID: state.workspace)
        if !state.floating, !ws.master.contains(id) {
            insertTiled(id, into: ws)
        }
        if isVisible(ws) {
            arrange(ws)
            focusWindow(id)
        } else {
            stash(id)
        }
    }
}

extension WindowManager {
    func broadcast(_ event: WMEvent) {
        events?.broadcast(event)
        refreshDesktopBar()
    }

    func broadcastFocusedMon() {
        if let m = monitorMgr.byID(focusedMonitorID),
           let wsID = activeWS[m.id], let ws = registry.existing(wsID) {
            broadcast(.focusedmon(monitor: m.name, workspace: ws.name))
        }
    }
}
