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

    @Test func appIconIsNotDrawnWhileTheOptionIsOff() throws {
        let plain = try pixel(render(button(icon: nil, configuration: iconOff)), offset: -7)
        let withIcon = try pixel(render(button(icon: red, configuration: iconOff)), offset: -7)

        #expect(withIcon == plain)
    }

    @Test func pressedPillKeepsTheAppIcon() throws {
        let button = try button(icon: red, configuration: iconOn)
        let normal = try pixel(render(button), offset: -7)
        let pressed = try pixel(render(button, highlighted: true), offset: -7)

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

    private func pixel(_ bitmap: NSBitmapImageRep, offset: Int) throws -> Pixel {
        let scale = bitmap.pixelsWide / 40
        let color = try #require(bitmap.colorAt(x: (20 + offset) * scale, y: bitmap.pixelsHigh / 2))
        return Pixel(red: color.redComponent, green: color.greenComponent,
                     blue: color.blueComponent, alpha: color.alphaComponent)
    }

    private struct Pixel: Equatable {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat
    }
}
