import CoreGraphics
import Foundation
import Testing
import VinduCore
@testable import vindud

struct WindowPlacementPolicyTests {
    @Test func resizableStandardWindowTilesAndCanReceiveBorder() {
        let snapshot = snapshot(
            kind: .standard,
            resizeCapability: .resizable,
            windowLevel: Int(CGWindowLevelForKey(.normalWindow))
        )

        #expect(!snapshot.defaultFloating)
        #expect(snapshot.borderEligible)
    }

    @Test func elevatedResizableStandardWindowFloatsAndCanReceiveBorder() {
        let snapshot = snapshot(
            kind: .standard,
            resizeCapability: .resizable,
            windowLevel: Int(CGWindowLevelForKey(.floatingWindow))
        )

        #expect(snapshot.defaultFloating)
        #expect(snapshot.borderEligible)
    }

    @Test func resizableStandardWindowWithUnknownLevelTilesAndCanReceiveBorder() {
        let snapshot = snapshot(kind: .standard, resizeCapability: .resizable)

        #expect(!snapshot.defaultFloating)
        #expect(snapshot.borderEligible)
    }

    @Test func fixedStandardWindowFloatsWithoutBorder() {
        let snapshot = snapshot(kind: .standard, resizeCapability: .fixed)

        #expect(snapshot.defaultFloating)
        #expect(!snapshot.borderEligible)
    }

    @Test func unknownStandardWindowTilesWithoutBorder() {
        let snapshot = snapshot(kind: .standard, resizeCapability: .unknown)

        #expect(!snapshot.defaultFloating)
        #expect(!snapshot.borderEligible)
    }

    @Test func dialogFloatsWithoutBorderWhenResizeCapabilityIsUnknown() {
        let snapshot = snapshot(kind: .dialog, resizeCapability: .unknown)

        #expect(snapshot.defaultFloating)
        #expect(!snapshot.borderEligible)
    }

    @Test @MainActor func minimizedFixedWindowKeepsFloatingMembershipAndSpawnFrame() throws {
        let manager = try manager()
        let frame = CGRect(x: 10, y: 20, width: 400, height: 300)
        let snapshot = snapshot(kind: .standard,
                                resizeCapability: .fixed,
                                frame: frame,
                                isMinimized: true)

        manager.windowAppeared(snapshot)

        let workspace = manager.workspace(forID: 1)
        #expect(manager.windows[42]?.floatFrame == frame)
        #expect(workspace.floating == [42])
        #expect(!workspace.master.contains(42))

        manager.windowDeminimized(42)

        #expect(workspace.floating == [42])
    }

    @Test @MainActor func elevatedResizableWindowUsesFloatingMembershipAndSpawnFrame() throws {
        let manager = try manager()
        let frame = CGRect(x: 10, y: 20, width: 400, height: 300)
        let snapshot = snapshot(
            kind: .standard,
            resizeCapability: .resizable,
            windowLevel: Int(CGWindowLevelForKey(.floatingWindow)),
            frame: frame
        )

        manager.windowAppeared(snapshot)

        let workspace = manager.workspace(forID: 1)
        #expect(manager.windows[42]?.floatFrame == frame)
        #expect(workspace.floating == [42])
        #expect(!workspace.master.contains(42))
    }

    @Test @MainActor func clientInfoReportsObservedFrame() throws {
        let manager = try manager()
        manager.windowAppeared(snapshot(kind: .standard, resizeCapability: .fixed))
        let target = CGRect(x: 870, y: 45, width: 845, height: 1059)
        let observed = CGRect(x: 948, y: 307, width: 689, height: 535)
        manager.windows[42]?.targetFrame = target
        manager.windows[42]?.observedFrame = observed

        let info = try #require(manager.clientInfo(42))

        #expect(info.at == [948, 307])
        #expect(info.size == [689, 535])
    }

    private func snapshot(kind: WindowKind,
                          resizeCapability: WindowResizeCapability,
                          windowLevel: Int? = nil,
                          frame: CGRect = CGRect(x: 10, y: 20, width: 400, height: 300),
                          isMinimized: Bool = false) -> WindowSnapshot {
        WindowSnapshot(id: 42,
                       pid: 1,
                       bundleID: "com.example.app",
                       clazz: "Example",
                       title: "Window",
                       frame: frame,
                       kind: kind,
                       resizeCapability: resizeCapability,
                       windowLevel: windowLevel,
                       isMinimized: isMinimized)
    }

    private func manager() throws -> WindowManager {
        let configuration: ConfigurationSnapshot
        switch ConfigurationCompiler().compile(Data(defaultConfigTemplate.utf8)) {
        case .success(let value):
            configuration = value
        case .failure(let failure):
            Issue.record("default configuration failed: \(failure.diagnostics)")
            throw failure
        }
        return WindowManager(configuration: configuration,
                             configPath: "/tmp/vindu-test.toml",
                             wroteCanonicalDefault: false,
                             broadcastEvent: { _ in },
                             runtimeWarningsChanged: { _ in },
                             quit: {})
    }
}
