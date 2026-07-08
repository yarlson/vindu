import Darwin
import Dispatch
import Foundation
import Testing
import VinduCore
@testable import VinduDaemonSupport

private final class ShortTemporaryDirectory {
    let url: URL

    init() throws {
        var template = Array("/tmp/vd.XXXXXX".utf8CString)
        let path = template.withUnsafeMutableBufferPointer { buffer in
            mkdtemp(buffer.baseAddress)
        }
        guard let path else {
            throw SecureSocketError.socketFailed("mkdtemp(): \(errno)")
        }
        url = URL(fileURLWithPath: String(cString: path), isDirectory: true)
        chmod(url.path, S_IRWXU)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

private func connectUnixSocket(_ path: String) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw SecureSocketError.socketFailed("socket(): \(errno)") }
    guard UnixSocket.connect(fd, to: path) == 0 else {
        let e = errno
        close(fd)
        throw SecureSocketError.socketFailed("connect \(path): \(e)")
    }
    return fd
}

@Suite struct SecureSocketTests {
    @Test func runtimeDirectoryMustNotBeSymlink() throws {
        let owner = try ShortTemporaryDirectory()
        let target = owner.url.appendingPathComponent("target")
        let link = owner.url.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(throws: SecureSocketError.self) {
            try SocketSecurity.ensurePrivateRuntimeDirectory(link.path)
        }
    }

    @Test func runtimeDirectoryMustBePrivate() throws {
        let owner = try ShortTemporaryDirectory()
        let runtime = owner.url.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: false)
        chmod(runtime.path, S_IRWXU | S_IRWXG)

