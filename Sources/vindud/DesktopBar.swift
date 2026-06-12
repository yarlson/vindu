import AppKit
import VinduCore

struct DesktopBarWorkspace {
    let id: Int
    let name: String
    let windows: Int
}

struct DesktopBarSnapshot {
    let monitors: [Monitor]
    let workspaces: [DesktopBarWorkspace]
    let activeWorkspaces: [CGDirectDisplayID: Int]
    let appName: String
    let windowTitle: String
    let layout: LayoutKind
    let submap: String
    let paused: Bool
    let system: DesktopBarSystemInfo
}

/// Same-process desktop bar. It deliberately uses vindu's own state instead of
/// subscribing to the public IPC stream from inside the daemon.
final class DesktopBar {
    var onWorkspaceSelected: ((Int, CGDirectDisplayID) -> Void)?

    private var panels: [CGDirectDisplayID: NSPanel] = [:]
    private var views: [CGDirectDisplayID: DesktopBarView] = [:]

    func update(settings: BarSettings, snapshot: DesktopBarSnapshot, primaryHeight: Double) {
        guard settings.enabled else {
            hide()
            return
        }

        let live = Set(snapshot.monitors.map(\.id))
        for id in Array(panels.keys) where !live.contains(id) {
            removePanel(for: id)
        }

        for monitor in snapshot.monitors {
            let panel = panel(for: monitor.id)
            let view = view(for: monitor.id)
            view.onWorkspaceSelected = { [weak self] workspaceID in
                self?.onWorkspaceSelected?(workspaceID, monitor.id)
            }
            view.render(settings: settings, snapshot: snapshot, monitor: monitor)
            panel.setFrame(Self.panelFrame(for: monitor, settings: settings, primaryHeight: primaryHeight),
                           display: true)
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        for id in Array(panels.keys) {
            removePanel(for: id)
        }
    }

    static func contentRect(for monitor: Monitor, settings: BarSettings) -> CGRect {
        BarGeometry.contentRect(displayFrame: monitor.frame, usable: monitor.usable,
                                settings: settings)
    }

    private func panel(for id: CGDirectDisplayID) -> NSPanel {
        if let panel = panels[id] { return panel }
        let panel = UnconstrainedPanel(contentRect: .zero,
                                       styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panels[id] = panel
        return panel
    }

    private func view(for id: CGDirectDisplayID) -> DesktopBarView {
        if let view = views[id] { return view }
        let view = DesktopBarView()
        views[id] = view
        panels[id]?.contentView = view
        return view
    }

    private func removePanel(for id: CGDirectDisplayID) {
        panels[id]?.orderOut(nil)
        panels.removeValue(forKey: id)
        views.removeValue(forKey: id)
    }

    private static func panelFrame(for monitor: Monitor, settings: BarSettings,
                                   primaryHeight: Double) -> CGRect {
        let topLeft = BarGeometry.barRect(displayFrame: monitor.frame, usable: monitor.usable,
                                          settings: settings)
        return CGRect(x: topLeft.minX,
                      y: primaryHeight - topLeft.maxY,
                      width: topLeft.width,
                      height: topLeft.height)
    }
}

private final class UnconstrainedPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

private final class DesktopBarView: NSView {
    var onWorkspaceSelected: ((Int) -> Void)?

    private let left = NSStackView()
    private let appLabel = NSTextField(labelWithString: "")
    private let right = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    func render(settings: BarSettings, snapshot: DesktopBarSnapshot, monitor: Monitor) {
        let metrics = DesktopBarMetrics(
            height: BarGeometry.resolvedHeight(displayFrame: monitor.frame,
                                               usable: monitor.usable,
                                               settings: settings)
        )
        wantsLayer = true
        layer?.backgroundColor = NSColor(vinduColor: settings.background).cgColor
        left.spacing = metrics.spacing
        right.spacing = metrics.spacing
        leftLeading?.constant = metrics.horizontalPadding
        rightTrailing?.constant = -metrics.horizontalPadding
        leftToRightGap?.constant = -metrics.horizontalPadding

        reset(left)
        reset(right)

        if settings.showWorkspaces {
            for workspace in snapshot.workspaces {
                let active = snapshot.activeWorkspaces[monitor.id] == workspace.id
                let item = WorkspaceButton(workspace: workspace,
                                           active: active,
                                           settings: settings,
                                           metrics: metrics)
                item.onClick = { [weak self] id in self?.onWorkspaceSelected?(id) }
                left.addArrangedSubview(item)
            }
        }

        if settings.showApp {
            appLabel.attributedStringValue = appTitle(snapshot, settings: settings,
                                                      metrics: metrics)
            left.addArrangedSubview(appLabel)
        }

        if settings.showIndicators {
            for item in settings.indicators {
                guard let value = indicatorValue(item, snapshot: snapshot, monitor: monitor) else {
                    continue
                }
                let color = (item == .pause || item == .submap) ? settings.active : settings.inactive
                right.addArrangedSubview(indicator(value, color: color, metrics: metrics))
            }
        }
    }

    private var leftLeading: NSLayoutConstraint?
    private var rightTrailing: NSLayoutConstraint?
    private var leftToRightGap: NSLayoutConstraint?

    private func configure() {
        wantsLayer = true

        for stack in [left, right] {
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 6
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
        }

        appLabel.lineBreakMode = .byTruncatingTail
        appLabel.maximumNumberOfLines = 1
        appLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let leftLeading = left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12)
        let rightTrailing = right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12)
        let leftToRightGap = left.trailingAnchor.constraint(lessThanOrEqualTo: right.leadingAnchor,
                                                            constant: -12)
        self.leftLeading = leftLeading
        self.rightTrailing = rightTrailing
        self.leftToRightGap = leftToRightGap

        NSLayoutConstraint.activate([
            leftLeading,
            left.centerYAnchor.constraint(equalTo: centerYAnchor),
            leftToRightGap,

            rightTrailing,
            right.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func reset(_ stack: NSStackView) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func appTitle(_ snapshot: DesktopBarSnapshot, settings: BarSettings,
                          metrics: DesktopBarMetrics) -> NSAttributedString {
        let app = snapshot.appName.isEmpty ? "No active window" : snapshot.appName
        let title = snapshot.windowTitle.isEmpty ? "" : " - \(snapshot.windowTitle)"
        let out = NSMutableAttributedString(string: app, attributes: [
            .font: NSFont.systemFont(ofSize: metrics.primaryFontSize, weight: .semibold),
            .foregroundColor: NSColor(vinduColor: settings.foreground),
        ])
        out.append(NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: metrics.primaryFontSize, weight: .regular),
            .foregroundColor: NSColor(vinduColor: settings.inactive),
        ]))
        return out
    }

