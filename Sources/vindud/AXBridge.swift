import AppKit
import ApplicationServices
import VinduCore

/// Private but long-stable API (used by every macOS tiling WM) that maps an
/// accessibility element to its CGWindowID.
@_silgen_name("_AXUIElementGetWindow")
@discardableResult
func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: inout CGWindowID) -> AXError

/// What kind of surface an AXWindow is. Mirrors how Hyprland treats clients:
/// standard windows tile, dialogs float, and chromeless auxiliary surfaces
/// (autocomplete dropdowns, tooltips) are never managed or focused at all —
/// keyboard focus stays with their parent window.
enum WindowKind {
    case standard
    case dialog
    case auxiliary
}

struct WindowSnapshot {
    let id: WindowID
    let pid: pid_t
    let clazz: String
    let title: String
    let frame: CGRect
    let kind: WindowKind
    let isMinimized: Bool
}

protocol AXBridgeDelegate: AnyObject {
    func windowAppeared(_ snap: WindowSnapshot)
    func windowDestroyed(_ id: WindowID)
    func windowFocused(_ id: WindowID)
    func windowMovedOrResized(_ id: WindowID, frame: CGRect)
    func windowTitleChanged(_ id: WindowID, title: String)
    func windowMinimized(_ id: WindowID)
    func windowDeminimized(_ id: WindowID)
}

private let axObserverCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    let app = Unmanaged<AXBridge.AppHandle>.fromOpaque(refcon).takeUnretainedValue()
    app.bridge?.handle(notification: notification as String, element: element, app: app)
}

/// Owns per-application AX observers and translates accessibility events into
/// window lifecycle callbacks. Main-thread only.
final class AXBridge {
    weak var delegate: AXBridgeDelegate?

    final class AppHandle {
        let pid: pid_t
        let element: AXUIElement
        let name: String
        var observer: AXObserver?
        var windows: [(element: AXUIElement, id: WindowID)] = []
        weak var bridge: AXBridge?

        init(pid: pid_t, name: String, bridge: AXBridge) {
            self.pid = pid
            self.name = name
            self.element = AXUIElementCreateApplication(pid)
            self.bridge = bridge
        }
    }

    private var apps: [pid_t: AppHandle] = [:]
    /// Consecutive reconcile passes a tracked window was absent from the
    /// window server's list. Two misses = really gone.
    private var missCounts: [WindowID: Int] = [:]
    let ownPID = ProcessInfo.processInfo.processIdentifier

