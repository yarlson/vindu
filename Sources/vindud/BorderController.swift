import VinduBorderEngine
import VinduCore

final class BorderController {
    private var engine: OpaquePointer? = VBEEngineCreate()

    func show(windowID: WindowID,
              gradient: MLGradient,
              width: Double,
              fallbackRadius: Double) {
        let colors = gradient.colors.map {
            VBEColor(red: $0.r, green: $0.g, blue: $0.b, alpha: $0.a)
        }
        colors.withUnsafeBufferPointer { buffer in
            guard let engine, let baseAddress = buffer.baseAddress else { return }
            VBEEngineSetTarget(engine,
                               windowID,
                               baseAddress,
                               buffer.count,
                               gradient.angleDeg,
                               width,
                               fallbackRadius)
        }
    }

    func hide() {
        guard let engine else { return }
        VBEEngineHide(engine)
    }

    func shutdown() {
        guard let engine else { return }
        VBEEngineDestroy(engine)
        self.engine = nil
    }

    deinit {
        shutdown()
    }
}
