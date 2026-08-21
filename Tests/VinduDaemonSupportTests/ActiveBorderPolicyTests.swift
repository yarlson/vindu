import Testing
@testable import VinduDaemonSupport

struct ActiveBorderPolicyTests {
    @Test func eligibleFocusedWindowReceivesTheBorder() {
        #expect(ActiveBorderPolicy.targetWindowID(for: state()) == 42)
    }

    @Test func borderHidesWhenFocusOrWindowStateIsIneligible() {
        #expect(ActiveBorderPolicy.targetWindowID(for: state(systemFocus: 7)) == nil)
        #expect(ActiveBorderPolicy.targetWindowID(for: state(managedFocus: nil)) == nil)
        #expect(ActiveBorderPolicy.targetWindowID(for: state(systemFocus: nil)) == nil)
        #expect(ActiveBorderPolicy.targetWindowID(for: state(eligible: false)) == nil)
        #expect(ActiveBorderPolicy.targetWindowID(for: state(paused: true)) == nil)
        #expect(ActiveBorderPolicy.targetWindowID(for: state(hidden: true)) == nil)
        #expect(ActiveBorderPolicy.targetWindowID(for: state(minimized: true)) == nil)
        #expect(ActiveBorderPolicy.targetWindowID(for: state(nativeFullscreen: true)) == nil)
        #expect(ActiveBorderPolicy.targetWindowID(for: state(managedFullscreen: true)) == nil)
        #expect(ActiveBorderPolicy.targetWindowID(for: state(width: 0)) == nil)
        #expect(ActiveBorderPolicy.targetWindowID(for: state(width: -.infinity)) == nil)
        #expect(ActiveBorderPolicy.targetWindowID(for: state(width: .nan)) == nil)
    }

    private func state(managedFocus: UInt32? = 42,
                       systemFocus: UInt32? = 42,
                       eligible: Bool = true,
                       paused: Bool = false,
                       hidden: Bool = false,
                       minimized: Bool = false,
                       nativeFullscreen: Bool = false,
                       managedFullscreen: Bool = false,
                       width: Double = 2) -> ActiveBorderState {
        ActiveBorderState(managedWindowID: managedFocus,
                          systemWindowID: systemFocus,
                          eligible: eligible,
                          paused: paused,
                          hidden: hidden,
                          minimized: minimized,
                          nativeFullscreen: nativeFullscreen,
                          managedFullscreen: managedFullscreen,
                          width: width)
    }
}