    private func indicator(_ text: String, color: MLColor,
                           metrics: DesktopBarMetrics) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedSystemFont(ofSize: metrics.secondaryFontSize, weight: .medium)
        label.textColor = NSColor(vinduColor: color)
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private func indicatorValue(_ item: BarIndicator, snapshot: DesktopBarSnapshot,
                                monitor: Monitor) -> String? {
        switch item {
        case .pause:
            return snapshot.paused ? "paused" : nil
        case .submap:
            return snapshot.submap.isEmpty ? nil : snapshot.submap
        case .layout:
            return snapshot.layout.rawValue
        case .windows:
            guard let active = snapshot.activeWorkspaces[monitor.id],
                  let ws = snapshot.workspaces.first(where: { $0.id == active }) else {
                return nil
            }
            return "\(ws.windows) win"
        case .date:
            return snapshot.system.date
        case .battery:
            return snapshot.system.battery
        case .network:
            return snapshot.system.network
        case .keyboard:
            return snapshot.system.keyboard
        case .volume:
            return snapshot.system.volume
        }
    }
}

private struct DesktopBarMetrics {
    let height: Double

    var horizontalPadding: CGFloat {
        CGFloat(min(max(height * 0.38, 10), 18))
    }

    var spacing: CGFloat {
        CGFloat(min(max(height * 0.22, 5), 10))
    }

    var pillHeight: CGFloat {
        CGFloat(min(max(height - 8, 18), max(18, height - 4)))
    }

    var pillMinWidth: CGFloat {
        max(22, pillHeight)
    }

    var pillMaxWidth: CGFloat {
        CGFloat(max(80, height * 4))
    }

    var cornerRadius: CGFloat {
        min(6, pillHeight / 4)
    }

    var primaryFontSize: CGFloat {
        CGFloat(min(max(height * 0.42, 12), 15))
    }

    var secondaryFontSize: CGFloat {
        CGFloat(min(max(height * 0.38, 11), 14))
    }
}

private final class WorkspaceButton: NSButton {
    let workspaceID: Int
    var onClick: ((Int) -> Void)?

    init(workspace: DesktopBarWorkspace, active: Bool, settings: BarSettings,
         metrics: DesktopBarMetrics) {
        self.workspaceID = workspace.id
        super.init(frame: .zero)

        let foreground = active
            ? NSColor.contrastingText(for: settings.active)
            : NSColor(vinduColor: workspace.windows > 0 ? settings.foreground : settings.inactive)
        attributedTitle = NSAttributedString(string: workspace.name, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: metrics.secondaryFontSize,
                                               weight: active ? .bold : .medium),
            .foregroundColor: foreground,
        ])
        cell?.lineBreakMode = .byTruncatingTail
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerRadius = metrics.cornerRadius
        layer?.backgroundColor = active
            ? NSColor(vinduColor: settings.active).cgColor
            : NSColor.clear.cgColor
        contentTintColor = foreground
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: metrics.pillHeight).isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: metrics.pillMinWidth).isActive = true
        widthAnchor.constraint(lessThanOrEqualToConstant: metrics.pillMaxWidth).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(workspaceID)
    }
}

private extension NSColor {
    convenience init(vinduColor color: MLColor) {
        self.init(calibratedRed: color.r, green: color.g, blue: color.b, alpha: color.a)
    }

    static func contrastingText(for color: MLColor) -> NSColor {
        let luminance = 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b
        return luminance > 0.55 ? .black : .white
    }
}
