import CoreGraphics

/// Pure geometry shared by the layout engines and the window manager.
/// All rects are top-left-origin global coordinates (CGWindow/AX space),
/// so `up` means decreasing y.
public enum LayoutMath {
    /// Hyprland gap semantics: a tile side flush with the workspace edge gets
    /// gapsOut; sides facing other tiles get gapsIn. Adjacent tiles both
    /// contribute, so the visual gap between two tiles is 2 × gapsIn.
    public static func applyGaps(to rect: CGRect, within container: CGRect,
                                 gapsIn: Double, gapsOut: Double) -> CGRect {
        let eps = 0.5
        let left = abs(rect.minX - container.minX) < eps ? gapsOut : gapsIn
        let right = abs(rect.maxX - container.maxX) < eps ? gapsOut : gapsIn
        let top = abs(rect.minY - container.minY) < eps ? gapsOut : gapsIn
        let bottom = abs(rect.maxY - container.maxY) < eps ? gapsOut : gapsIn
        return CGRect(
            x: rect.minX + left,
            y: rect.minY + top,
            width: max(rect.width - left - right, 1),
            height: max(rect.height - top - bottom, 1)
        )
    }

    /// Splits a rect into `count` equal tiles along one axis.
    public static func stackRects(_ rect: CGRect, count: Int, vertical: Bool) -> [CGRect] {
        guard count > 0 else { return [] }
        var out: [CGRect] = []
        if vertical {
            let h = rect.height / Double(count)
            for i in 0..<count {
                out.append(CGRect(x: rect.minX, y: rect.minY + Double(i) * h, width: rect.width, height: h))
            }
        } else {
            let w = rect.width / Double(count)
            for i in 0..<count {
                out.append(CGRect(x: rect.minX + Double(i) * w, y: rect.minY, width: w, height: rect.height))
            }
        }
        return out
    }

    /// Directional focus: nearest candidate whose center lies beyond the
    /// source's center in `direction`, penalizing perpendicular offset.
    public static func neighbor<ID>(of source: CGRect, in direction: Direction,
                                    candidates: [(id: ID, rect: CGRect)]) -> ID? {
        let sc = CGPoint(x: source.midX, y: source.midY)
        var bestID: ID?
        var bestScore = Double.infinity
        for (id, rect) in candidates {
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let primary: Double
            let perp: Double
            switch direction {
            case .left:
                primary = sc.x - c.x
                perp = abs(c.y - sc.y)
            case .right:
                primary = c.x - sc.x
                perp = abs(c.y - sc.y)
            case .up:
                primary = sc.y - c.y
                perp = abs(c.x - sc.x)
            case .down:
                primary = c.y - sc.y
                perp = abs(c.x - sc.x)
            }
            guard primary > 1 else { continue }
            let score = primary + perp * 2
            if score < bestScore {
                bestScore = score
                bestID = id
            }
        }
        return bestID
    }
}
