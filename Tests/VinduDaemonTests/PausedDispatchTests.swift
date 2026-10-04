import Testing
import VinduCore
@testable import vindud

struct PausedDispatchTests {
    @Test func keybindingAndDispatcherPathsExemptTheSameActionsFromPause() throws {
        let command = try #require(try defaultConfiguration().keyboard.bindings.first {
            if case .command = $0.action { return true }
            return false
        }?.action)
        let equivalents: [(ConfiguredAction, Dispatcher)] = [
            (command, .exec("open -a Terminal")),
            (.window(.pause(.toggle)), .pause(.toggle)),
            (.window(.quit), .exit),
            (.window(.workspace(.id(2))), .workspace(.id(2))),
            (.window(.monitor(.current)), .focusmonitor(.current)),
            (.window(.enterMode("resize")), .submap("resize")),
        ]

        for (keybinding, dispatcher) in equivalents {
            #expect(keybinding.runsWhilePaused == dispatcher.runsWhilePaused,
                    "\(keybinding) and \(dispatcher) disagree while paused")
        }
    }

    @Test @MainActor func pausedWorkspaceSwitchIsRejectedOnBothPaths() throws {
        let manager = try makeDefaultWindowManager()
        manager.setPaused(true)

        let keybindingReply = manager.dispatch(ConfiguredAction.window(.workspace(.id(2))))
        let dispatcherReply = manager.dispatch(Dispatcher.workspace(.id(2)))

        #expect(keybindingReply.hasPrefix("err: tiling is paused"))
        #expect(dispatcherReply == keybindingReply)
    }
}