    func start() {
        // AX destroy notifications are unreliable (destroyed elements lose
        // CFEqual identity; some apps never send one). The window server's
        // list is authoritative, so reap against it periodically.
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.reconcile()
        }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                           object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.attachWhenReady(app)
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                           object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.detach(pid: app.processIdentifier)
        }
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                           object: nil, queue: .main) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let handle = self.apps[app.processIdentifier] else { return }
            if let focused = self.focusedWindowID(of: handle) {
                self.delegate?.windowFocused(focused)
            }
        }

        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            attach(app)
        }
    }

    /// Apps register with the accessibility server asynchronously after launch;
    /// retry window discovery a few times so early windows are not missed.
    private func attachWhenReady(_ app: NSRunningApplication) {
        guard app.activationPolicy == .regular else { return }
        attach(app)
        for delay in [0.5, 1.5, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let handle = self.apps[app.processIdentifier] else { return }
                self.scanWindows(of: handle)
            }
        }
    }

    private func attach(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid != ownPID, apps[pid] == nil else { return }
        let handle = AppHandle(pid: pid, name: app.localizedName ?? "unknown", bridge: self)

        var observer: AXObserver?
        guard AXObserverCreate(pid, axObserverCallback, &observer) == .success, let observer else {
            return
        }
        handle.observer = observer
        let refcon = Unmanaged.passUnretained(handle).toOpaque()
        AXObserverAddNotification(observer, handle.element, kAXWindowCreatedNotification as CFString, refcon)
        AXObserverAddNotification(observer, handle.element, kAXFocusedWindowChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)

        apps[pid] = handle
        scanWindows(of: handle)
    }

    private func detach(pid: pid_t) {
        guard let handle = apps.removeValue(forKey: pid) else { return }
        if let observer = handle.observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        for (_, id) in handle.windows {
            delegate?.windowDestroyed(id)
        }
    }

    private func scanWindows(of handle: AppHandle) {
        guard let list: [AXUIElement] = axValue(handle.element, kAXWindowsAttribute) else { return }
        for element in list {
            register(element: element, app: handle)
        }
    }

    @discardableResult
    private func register(element: AXUIElement, app: AppHandle) -> WindowID? {
        guard (axValue(element, kAXRoleAttribute) as String?) == kAXWindowRole else { return nil }
        var wid: CGWindowID = 0
        guard _AXUIElementGetWindow(element, &wid) == .success, wid != 0 else { return nil }
        if app.windows.contains(where: { $0.id == wid }) { return wid }
        guard classify(element) != .auxiliary else { return nil }

        guard let observer = app.observer else { return nil }
        let refcon = Unmanaged.passUnretained(app).toOpaque()
        for note in [kAXUIElementDestroyedNotification, kAXWindowMovedNotification,
                     kAXWindowResizedNotification, kAXTitleChangedNotification,
                     kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification] {
            AXObserverAddNotification(observer, element, note as CFString, refcon)
        }
        app.windows.append((element: element, id: wid))
        delegate?.windowAppeared(snapshot(element: element, id: wid, app: app))
        return wid
    }

    fileprivate func handle(notification: String, element: AXUIElement, app: AppHandle) {
        switch notification {
        case kAXWindowCreatedNotification:
            register(element: element, app: app)
        case kAXFocusedWindowChangedNotification:
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(element, &wid) == .success, wid != 0 {
                // Auxiliary surfaces (popups) never register; swallowing their
                // focus events keeps the parent window focused and bordered.
                let known = app.windows.contains { $0.id == wid }
                if known || register(element: element, app: app) != nil {
                    delegate?.windowFocused(wid)
                }
            }
        case kAXUIElementDestroyedNotification:
            if let idx = app.windows.firstIndex(where: { CFEqual($0.element, element) }) {
                let id = app.windows.remove(at: idx).id
                delegate?.windowDestroyed(id)
            } else {
                // Destroyed elements can lose CFEqual identity; the window id
                // usually still resolves.
                var wid: CGWindowID = 0
                if _AXUIElementGetWindow(element, &wid) == .success, wid != 0,
                   let idx = app.windows.firstIndex(where: { $0.id == wid }) {
                    app.windows.remove(at: idx)
                    delegate?.windowDestroyed(wid)
                }
            }
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            if let entry = app.windows.first(where: { CFEqual($0.element, element) }) {
                delegate?.windowMovedOrResized(entry.id, frame: frame(of: element) ?? .zero)
            }
        case kAXTitleChangedNotification:
            if let entry = app.windows.first(where: { CFEqual($0.element, element) }) {
                delegate?.windowTitleChanged(entry.id, title: axValue(element, kAXTitleAttribute) ?? "")
            }
        case kAXWindowMiniaturizedNotification:
            if let entry = app.windows.first(where: { CFEqual($0.element, element) }) {
                delegate?.windowMinimized(entry.id)
            }
        case kAXWindowDeminiaturizedNotification:
            if let entry = app.windows.first(where: { CFEqual($0.element, element) }) {
                delegate?.windowDeminimized(entry.id)
            }
        default:
            break
        }
    }

    private func classify(_ element: AXUIElement) -> WindowKind {
        // Real windows can become the app's main window. Input-method
        // candidate panels, picker HUDs, and other non-activating system
        // surfaces refuse — never manage or focus those.
        var mainSettable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXMainAttribute as CFString, &mainSettable) == .success,
           !mainSettable.boolValue {
            return .auxiliary
        }
        let subrole: String? = axValue(element, kAXSubroleAttribute)
        if subrole == kAXStandardWindowSubrole as String {
            return .standard
        }
        if subrole == kAXDialogSubrole as String
            || subrole == kAXSystemDialogSubrole as String
            || subrole == kAXFloatingWindowSubrole as String {
            return .dialog
        }
        // Unknown or missing subrole: real windows still carry chrome (a title
        // or a close button); chromeless AXWindows are popups — autocomplete
        // dropdowns, tooltips — and must stay invisible to the WM.
        let title: String = axValue(element, kAXTitleAttribute) ?? ""
        let hasCloseButton = (axValue(element, kAXCloseButtonAttribute) as AXUIElement?) != nil
        if hasCloseButton || !title.isEmpty {
            return subrole == nil ? .standard : .dialog
        }
        return .auxiliary
    }

    private func snapshot(element: AXUIElement, id: WindowID, app: AppHandle) -> WindowSnapshot {
        WindowSnapshot(
            id: id,
            pid: app.pid,
            clazz: app.name,
            title: axValue(element, kAXTitleAttribute) ?? "",
            frame: frame(of: element) ?? .zero,
            kind: classify(element),
            isMinimized: (axValue(element, kAXMinimizedAttribute) as Bool?) ?? false
        )
    }

    /// Reaps tracked windows the window server no longer lists. A window must
    /// be absent on two consecutive passes before it is declared dead, so a
    /// transient gap in the list can't kill a live window.
    private func reconcile() {
        guard let list = CGWindowListCopyWindowInfo(.excludeDesktopElements,
                                                    kCGNullWindowID) as? [[String: Any]] else {
            return
        }
        let alive = Set(list.compactMap { $0[kCGWindowNumber as String] as? UInt32 })
        for app in apps.values {
            for (_, id) in app.windows {
                if alive.contains(id) {
                    missCounts.removeValue(forKey: id)
                    continue
                }
                let misses = (missCounts[id] ?? 0) + 1
                missCounts[id] = misses
                guard misses >= 2 else { continue }
                missCounts.removeValue(forKey: id)
                app.windows.removeAll { $0.id == id }
                delegate?.windowDestroyed(id)
            }
        }
    }

    // MARK: - Element queries

    func element(for id: WindowID) -> (element: AXUIElement, pid: pid_t)? {
        for (_, app) in apps {
            if let entry = app.windows.first(where: { $0.id == id }) {
                return (entry.element, app.pid)
            }
        }
        return nil
    }

    private func focusedWindowID(of app: AppHandle) -> WindowID? {
        guard let el: AXUIElement = axValue(app.element, kAXFocusedWindowAttribute) else { return nil }
        var wid: CGWindowID = 0
        guard _AXUIElementGetWindow(el, &wid) == .success, wid != 0 else { return nil }
        return wid
    }

    func systemFocusedWindowID() -> WindowID? {
        guard let front = NSWorkspace.shared.frontmostApplication,
              let handle = apps[front.processIdentifier] else { return nil }
        return focusedWindowID(of: handle)
    }

    // MARK: - Window operations (top-left-origin global coordinates)

    func frame(of element: AXUIElement) -> CGRect? {
        guard let posValue: AXValue = axValue(element, kAXPositionAttribute),
              let sizeValue: AXValue = axValue(element, kAXSizeAttribute) else { return nil }
        var p = CGPoint.zero
        var s = CGSize.zero
        AXValueGetValue(posValue, .cgPoint, &p)
        AXValueGetValue(sizeValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    func frame(of id: WindowID) -> CGRect? {
        element(for: id).flatMap { frame(of: $0.element) }
    }

    func setFrame(_ id: WindowID, _ rect: CGRect) {
        guard let (el, _) = element(for: id) else { return }
        // Position-size-position: apps clamp size against the current position,
        // so a single pass can land off-target when crossing displays.
        setPosition(el, rect.origin)
        var size = rect.size
        if let v = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, v)
        }
        setPosition(el, rect.origin)
    }

    func setPosition(_ id: WindowID, _ point: CGPoint) {
        guard let (el, _) = element(for: id) else { return }
        setPosition(el, point)
    }

    private func setPosition(_ el: AXUIElement, _ point: CGPoint) {
        var p = point
        if let v = AXValueCreate(.cgPoint, &p) {
            AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, v)
        }
    }

    func focus(_ id: WindowID) {
        guard let (el, pid) = element(for: id) else { return }
        AXUIElementSetAttributeValue(el, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(el, kAXRaiseAction as CFString)
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(options: [])
        }
    }

    func raise(_ id: WindowID) {
        guard let (el, _) = element(for: id) else { return }
        AXUIElementPerformAction(el, kAXRaiseAction as CFString)
    }

    func close(_ id: WindowID) {
        guard let (el, _) = element(for: id) else { return }
        if let button: AXUIElement = axValue(el, kAXCloseButtonAttribute) {
            AXUIElementPerformAction(button, kAXPressAction as CFString)
        }
    }

    func setMinimized(_ id: WindowID, _ minimized: Bool) {
        guard let (el, _) = element(for: id) else { return }
        AXUIElementSetAttributeValue(el, kAXMinimizedAttribute as CFString,
                                     minimized ? kCFBooleanTrue : kCFBooleanFalse)
    }

    /// True while the window is in native macOS fullscreen (its own Space).
    func isNativeFullscreen(_ id: WindowID) -> Bool {
        guard let (el, _) = element(for: id) else { return false }
        return (axValue(el, "AXFullScreen") as Bool?) ?? false
    }

    /// Frame of the window's green zoom button, for detecting clicks that are
    /// about to start a fullscreen transition.
    func fullscreenButtonFrame(_ id: WindowID) -> CGRect? {
        guard let (el, _) = element(for: id),
              let button: AXUIElement = axValue(el, "AXFullScreenButton") else { return nil }
        return frame(of: button)
    }

    /// Topmost normal window at a point (top-left-origin), excluding our own
    /// overlay panels.
    func windowID(at point: CGPoint) -> WindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: boundsDict),
                  rect.contains(point),
                  let num = info[kCGWindowNumber as String] as? UInt32 else {
                continue
            }
            return num
        }
        return nil
    }
}

/// Typed AX attribute read.
func axValue<T>(_ element: AXUIElement, _ attribute: String) -> T? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else {
        return nil
    }
    return ref as? T
}
