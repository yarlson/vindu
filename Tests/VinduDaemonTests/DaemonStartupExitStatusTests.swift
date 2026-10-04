import Testing
import VinduDaemonSupport
@testable import vindud

struct DaemonStartupExitStatusTests {
    @Test func anotherRunningInstanceExitsSuccessfullySoLaunchdDoesNotRestart() {
        let error = SecureSocketError.alreadyRunning("/tmp/vindu/vindu.sock")

        #expect(DaemonCoordinator.startupExitStatus(for: error) == 0)
    }

    @Test(arguments: [
        SecureSocketError.unsafeRuntimeDirectory("mode 0755"),
        SecureSocketError.unsafeSocketPath("symlink"),
        SecureSocketError.pathTooLong("/tmp/long"),
        SecureSocketError.socketFailed("bind(): 13"),
    ])
    func otherStartupFailuresExitWithFailure(_ error: SecureSocketError) {
        #expect(DaemonCoordinator.startupExitStatus(for: error) == 1)
    }
}