        #expect(throws: SecureSocketError.self) {
            try SocketSecurity.ensurePrivateRuntimeDirectory(runtime.path)
        }
    }

    @Test func regularFileAtSocketPathIsRejectedAndPreserved() throws {
        let owner = try ShortTemporaryDirectory()
        let socketPath = owner.url.appendingPathComponent("vindu.sock").path
        try SocketSecurity.ensurePrivateRuntimeDirectory(owner.url.path)
        FileManager.default.createFile(atPath: socketPath, contents: Data("not a socket".utf8))

        #expect(throws: SecureSocketError.self) {
            try SocketSecurity.prepareSocketPath(socketPath)
        }
        #expect(FileManager.default.fileExists(atPath: socketPath))
    }

    @Test func symlinkAtSocketPathIsRejectedAndPreserved() throws {
        let owner = try ShortTemporaryDirectory()
        let socketPath = owner.url.appendingPathComponent("vindu.sock").path
        let target = owner.url.appendingPathComponent("target")
        try SocketSecurity.ensurePrivateRuntimeDirectory(owner.url.path)
        try "target".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: socketPath, withDestinationPath: target.path)

        #expect(throws: SecureSocketError.self) {
            try SocketSecurity.prepareSocketPath(socketPath)
        }

        var st = stat()
        #expect(lstat(socketPath, &st) == 0)
        #expect((st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK))
    }

    @Test func staleOwnedSocketIsUnlinkedBeforeBind() throws {
        let owner = try ShortTemporaryDirectory()
        let socketPath = owner.url.appendingPathComponent("vindu.sock").path
        try SocketSecurity.ensurePrivateRuntimeDirectory(owner.url.path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(fd >= 0)
        #expect(UnixSocket.bind(fd, to: socketPath) == 0)
        close(fd)

        try SocketSecurity.prepareSocketPath(socketPath)

        #expect(!FileManager.default.fileExists(atPath: socketPath))
    }

    @Test func liveOwnedSocketReportsAlreadyRunning() throws {
        let owner = try ShortTemporaryDirectory()
        let socketPath = owner.url.appendingPathComponent("vindu.sock").path
        try SocketSecurity.ensurePrivateRuntimeDirectory(owner.url.path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(fd >= 0)
        defer {
            close(fd)
            unlink(socketPath)
        }
        #expect(UnixSocket.bind(fd, to: socketPath) == 0)
        #expect(listen(fd, 1) == 0)

        do {
            try SocketSecurity.prepareSocketPath(socketPath)
            Issue.record("expected alreadyRunning")
        } catch SecureSocketError.alreadyRunning(let path) {
            #expect(path == socketPath)
        }
    }

    @Test func commandServerRepliesAndCloses() throws {
        let owner = try ShortTemporaryDirectory()
        let path = owner.url.appendingPathComponent("vindu.sock").path
        let queue = DispatchQueue(label: "vindu.ipc.test")
        let server = IPCServer(path: path, queue: queue, peerValidator: { _ in true }) {
            "reply:\($0)"
        }
        try server.start()
        defer { server.stop() }

        let fd = try connectUnixSocket(path)
        defer { close(fd) }
        #expect(writeAll(fd, data: Array("ping".utf8)))
        shutdown(fd, SHUT_WR)

        #expect(try readUntilEOF(fd: fd) == "reply:ping\n")
    }

    @Test func commandServerRejectsUnauthorizedPeer() throws {
        let owner = try ShortTemporaryDirectory()
        let path = owner.url.appendingPathComponent("vindu.sock").path
        let queue = DispatchQueue(label: "vindu.ipc.reject.test")
        let server = IPCServer(path: path,
                               queue: queue,
                               idleTimeout: .milliseconds(100),
                               peerValidator: { _ in false }) { _ in
            Issue.record("handler must not run for rejected peers")
            return "unexpected"
        }
        try server.start()
        defer { server.stop() }

        let fd = try connectUnixSocket(path)
        defer { close(fd) }
        #expect(writeAll(fd, data: Array("ping".utf8)))
        shutdown(fd, SHUT_WR)

        #expect(try readUntilEOF(fd: fd) == "")
    }

    @Test func commandServerClosesIdleClient() throws {
        let owner = try ShortTemporaryDirectory()
        let path = owner.url.appendingPathComponent("vindu.sock").path
        let queue = DispatchQueue(label: "vindu.ipc.idle.test")
        let server = IPCServer(path: path,
                               queue: queue,
                               idleTimeout: .milliseconds(100),
                               peerValidator: { _ in true }) { _ in
            Issue.record("handler must not run for idle clients")
            return "unexpected"
        }
        try server.start()
        defer { server.stop() }

        let fd = try connectUnixSocket(path)
        defer { close(fd) }

        #expect(try readUntilEOF(fd: fd) == "")
    }

    @Test func commandServerClosesOversizedRequest() throws {
        let owner = try ShortTemporaryDirectory()
        let path = owner.url.appendingPathComponent("vindu.sock").path
        let queue = DispatchQueue(label: "vindu.ipc.oversize.test")
        let server = IPCServer(path: path,
                               queue: queue,
                               idleTimeout: .milliseconds(100),
                               peerValidator: { _ in true }) { _ in
            Issue.record("handler must not run for oversized requests")
            return "unexpected"
        }
        try server.start()
        defer { server.stop() }

        let fd = try connectUnixSocket(path)
        defer { close(fd) }
        #expect(writeAll(fd, data: Array(repeating: UInt8(ascii: "x"),
                                        count: SocketSecurity.requestLimit + 1)))
        shutdown(fd, SHUT_WR)

        #expect(try readUntilEOF(fd: fd) == "")
    }

    @Test func eventBroadcasterStreamsToAuthorizedClient() throws {
        let owner = try ShortTemporaryDirectory()
        let path = owner.url.appendingPathComponent("vindu.events.sock").path
        let queue = DispatchQueue(label: "vindu.events.test")
        let events = EventBroadcaster(path: path, queue: queue, peerValidator: { _ in true })
        try events.start()
        defer { events.stop() }

        let fd = try connectUnixSocket(path)
        defer { close(fd) }
        try waitForCondition { queue.sync { events.clientCountForTesting == 1 } }
        queue.sync { events.broadcast(.workspace("2")) }

        #expect(try readAvailable(fd: fd) == "workspace>>2\n")
    }

    @Test func eventBroadcasterRejectsUnauthorizedPeer() throws {
        let owner = try ShortTemporaryDirectory()
        let path = owner.url.appendingPathComponent("vindu.events.sock").path
        let queue = DispatchQueue(label: "vindu.events.reject.test")
        let events = EventBroadcaster(path: path, queue: queue, peerValidator: { _ in false })
        try events.start()
        defer { events.stop() }

        let fd = try connectUnixSocket(path)
        defer { close(fd) }

        #expect(try readUntilEOF(fd: fd) == "")
    }

    @Test func eventBroadcasterPrunesPartialWriteClient() throws {
        let owner = try ShortTemporaryDirectory()
        let path = owner.url.appendingPathComponent("vindu.events.sock").path
        let queue = DispatchQueue(label: "vindu.events.partial.test")
        let writes = LockedCounter()
        let events = EventBroadcaster(path: path, queue: queue, peerValidator: { _ in true }) { _, data in
            writes.increment()
            return data.count - 1
        }
        try events.start()
        defer { events.stop() }

        let fd = try connectUnixSocket(path)
        defer { close(fd) }
        try waitForCondition { queue.sync { events.clientCountForTesting == 1 } }
        queue.sync {
            events.broadcast(.workspace("1"))
            events.broadcast(.workspace("2"))
        }

        #expect(writes.value == 1)
        #expect(queue.sync { events.clientCountForTesting } == 0)
    }

    @Test func eventBroadcasterPrunesEAGAINClient() throws {
        let owner = try ShortTemporaryDirectory()
        let path = owner.url.appendingPathComponent("vindu.events.sock").path
        let queue = DispatchQueue(label: "vindu.events.eagain.test")
        let writes = LockedCounter()
        let events = EventBroadcaster(path: path, queue: queue, peerValidator: { _ in true }) { _, _ in
            writes.increment()
            errno = EAGAIN
            return -1
        }
        try events.start()
        defer { events.stop() }

        let fd = try connectUnixSocket(path)
        defer { close(fd) }
        try waitForCondition { queue.sync { events.clientCountForTesting == 1 } }
        queue.sync {
            events.broadcast(.workspace("1"))
            events.broadcast(.workspace("2"))
        }

        #expect(writes.value == 1)
        #expect(queue.sync { events.clientCountForTesting } == 0)
    }
}

