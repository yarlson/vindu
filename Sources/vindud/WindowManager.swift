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
    guard frame.size.width > 0, frame.size.height > 0,
          checkedGeometryInt(frame.maxX) != nil,
          checkedGeometryInt(frame.maxY) != nil,
          let x = checkedGeometryInt(frame.origin.x),
          let y = checkedGeometryInt(frame.origin.y),
          let width = checkedGeometryInt(frame.size.width),
          let height = checkedGeometryInt(frame.size.height) else { return nil }
    return (x, y, width, height)
}

func isValidWindowFrame(_ frame: CGRect) -> Bool {
    windowFrameValues(frame) != nil
}

func nextAvailableWorkspaceID(preferred: Int, activeIDs: Set<Int>) -> Int? {
    if preferred > 0, preferred <= 1000, !activeIDs.contains(preferred) {
        return preferred
    }
    return (1...1000).first { !activeIDs.contains($0) }
}

func workspaceIDsVisibleOnlyOnRemovedMonitors(
    activeWorkspaces: [CGDirectDisplayID: Int],
    specialWorkspaces: [CGDirectDisplayID: Int],
    aliveMonitors: Set<CGDirectDisplayID>
) -> Set<Int> {
    let normal = activeWorkspaces.compactMap { monitor, workspace in
        aliveMonitors.contains(monitor) ? nil : workspace
    }
    let special = specialWorkspaces.compactMap { monitor, workspace in
        aliveMonitors.contains(monitor) ? nil : workspace
    }
    return Set(normal + special)
}

/// Per-window state the WM owns; geometry lives in top-left-origin coords.
final class WindowState {
    let id: WindowID
    let pid: pid_t
    let bundleID: String?
    let initialClass: String
    let initialTitle: String
    let borderEligible: Bool
    var clazz: String
    var title: String
    var workspace: Int
    var targetFrame: CGRect
    var observedFrame: CGRect
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

    init(id: WindowID, pid: pid_t, bundleID: String?, clazz: String, title: String, workspace: Int,
         frame: CGRect, borderEligible: Bool) {
        self.id = id
        self.pid = pid
        self.bundleID = bundleID
        self.clazz = clazz
        self.title = title
        self.initialClass = clazz
        self.initialTitle = title
        self.borderEligible = borderEligible
        self.workspace = workspace
        self.targetFrame = frame
        self.observedFrame = frame
    }
}

/// The window manager. Single-threaded on the main queue: AX events, hotkey
/// dispatch, and IPC requests all funnel here.
final class WindowManager {
    let bridge = AXBridge()
    lazy var geometry = WindowGeometryController(
        backend: bridge,
        onObservedFrame: { [weak self] id, frame in
            self?.windows[id]?.observedFrame = frame
        },
        onOutcome: { [weak self] id, outcome in
            self?.reportGeometryOutcome(id, outcome)
        }
    )
    let monitorMgr = MonitorManager()
    let tap = HotkeyTap()
    let border = BorderController()
    let statusItem = StatusItem()
    let desktopBar = DesktopBar()
    let desktopBarRefresh = DesktopBarRefreshCoordinator()
    let cheatSheet = CheatSheet()
    let registry = WorkspaceRegistry()
    var configuration: ConfigurationSnapshot
    let configPath: String
    let wroteCanonicalDefault: Bool
    let broadcastEvent: (WMEvent) -> Void
    let runtimeWarningsChanged: ([LocatedConfigDiagnostic]) -> Void
    let quit: () -> Void
    /// Tiling suspended (`pause` dispatcher): no frame enforcement, non-pause
    /// chords pass through. Resume reasserts the grid.
    private(set) var paused = false
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
    private var lastFullscreenPoll: [WindowID: Double] = [:]
    var desktopBarRefreshQueued = false
    private var didReportInvalidGeometry = false
    /// Last explicit switch gesture (⌘Tab, Dock click). Activations that
    /// follow one are user intent and may switch workspaces.
    private var lastUserGesture = 0.0

