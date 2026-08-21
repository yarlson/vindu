import CoreGraphics
import Foundation
import Testing
import VinduCore
@testable import vindud

struct DefaultConfigurationTests {
    @Test func bracketBindingsMoveBetweenAdjacentWorkspaces() throws {
        let snapshot: ConfigurationSnapshot
        switch ConfigurationCompiler().compile(Data(defaultConfigTemplate.utf8)) {
        case .success(let value):
            snapshot = value
        case .failure(let failure):
            Issue.record("default configuration failed: \(failure.diagnostics)")
            throw failure
        }

        let left = snapshot.keyboard.bindings.first {
            $0.mode == "default" && $0.chord.text == "option+bracketleft"
        }
        let right = snapshot.keyboard.bindings.first {
            $0.mode == "default" && $0.chord.text == "option+bracketright"
        }
        #expect(left?.action == .window(.workspace(.relative(-1))))
        #expect(right?.action == .window(.workspace(.relative(1))))
    }

    @Test func keyReleaseStaysConsumedAfterModeChange() throws {
        let snapshot: ConfigurationSnapshot
        switch ConfigurationCompiler().compile(Data(defaultConfigTemplate.utf8)) {
        case .success(let value):
            snapshot = value
        case .failure(let failure):
            Issue.record("default configuration failed: \(failure.diagnostics)")
            throw failure
        }

        let keycode = try #require(KeyCodes.code(for: "r"))
        let press = try #require(CGEvent(keyboardEventSource: nil,
                                         virtualKey: CGKeyCode(keycode),
                                         keyDown: true))
        press.flags = .maskAlternate
        let release = try #require(CGEvent(keyboardEventSource: nil,
                                           virtualKey: CGKeyCode(keycode),
                                           keyDown: false))
        release.flags = .maskAlternate
        let repeatedPress = try #require(CGEvent(keyboardEventSource: nil,
                                                 virtualKey: CGKeyCode(keycode),
                                                 keyDown: true))
        repeatedPress.flags = .maskAlternate
        repeatedPress.setIntegerValueField(.keyboardEventAutorepeat, value: 1)

        let tap = HotkeyTap()
        tap.rebuild(configuration: snapshot.keyboard)
        #expect(tap.handle(type: .keyDown, event: press) == nil)
        tap.setMode("resize")
        #expect(tap.handle(type: .keyDown, event: repeatedPress) == nil)
        #expect(tap.handle(type: .keyUp, event: release) == nil)
    }
}
