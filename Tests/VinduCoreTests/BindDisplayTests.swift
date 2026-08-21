import Foundation
import Testing
@testable import VinduCore

struct BindDisplayTests {
    @Test func rowsRenderCommandsModesAndPointerBindings() {
        let bindings = [
            binding(chord: chord([.option], "return"),
                    action: .command(CommandSpec(
                        execution: .run(["/usr/bin/open", "-a", "Terminal"]),
                        environment: [:]
                    ))),
            binding(chord: chord([.option], "h"), action: .window(.focus(.left))),
            binding(mode: "resize", chord: chord([], "l"),
                    action: .window(.resize(x: 30, y: 0))),
        ]
        let pointer = PointerBinding(modifiers: [.option], button: .left, drag: .move)

        let rows = BindDisplay.rows(bindings, pointerBindings: [pointer])

        #expect(rows.map(\.chord) == ["⌥ ↩", "⌥ H", "⌥ Left drag"])
        #expect(rows.map(\.action) == ["Open Terminal", "Focus left", "Move window"])
    }

    @Test func rowsCollapseWorkspaceDigitRuns() {
        let bindings = (1...4).map { id in
            binding(chord: chord([.option], String(id)),
                    action: .window(.workspace(.id(id))))
        }

        let rows = BindDisplay.rows(bindings)

        #expect(rows.count == 1)
        #expect(rows[0].chord == "⌥ 1…4")
        #expect(rows[0].action == "Workspace 1–4")
    }

    @Test func bindInfoProjectionKeepsArgvAndBindingFlags() throws {
        let command = CommandSpec(execution: .run(["/bin/echo", "two words"]), environment: [:])
        let keyboard = binding(chord: chord([.control, .option], "e"),
                               edge: .release,
                               action: .command(command))
        let pointer = PointerBinding(modifiers: [.option], button: .right, drag: .resize)

        let projection = BindDisplay.bindInfoProjection([keyboard], pointerBindings: [pointer])
        let argv = try JSONDecoder().decode([String].self, from: Data(projection[0].arg.utf8))

        #expect(argv == ["/bin/echo", "two words"])
        #expect(projection[0].release)
        #expect(projection[0].dispatcher == "run")
        #expect(projection[1].mouse)
        #expect(projection[1].dispatcher == "resize")
    }

    private func chord(_ modifiers: [KeyboardModifier], _ key: String) -> KeyChord {
        KeyChord(modifiers: modifiers, key: key)
    }

    private func binding(mode: String = "default",
                         chord: KeyChord,
                         edge: BindingEdge = .press,
                         repeats: Bool = false,
                         action: ConfiguredAction) -> KeyboardBinding {
        KeyboardBinding(mode: mode, chord: chord, edge: edge, repeats: repeats, action: action)
    }
}