    init(configuration: ConfigurationSnapshot,
         configPath: String,
         wroteCanonicalDefault: Bool,
         broadcastEvent: @escaping (WMEvent) -> Void,
         runtimeWarningsChanged: @escaping ([LocatedConfigDiagnostic]) -> Void,
         quit: @escaping () -> Void) {
        self.configuration = configuration
        self.configPath = configPath
        self.wroteCanonicalDefault = wroteCanonicalDefault
        self.broadcastEvent = broadcastEvent
        self.runtimeWarningsChanged = runtimeWarningsChanged
        self.quit = quit
        registry.onCreate = { [weak self] ws in self?.broadcast(.createworkspace(ws.name)) }
        registry.onDestroy = { [weak self] ws in self?.broadcast(.destroyworkspace(ws.name)) }
    }

    // MARK: - Bootstrap

    func bootstrap() {
        monitorMgr.start()
        monitorMgr.onChange = { [weak self] change in self?.monitorsChanged(change) }
        ensureWorkspacesForMonitors()
        focusedMonitorID = monitorMgr.primary?.id ?? 0

        bridge.delegate = self
        bridge.start()

        tap.onAction = { [weak self] action in _ = self?.dispatch(action) }
        tap.onMouseDrag = { [weak self] drag, point, phase in
            self?.handleDrag(drag: drag, point: point, phase: phase)
        }
        tap.onRawLeftMouse = { [weak self] point, phase in
            self?.handleRawLeftMouse(point, phase)
        }
        tap.onUserGesture = { [weak self] in self?.lastUserGesture = CFAbsoluteTimeGetCurrent() }
        tap.onMouseMoved = { [weak self] point in self?.followMouse(point) }
        if !tap.start() {
            log("event tap unavailable — check Accessibility permission; binds disabled")
        }

        statusItem.onPauseToggle = { [weak self] in _ = self?.dispatch(.pause(.toggle)) }
        statusItem.onShowKeybindings = { [weak self] in self?.toggleCheatSheet() }
        statusItem.onOpenConfig = { [weak self] in
            guard let self else { return }
            Exec.run("/usr/bin/open", args: ["-t", self.configPath])
        }
        statusItem.onQuit = { [weak self] in self?.quit() }
        desktopBar.onWorkspaceSelected = { [weak self] workspaceID, monitorID in
            guard let self else { return }
            self.focusedMonitorID = monitorID
            _ = self.dispatch(.workspace(.id(workspaceID)))
        }
        desktopBarRefresh.onChange = { [weak self] in self?.refreshDesktopBar() }
        applyConfiguration(configuration, broadcastReload: false)

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.activeSpaceChanged()
        }

