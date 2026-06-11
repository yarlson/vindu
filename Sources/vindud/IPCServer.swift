import Foundation
import VinduCore

enum IPCError: Error, CustomStringConvertible {
    case alreadyRunning(String)
    case socketFailed(String)

    var description: String {
        switch self {
        case .alreadyRunning(let p): return "another vindu instance owns \(p)"
        case .socketFailed(let m): return "socket error: \(m)"
        }
    }
}

private func bindAndListen(path: String) throws -> Int32 {
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                             withIntermediateDirectories: true)
    guard UnixSocket.makeAddress(path) != nil else {
        throw IPCError.socketFailed("path too long: \(path)")
    }

    // A live socket file means another daemon; a dead one is stale and removable.
    if FileManager.default.fileExists(atPath: path) {
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(probe) }
        if UnixSocket.connect(probe, to: path) == 0 {
            throw IPCError.alreadyRunning(path)
        }
        unlink(path)
    }

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw IPCError.socketFailed("socket(): \(errno)") }
    guard UnixSocket.bind(fd, to: path) == 0, listen(fd, 16) == 0 else {
        close(fd)
        throw IPCError.socketFailed("bind/listen failed for \(path): \(errno)")
    }
    return fd
}

/// Request/response socket, wire-compatible with Hyprland's socket1: one
/// plain-text command per connection, one reply, close. A `j/` prefix asks
/// for JSON. The handler runs on the main queue.
final class IPCServer {
    typealias Handler = (String) -> String

    private let path: String
    private let handler: Handler
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?

    init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    func start() throws {
        fd = try bindAndListen(path: path)
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [weak self] in self?.acceptConnection() }
        source = src
        src.resume()
    }

    func stop() {
        source?.cancel()
        if fd >= 0 { close(fd) }
        unlink(path)
    }

    private func acceptConnection() {
        let conn = accept(fd, nil, nil)
        guard conn >= 0 else { return }
        DispatchQueue.global().async { [handler] in
            var buf = [UInt8](repeating: 0, count: 16 * 1024)
            let n = read(conn, &buf, buf.count)
            guard n > 0 else {
                close(conn)
                return
            }
            let request = String(decoding: buf[0..<n], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                let reply = handler(request)
                DispatchQueue.global().async {
                    let data = Array((reply + "\n").utf8)
                    data.withUnsafeBytes { _ = write(conn, $0.baseAddress, $0.count) }
                    close(conn)
                }
            }
        }
    }
}

/// Event stream socket, wire-compatible with Hyprland's socket2:
/// `EVENT>>DATA\n` pushed to every connected client.
final class EventBroadcaster {
    private let path: String
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var clients: [Int32] = []

    init(path: String) {
        self.path = path
    }

    func start() throws {
        fd = try bindAndListen(path: path)
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let conn = accept(self.fd, nil, nil)
            guard conn >= 0 else { return }
            // Non-blocking so one stalled client cannot wedge the daemon.
            let flags = fcntl(conn, F_GETFL)
            _ = fcntl(conn, F_SETFL, flags | O_NONBLOCK)
            self.clients.append(conn)
        }
        source = src
        src.resume()
    }

    func stop() {
        source?.cancel()
        for c in clients { close(c) }
        clients.removeAll()
        if fd >= 0 { close(fd) }
        unlink(path)
    }

    func broadcast(_ event: WMEvent) {
        guard !clients.isEmpty else { return }
        let data = Array((event.line + "\n").utf8)
        clients.removeAll { conn in
            let n = data.withUnsafeBytes { write(conn, $0.baseAddress, $0.count) }
            if n < 0 && errno != EAGAIN {
                close(conn)
                return true
            }
            return false
        }
    }
}