private final class LockedCounter {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}

private func readUntilEOF(fd: Int32, timeoutMs: Int = 1_000) throws -> String {
    try setReadTimeout(fd: fd, timeoutMs: timeoutMs)
    var data = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fd, &buf, buf.count)
        if n > 0 {
            data.append(contentsOf: buf[0..<n])
            continue
        }
        if n == 0 {
            return String(decoding: data, as: UTF8.self)
        }
        if errno == EINTR {
            continue
        }
        throw SecureSocketError.socketFailed("read(): \(errno)")
    }
}

private func readAvailable(fd: Int32, timeoutMs: Int = 1_000) throws -> String {
    try setReadTimeout(fd: fd, timeoutMs: timeoutMs)
    var buf = [UInt8](repeating: 0, count: 4096)
    let n = read(fd, &buf, buf.count)
    if n > 0 {
        return String(decoding: buf[0..<n], as: UTF8.self)
    }
    if n == 0 {
        return ""
    }
    throw SecureSocketError.socketFailed("read(): \(errno)")
}

private func setReadTimeout(fd: Int32, timeoutMs: Int) throws {
    var timeout = timeval(tv_sec: timeoutMs / 1000,
                          tv_usec: Int32(timeoutMs % 1000) * 1000)
    let result = withUnsafePointer(to: &timeout) { ptr in
        ptr.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<timeval>.size) {
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
    }
    if result != 0 {
        throw SecureSocketError.socketFailed("setsockopt(SO_RCVTIMEO): \(errno)")
    }
}

private func waitForCondition(timeout: TimeInterval = 1.0, _ condition: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        usleep(10_000)
    }
    throw SecureSocketError.socketFailed("condition timed out")
}
