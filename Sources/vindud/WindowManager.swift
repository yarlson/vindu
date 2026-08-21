import AppKit
import VinduCore
import VinduDaemonSupport

func checkedGeometryInt(_ value: CGFloat) -> Int? {
    guard value.isFinite else { return nil }
    return Int(exactly: value.rounded(.towardZero))
}

func isValidWindowPoint(_ point: CGPoint) -> Bool {
    checkedGeometryInt(point.x) != nil && checkedGeometryInt(point.y) != nil
}

func windowFrameValues(_ frame: CGRect) -> (x: Int, y: Int, width: Int, height: Int)? {
    guard frame.width > 0, frame.height > 0,
          checkedGeometryInt(frame.maxX) != nil,
          checkedGeometryInt(frame.maxY) != nil,
          let x = checkedGeometryInt(frame.minX),
          let y = checkedGeometryInt(frame.minY),
          let width = checkedGeometryInt(frame.width),
          let height = checkedGeometryInt(frame.height) else { return nil }
    return (x, y, width, height)
}

func isValidWindowFrame(_ frame: CGRect) -> Bool {
    windowFrameValues(frame) != nil
}

/// Per-window state the WM owns; geometry lives in top-left-origin coords.
final class WindowState {
    let id: WindowID
    let pid: pid_t
    let initialClass: String
    let initialTitle: String
    let borderEligible: Bool
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

    init(id: WindowID, pid: pid_t, clazz: String, title: String, workspace: Int,
         frame: CGRect, borderEligible: Bool) {
        self.id = id
        self.pid = pid
        self.clazz = clazz
        self.title = title
        self.initialClass = clazz
        self.initialTitle = title
        self.borderEligible = borderEligible
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
    let border = BorderController()
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
    var wroteDefaultConfig = false
    var shutdownRequested = false

    var windows: [WindowID: WindowState] = [:]
    /// Visible (non-special) workspace per monitor.
    var activeWS: [CGDirectDisplayID: Int] = [:]
    var prevWS: [CGDirectDisplayID: Int] = [:]
    /// Special workspace currently overlaid per monitor.
    var shownSpecial: [CGDirectDisplayID: Int] = [:]
    var focusedWindow: WindowID?
    var systemFocusedSurface: WindowID?
    var focusedMonitorID: CGDirectDisplayID = 0
    var focusHistory: [WindowID] = []

    var drag: DragSession?
    var lastDragApply = 0.0
    private var lastReassert: [WindowID: Double] = [:]
    private var lastFullscreenPoll: [WindowID: Double] = [:]
    private var settleWork: [WindowID: DispatchWorkItem] = [:]
    var desktopBarRefreshQueued = false
    private var didReportInvalidGeometry = false
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
        guard loadInitialConfig() else { exit(1) }
        monitorMgr.start()
        monitorMgr.onChange = { [weak self] change in self?.monitorsChanged(change) }
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
        bridge.reportSystemFocus()
        // First run: nobody knows the chords yet — show the cheat sheet once
        // the initial tiling has settled.
        if wroteDefaultConfig {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.showCheatSheetIfHidden()
            }
        }
        log("ready — \(monitorMgr.monitors.count) monitor(s), socket \(VinduPaths.commandSocketPath)")
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

