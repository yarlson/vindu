import AppKit
import VinduCore

/// Active-window border, Hyprland's `col.active_border`. macOS gives no access
/// to other apps' compositing, so the border is a transparent click-through
/// panel floated around the focused window's frame.
final class BorderOverlay {
    private let panel: NSPanel
    private let view = NSView()

    init() {
        panel = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        view.wantsLayer = true
        panel.contentView = view
    }

    /// `frame` is the focused window in top-left-origin global coordinates;
    /// `primaryHeight` converts to AppKit's bottom-left origin.
    func show(around frame: CGRect, gradient: MLGradient, width: Double,
              rounding: Double, primaryHeight: Double) {
        guard width > 0, let color = gradient.colors.first else {
            hide()
            return
        }
        let outer = frame.insetBy(dx: -width, dy: -width)
        let bl = CGRect(x: outer.minX,
                        y: primaryHeight - outer.maxY,
                        width: outer.width,
                        height: outer.height)
        panel.setFrame(bl, display: false)
        if let layer = view.layer {
            layer.borderWidth = width
            layer.cornerRadius = rounding > 0 ? rounding + width : 0
            layer.borderColor = CGColor(red: color.r, green: color.g, blue: color.b, alpha: color.a)
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}
