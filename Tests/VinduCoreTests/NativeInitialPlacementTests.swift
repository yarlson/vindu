import CoreGraphics
import Testing
@testable import VinduCore

@Suite struct NativeInitialPlacementTests {
    @Test func rulesMatchBundleAndRegexFields() {
        let rule = NativeWindowRule(
            match: NativeWindowMatcher(
                bundleID: "com.example.editor",
                appName: "^Editor$",
                title: "Project"
            ),
            floating: true
        )
        let placement = NativeInitialPlacement.evaluate(
            rules: [rule],
            bundleID: "com.example.editor",
            appName: "Editor",
            title: "Project One",
            defaultFloating: false,
            windowFrame: CGRect(x: 10, y: 10, width: 200, height: 100),
            usable: CGRect(x: 0, y: 0, width: 1000, height: 800)
        )
        #expect(placement.floating)
    }

    @Test func laterFieldsWinBeforeGeometryIsDerived() {
        let rules = [
            NativeWindowRule(
                match: NativeWindowMatcher(appName: "Editor"),
                centered: true,
                size: WindowVector(x: 400, y: 200),
                workspace: .id(2)
            ),
            NativeWindowRule(
                match: NativeWindowMatcher(title: "Project"),
                centered: false,
                position: WindowVector(x: 30, y: 40),
                monitor: .id(1)
            ),
        ]
        let placement = NativeInitialPlacement.evaluate(
            rules: rules,
            bundleID: nil,
            appName: "Editor",
            title: "Project One",
            defaultFloating: false,
            windowFrame: CGRect(x: 10, y: 10, width: 200, height: 100),
            usable: CGRect(x: 100, y: 200, width: 1000, height: 800)
        )
        #expect(placement.floating)
        #expect(placement.workspace == nil)
        #expect(placement.monitor == .id(1))
        #expect(placement.floatFrame == CGRect(x: 130, y: 240, width: 400, height: 200))
    }

    @Test func geometryAndPinImplyFloating() {
        let placement = NativeInitialPlacement.evaluate(
            rules: [NativeWindowRule(
                match: NativeWindowMatcher(bundleID: "com.example.panel"),
                floating: false,
                pinned: true
            )],
            bundleID: "com.example.panel",
            appName: "Panel",
            title: "",
            defaultFloating: false,
            windowFrame: CGRect(x: 10, y: 10, width: 200, height: 100),
            usable: CGRect(x: 0, y: 0, width: 1000, height: 800)
        )
        #expect(placement.floating)
        #expect(placement.pinned)
    }

    @Test func explicitRuleCanTileWindowThatFloatsByDefault() {
        let placement = NativeInitialPlacement.evaluate(
            rules: [NativeWindowRule(
                match: NativeWindowMatcher(appName: "Panel"),
                floating: false
            )],
            bundleID: nil,
            appName: "Panel",
            title: "Preferences",
            defaultFloating: true,
            windowFrame: CGRect(x: 10, y: 10, width: 400, height: 300),
            usable: CGRect(x: 0, y: 0, width: 1000, height: 800)
        )

        #expect(!placement.floating)
    }

    @Test func explicitGeometryIsKeptWhenItMatchesTheSpawnFrame() {
        let frame = CGRect(x: 10, y: 20, width: 200, height: 100)
        let placement = NativeInitialPlacement.evaluate(
            rules: [NativeWindowRule(
                match: NativeWindowMatcher(appName: "Panel"),
                size: WindowVector(x: 200, y: 100),
                position: WindowVector(x: 10, y: 20)
            )],
            bundleID: nil,
            appName: "Panel",
            title: "",
            defaultFloating: false,
            windowFrame: frame,
            usable: CGRect(x: 0, y: 0, width: 1000, height: 800)
        )
        #expect(placement.floatFrame == frame)
    }
}
