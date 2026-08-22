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

    @Test func visibleTiledWindowSchedulesInitialSettle() {
        #expect(shouldScheduleInitialTileSettle(
            floating: false,
            minimized: false,
            visible: true
        ))
    }

    @Test func floatingWindowDoesNotScheduleInitialSettle() {
        #expect(!shouldScheduleInitialTileSettle(
            floating: true,
            minimized: false,
            visible: true
        ))
    }

    @Test func minimizedTiledWindowDoesNotScheduleInitialSettle() {
        #expect(!shouldScheduleInitialTileSettle(
            floating: false,
            minimized: true,
            visible: true
        ))
    }

    @Test func hiddenWorkspaceWindowDoesNotScheduleInitialSettle() {
        #expect(!shouldScheduleInitialTileSettle(
            floating: false,
            minimized: false,
            visible: false
        ))
    }

    @Test func startupDriftDoesNotReplacePendingInitialSettle() {
        #expect(!shouldReplaceScheduledTileSettle(
            initialPending: true,
            requestingInitial: false
        ))
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
