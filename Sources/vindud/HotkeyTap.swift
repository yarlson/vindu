import AppKit
import VinduCore

private let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<HotkeyTap>.fromOpaque(refcon).takeUnretainedValue()
    return tap.handle(type: type, event: event)
}

/// Session event tap implementing `bind`/`binde`/`bindr` keys, `bindm` mouse
/// drags, submaps, and focus-follows-mouse. Bound chords are swallowed before
/// the frontmost app sees them — this is what lets SUPER (⌘) binds shadow
/// system shortcuts, like Hyprland owning the SUPER key.
final class HotkeyTap {
    enum DragPhase { case began, moved, ended }

    /// All callbacks fire on the main queue.
    var onDispatcher: ((Dispatcher) -> Void)?
    var onMouseDrag: ((Dispatcher, CGPoint, DragPhase) -> Void)?
    var onMouseMoved: ((CGPoint) -> Void)?
    /// Unbound left-button press/drag/release, observed (never consumed) so the
    /// WM can track native title-bar drags of tiled windows.
    var onRawLeftMouse: ((CGPoint, DragPhase) -> Void)?
    /// Fires on explicit app-switching gestures: any click (Dock, Mission
    /// Control) and ⌘Tab sessions (each Tab press and the final ⌘ release).
    /// Lets the WM tell a user-driven activation from an app-initiated
    /// focus steal.
    var onUserGesture: (() -> Void)?
    /// Fires on the native fullscreen shortcuts (fn+F, ⌃⌘F) so the border can
    /// hide before the Space animation starts.
    var onFullscreenShortcut: (() -> Void)?

    private(set) var activeSubmap = ""

    private struct KeyChord: Hashable {
        let mods: UInt8
        let keycode: UInt16
        let submap: String
    }

    private struct MouseChord: Hashable {
        let mods: UInt8
        let button: MouseButton
        let submap: String
    }

    private var keyBinds: [KeyChord: [Bind]] = [:]
    private var mouseBinds: [MouseChord: Bind] = [:]
    private var tap: CFMachPort?
    private var activeDrag: (button: MouseButton, dispatcher: Dispatcher)?
    private var lastMouseMoved = 0.0
    private var lastRawDrag = 0.0
    /// True while the system app switcher is likely up (⌘Tab seen, ⌘ still held).
    private var switcherActive = false

    func rebuild(binds: [Bind]) {
        keyBinds.removeAll()
        mouseBinds.removeAll()
        for bind in binds {
            if bind.flags.contains(.mouse) {
                guard let button = MouseButton.parse(bindKey: bind.key) else { continue }
                mouseBinds[MouseChord(mods: bind.mods.rawValue, button: button, submap: bind.submap)] = bind
            } else if let code = KeyCodes.code(for: bind.key) {
                let chord = KeyChord(mods: bind.mods.rawValue, keycode: code, submap: bind.submap)
                keyBinds[chord, default: []].append(bind)
            }
        }
    }

    func setSubmap(_ name: String) {
        activeSubmap = name
    }