    func workspaceTargetExceedsRange(_ target: WorkspaceTarget) -> Bool {
        guard case .relative(let delta) = target, delta > 0 else { return false }
        return (activeWS[focusedMonitorID] ?? 1).addingReportingOverflow(delta).overflow
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

        var frames: [(state: WindowState, frame: CGRect)] = []
        for (id, rect) in raw {
            guard id != excluding, let state = windows[id], !state.minimized else { continue }
            var frame = LayoutMath.applyGaps(to: rect, within: container,
                                             gapsIn: g.gapsIn, gapsOut: g.gapsOut)
            frame = frame.insetBy(dx: g.borderSize, dy: g.borderSize)
            if ws.fullscreen == id {
                frame = fullscreenFrame(for: ws)
            }
            frames.append((state, frame))
        }

        for id in ws.floating {
            guard let state = windows[id], !state.minimized, !state.nativeFullscreen else { continue }
            var frame = state.floatFrame ?? defaultFloatFrame(for: ws)
            if ws.fullscreen == id {
                frame = fullscreenFrame(for: ws)
            }
            frames.append((state, frame))
        }

        guard frames.allSatisfy({ isValidWindowFrame($0.frame) }) else {
            reportInvalidGeometry()
            return
        }

        for (state, frame) in frames {
            state.frame = frame
            state.hidden = false
            bridge.setFrame(state.id, frame)
        }

        if let fs = ws.fullscreen {
            bridge.raise(fs)
        }
        if ws.isSpecial {
            for id in ws.allWindows { bridge.raise(id) }
        }
        syncBorder()
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
        if focusedWindow == id { syncBorder() }
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
        guard !workspaceTargetExceedsRange(resolved) else {
            return "err: workspace id is out of range"
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
        syncBorder()
        broadcast(.activewindow(clazz: state.clazz, title: state.title))
        broadcast(.activewindowv2(state.id))
    }

    func clearFocus() {
        focusedWindow = nil
        syncBorder()
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

    func syncBorder() {
        guard let id = focusedWindow, let state = windows[id] else {
            border.hide()
            return
        }
        let borderState = ActiveBorderState(
            managedWindowID: id,
            systemWindowID: systemFocusedSurface,
            eligible: state.borderEligible,
            paused: paused,
            hidden: state.hidden,
            minimized: state.minimized,
            nativeFullscreen: state.nativeFullscreen,
            managedFullscreen: workspace(forID: state.workspace).fullscreen == id,
            width: settings.general.borderSize
        )
        guard let target = ActiveBorderPolicy.targetWindowID(for: borderState) else {
            border.hide()
            return
        }
        let gradient = tap.activeSubmap.isEmpty
            ? settings.general.activeBorder
            : settings.general.submapBorder
        border.show(windowID: target,
                    gradient: gradient,
                    width: settings.general.borderSize,
                    fallbackRadius: settings.decoration.rounding)
    }

    @discardableResult
    func applyFloatingFrame(_ state: WindowState, _ frame: CGRect) -> Bool {
        guard isValidWindowFrame(frame) else {
            reportInvalidGeometry()
            return false
        }
        state.frame = frame
        state.floatFrame = frame
        bridge.setFrame(state.id, frame)
        return true
    }

    private func reportInvalidGeometry() {
        guard !didReportInvalidGeometry else { return }
        didReportInvalidGeometry = true
        log("invalid window geometry ignored; check numeric configuration values")
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

    func monitorsChanged(_ change: MonitorChange) {
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
        for name in change.removed {
            broadcast(.monitorremoved(name))
        }
        for name in change.added {
            broadcast(.monitoradded(name))
        }
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
            syncBorder()
            log("tiling paused")
        } else {
            for ws in registry.byID.values where !isVisible(ws) {
                hideWorkspace(ws)
            }
            arrangeAllVisible()
            syncBorder()
            log("tiling resumed")
        }
    }

}

// MARK: - AXBridgeDelegate

extension WindowManager: AXBridgeDelegate {
    func windowAppeared(_ snap: WindowSnapshot) {
        guard windows[snap.id] == nil, isValidWindowFrame(snap.frame) else { return }

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
                                title: snap.title, workspace: wsID, frame: snap.frame,
                                borderEligible: snap.kind == .standard && snap.isResizable)
        state.floating = placement.floating
        state.pinned = placement.pinned
        state.minimized = snap.isMinimized
        if let frame = placement.floatFrame, isValidWindowFrame(frame) {
            state.floatFrame = frame
        } else if placement.floatFrame != nil {
            reportInvalidGeometry()
        }
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
        if focusedWindow == id { syncBorder() }
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

    func systemFocusedSurfaceChanged(_ id: WindowID?) {
        systemFocusedSurface = id
        syncBorder()
    }

    func windowMovedOrResized(_ id: WindowID, frame: CGRect) {
        guard let state = windows[id], isValidWindowFrame(frame) else { return }
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
            syncBorder()
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
        syncBorder()
    }

    /// Move events for the window we're dragging: bindm echoes of our own
    /// setFrame are swallowed; native drags engage the session and track the
    /// OS-driven frame.
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
        }
        return true
    }

    private func trackFloatingFrame(_ state: WindowState, _ frame: CGRect) {
        state.frame = frame
        state.floatFrame = frame
    }

    /// Tiled windows stick to their tile. Re-assert promptly (cooldown
    /// prevents fight loops with stubborn apps), and always settle back to
    /// the exact tile once the event burst quiets down.
    private func holdTile(_ state: WindowState, _ frame: CGRect) {
        let desired = state.frame
        if let centered = centeredConstrainedFrame(frame, in: desired) {
            if frameDistance(frame, centered) > 4 {
                reassertFrame(centered, for: state.id)
            }
            return
        }

        let drift = frameDistance(frame, desired)
        guard drift > 4 else { return }
        reassertFrame(desired, for: state.id)
        scheduleSettle(state.id)
    }

    private func frameDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        abs(lhs.minX - rhs.minX) + abs(lhs.minY - rhs.minY)
            + abs(lhs.width - rhs.width) + abs(lhs.height - rhs.height)
    }

    private func centeredConstrainedFrame(_ actual: CGRect, in desired: CGRect) -> CGRect? {
        let tolerance: CGFloat = 4
        let constrainedWidth = actual.width < desired.width - tolerance
        let constrainedHeight = actual.height < desired.height - tolerance
        guard constrainedWidth || constrainedHeight else { return nil }

        var frame = desired
        if constrainedWidth {
            frame.origin.x = desired.midX - actual.width / 2
            frame.size.width = actual.width
        }
        if constrainedHeight {
            frame.origin.y = desired.midY - actual.height / 2
            frame.size.height = actual.height
        }
        return frame
    }

    private func reassertFrame(_ frame: CGRect, for id: WindowID) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - (lastReassert[id] ?? 0) > 0.4 else { return }
        lastReassert[id] = now
        bridge.setFrame(id, frame)
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
        if focusedWindow == id { syncBorder() }
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
        desktopBarRefresh.handle(event: event)
        refreshDesktopBar()
    }

    func broadcastFocusedMon() {
        if let m = monitorMgr.byID(focusedMonitorID),
           let wsID = activeWS[m.id], let ws = registry.existing(wsID) {
            broadcast(.focusedmon(monitor: m.name, workspace: ws.name))
        }
    }
}
