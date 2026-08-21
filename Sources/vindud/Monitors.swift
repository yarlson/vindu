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

struct MonitorChange: Equatable {
    var added: [String] = []
    var removed: [String] = []

    var isEmpty: Bool {
        added.isEmpty && removed.isEmpty
    }
}

final class MonitorManager {
    private(set) var monitors: [Monitor] = []
    var onChange: ((MonitorChange) -> Void)?

    /// Height of the primary screen; converts top-left CG coords to AppKit's
    /// bottom-left for NSWindow placement.
    private(set) var primaryHeight: Double = 0

    func start() {
        _ = rebuild()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let change = self.rebuild()
            self.onChange?(change)
        }
    }

    @discardableResult
    func rebuild() -> MonitorChange {
        let previous = Dictionary(uniqueKeysWithValues: monitors.map { ($0.id, $0.name) })
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
        return Self.change(from: previous, to: monitors)
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
            guard let currentIndex = monitors.firstIndex(where: { $0.id == current }),
                  !monitors.isEmpty else { return nil }
            let n = monitors.count
            let offset = d % n
            let candidate = currentIndex + offset
            let index = candidate >= 0 ? candidate % n : candidate + n
            return monitors[index]
        case .name(let s):
            return monitors.first { $0.name.localizedCaseInsensitiveContains(s) }
        case .direction(let d):
            guard let cur = byID(current) else { return nil }
            return neighbor(of: cur, direction: d)
        }
    }

    func neighbor(of monitor: Monitor, direction: Direction) -> Monitor? {
        let candidates = monitors
            .filter { $0.id != monitor.id }
            .map { (id: $0.id, rect: $0.frame) }
        return LayoutMath.neighbor(of: monitor.frame, in: direction, candidates: candidates)
            .flatMap(byID)
    }

    private static func change(from previous: [CGDirectDisplayID: String],
                               to monitors: [Monitor]) -> MonitorChange {
        let current = Dictionary(uniqueKeysWithValues: monitors.map { ($0.id, $0.name) })
        let added = current.keys
            .filter { previous[$0] == nil }
            .sorted()
            .compactMap { current[$0] }
        let removed = previous.keys
            .filter { current[$0] == nil }
            .sorted()
            .compactMap { previous[$0] }
        return MonitorChange(added: added, removed: removed)
    }
}
