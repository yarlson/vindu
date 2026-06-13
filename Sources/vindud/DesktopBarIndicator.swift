import AppKit
import VinduCore

struct DesktopBarIndicatorPresentation {
    let text: String
    let textWithSymbol: String?
    let symbolNames: [String]
    let color: MLColor

    init(item: BarIndicator, text: String, color: MLColor) {
        self.text = text
        self.symbolNames = Self.symbolNames(for: item, text: text)
        self.color = color

        switch item {
        case .network, .volume:
            self.textWithSymbol = nil
        default:
            self.textWithSymbol = text
        }
    }

    private static func symbolNames(for item: BarIndicator, text: String) -> [String] {
        switch item {
        case .pause:
            return ["pause.fill", "pause"]
        case .submap:
            return ["keyboard"]
        case .layout:
            return ["rectangle.split.2x1", "rectangle.split.2x1.fill"]
        case .windows:
            return ["macwindow.on.rectangle", "macwindow"]
        case .date:
            return []
        case .battery:
            return batterySymbolNames(text)
        case .network:
            return text == "offline" ? ["wifi.slash", "wifi"] : ["wifi", "network"]
        case .keyboard:
            return ["keyboard"]
        case .volume:
            return text == "muted"
                ? ["speaker.slash.fill", "speaker.slash"]
                : ["speaker.wave.2.fill", "speaker.wave.2"]
        }
    }

    private static func batterySymbolNames(_ text: String) -> [String] {
        if text.hasSuffix("+") {
            return ["battery.100.bolt", "battery.100"]
        }
        let capacity = Int(text.prefix { $0.isNumber }) ?? 100
        switch capacity {
        case 90...:
            return ["battery.100"]
        case 65..<90:
            return ["battery.75", "battery.100"]
        case 35..<65:
            return ["battery.50", "battery.100"]
        case 10..<35:
            return ["battery.25", "battery.100"]
        default:
            return ["battery.0", "battery.100"]
        }
    }
}

final class DesktopBarIndicatorView: NSView {
    init(presentation: DesktopBarIndicatorPresentation, metrics: DesktopBarMetrics) {
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: metrics.indicatorHeight).isActive = true

        let tint = NSColor(vinduColor: presentation.color)
        let image = Self.symbolImage(names: presentation.symbolNames, metrics: metrics)
        let labelText = image == nil ? presentation.text : presentation.textWithSymbol

        if let image {
            addImage(image, tint: tint, labelText: labelText, metrics: metrics)
        } else if let labelText {
            addLabel(labelText, tint: tint, metrics: metrics)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func symbolImage(names: [String], metrics: DesktopBarMetrics) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: metrics.iconPointSize,
                                                        weight: .medium)
        for name in names {
            guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                    .withSymbolConfiguration(configuration) else {
                continue
            }
            image.isTemplate = true
            return image
        }
        return nil
    }

    private func addImage(_ image: NSImage, tint: NSColor, labelText: String?,
                          metrics: DesktopBarMetrics) {
        let imageView = NSImageView(image: image)
        imageView.contentTintColor = tint
        imageView.imageAlignment = .alignCenter
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        var constraints = [
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor,
                                               constant: metrics.iconCenterOffset),
            imageView.widthAnchor.constraint(equalToConstant: metrics.iconBoxSize),
            imageView.heightAnchor.constraint(equalToConstant: metrics.iconBoxSize),
        ]
        if let labelText {
            let label = Self.label(labelText, tint: tint, metrics: metrics)
            addSubview(label)
            constraints += [
                label.leadingAnchor.constraint(equalTo: imageView.trailingAnchor,
                                               constant: metrics.iconTextSpacing),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
                label.trailingAnchor.constraint(equalTo: trailingAnchor),
            ]
        } else {
            constraints.append(imageView.trailingAnchor.constraint(equalTo: trailingAnchor))
        }
        NSLayoutConstraint.activate(constraints)
    }

    private func addLabel(_ text: String, tint: NSColor, metrics: DesktopBarMetrics) {
        let label = Self.label(text, tint: tint, metrics: metrics)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    private static func label(_ text: String, tint: NSColor,
                              metrics: DesktopBarMetrics) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedSystemFont(ofSize: metrics.secondaryFontSize, weight: .medium)
        label.textColor = tint
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }
}
