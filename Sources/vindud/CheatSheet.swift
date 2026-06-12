import AppKit
import VinduCore

/// Keybinding overlay: a click-to-dismiss panel listing the root keymap,
/// rendered from the live parsed binds so it always matches the user's
/// config. Shown automatically on first run and on demand from the menu bar.
final class CheatSheet {
    /// Content view that dismisses the panel on any click.
    private final class DismissView: NSView {
        var onClick: (() -> Void)?
        override func mouseDown(with event: NSEvent) { onClick?() }
    }

    private let panel: NSPanel
    private let container = DismissView()
    private let label = NSTextField()

    init() {
        panel = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 0.94).cgColor
        container.layer?.cornerRadius = 14
        container.onClick = { [weak self] in self?.hide() }

        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.drawsBackground = false
        label.maximumNumberOfLines = 0
        container.addSubview(label)
        panel.contentView = container
    }

    func toggle(rows: [(chord: String, action: String)], monitorFrame: CGRect, primaryHeight: Double) {
        if panel.isVisible {
            hide()
        } else {
            show(rows: rows, monitorFrame: monitorFrame, primaryHeight: primaryHeight)
        }
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// `monitorFrame` is the target monitor's usable area in top-left-origin
    /// global coordinates; `primaryHeight` converts to AppKit's bottom-left
    /// origin for the panel frame.
    private func show(rows: [(chord: String, action: String)], monitorFrame: CGRect,
                      primaryHeight: Double) {
        label.attributedStringValue = render(rows)
        label.sizeToFit()
        let pad: CGFloat = 28
        let size = CGSize(width: label.frame.width + pad * 2,
                          height: label.frame.height + pad * 2)
        label.setFrameOrigin(NSPoint(x: pad, y: pad))

        let topLeft = CGRect(x: monitorFrame.midX - size.width / 2,
                             y: monitorFrame.midY - size.height / 2,
                             width: size.width, height: size.height)
        let bottomLeft = CGRect(x: topLeft.minX, y: primaryHeight - topLeft.maxY,
                                width: topLeft.width, height: topLeft.height)
        panel.setFrame(bottomLeft, display: true)
        panel.orderFrontRegardless()
    }

    private func render(_ rows: [(chord: String, action: String)]) -> NSAttributedString {
        let mono = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let monoBold = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
        let chordWidth = rows.map { $0.chord.count }.max() ?? 0

        let out = NSMutableAttributedString()
        out.append(NSAttributedString(string: "vindu — keybindings\n\n", attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .bold),
            .foregroundColor: NSColor.white,
        ]))
        for row in rows {
            let padded = String(repeating: " ", count: max(0, chordWidth - row.chord.count))
                + row.chord
            out.append(NSAttributedString(string: padded + "   ", attributes: [
                .font: monoBold,
                .foregroundColor: NSColor.systemTeal,
            ]))
            out.append(NSAttributedString(string: row.action + "\n", attributes: [
                .font: mono,
                .foregroundColor: NSColor.white,
            ]))
        }
        out.append(NSAttributedString(string: "\nclick to dismiss — reopen from the menu bar",
                                      attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor(calibratedWhite: 1.0, alpha: 0.5),
        ]))
        return out
    }
}
