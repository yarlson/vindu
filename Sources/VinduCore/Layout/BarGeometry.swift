import CoreGraphics

public enum BarGeometry {
    public static func resolvedHeight(displayFrame: CGRect, usable: CGRect,
                                      configuration: NativeBarConfiguration) -> Double {
        let raw: Double
        switch configuration.height {
        case .points(let height):
            raw = Double(height)
        case .automatic where configuration.position == .top:
            raw = max(28, usable.minY - displayFrame.minY)
        case .automatic:
            raw = 28
        }
        return min(max(raw, 0), max(0, displayFrame.height - 1))
    }

    public static func contentRect(displayFrame: CGRect, usable: CGRect,
                                   configuration: NativeBarConfiguration) -> CGRect {
        guard configuration.enabled else { return usable }
        var rect = usable
        let bar = barRect(displayFrame: displayFrame, usable: usable,
                          configuration: configuration)
        let overlap = usable.intersection(bar)
        let reserved = overlap.isNull ? 0 : overlap.height
        switch configuration.position {
        case .top:
            rect.origin.y += reserved
        case .bottom:
            break
        }
        rect.size.height = max(0, rect.height - reserved)
        return rect
    }

    public static func barRect(displayFrame: CGRect, usable: CGRect,
                               configuration: NativeBarConfiguration) -> CGRect {
        let height = resolvedHeight(displayFrame: displayFrame, usable: usable,
                                    configuration: configuration)
        switch configuration.position {
        case .top:
            return CGRect(x: displayFrame.minX, y: displayFrame.minY,
                          width: displayFrame.width, height: height)
        case .bottom:
            return CGRect(x: usable.minX, y: usable.maxY - height,
                          width: usable.width, height: height)
        }
    }

}
