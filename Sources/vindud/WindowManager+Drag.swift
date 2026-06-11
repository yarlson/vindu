import AppKit
import VinduCore

/// Mouse drag engine. Two entry points share one session model:
/// - bindm drags (we own the window's frame),
/// - native title-bar drags of tiled windows (the OS moves the window, we
///   re-tile around it).
/// Tiled windows snap back to the grid on release; tiles swap live while the
/// cursor crosses them, mirroring Hyprland's drag behavior.
extension WindowManager {
    enum DragKind { case move, resize }
    enum DragSource { case bindm, native }

    struct DragSession {
        let id: WindowID
        let kind: DragKind
        let source: DragSource
        let startPoint: CGPoint
        let startFrame: CGRect
        /// Native drags engage only once the window actually moves, so clicks
        /// and in-window drags (text selection) never trigger re-tiling.
        var engaged: Bool
        var sawResize = false
        var lastSwapTarget: WindowID?
        var lastPoint: CGPoint
    }

    /// bindm drags. Hyprland semantics: `movewindow` on a tiled window drags it
    /// across the grid, swapping tiles as the cursor crosses them; on a floating
    /// window it free-moves. `resizewindow` drags split ratios (tiled) or the
    /// frame (floating).
    func handleDrag(dispatcher: Dispatcher, point: CGPoint, phase: HotkeyTap.DragPhase) {
        switch phase {
        case .began:
            guard let id = bridge.windowID(at: point), let state = windows[id] else { return }
            let kind: DragKind = {
                if case .resizewindow = dispatcher { return .resize }
                return .move
            }()
            drag = DragSession(id: id, kind: kind, source: .bindm, startPoint: point,
                               startFrame: state.frame, engaged: true, lastPoint: point)
            focusWindow(id)
        case .moved:
            guard var session = drag, session.source == .bindm,
                  let state = windows[session.id] else { return }
            let now = CFAbsoluteTimeGetCurrent()
            guard now - lastDragApply > 0.02 else { return }
            lastDragApply = now
            let dx = point.x - session.startPoint.x
            let dy = point.y - session.startPoint.y

            if state.floating {
                var frame = session.startFrame
                if session.kind == .move {
                    frame.origin.x += dx
                    frame.origin.y += dy
                } else {
                    frame.size.width = max(120, frame.width + dx)
                    frame.size.height = max(90, frame.height + dy)
                }
                applyFloatingFrame(state, frame)
            } else if session.kind == .move {
                var frame = session.startFrame
                frame.origin.x += dx
                frame.origin.y += dy
                state.frame = frame
                bridge.setFrame(session.id, frame)
                refreshBorder()
                liveSwapDuringDrag(at: point)
            } else {
                let ddx = point.x - session.lastPoint.x
                let ddy = point.y - session.lastPoint.y
                session.lastPoint = point
                drag = session
                resizeTiledBy(session.id, dx: ddx, dy: ddy)
                arrange(workspace(forID: state.workspace))
            }
        case .ended:
            finishDrag(at: point)
        }
    }

    /// Native (unbound) left drags: a tiled window dragged by its title bar
    /// re-tiles like a bindm drag instead of fighting the layout.
    func handleRawLeftMouse(_ point: CGPoint, _ phase: HotkeyTap.DragPhase) {
        switch phase {
        case .began:
            guard let id = bridge.windowID(at: point), let state = windows[id] else { return }
            // A click on the green zoom button is about to start the native
            // fullscreen animation — drop the border before it begins.
            if let button = bridge.fullscreenButtonFrame(id),
               button.insetBy(dx: -2, dy: -2).contains(point) {
                suppressBorder(for: 1.2)
                return
            }
            guard drag == nil, !state.floating, !state.hidden, !state.minimized else { return }
            drag = DragSession(id: id, kind: .move, source: .native, startPoint: point,
                               startFrame: state.frame, engaged: false, lastPoint: point)
        case .moved:
            guard let session = drag, session.source == .native,
                  session.engaged, !session.sawResize else { return }
            liveSwapDuringDrag(at: point)
        case .ended:
            guard let session = drag, session.source == .native else { return }
            if session.engaged {
                finishDrag(at: point)
            } else {
                drag = nil
            }
        }
    }

    /// While a tiled window is dragged, swap it with whichever tile the cursor
    /// enters; the rest of the workspace re-flows around it live.
    func liveSwapDuringDrag(at point: CGPoint) {
        guard var session = drag, let state = windows[session.id], !state.floating else { return }
        let ws = workspace(forID: state.workspace)
        if let last = session.lastSwapTarget,
           !(windows[last]?.frame.contains(point) ?? false) {
            session.lastSwapTarget = nil
            drag = session
        }
        let target = ws.tiled.first { other in
            other != session.id
                && other != session.lastSwapTarget
                && windows[other]?.minimized != true
                && windows[other]?.hidden != true
                && (windows[other]?.frame.contains(point) ?? false)
        }
        guard let target else { return }
        ws.swapTiled(session.id, target)
        session.lastSwapTarget = target
        drag = session
        arrange(ws, excluding: session.id)
    }

    func finishDrag(at point: CGPoint) {
        guard let session = drag else { return }
        drag = nil
        guard let state = windows[session.id] else {
            refreshBorder()
            return
        }
        if state.floating {
            state.floatFrame = state.frame
            refreshBorder()
            return
        }
        if session.sawResize {
            // Native edge-resize of a tiled window: adopt the user's size
            // intent into the split ratios, then snap everything to the grid.
            let current = bridge.frame(of: session.id) ?? state.frame
            resizeTiledBy(session.id,
                          dx: current.width - session.startFrame.width,
                          dy: current.height - session.startFrame.height)
            arrange(workspace(forID: state.workspace))
            return
        }
        let ws = workspace(forID: state.workspace)
        if let m = monitorMgr.containing(point), m.id != ws.monitor {
            // Dropped on another monitor → join its visible workspace, tiled.
            _ = moveWindowToWorkspace(session.id, target: .id(activeWS[m.id] ?? 1), silent: true)
            focusedMonitorID = m.id
            focusWindow(session.id)
        } else {
            arrange(ws)
        }
        refreshBorder()
    }
}