    func start() -> Bool {
        let interesting: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged,
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged,
            .mouseMoved,
        ]
        var mask: CGEventMask = 0
        for t in interesting {
            mask |= CGEventMask(1) << CGEventMask(t.rawValue)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: tapCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        self.tap = tap
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        case .keyDown:
            // ⌘Tab is the system switcher; observe it (never consumable anyway)
            // so activations it causes count as user gestures.
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            if keycode == 48, event.flags.contains(.maskCommand) {
                switcherActive = true
                fireUserGesture()
            }
            // Native fullscreen shortcuts: fn+F and ⌃⌘F (keycode 3 = F).
            if keycode == 3,
               event.flags.contains(.maskSecondaryFn)
                || (event.flags.contains(.maskCommand) && event.flags.contains(.maskControl)) {
                DispatchQueue.main.async { [weak self] in self?.onFullscreenShortcut?() }
            }
            return handleKey(event: event, isDown: true)
        case .keyUp:
            return handleKey(event: event, isDown: false)
        case .flagsChanged:
            // Releasing ⌘ commits the switcher selection, however long it was held.
            if switcherActive, !event.flags.contains(.maskCommand) {
                switcherActive = false
                fireUserGesture()
            }
            return Unmanaged.passUnretained(event)
        case .leftMouseDown:
            return handleMouseDown(event: event, button: .left)
        case .rightMouseDown:
            return handleMouseDown(event: event, button: .right)
        case .otherMouseDown:
            return handleMouseDown(event: event, button: .middle)
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return handleDragged(event: event, type: type)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            return handleMouseUp(event: event, type: type)
        case .mouseMoved:
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastMouseMoved > 0.08 {
                lastMouseMoved = now
                let point = event.location
                DispatchQueue.main.async { [weak self] in self?.onMouseMoved?(point) }
            }
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func mods(of event: CGEvent) -> UInt8 {
        var m: Modifiers = []
        let flags = event.flags
        if flags.contains(.maskCommand) { m.insert(.cmd) }
        if flags.contains(.maskAlternate) { m.insert(.alt) }
        if flags.contains(.maskControl) { m.insert(.ctrl) }
        if flags.contains(.maskShift) { m.insert(.shift) }
        return m.rawValue
    }

    private func handleKey(event: CGEvent, isDown: Bool) -> Unmanaged<CGEvent>? {
        let keycode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let chord = KeyChord(mods: mods(of: event), keycode: keycode, submap: activeSubmap)
        guard let binds = keyBinds[chord], !binds.isEmpty else {
            return Unmanaged.passUnretained(event)
        }
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        for bind in binds {
            let wantsDown = !bind.flags.contains(.release)
            guard wantsDown == isDown else { continue }
            if isRepeat && !bind.flags.contains(.repeats) { continue }
            let dispatcher = bind.dispatcher
            DispatchQueue.main.async { [weak self] in self?.onDispatcher?(dispatcher) }
        }
        // Swallow both edges of a bound chord so apps never see half a shortcut.
        return nil
    }

    private func handleMouseDown(event: CGEvent, button: MouseButton) -> Unmanaged<CGEvent>? {
        let chord = MouseChord(mods: mods(of: event), button: button, submap: activeSubmap)
        if chord.mods != 0, let bind = mouseBinds[chord] {
            activeDrag = (button, bind.dispatcher)
            let point = event.location
            let dispatcher = bind.dispatcher
            DispatchQueue.main.async { [weak self] in self?.onMouseDrag?(dispatcher, point, .began) }
            return nil
        }
        fireUserGesture()
        if button == .left {
            let point = event.location
            DispatchQueue.main.async { [weak self] in self?.onRawLeftMouse?(point, .began) }
        }
        return Unmanaged.passUnretained(event)
    }

    private func fireUserGesture() {
        DispatchQueue.main.async { [weak self] in self?.onUserGesture?() }
    }

    private func handleDragged(event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        if let drag = activeDrag, button(for: type) == drag.button {
            let point = event.location
            DispatchQueue.main.async { [weak self] in self?.onMouseDrag?(drag.dispatcher, point, .moved) }
            return nil
        }
        if type == .leftMouseDragged {
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastRawDrag > 0.03 {
                lastRawDrag = now
                let point = event.location
                DispatchQueue.main.async { [weak self] in self?.onRawLeftMouse?(point, .moved) }
            }
        }
        return Unmanaged.passUnretained(event)
    }

    private func handleMouseUp(event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        if let drag = activeDrag, button(for: type) == drag.button {
            activeDrag = nil
            let point = event.location
            DispatchQueue.main.async { [weak self] in self?.onMouseDrag?(drag.dispatcher, point, .ended) }
            return nil
        }
        if type == .leftMouseUp {
            let point = event.location
            DispatchQueue.main.async { [weak self] in self?.onRawLeftMouse?(point, .ended) }
        }
        return Unmanaged.passUnretained(event)
    }

    private func button(for type: CGEventType) -> MouseButton {
        switch type {
        case .leftMouseDragged, .leftMouseUp: return .left
        case .rightMouseDragged, .rightMouseUp: return .right
        default: return .middle
        }
    }
}
