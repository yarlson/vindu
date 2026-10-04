import Testing
import VinduCore
@testable import vindud

struct SubmapDispatchTests {
    @Test @MainActor func unknownModeIsRejectedAndKeepsTheActiveMode() throws {
        let manager = try makeDefaultWindowManager()

        let reply = manager.dispatch(Dispatcher.submap("rezise"))

        #expect(reply == "err: unknown mode: rezise")
        #expect(manager.tap.activeMode == "default")
    }

    @Test @MainActor func configuredModeIsEnteredAndResetReturnsToDefault() throws {
        let manager = try makeDefaultWindowManager()

        #expect(manager.dispatch(Dispatcher.submap("resize")) == "ok")
        #expect(manager.tap.activeMode == "resize")

        #expect(manager.dispatch(Dispatcher.submap("")) == "ok")
        #expect(manager.tap.activeMode == "default")
    }
}
