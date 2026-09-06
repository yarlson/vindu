import AppKit
import VinduCore

extension WindowManager {
    func canCaptureScroll(at point: CGPoint) -> Bool {
        guard !paused,
              let monitor = monitorMgr.containing(point),
              shownSpecial[monitor.id] == nil,
              let workspaceID = activeWS[monitor.id],
              let workspace = registry.existing(workspaceID) else { return false }
        return effectiveLayoutKind(for: workspace) == .scrolling
    }

    func handleScroll(_ input: HotkeyTap.ScrollInput) -> Bool {
        if input.phase & 8 != 0 || input.momentumPhase & 8 != 0 {
            let captured = scrollingGesture != nil
            finishScrollingGesture()
            return captured
        }

        if scrollingGesture == nil {
            guard input.optionPressed,
                  let monitor = monitorMgr.containing(input.location),
                  shownSpecial[monitor.id] == nil,
                  let workspaceID = activeWS[monitor.id],
                  let workspace = registry.existing(workspaceID),
                  effectiveLayoutKind(for: workspace) == .scrolling else { return false }
            cancelViewportAnimation()
            focusedMonitorID = monitor.id
            scrollingGesture = ScrollingGestureSession(monitorID: monitor.id,
                                                        workspaceID: workspaceID)
        }

        guard var gesture = scrollingGesture,
              let workspace = registry.existing(gesture.workspaceID),
              workspace.monitor == gesture.monitorID,
              effectiveLayoutKind(for: workspace) == .scrolling else {
            finishScrollingGesture()
            return true
        }

        scrollingGestureEnd?.cancel()
        scrollingGestureEnd = nil
        let action = gesture.update(deltaX: input.deltaX, deltaY: input.deltaY)
        scrollingGesture = gesture
        switch action {
        case .horizontal(let delta):
            guard isVisible(workspace), shownSpecial[gesture.monitorID] == nil else { break }
            _ = workspace.scrolling.scroll(by: -delta, in: containerRect(for: workspace))
            if scrollingGestureMotionStarted {
                scrollingMotionNeedsFrame = true
            } else {
                arrange(workspace, scrollingMotion: .begin)
                scrollingGestureMotionStarted = true
                startScrollingMotionTimer()
            }
        case .workspace(let offset):
            focusedMonitorID = gesture.monitorID
            _ = switchWorkspace(to: .relative(offset))
        case .pending, .consumed:
            break
        }

        if input.momentumPhase & 4 != 0 {
            finishScrollingGesture()
        } else if input.phase & 4 != 0 || (input.phase == 0 && input.momentumPhase == 0) {
            let work = DispatchWorkItem { [weak self] in self?.finishScrollingGesture() }
            scrollingGestureEnd = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
        }
        return true
    }

    func finishScrollingGesture() {
        scrollingGestureEnd?.cancel()
        scrollingGestureEnd = nil
        tap.releaseScrollCapture()
        guard let gesture = scrollingGesture else { return }
        scrollingGesture = nil
        scrollingMotionTimer?.invalidate()
        scrollingMotionTimer = nil
        scrollingMotionNeedsFrame = false
        if scrollingGestureMotionStarted,
           let workspace = registry.existing(gesture.workspaceID), isVisible(workspace) {
            arrange(workspace, scrollingMotion: .finish)
            focusNearestVisibleWindow(in: workspace)
        }
        scrollingGestureMotionStarted = false
    }

    private func startScrollingMotionTimer() {
        scrollingMotionTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self, self.scrollingMotionNeedsFrame,
                  let gesture = self.scrollingGesture,
                  let workspace = self.registry.existing(gesture.workspaceID),
                  self.isVisible(workspace) else { return }
            self.scrollingMotionNeedsFrame = false
            self.arrange(workspace, scrollingMotion: .update)
        }
        scrollingMotionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func animateScrollingViewport(_ workspace: WorkspaceState, from start: Double, to end: Double) {
        cancelViewportAnimation()
        let container = containerRect(for: workspace)
        guard abs(end - start) > 0.5 else {
            workspace.scrolling.setViewportOffset(end, in: container)
            arrange(workspace)
            return
        }

        workspace.scrolling.setViewportOffset(start, in: container)
        arrange(workspace, scrollingMotion: .begin)
        let startedAt = CFAbsoluteTimeGetCurrent()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self, weak workspace] timer in
            guard let self, let workspace, self.isVisible(workspace),
                  self.effectiveLayoutKind(for: workspace) == .scrolling else {
                timer.invalidate()
                self?.viewportAnimation = nil
                self?.viewportAnimationWorkspaceID = nil
                return
            }
            let progress = min((CFAbsoluteTimeGetCurrent() - startedAt) / 0.15, 1)
            let offset = start + (end - start) * cubicEaseOut(progress)
            workspace.scrolling.setViewportOffset(offset, in: container)
            self.arrange(workspace, scrollingMotion: progress >= 1 ? .finish : .update)
            if progress >= 1 {
                timer.invalidate()
                self.viewportAnimation = nil
                self.viewportAnimationWorkspaceID = nil
            }
        }
        viewportAnimation = timer
        viewportAnimationWorkspaceID = workspace.id
        RunLoop.main.add(timer, forMode: .common)
    }

    func cancelViewportAnimation() {
        guard let timer = viewportAnimation else { return }
        timer.invalidate()
        viewportAnimation = nil
        if let workspaceID = viewportAnimationWorkspaceID,
           let workspace = registry.existing(workspaceID), isVisible(workspace) {
            arrange(workspace, scrollingMotion: .finish)
        }
        viewportAnimationWorkspaceID = nil
    }

    func focusNearestVisibleWindow(in workspace: WorkspaceState) {
        let container = containerRect(for: workspace)
        if let focusedWindow, let state = windows[focusedWindow],
           state.workspace == workspace.id, !state.viewportHidden { return }
        let frames = workspace.scrolling.frames(in: container)
        let target = frames
            .filter { $0.value.maxX > container.minX && $0.value.minX < container.maxX }
            .min { abs($0.value.midX - container.midX) < abs($1.value.midX - container.midX) }?.key
        if let target { focusWindow(target) }
    }
}
