import Foundation

/// Watches the config file and fires a debounced callback on change.
/// Editors save atomically (rename over the original), so the watch re-arms
/// on the new inode after delete/rename events.
final class ConfigWatcher {
    private let path: String
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var debounce: DispatchWorkItem?

    init(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
    }

    func start() {
        arm()
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func arm() {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in self?.arm() }
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = src.data
            self.scheduleReload()
            if flags.contains(.delete) || flags.contains(.rename) {
                src.cancel()
            }
        }
        src.setCancelHandler { [weak self] in
            close(fd)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self?.arm() }
        }
        source = src
        src.resume()
    }

    private func scheduleReload() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
}
