import CoreGraphics
import Foundation
import Testing
@testable import vindud

struct HotkeyTapTests {
    @Test @MainActor func reenabledTapEndsTheLostPointerDragAndPassesTheNextRelease() async throws {
        let tap = HotkeyTap()
        tap.rebuild(configuration: try compileConfiguration("""
        schema = 1
        [keyboard]
        pointer_bindings = [{ modifiers = ["option"], button = "left", drag = "move" }]
        """).keyboard)
        var endedDrags = 0
        tap.onMouseDrag = { _, _, phase in
            if phase == .ended { endedDrags += 1 }
        }
        let optionDown = try mouseEvent(.leftMouseDown, flags: .maskAlternate)
        #expect(tap.handle(type: .leftMouseDown, event: optionDown) == nil)

        _ = tap.handle(type: .tapDisabledByTimeout, event: try mouseEvent(.mouseMoved))
        let release = try mouseEvent(.leftMouseUp)

        #expect(tap.handle(type: .leftMouseUp, event: release) != nil)
        await drainMainQueue()
        #expect(endedDrags == 1)
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func mouseEvent(_ type: CGEventType, flags: CGEventFlags = []) throws -> CGEvent {
        let event = try #require(CGEvent(mouseEventSource: nil,
                                         mouseType: type,
                                         mouseCursorPosition: CGPoint(x: 100, y: 100),
                                         mouseButton: .left))
        event.flags = flags
        return event
    }
}
