import AppKit
import VinduCore

/// A display. All rects are top-left-origin global coordinates (CG space):
/// `frame` is the full display, `usable` excludes the menu bar and Dock.
struct Monitor {
    let id: CGDirectDisplayID
    let index: Int
    let name: String
    let frame: CGRect
    let usable: CGRect
    let scale: Double
}

final class MonitorManager {
    private(set) var monitors: [Monitor] = []
    var onChange: (() -> Void)?

    /// Height of the primary screen; converts top-left CG coords to AppKit's
    /// bottom-left for NSWindow placement.
    private(set) var primaryHeight: Double = 0

    func start() {
        rebuild()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.rebuild()
            self?.onChange?()
        }
    }

    func rebuild() {
        primaryHeight = Double(NSScreen.screens.first?.frame.height ?? 0)
        var out: [Monitor] = []
        for (i, screen) in NSScreen.screens.enumerated() {
            guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            let did = CGDirectDisplayID(num.uint32Value)
            let bounds = CGDisplayBounds(did)
            let f = screen.frame
            let v = screen.visibleFrame
            let usable = CGRect(
                x: bounds.minX + (v.minX - f.minX),
                y: bounds.minY + (f.maxY - v.maxY),
                width: v.width,
                height: v.height
            )
            out.append(Monitor(id: did, index: i, name: screen.localizedName,
                               frame: bounds, usable: usable,
                               scale: Double(screen.backingScaleFactor)))
        }
        monitors = out
    }

    var primary: Monitor? { monitors.first }

    func byID(_ id: CGDirectDisplayID) -> Monitor? {
        monitors.first { $0.id == id }
    }

    func containing(_ point: CGPoint) -> Monitor? {
        monitors.first { $0.frame.contains(point) } ?? monitors.first
    }

    func resolve(_ target: MonitorTarget, current: CGDirectDisplayID) -> Monitor? {
        switch target {
        case .current:
            return byID(current)
        case .id(let n):
            return monitors.first { $0.index == n }
        case .relative(let d):
            guard let cur = byID(current), !monitors.isEmpty else { return nil }
            let n = monitors.count
            return monitors[((cur.index + d) % n + n) % n]
        case .name(let s):
            return monitors.first { $0.name.localizedCaseInsensitiveContains(s) }
        case .direction(let d):
            guard let cur = byID(current) else { return nil }
            return neighbor(of: cur, direction: d)
        }
    }

    func neighbor(of monitor: Monitor, direction: Direction) -> Monitor? {
        let sc = CGPoint(x: monitor.frame.midX, y: monitor.frame.midY)
        var best: (Monitor, Double)?
        for m in monitors where m.id != monitor.id {
            let c = CGPoint(x: m.frame.midX, y: m.frame.midY)
            let primary: Double
            let perp: Double
            switch direction {
            case .left: primary = sc.x - c.x; perp = abs(c.y - sc.y)
            case .right: primary = c.x - sc.x; perp = abs(c.y - sc.y)
            case .up: primary = sc.y - c.y; perp = abs(c.x - sc.x)
            case .down: primary = c.y - sc.y; perp = abs(c.x - sc.x)
            }
            guard primary > 1 else { continue }
            let score = primary + perp * 2
            if best == nil || score < best!.1 {
                best = (m, score)
            }
        }
        return best?.0
    }
}
