import AppKit
import VinduCore

private let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<HotkeyTap>.fromOpaque(refcon).takeUnretainedValue()
    return tap.handle(type: type, event: event)
}

final class HotkeyTap {
    enum DragPhase { case began, moved, ended }

    var onAction: ((ConfiguredAction) -> Void)?
    var onMouseDrag: ((PointerDrag, CGPoint, DragPhase) -> Void)?
    var onMouseMoved: ((CGPoint) -> Void)?
    /// Unbound left-button press/drag/release, observed (never consumed) so the
    /// WM can track native title-bar drags of tiled windows.
    var onRawLeftMouse: ((CGPoint, DragPhase) -> Void)?
    /// Fires on explicit app-switching gestures: any click (Dock, Mission
    /// Control) and ⌘Tab sessions (each Tab press and the final ⌘ release).
    /// Lets the WM tell a user-driven activation from an app-initiated
    /// focus steal.
    var onUserGesture: (() -> Void)?

    private(set) var activeMode = "default"

    /// While paused, only `pause` binds match — everything else passes through
    /// to apps untouched, including mouse binds and raw drag tracking.
    var paused = false {
        didSet { if paused { activeDrag = nil } }
    }

    private struct KeyChord: Hashable {
        let mods: UInt8
        let keycode: UInt16
        let mode: String
    }

    private struct MouseChord: Hashable {
        let mods: UInt8
        let button: PointerButton
    }

    private var keyBinds: [KeyChord: [KeyboardBinding]] = [:]
    private var pressedKeyBindings: [UInt16: [KeyboardBinding]] = [:]
    private var mouseBinds: [MouseChord: PointerBinding] = [:]
    private var tap: CFMachPort?
    private var activeDrag: (button: PointerButton, drag: PointerDrag)?
    private var lastMouseMoved = 0.0
    private var lastRawDrag = 0.0
    /// True while the system app switcher is likely up (⌘Tab seen, ⌘ still held).
    private var switcherActive = false

    func rebuild(configuration: KeyboardConfiguration) {
        keyBinds.removeAll()
        mouseBinds.removeAll()
        let modes = Set(configuration.bindings.map(\.mode))
        if activeMode != "default", !modes.contains(activeMode) {
            activeMode = "default"
        }
        for binding in configuration.bindings {
            guard let code = KeyCodes.code(for: binding.chord.key) else { continue }
            let chord = KeyChord(mods: modifierMask(binding.chord.modifiers),
                                 keycode: code,
                                 mode: binding.mode)
            keyBinds[chord, default: []].append(binding)
        }
        for binding in configuration.pointerBindings {
            let chord = MouseChord(mods: modifierMask(binding.modifiers), button: binding.button)
            mouseBinds[chord] = binding
        }
    }

    func setMode(_ name: String) {
        activeMode = name
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

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        case .keyDown:
            // ⌘Tab is the system switcher; observe it (never consumable anyway)
            // so activations it causes count as user gestures.
            if event.getIntegerValueField(.keyboardEventKeycode) == 48,
               event.flags.contains(.maskCommand) {
                switcherActive = true
                fireUserGesture()
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
        var value: UInt8 = 0
        let flags = event.flags
        if flags.contains(.maskCommand) { value |= 1 << 0 }
        if flags.contains(.maskAlternate) { value |= 1 << 1 }
        if flags.contains(.maskControl) { value |= 1 << 2 }
        if flags.contains(.maskShift) { value |= 1 << 3 }
        return value
    }

    private func modifierMask(_ modifiers: [KeyboardModifier]) -> UInt8 {
        modifiers.reduce(into: 0) { value, modifier in
            switch modifier {
            case .command: value |= 1 << 0
            case .option: value |= 1 << 1
            case .control: value |= 1 << 2
            case .shift: value |= 1 << 3
            }
        }
    }

    private func handleKey(event: CGEvent, isDown: Bool) -> Unmanaged<CGEvent>? {
        let keycode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        var matchedPressedKey = false
        var binds: [KeyboardBinding]
        if isDown, isRepeat, let pressed = pressedKeyBindings[keycode] {
            binds = pressed
            matchedPressedKey = true
        } else if !isDown, let pressed = pressedKeyBindings.removeValue(forKey: keycode) {
            binds = pressed
            matchedPressedKey = true
        } else {
            let chord = KeyChord(mods: mods(of: event), keycode: keycode, mode: activeMode)
            guard let configured = keyBinds[chord], !configured.isEmpty else {
                return Unmanaged.passUnretained(event)
            }
            binds = configured
            if isDown, !isRepeat {
                pressedKeyBindings[keycode] = binds
            }
        }
        if paused {
            binds = binds.filter {
                if case .window(.pause) = $0.action { return true }
                return false
            }
            guard !binds.isEmpty else {
                return matchedPressedKey ? nil : Unmanaged.passUnretained(event)
            }
        }
        for bind in binds {
            let wantsDown = bind.edge == .press
            guard wantsDown == isDown else { continue }
            if isRepeat && !bind.repeats { continue }
            let action = bind.action
            DispatchQueue.main.async { [weak self] in self?.onAction?(action) }
        }
        // Swallow both edges of a bound chord so apps never see half a shortcut.
        return nil
    }

    private func handleMouseDown(event: CGEvent, button: PointerButton) -> Unmanaged<CGEvent>? {
        guard !paused else { return Unmanaged.passUnretained(event) }
        let chord = MouseChord(mods: mods(of: event), button: button)
        if chord.mods != 0, let bind = mouseBinds[chord] {
            activeDrag = (button, bind.drag)
            let point = event.location
            let drag = bind.drag
            DispatchQueue.main.async { [weak self] in self?.onMouseDrag?(drag, point, .began) }
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
        guard !paused else { return Unmanaged.passUnretained(event) }
        if let drag = activeDrag, button(for: type) == drag.button {
            let point = event.location
            DispatchQueue.main.async { [weak self] in self?.onMouseDrag?(drag.drag, point, .moved) }
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
        guard !paused else { return Unmanaged.passUnretained(event) }
        if let drag = activeDrag, button(for: type) == drag.button {
            activeDrag = nil
            let point = event.location
            DispatchQueue.main.async { [weak self] in self?.onMouseDrag?(drag.drag, point, .ended) }
            return nil
        }
        if type == .leftMouseUp {
            let point = event.location
            DispatchQueue.main.async { [weak self] in self?.onRawLeftMouse?(point, .ended) }
        }
        return Unmanaged.passUnretained(event)
    }

    private func button(for type: CGEventType) -> PointerButton {
        switch type {
        case .leftMouseDragged, .leftMouseUp: return .left
        case .rightMouseDragged, .rightMouseUp: return .right
        default: return .middle
        }
    }
}
