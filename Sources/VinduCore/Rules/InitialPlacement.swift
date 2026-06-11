import CoreGraphics

/// The outcome of folding window rules over a newly appeared window.
public struct InitialPlacement: Equatable {
    public var floating: Bool
    public var pinned = false
    public var silent = false
    public var wantsFullscreen = false
    public var workspaceTarget: WorkspaceTarget?
    public var monitorName: String?
    public var floatFrame: CGRect?

    public init(floating: Bool) {
        self.floating = floating
    }

    /// `usable` is the monitor work area the window appeared on; `windowFrame`
    /// its spawn frame. Rules apply in config order, later rules winning.
    public static func evaluate(rules: [WindowRule], target: MatchTarget,
                                defaultFloating: Bool, windowFrame: CGRect,
                                usable: CGRect) -> InitialPlacement {
        var p = InitialPlacement(floating: defaultFloating)
        for rule in rules where rule.matches(target) {
            switch rule.effect {
            case .float:
                p.floating = true
            case .tile:
                p.floating = false
            case .workspace(let t, let silent):
                p.workspaceTarget = t
                p.silent = p.silent || silent
            case .monitor(let name):
                p.monitorName = name
            case .size(let w, let h):
                p.floating = true
                p.floatFrame = CGRect(origin: (p.floatFrame ?? windowFrame).origin,
                                      size: CGSize(width: w.resolved(against: usable.width),
                                                   height: h.resolved(against: usable.height)))
            case .move(let x, let y):
                p.floating = true
                var f = p.floatFrame ?? windowFrame
                f.origin = CGPoint(x: usable.minX + x.resolved(against: usable.width),
                                   y: usable.minY + y.resolved(against: usable.height))
                p.floatFrame = f
            case .center:
                p.floating = true
                var f = p.floatFrame ?? windowFrame
                f.origin = CGPoint(x: usable.midX - f.width / 2, y: usable.midY - f.height / 2)
                p.floatFrame = f
            case .fullscreen, .maximize:
                p.wantsFullscreen = true
            case .pin:
                p.floating = true
                p.pinned = true
            case .unsupported:
                break
            }
        }
        return p
    }
}
