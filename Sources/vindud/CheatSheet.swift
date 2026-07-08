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

    private final class DismissScrollView: NSScrollView {
        var onClick: (() -> Void)?
        override func mouseDown(with event: NSEvent) { onClick?() }
    }

    private let panel: NSPanel
    private let container = DismissView()
    private let scrollView = DismissScrollView()
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
        scrollView.onClick = { [weak self] in self?.hide() }

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = label
        scrollView.translatesAutoresizingMaskIntoConstraints = true
        container.addSubview(scrollView)

        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.drawsBackground = false
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.setAccessibilityLabel("vindu keybindings")
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

    func showIfHidden(rows: [(chord: String, action: String)], monitorFrame: CGRect,
                      primaryHeight: Double) {
        guard !panel.isVisible else { return }
        show(rows: rows, monitorFrame: monitorFrame, primaryHeight: primaryHeight)
    }

    /// `monitorFrame` is the target monitor's usable area in top-left-origin
    /// global coordinates; `primaryHeight` converts to AppKit's bottom-left
    /// origin for the panel frame.
    private func show(rows: [(chord: String, action: String)], monitorFrame: CGRect,
                      primaryHeight: Double) {
        label.attributedStringValue = render(rows)
        let layout = Self.layout(for: label, monitorFrame: monitorFrame)
        container.frame = CGRect(origin: .zero, size: layout.panelSize)
        scrollView.frame = CGRect(origin: CGPoint(x: layout.padding, y: layout.padding),
                                  size: layout.viewportSize)
        scrollView.hasVerticalScroller = layout.needsVerticalScroller
        label.frame = CGRect(origin: .zero, size: layout.documentSize)

        let topLeft = Self.centeredFrame(size: layout.panelSize, in: monitorFrame)
        let bottomLeft = CGRect(x: topLeft.minX, y: primaryHeight - topLeft.maxY,
                                width: topLeft.width, height: topLeft.height)
        panel.setFrame(bottomLeft, display: true)
        panel.orderFrontRegardless()
    }

    private struct Layout {
        var padding: CGFloat
        var panelSize: CGSize
        var viewportSize: CGSize
        var documentSize: CGSize
        var needsVerticalScroller: Bool
    }

    private static func layout(for label: NSTextField, monitorFrame: CGRect) -> Layout {
        let padding: CGFloat = 28
        let margin: CGFloat = 32
        let minimumWidth: CGFloat = min(320, max(0, monitorFrame.width - margin * 2))
        let maxPanelWidth = max(minimumWidth, min(760, monitorFrame.width - margin * 2))
        let maxPanelHeight = max(160, monitorFrame.height - margin * 2)
        let maxTextWidth = max(160, maxPanelWidth - padding * 2)

        label.preferredMaxLayoutWidth = maxTextWidth
        label.frame = CGRect(x: 0, y: 0, width: maxTextWidth, height: .greatestFiniteMagnitude)
        label.sizeToFit()

        let contentWidth = min(max(label.frame.width, minimumWidth - padding * 2), maxTextWidth)
        let contentHeight = label.frame.height
        let panelSize = CGSize(width: min(maxPanelWidth, contentWidth + padding * 2),
                               height: min(maxPanelHeight, contentHeight + padding * 2))
        let viewportSize = CGSize(width: max(0, panelSize.width - padding * 2),
                                  height: max(0, panelSize.height - padding * 2))
        let documentSize = CGSize(width: viewportSize.width,
                                  height: max(contentHeight, viewportSize.height))
        return Layout(padding: padding,
                      panelSize: panelSize,
                      viewportSize: viewportSize,
                      documentSize: documentSize,
                      needsVerticalScroller: contentHeight > viewportSize.height)
    }

    private static func centeredFrame(size: CGSize, in monitorFrame: CGRect) -> CGRect {
        let raw = CGRect(x: monitorFrame.midX - size.width / 2,
                         y: monitorFrame.midY - size.height / 2,
                         width: size.width, height: size.height)
        let x = min(max(raw.minX, monitorFrame.minX), max(monitorFrame.minX, monitorFrame.maxX - size.width))
        let y = min(max(raw.minY, monitorFrame.minY), max(monitorFrame.minY, monitorFrame.maxY - size.height))
        return CGRect(x: x, y: y, width: size.width, height: size.height)
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
