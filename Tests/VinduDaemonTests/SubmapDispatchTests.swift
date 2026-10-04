import Testing
import VinduCore
@testable import vindud

struct SubmapDispatchTests {
    @Test @MainActor func unknownModeIsRejectedAndKeepsTheActiveMode() throws {
        let manager = try managerWithResizeMode()

        let reply = manager.dispatch(Dispatcher.submap("rezise"))

        #expect(reply == "err: unknown mode: rezise")
        #expect(manager.tap.activeMode == "default")
    }

    @Test @MainActor func keybindingToUnknownModeIsRejectedLikeTheSubmapDispatcher() throws {
        let manager = try managerWithResizeMode()

        let reply = manager.dispatch(ConfiguredAction.window(.enterMode("rezise")))

        #expect(reply == "err: unknown mode: rezise")
        #expect(manager.tap.activeMode == "default")
    }

    @Test @MainActor func configuredModeIsEnteredAndResetReturnsToDefault() throws {
        let manager = try managerWithResizeMode()

        #expect(manager.dispatch(Dispatcher.submap("resize")) == "ok")
        #expect(manager.tap.activeMode == "resize")

        #expect(manager.dispatch(Dispatcher.submap("")) == "ok")
        #expect(manager.tap.activeMode == "default")
    }

    private func managerWithResizeMode() throws -> WindowManager {
        try makeTestWindowManager(configuration: compileConfiguration("""
        schema = 1
        [keyboard]
        bindings = [
          { chord = "option+r", enter_mode = "resize" },
          { mode = "resize", chord = "escape", enter_mode = "default" },
        ]
        """))
    }
}
