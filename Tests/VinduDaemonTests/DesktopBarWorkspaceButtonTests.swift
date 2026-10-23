import AppKit
import Testing
import VinduCore
@testable import vindud

@MainActor
struct DesktopBarWorkspaceButtonTests {
    private let red = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
        NSColor.red.setFill()
        rect.fill()
        return true
    }

    private let blue = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
        NSColor.blue.setFill()
        rect.fill()
        return true
    }

    private let redOverBlue = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
        NSColor.blue.setFill()
        rect.fill()
        NSColor.red.setFill()
        NSRect(x: 0, y: 32, width: 64, height: 32).fill()
        return true
    }

    // U+2588 fills its glyph box, so the pill center is title ink and a point
    // 7 pt left of it is inside the 20 pt icon square but outside the glyph.
    private let workspace = DesktopBarWorkspace(id: 1, name: "\u{2588}", windows: 1,
                                                appProcessIdentifier: 7, appName: "Notes")

    @Test func appIconStaysBeneathTheWorkspaceName() throws {
        let plain = try pixel(render(button(icon: nil, configuration: iconOn)), offset: 0)
        let withIcon = try pixel(render(button(icon: red, configuration: iconOn)), offset: 0)

        #expect(withIcon == plain)
    }

    @Test func appIconIsTranslucentAboveThePill() throws {
        let plain = try pixel(render(button(icon: nil, configuration: iconOn)), offset: -7)
        let translucent = try pixel(render(button(icon: red, configuration: iconOn)), offset: -7)
        let opaque = try pixel(render(button(icon: red, configuration: iconOpaque)), offset: -7)

        #expect(plain.red < translucent.red && translucent.red < opaque.red,
                "red: pill \(plain.red), 0.35 \(translucent.red), 1 \(opaque.red)")
        #expect(plain.green > translucent.green && translucent.green > opaque.green,
                "green: pill \(plain.green), 0.35 \(translucent.green), 1 \(opaque.green)")
    }

    @Test func appIconScaleShrinksTheIcon() throws {
        let plain = try pixel(render(button(icon: nil, configuration: iconOn)), offset: -7)
        let halfSize = try pixel(render(button(icon: red, configuration: iconOn + "\napp_icon_scale = 0.5")),
                                 offset: -7)

        // Half of the 20 pt pill gives a 10 pt icon, which ends 5 pt left of center.
        #expect(halfSize == plain)
    }

    @Test func appIconIsUpright() throws {
        let bitmap = try render(button(icon: redOverBlue, configuration: iconOpaque))
        let upper = try pixel(bitmap, offset: -7, rise: 5)
        let lower = try pixel(bitmap, offset: -7, rise: -5)

        #expect(upper.red > upper.blue, "upper half of the icon: \(upper)")
        #expect(lower.blue > lower.red, "lower half of the icon: \(lower)")
    }

    @Test func appIconIsNotDrawnWhileTheOptionIsOff() throws {
        let plain = try pixel(render(button(icon: nil, configuration: iconOff)), offset: -7)
        let withIcon = try pixel(render(button(icon: red, configuration: iconOff)), offset: -7)

        #expect(withIcon == plain)
    }

    @Test func pillsWithoutTheOptionKeepAppKitLayerRendering() throws {
        #expect(try button(icon: red, configuration: iconOff).wantsUpdateLayer)
    }

    @Test func pressedPillKeepsTheAppIcon() throws {
        let plain = try pixel(render(button(icon: nil, configuration: iconOn)), offset: -7)
        let button = try button(icon: red, configuration: iconOn)
        let normal = try pixel(render(button), offset: -7)
        let pressed = try pixel(render(button, highlighted: true), offset: -7)

        #expect(normal != plain)
        #expect(pressed == normal)
    }

    @Test func accessibilityValueNamesTheAppOnlyWhenTheIconIsDrawn() throws {
        #expect(try button(icon: red, configuration: iconOn).accessibilityValue() as? String
                == "active, Notes")
        #expect(try button(icon: nil, configuration: iconOn).accessibilityValue() as? String
                == "active")
        #expect(try button(icon: red, configuration: iconOff).accessibilityValue() as? String
                == "active")
    }

    @Test func barViewHandsCachedIconsToPillsAndTheAppItem() throws {
        let configuration = try compileConfiguration("""
        schema = 1
        [ui.bar]
        left = ["workspaces", "application"]
        center = []
        right = []
        [ui.bar.workspaces]
        app_icon = true
        """).ui.bar
        let monitor = Monitor(id: 1, index: 0, name: "Main",
                              frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                              usable: CGRect(x: 0, y: 28, width: 800, height: 572),
                              scale: 2, topObstruction: nil)
        let snapshot = testDesktopBarSnapshot(monitors: [monitor], workspaces: [workspace],
                                              activeWorkspaces: [1: 1], appProcessIdentifier: 9)
        let view = DesktopBarView(frame: NSRect(x: 0, y: 0, width: 800, height: 28))

        view.render(configuration: configuration, snapshot: snapshot, monitor: monitor,
                    appIcons: [7: red, 9: blue])

        let subviews = descendants(of: view)
        let pill = try #require(subviews.compactMap { $0 as? WorkspaceButton }.first)
        #expect(pill.accessibilityValue() as? String == "active, Notes")
        #expect(subviews.compactMap { ($0 as? NSImageView)?.image }.contains { $0 === blue })
    }

    private var iconOn: String { "schema = 1\n[ui.bar.workspaces]\napp_icon = true" }
    private var iconOpaque: String { iconOn + "\napp_icon_opacity = 1" }
    private var iconOff: String { "schema = 1\n" }

    private func button(icon: NSImage?, configuration text: String) throws -> WorkspaceButton {
        let bar = try compileConfiguration(text).ui.bar
        return WorkspaceButton(workspace: workspace, active: true, appIcon: icon,
                               appIconStyle: bar.workspaceAppIcon, colors: bar.colors,
                               metrics: DesktopBarMetrics(height: 28))
    }

    private func render(_ button: WorkspaceButton,
                        highlighted: Bool = false) throws -> NSBitmapImageRep {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 28))
        host.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: host.centerYAnchor),
        ])
        button.highlight(highlighted)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        button.removeFromSuperview()
        return bitmap
    }

    /// `offset` and `rise` are points from the center; bitmap row 0 is the top.
    private func pixel(_ bitmap: NSBitmapImageRep, offset: Int, rise: Int = 0) throws -> Pixel {
        let scale = bitmap.pixelsWide / 40
        let color = try #require(bitmap.colorAt(x: (20 + offset) * scale,
                                                y: bitmap.pixelsHigh / 2 - rise * scale))
        return Pixel(red: color.redComponent, green: color.greenComponent,
                     blue: color.blueComponent, alpha: color.alphaComponent)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }

    private struct Pixel: Equatable {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat
    }
}
