import AppKit
import VinduCore
import VinduDaemonSupport

struct DesktopBarWorkspace {
    let id: Int
    let name: String
    let windows: Int
}

struct DesktopBarSnapshot {
    let monitors: [Monitor]
    let workspaces: [DesktopBarWorkspace]
    let activeWorkspaces: [CGDirectDisplayID: Int]
    let appProcessIdentifier: pid_t?
    let appName: String
    let windowTitle: String
    let layout: LayoutKind
    let submap: String
    let paused: Bool
    let system: DesktopBarSystemInfo
    let plugins: [String: BarPluginValue]
}

/// Same-process desktop bar. It deliberately uses vindu's own state instead of
/// subscribing to the public IPC stream from inside the daemon.
final class DesktopBar {
    var onWorkspaceSelected: ((Int, CGDirectDisplayID) -> Void)?

    private var panels: [CGDirectDisplayID: NSPanel] = [:]
    private var views: [CGDirectDisplayID: DesktopBarView] = [:]

    func update(configuration: NativeBarConfiguration, snapshot: DesktopBarSnapshot,
                primaryHeight: Double) {
        guard configuration.enabled else {
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
            panel.setFrame(Self.panelFrame(for: monitor, configuration: configuration,
                                           primaryHeight: primaryHeight), display: true)
            view.render(configuration: configuration, snapshot: snapshot, monitor: monitor)
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        for id in Array(panels.keys) {
            removePanel(for: id)
        }
    }

    static func contentRect(for monitor: Monitor,
                            configuration: NativeBarConfiguration) -> CGRect {
        BarGeometry.contentRect(displayFrame: monitor.frame, usable: monitor.usable,
                                configuration: configuration)
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

    private static func panelFrame(for monitor: Monitor,
                                   configuration: NativeBarConfiguration,
                                   primaryHeight: Double) -> CGRect {
        let topLeft = BarGeometry.barRect(displayFrame: monitor.frame, usable: monitor.usable,
                                          configuration: configuration)
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
    private let center = NSStackView()
    private let appView = DesktopBarAppView()
    private let right = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    func render(configuration: NativeBarConfiguration, snapshot: DesktopBarSnapshot,
                monitor: Monitor) {
        let metrics = DesktopBarMetrics(
            height: BarGeometry.resolvedHeight(displayFrame: monitor.frame,
                                               usable: monitor.usable,
                                               configuration: configuration)
        )
        wantsLayer = true
        layer?.backgroundColor = NSColor(vinduColor: configuration.colors.background.displayColor)
            .cgColor
        for stack in [left, center, right] {
            stack.spacing = metrics.spacing
        }
        leftLeading?.constant = metrics.horizontalPadding
        rightTrailing?.constant = -metrics.horizontalPadding
        leftToRightGap?.constant = -metrics.horizontalPadding

        reset(left)
        reset(center)
        reset(right)
        center.isHidden = false

        render(configuration.left, into: left, configuration: configuration,
               snapshot: snapshot, monitor: monitor, metrics: metrics)
        render(configuration.center, into: center, configuration: configuration,
               snapshot: snapshot, monitor: monitor, metrics: metrics)
        render(configuration.right, into: right, configuration: configuration,
               snapshot: snapshot, monitor: monitor, metrics: metrics)

        layoutSubtreeIfNeeded()
        center.isHidden = !BarZoneGeometry.centerIsVisible(
            barWidth: Double(bounds.width),
            horizontalPadding: Double(metrics.horizontalPadding),
            minimumGap: Double(metrics.horizontalPadding),
            leftWidth: Double(left.fittingSize.width),
            centerWidth: Double(center.fittingSize.width),
            rightWidth: Double(right.fittingSize.width),
            position: configuration.position,
            topObstruction: monitor.topObstruction
        )
    }

    private var leftLeading: NSLayoutConstraint?
    private var rightTrailing: NSLayoutConstraint?
    private var leftToRightGap: NSLayoutConstraint?

    private func configure() {
        wantsLayer = true

        for stack in [left, center, right] {
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 6
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
        }

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

            center.centerXAnchor.constraint(equalTo: centerXAnchor),
            center.centerYAnchor.constraint(equalTo: centerYAnchor),

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

    private func render(_ items: [NativeBarItem], into stack: NSStackView,
                        configuration: NativeBarConfiguration,
                        snapshot: DesktopBarSnapshot, monitor: Monitor,
                        metrics: DesktopBarMetrics) {
        for item in items {
            switch item {
            case .workspaces:
                for workspace in snapshot.workspaces {
                    let active = snapshot.activeWorkspaces[monitor.id] == workspace.id
                    let button = WorkspaceButton(workspace: workspace,
                                                 active: active,
                                                 colors: configuration.colors,
                                                 metrics: metrics)
                    button.onClick = { [weak self] id in self?.onWorkspaceSelected?(id) }
                    stack.addArrangedSubview(button)
                }
            case .application:
                appView.render(title: appTitle(snapshot, configuration: configuration,
                                               metrics: metrics),
                               processIdentifier: snapshot.appProcessIdentifier,
                               metrics: metrics)
                stack.addArrangedSubview(appView)
            default:
                guard let presentation = indicatorPresentation(
                    item, snapshot: snapshot, monitor: monitor,
                    configuration: configuration
                ) else { continue }
                stack.addArrangedSubview(
                    DesktopBarIndicatorView(presentation: presentation, metrics: metrics)
                )
            }
        }
    }

    private func appTitle(_ snapshot: DesktopBarSnapshot,
                          configuration: NativeBarConfiguration,
                          metrics: DesktopBarMetrics) -> NSAttributedString {
        let app = snapshot.appName.isEmpty ? "No active window" : snapshot.appName
        let title = snapshot.windowTitle.isEmpty ? "" : " - \(snapshot.windowTitle)"
        let out = NSMutableAttributedString(string: app, attributes: [
            .font: NSFont.systemFont(ofSize: metrics.primaryFontSize, weight: .semibold),
            .foregroundColor: NSColor(vinduColor: configuration.colors.foreground.displayColor),
        ])
        out.append(NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: metrics.primaryFontSize, weight: .regular),
            .foregroundColor: NSColor(vinduColor: configuration.colors.inactive.displayColor),
        ]))
        return out
    }

    private func indicatorPresentation(_ item: NativeBarItem, snapshot: DesktopBarSnapshot,
                                       monitor: Monitor,
                                       configuration: NativeBarConfiguration)
        -> DesktopBarIndicatorPresentation? {
        switch item {
        case .plugin(let id):
            guard let value = snapshot.plugins[id] else { return nil }
            return DesktopBarIndicatorPresentation(text: value.text,
                                                   color: pluginColor(value.color,
                                                                      colors: configuration.colors),
                                                   symbolNames: value.symbolNames)
        case .workspaces, .application:
            return nil
        default:
            return builtinIndicatorPresentation(item, snapshot: snapshot,
                                                monitor: monitor,
                                                configuration: configuration)
        }
    }

    private func builtinIndicatorPresentation(_ item: NativeBarItem,
                                              snapshot: DesktopBarSnapshot,
                                              monitor: Monitor,
                                              configuration: NativeBarConfiguration)
        -> DesktopBarIndicatorPresentation? {
        let color = (item == .pause || item == .mode)
            ? configuration.colors.active.displayColor
            : configuration.colors.foreground.displayColor
        if item == .weather {
            guard let weather = snapshot.system.weather else { return nil }
            return DesktopBarIndicatorPresentation(item: item,
                                                   text: weather.text,
                                                   color: color,
                                                   symbolNames: weather.symbolNames)
        }
        if item == .volume {
            guard let volume = snapshot.system.volume else { return nil }
            return DesktopBarIndicatorPresentation(item: item,
                                                   text: volume.text,
                                                   color: color,
                                                   symbolNames: DesktopBarIndicatorPresentation
                                                       .volumeSymbolNames(volume))
        }
        guard let value = indicatorValue(item, snapshot: snapshot, monitor: monitor) else {
            return nil
        }
        return DesktopBarIndicatorPresentation(item: item, text: value, color: color)
    }

    private func pluginColor(_ color: BarPluginColor, colors: NativeBarColors) -> MLColor {
        switch color {
        case .foreground: return colors.foreground.displayColor
        case .inactive: return colors.inactive.displayColor
        case .active: return colors.active.displayColor
        case .custom(let custom): return custom
        }
    }

    private func indicatorValue(_ item: NativeBarItem, snapshot: DesktopBarSnapshot,
                                monitor: Monitor) -> String? {
        switch item {
        case .pause:
            return snapshot.paused ? "paused" : nil
        case .mode:
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
            return snapshot.system.volume?.text
        case .weather:
            return snapshot.system.weather?.text
        case .workspaces, .application, .plugin:
            return nil
        }
    }
}

private final class DesktopBarAppView: NSStackView {
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var iconWidth: NSLayoutConstraint?
    private var iconHeight: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    func render(title: NSAttributedString, processIdentifier: pid_t?,
                metrics: DesktopBarMetrics) {
        spacing = metrics.iconTextSpacing
        label.attributedStringValue = title
        iconWidth?.constant = metrics.appIconSize
        iconHeight?.constant = metrics.appIconSize

        let image = processIdentifier.flatMap {
            NSRunningApplication(processIdentifier: $0)?.icon
        }
        iconView.image = image
        iconView.isHidden = image == nil
    }

