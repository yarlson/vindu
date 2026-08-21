import CoreGraphics
import Foundation

public struct NativeInitialPlacement: Equatable {
    public var floating: Bool
    public var pinned: Bool
    public var fullscreen: Bool
    public var workspace: WorkspaceTarget?
    public var monitor: MonitorTarget?
    public var floatFrame: CGRect?

    public static func evaluate(rules: [NativeWindowRule],
                                bundleID: String?,
                                appName: String,
                                title: String,
                                defaultFloating: Bool,
                                windowFrame: CGRect,
                                usable: CGRect) -> NativeInitialPlacement {
        var floating = defaultFloating
        var centered = false
        var pinned = false
        var fullscreen = false
        var size: WindowVector?
        var position: WindowVector?
        var workspace: WorkspaceTarget?
        var monitor: MonitorTarget?

        for rule in rules where rule.match.matches(bundleID: bundleID,
                                                    appName: appName,
                                                    title: title) {
            if let value = rule.floating { floating = value }
            if let value = rule.centered { centered = value }
            if let value = rule.pinned { pinned = value }
            if let value = rule.fullscreen { fullscreen = value }
            if let value = rule.size { size = value }
            if let value = rule.position { position = value }
            if let value = rule.workspace {
                workspace = value
                monitor = nil
            }
            if let value = rule.monitor {
                monitor = value
                workspace = nil
            }
        }

        if centered || pinned || size != nil || position != nil {
            floating = true
        }

        var frame = windowFrame
        if let size {
            frame.size = CGSize(width: size.x, height: size.y)
        }
        if let position {
            frame.origin = CGPoint(x: usable.minX + position.x,
                                   y: usable.minY + position.y)
        }
        if centered {
            frame.origin = CGPoint(x: usable.midX - frame.width / 2,
                                   y: usable.midY - frame.height / 2)
        }

        return NativeInitialPlacement(
            floating: floating,
            pinned: pinned,
            fullscreen: fullscreen,
            workspace: workspace,
            monitor: monitor,
            floatFrame: floating && (size != nil || position != nil || centered) ? frame : nil
        )
    }
}

private extension NativeWindowMatcher {
    func matches(bundleID: String?, appName: String, title: String) -> Bool {
        if let expected = self.bundleID, expected != bundleID { return false }
        if let pattern = self.appName, !pattern.matches(appName) { return false }
        if let pattern = self.title, !pattern.matches(title) { return false }
        return true
    }
}

private extension String {
    func matches(_ value: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: self) else { return false }
        let range = NSRange(location: 0, length: (value as NSString).length)
        return expression.firstMatch(in: value, range: range) != nil
    }
}
