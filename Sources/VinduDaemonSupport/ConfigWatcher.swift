import Foundation

/// Watches one config file and re-arms after atomic-save renames while running.
public final class ConfigWatcher {
    private let path: String
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var debounce: DispatchWorkItem?
    private var retry: DispatchWorkItem?
    private var running = false

    public init(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
    }

    public func start() {
        guard !running else { return }
        running = true
        arm()
    }

    public func stop() {
        running = false
        retry?.cancel()
        retry = nil
        debounce?.cancel()
        debounce = nil
        source?.cancel()
        source = nil
    }

    private func arm() {
        guard running, source == nil else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            scheduleArm(after: 2.0)
            return
        }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        src.setEventHandler { [weak self, weak src] in
            guard let self, let src, self.running else { return }
            let flags = src.data
            self.scheduleReload()
            if flags.contains(.delete) || flags.contains(.rename) {
                self.source = nil
                src.cancel()
            }
        }
        src.setCancelHandler { [weak self] in
            close(fd)
            guard let self, self.running else { return }
            self.source = nil
            self.scheduleArm(after: 0.2)
        }
        source = src
        src.resume()
    }

    private func scheduleArm(after delay: TimeInterval) {
        retry?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.running else { return }
            self.retry = nil
            self.arm()
        }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func scheduleReload() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.running else { return }
            self.onChange()
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
}