    private func configure() {
        orientation = .horizontal
        alignment = .centerY
        spacing = 4
        translatesAutoresizingMaskIntoConstraints = false

        iconView.imageAlignment = .alignCenter
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconWidth = iconView.widthAnchor.constraint(equalToConstant: 16)
        iconHeight = iconView.heightAnchor.constraint(equalToConstant: 16)

        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addArrangedSubview(iconView)
        addArrangedSubview(label)
        NSLayoutConstraint.activate([iconWidth, iconHeight].compactMap { $0 })
    }
}

struct DesktopBarMetrics {
    let height: Double

    var horizontalPadding: CGFloat {
        CGFloat(min(max(height * 0.38, 10), 18))
    }

    var spacing: CGFloat {
        CGFloat(min(max(height * 0.22, 5), 10))
    }

    var indicatorSpacing: CGFloat {
        CGFloat(min(max(height * 0.46, 10), 15))
    }

    var iconTextSpacing: CGFloat {
        CGFloat(min(max(height * 0.14, 3), 6))
    }

    var indicatorHeight: CGFloat {
        CGFloat(min(max(height * 0.62, 15), 18))
    }

    var appIconSize: CGFloat {
        indicatorHeight
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

    var iconPointSize: CGFloat {
        CGFloat(min(max(height * 0.54, 13), 16))
    }

    var iconBoxSize: CGFloat {
        iconPointSize + 1
    }

    var iconCenterOffset: CGFloat {
        -0.5
    }
}

private final class WorkspaceButton: NSButton {
    let workspaceID: Int
    var onClick: ((Int) -> Void)?