        arrangeAllVisible()
        refreshDesktopBar()
        bridge.reportSystemFocus()
        for command in configuration.startup.commands {
            Exec.run(command)
        }
        if wroteCanonicalDefault {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.showCheatSheetIfHidden()
            }
        }
        log("ready — \(monitorMgr.monitors.count) monitor(s), socket \(VinduPaths.commandSocketPath)")
    }

    func applyDesktopUISettings() -> Set<String> {
        statusItem.setVisible(configuration.ui.menuBar.enabled)
        let restartedPlugins = desktopBarRefresh.sync(configuration: configuration.ui.bar)
        refreshDesktopBar()
        return restartedPlugins
    }

    // MARK: - Workspace bookkeeping

    /// Default workspace ids 1…N map onto monitors in order, unless a native
    /// workspace assignment places them elsewhere.
    func ensureWorkspacesForMonitors() {
        var activeIDs: Set<Int> = []
        for (index, monitor) in monitorMgr.monitors.enumerated() {
            if let workspaceID = activeWS[monitor.id],
               let workspace = registry.existing(workspaceID),
               activeIDs.insert(workspaceID).inserted {
                workspace.monitor = monitor.id
                continue
            }
            guard let workspaceID = nextAvailableWorkspaceID(preferred: index + 1,
                                                             activeIDs: activeIDs) else {
                continue
            }
            let ws = workspace(forID: workspaceID, createOn: monitor.id)
            ws.monitor = monitor.id
            activeWS[monitor.id] = ws.id
            activeIDs.insert(ws.id)
        }
    }

    func reconcileWorkspaceAssignments() -> [LocatedConfigDiagnostic] {
        var warnings: [LocatedConfigDiagnostic] = []
        let names = monitorMgr.monitors.map(\.name)
        for assignment in configuration.workspaces.assignments {
            switch ConfiguredMonitorResolver.resolve(assignment.monitor, in: names) {
            case .matched(let index):
                if let workspace = registry.existing(assignment.id) {
                    assign(workspace, to: monitorMgr.monitors[index])
                }
            case .missing:
                warnings.append(assignmentWarning(
                    assignment,
                    message: "monitor \(assignment.monitor) is not connected"
                ))
            case .ambiguous:
                warnings.append(assignmentWarning(
                    assignment,
                    message: "monitor \(assignment.monitor) matches more than one display"
                ))
            }
        }
        return warnings
    }

    private func assignmentWarning(_ assignment: WorkspaceAssignment,
                                   message: String) -> LocatedConfigDiagnostic {
        LocatedConfigDiagnostic(
            file: configPath,
            schemaPath: "workspaces.assignments[id=\(assignment.id)].monitor",
            message: message
        )
    }

    private func assign(_ workspace: WorkspaceState, to monitor: Monitor) {
        guard workspace.monitor != monitor.id else { return }
        let oldMonitor = workspace.monitor
        if activeWS[oldMonitor] == workspace.id {
            let replacement = replacementWorkspace(for: workspace, on: oldMonitor)
            activeWS[oldMonitor] = replacement.id
            arrange(replacement)
            if let displacedID = activeWS[monitor.id],
               let displaced = registry.existing(displacedID),
               displacedID != workspace.id {
                hideWorkspace(displaced)
                prevWS[monitor.id] = displacedID
            }
            workspace.monitor = monitor.id
            activeWS[monitor.id] = workspace.id
            arrange(workspace)
            return
        }

        workspace.monitor = monitor.id
        for id in workspace.allWindows where windows[id]?.hidden == true {
            geometry.submitStashPosition(CGPoint(x: monitor.frame.maxX - 2,
                                                 y: monitor.frame.maxY - 2), for: id)
        }
    }

    func workspace(forID id: Int, createOn monitor: CGDirectDisplayID? = nil) -> WorkspaceState {
        registry.workspace(forID: id,
                           monitor: monitor ?? boundMonitor(forWorkspace: id) ?? focusedMonitorID)
    }

    private func boundMonitor(forWorkspace id: Int) -> CGDirectDisplayID? {
        guard let assignment = configuration.workspaces.assignments.first(where: { $0.id == id }),
              case .matched(let index) = ConfiguredMonitorResolver.resolve(
                assignment.monitor,
                in: monitorMgr.monitors.map(\.name)
              ) else { return nil }
        return monitorMgr.monitors[index].id
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
        let isBound = configuration.workspaces.assignments.contains { $0.id == ws.id }
        registry.destroyIfEmpty(ws, isVisible: isVisible(ws), isBound: isBound)
    }

    // MARK: - Arrange

    func containerRect(for ws: WorkspaceState) -> CGRect {
        guard let monitor = monitorMgr.byID(ws.monitor) ?? monitorMgr.primary else { return .zero }
        let usable = DesktopBar.contentRect(for: monitor, configuration: configuration.ui.bar)
        if ws.isSpecial {
            // A special workspace uses an inset overlay inside its monitor.
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
        let g = configuration.layout

        let raw: [WindowID: CGRect]
        switch g.kind {
        case .dwindle:
            raw = ws.dwindle.frames(in: container)
        case .master:
            raw = ws.master.frames(in: container, configuration: g.master)
        }

        var frames: [(state: WindowState, frame: CGRect)] = []
        for (id, rect) in raw {
            guard id != excluding, let state = windows[id], !state.minimized else { continue }
            var frame = LayoutMath.applyGaps(to: rect, within: container,
                                             gapsIn: g.innerGap, gapsOut: g.outerGap)
            frame = frame.insetBy(dx: configuration.ui.focusBorder.width,
                                  dy: configuration.ui.focusBorder.width)
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
            state.targetFrame = frame
            state.hidden = false
            geometry.submitFrame(frame, for: state.id)
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
        return monitor.usable.insetBy(dx: configuration.layout.outerGap,
                                      dy: configuration.layout.outerGap)
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
        geometry.submitStashPosition(
            CGPoint(x: monitor.frame.maxX - 2, y: monitor.frame.maxY - 2),
            for: id
        )
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
        if case .id(let n) = target, n == currentID, configuration.workspaces.backAndForth,
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
                       dwindleConfiguration: configuration.layout.dwindle,
                       masterConfiguration: configuration.layout.master)
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
            width: configuration.ui.focusBorder.width
        )
        guard let target = ActiveBorderPolicy.targetWindowID(for: borderState) else {
            border.hide()
            return
        }
        let colors = tap.activeMode == "default"
            ? configuration.ui.focusBorder.activeColors
            : configuration.ui.focusBorder.modeColors
        let gradient = MLGradient(
            colors: colors.map { MLColor(r: $0.red, g: $0.green, b: $0.blue, a: $0.alpha) },
            angleDeg: configuration.ui.focusBorder.activeAngle
        )
        border.show(windowID: target,
                    gradient: gradient,
                    width: configuration.ui.focusBorder.width,
                    fallbackRadius: configuration.ui.focusBorder.fallbackCornerRadius)
    }

    @discardableResult
    func applyFloatingFrame(_ state: WindowState, _ frame: CGRect) -> Bool {
        guard isValidWindowFrame(frame) else {
            reportInvalidGeometry()
            return false
        }
        state.targetFrame = frame
        state.floatFrame = frame
        geometry.submitFrame(frame, for: state.id)
        return true
    }

    private func reportInvalidGeometry() {
        guard !didReportInvalidGeometry else { return }
        didReportInvalidGeometry = true
        log("invalid window geometry ignored; check numeric configuration values")
    }

    private func reportGeometryOutcome(_ id: WindowID, _ outcome: WindowGeometryOutcome) {
        guard case .failed(let actual, let error) = outcome else { return }
        let actualText = actual.map {
            "actual \(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))"
        } ?? "actual frame unavailable"
        let errorText = error.map { "; \($0.description)" } ?? ""
        log("window \(id) did not reach its requested frame; \(actualText)\(errorText)")
    }

    func followMouse(_ point: CGPoint) {
        guard configuration.focus.followsPointer, !paused else { return }
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
        let orphanedVisible = workspaceIDsVisibleOnlyOnRemovedMonitors(
            activeWorkspaces: activeWS,
            specialWorkspaces: shownSpecial,
            aliveMonitors: alive
        )
        for ws in registry.byID.values where !alive.contains(ws.monitor) {
            ws.monitor = fallback
        }
        activeWS = activeWS.filter { alive.contains($0.key) }
        shownSpecial = shownSpecial.filter { alive.contains($0.key) }
        prevWS = prevWS.filter {
            alive.contains($0.key) && registry.existing($0.value)?.monitor == $0.key
        }
        if !alive.contains(focusedMonitorID) {
            focusedMonitorID = fallback
        }
        ensureWorkspacesForMonitors()
        let warnings = reconcileWorkspaceAssignments()
        prevWS = prevWS.filter {
            alive.contains($0.key) && registry.existing($0.value)?.monitor == $0.key
        }
        for workspaceID in orphanedVisible {
            if let workspace = registry.existing(workspaceID), !isVisible(workspace) {
                hideWorkspace(workspace)
            }
        }
        runtimeWarningsChanged(warnings)
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
            for id in windows.keys {
                geometry.cancel(id)
            }
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
        let initialPlacement = NativeInitialPlacement.evaluate(
            rules: configuration.windows.rules,
            bundleID: snap.bundleID,
            appName: snap.clazz,
            title: snap.title,
            defaultFloating: snap.defaultFloating,
            windowFrame: snap.frame,
            usable: monitor?.usable ?? .zero
        )

        var wsID = activeWS[monitor?.id ?? focusedMonitorID] ?? 1
        if let target = initialPlacement.workspace,
           let resolved = resolveWorkspaceID(target, create: true) {
            wsID = resolved
        } else if let target = initialPlacement.monitor,
                  let m = monitorMgr.resolve(target, current: focusedMonitorID) {
            wsID = activeWS[m.id] ?? wsID
        }

        let ws = workspace(forID: wsID)
        let destinationUsable = monitorMgr.byID(ws.monitor)?.usable ?? monitor?.usable ?? .zero
        let placement = NativeInitialPlacement.evaluate(
            rules: configuration.windows.rules,
            bundleID: snap.bundleID,
            appName: snap.clazz,
            title: snap.title,
            defaultFloating: snap.defaultFloating,
            windowFrame: snap.frame,
            usable: destinationUsable
        )

        let state = WindowState(id: snap.id, pid: snap.pid, bundleID: snap.bundleID,
                                clazz: snap.clazz,
                                title: snap.title, workspace: wsID, frame: snap.frame,
                                borderEligible: snap.borderEligible)
        state.floating = placement.floating
        state.pinned = placement.pinned
        state.minimized = snap.isMinimized
        if let frame = placement.floatFrame, isValidWindowFrame(frame) {
            state.floatFrame = frame
        } else if placement.floatFrame != nil {
            reportInvalidGeometry()
        }
        windows[snap.id] = state
        geometry.register(snap.id, observedFrame: snap.frame)

        if state.floating {
            ws.floating.append(snap.id)
            if state.floatFrame == nil {
                state.floatFrame = snap.frame.isEmpty ? defaultFloatFrame(for: ws) : snap.frame
            }
        } else if !state.minimized {
            insertTiled(snap.id, into: ws)
        }
        if placement.fullscreen {
            ws.fullscreen = snap.id
            ws.fullscreenMode = 0
        }

        broadcast(.openwindow(snap.id, workspace: ws.name, clazz: snap.clazz, title: snap.title))
        if isVisible(ws) {
            arrange(ws)
            let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let userDriven = snap.pid == frontmost || focusedWindow == nil
            if !state.minimized && (userDriven || placement.workspace != nil) {
                focusWindow(snap.id)
            }
        } else if !state.minimized, let target = placement.workspace {
            ws.lastFocused = snap.id
            _ = switchWorkspace(to: target)
        } else {
            stash(snap.id)
        }
    }

    func windowElementReplaced(_ id: WindowID, frame: CGRect) {
        guard let state = windows[id], isValidWindowFrame(frame) else { return }
        geometry.replaceElement(id, observedFrame: frame)
        guard !paused, !state.minimized, !state.nativeFullscreen else { return }
        if state.hidden {
            guard let monitor = monitorMgr.byID(workspace(forID: state.workspace).monitor)
                    ?? monitorMgr.primary else { return }
            geometry.submitStashPosition(CGPoint(x: monitor.frame.maxX - 2,
                                                 y: monitor.frame.maxY - 2), for: id)
        } else {
            geometry.submitFrame(state.targetFrame, for: id)
        }
    }

    func windowDestroyed(_ id: WindowID) {
        guard let state = windows.removeValue(forKey: id) else { return }
        geometry.unregister(id)
        if focusedWindow == id { syncBorder() }
        let ws = workspace(forID: state.workspace)
        ws.removeWindow(id)
        focusHistory.removeAll { $0 == id }
        lastFullscreenPoll.removeValue(forKey: id)
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
        // app-initiated focus steal, controlled by allowAppActivation.
        let ws = workspace(forID: state.workspace)
        if !isVisible(ws), !paused {
            let isUserGesture = CFAbsoluteTimeGetCurrent() - lastUserGesture < 3.0
            guard isUserGesture || configuration.focus.allowAppActivation else { return }
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
        let observation = geometry.observe(frame, for: id)
        if handleFullscreenTransition(state, frame) {
            geometry.cancel(id)
            return
        }
        if state.nativeFullscreen {
            geometry.cancel(id)
            return
        }
        if paused {
            if state.floating { trackFloatingFrame(state, frame) }
            return
        }
        if handleDragEcho(state, frame) { return }
        guard !state.hidden else { return }
        if state.floating {
            if observation == .external {
                trackFloatingFrame(state, frame)
            }
        } else if observation == .external {
            geometry.submitFrame(state.targetFrame, for: id)
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
            geometry.cancel(state.id)
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

    /// Move events for the window under a pointer drag: echoes of our own
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
            geometry.cancel(state.id)
            state.targetFrame = frame
            state.observedFrame = frame
        }
        return true
    }

    private func trackFloatingFrame(_ state: WindowState, _ frame: CGRect) {
        state.targetFrame = frame
        state.observedFrame = frame
        state.floatFrame = frame
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
        geometry.cancel(id)
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
    func broadcast(_ event: WMEvent, excludingPlugins: Set<String> = []) {
        broadcastEvent(event)
        desktopBarRefresh.handle(event: event, excludingPlugins: excludingPlugins)
        refreshDesktopBar()
    }

    func broadcastFocusedMon() {
        if let m = monitorMgr.byID(focusedMonitorID),
           let wsID = activeWS[m.id], let ws = registry.existing(wsID) {
            broadcast(.focusedmon(monitor: m.name, workspace: ws.name))
        }
    }
}