    init(workspace: DesktopBarWorkspace, active: Bool, colors: NativeBarColors,
         metrics: DesktopBarMetrics) {
        self.workspaceID = workspace.id
        super.init(frame: .zero)

        let foreground = active
            ? NSColor.contrastingText(for: colors.active.displayColor)
            : NSColor(vinduColor: workspace.windows > 0
                ? colors.foreground.displayColor : colors.inactive.displayColor)
        attributedTitle = NSAttributedString(string: workspace.name, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: metrics.secondaryFontSize,
                                               weight: active ? .bold : .medium),
            .foregroundColor: foreground,
        ])
        cell?.lineBreakMode = .byTruncatingTail
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        target = self
        action = #selector(activateWorkspace)
        wantsLayer = true
        layer?.cornerRadius = metrics.cornerRadius
        layer?.backgroundColor = active
            ? NSColor(vinduColor: colors.active.displayColor).cgColor
            : NSColor.clear.cgColor
        contentTintColor = foreground
        setAccessibilityLabel("Workspace \(workspace.name)")
        setAccessibilityValue(active ? "active" : "\(workspace.windows) windows")
        setAccessibilityHelp("Switch to workspace \(workspace.name)")
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: metrics.pillHeight).isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: metrics.pillMinWidth).isActive = true
        widthAnchor.constraint(lessThanOrEqualToConstant: metrics.pillMaxWidth).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func activateWorkspace() {
        onClick?(workspaceID)
    }
}

private extension ConfigurationColor {
    var displayColor: MLColor {
        MLColor(r: red, g: green, b: blue, a: alpha)
    }
}

extension NSColor {
    convenience init(vinduColor color: MLColor) {
        self.init(calibratedRed: color.r, green: color.g, blue: color.b, alpha: color.a)
    }

    static func contrastingText(for color: MLColor) -> NSColor {
        let luminance = 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b
        return luminance > 0.55 ? .black : .white
    }
}
