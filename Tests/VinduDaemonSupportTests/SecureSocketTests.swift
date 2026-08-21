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
    do {
        try setSocketNoSigPipe(fd)
        guard UnixSocket.connect(fd, to: path) == 0 else {
            throw SecureSocketError.socketFailed("connect \(path): \(errno)")
        }
        return fd
    } catch {
        close(fd)
        throw error
    }
}

private enum ExpectedSocketFailure: Error {
    case failed
}

@Suite struct SecureSocketTests {
    @Test func disconnectedSocketWriteReturnsEPIPE() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw SecureSocketError.socketFailed("socketpair(): \(errno)")
        }
        let writer = descriptors[0]
        let peer = descriptors[1]
        var peerIsOpen = true
        defer {
            close(writer)
            if peerIsOpen { close(peer) }
        }

        try setSocketNoSigPipe(writer)
        var enabled: Int32 = 0
        var optionLength = socklen_t(MemoryLayout.size(ofValue: enabled))
        #expect(getsockopt(writer, SOL_SOCKET, SO_NOSIGPIPE, &enabled, &optionLength) == 0)
        #expect(enabled == 1)
        close(peer)
        peerIsOpen = false

        let firstWrite = writeOnce(writer, data: Array("first".utf8))
        let firstWriteError = errno
        #expect(firstWrite == -1)
        #expect(firstWriteError == EPIPE)
        let secondWrite = writeAll(writer, data: Array("second".utf8))
        let secondWriteError = errno
        #expect(!secondWrite)
        #expect(secondWriteError == EPIPE)
    }

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

    @Test func failedDescriptorSetupClosesDescriptorAndRemovesSocket() throws {
        let owner = try ShortTemporaryDirectory()
        let socketPath = owner.url.appendingPathComponent("vindu.sock").path
        var descriptor: Int32 = -1
        var originalDescriptorStat = stat()

        #expect(throws: ExpectedSocketFailure.self) {
            _ = try bindAndListen(path: socketPath) { fd in
                descriptor = fd
                #expect(fstat(fd, &originalDescriptorStat) == 0)
                throw ExpectedSocketFailure.failed
            }
        }

        #expect(descriptor >= 0)
        var currentDescriptorStat = stat()
        let statResult = fstat(descriptor, &currentDescriptorStat)
        #expect(statResult == -1 ||
                currentDescriptorStat.st_dev != originalDescriptorStat.st_dev ||
                currentDescriptorStat.st_ino != originalDescriptorStat.st_ino)
        #expect(!FileManager.default.fileExists(atPath: socketPath))
    }

    @Test func failedPermissionSetupClosesDescriptorAndRemovesSocket() throws {
        let owner = try ShortTemporaryDirectory()
        let socketPath = owner.url.appendingPathComponent("vindu.sock").path
        var descriptor: Int32 = -1
        var originalDescriptorStat = stat()

        #expect(throws: SecureSocketError.self) {
            _ = try bindAndListen(
                path: socketPath,
                makeNonBlocking: { fd in
                    descriptor = fd
                    #expect(fstat(fd, &originalDescriptorStat) == 0)
                    try setSocketNonBlocking(fd)
                },
                setPermissions: { _, _ in
                    errno = EPERM
                    return -1
                }
            )
        }

        #expect(descriptor >= 0)
        var currentDescriptorStat = stat()
        let statResult = fstat(descriptor, &currentDescriptorStat)
        #expect(statResult == -1 ||
                currentDescriptorStat.st_dev != originalDescriptorStat.st_dev ||
                currentDescriptorStat.st_ino != originalDescriptorStat.st_ino)
        #expect(!FileManager.default.fileExists(atPath: socketPath))
    }

    @Test func commandServerRepliesAndCloses() throws {
        let owner = try ShortTemporaryDirectory()
        let path = owner.url.appendingPathComponent("vindu.sock").path
        let queue = DispatchQueue(label: "vindu.ipc.test")
        let server = IPCServer(path: path, queue: queue) {
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

    @Test func commandServerStopsAndRestartsFromItsQueue() throws {
        let owner = try ShortTemporaryDirectory()
        let path = owner.url.appendingPathComponent("vindu.sock").path
        let queue = DispatchQueue(label: "vindu.ipc.restart.test")
        let server = IPCServer(path: path, queue: queue) { _ in "ok" }
        try server.start()

        try queue.sync {
            server.stop()
            try server.start()
        }
        server.stop()

        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test @MainActor func commandServerStartsAndStopsOnMainThread() throws {
        let owner = try ShortTemporaryDirectory()
        let path = owner.url.appendingPathComponent("vindu.sock").path
        let server = IPCServer(path: path) { _ in "ok" }

        try server.start()
        server.stop()

        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func commandServerCancellationPreservesReplacementSocket() throws {
        let owner = try ShortTemporaryDirectory()
        let path = owner.url.appendingPathComponent("vindu.sock").path
        let queue = DispatchQueue(label: "vindu.ipc.replacement.test")
        let server = IPCServer(path: path, queue: queue) { _ in "ok" }
        try server.start()
        var replacement: Int32 = -1

        try queue.sync {
            server.stop()
            replacement = socket(AF_UNIX, SOCK_STREAM, 0)
            guard replacement >= 0 else {
                throw SecureSocketError.socketFailed("socket(): \(errno)")
            }
            guard UnixSocket.bind(replacement, to: path) == 0,
                  listen(replacement, 1) == 0 else {
                throw SecureSocketError.socketFailed("replacement bind/listen: \(errno)")
            }
        }
        defer {
            if replacement >= 0 { close(replacement) }
            unlink(path)
        }
        queue.sync {}

        var socketStat = stat()
        #expect(lstat(path, &socketStat) == 0)
        #expect((socketStat.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK))
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

        #expect(try readUntilEOF(fd: fd) == "")
    }

    @Test func commandServerSurvivesClientDisconnectBeforeReply() throws {
        let owner = try ShortTemporaryDirectory()
        let path = owner.url.appendingPathComponent("vindu.sock").path
        let queue = DispatchQueue(label: "vindu.ipc.disconnect.test")
        let handlerStarted = DispatchSemaphore(value: 0)
        let allowReply = DispatchSemaphore(value: 0)
        let server = IPCServer(path: path,
                               queue: queue,
                               idleTimeout: .seconds(5),
                               peerValidator: { _ in true }) { _ in
            handlerStarted.signal()
            allowReply.wait()
            return "ok"
        }
        try server.start()
        defer {
            allowReply.signal()
            server.stop()
        }

        var fd = try connectUnixSocket(path)
        defer {
            if fd >= 0 { close(fd) }
        }
        #expect(writeAll(fd, data: Array("ping".utf8)))
        shutdown(fd, SHUT_WR)
        guard handlerStarted.wait(timeout: .now() + 1) == .success else {
            Issue.record("handler did not start")
            return
        }

        close(fd)
        fd = -1
        allowReply.signal()

        try waitForCondition {
            queue.sync { server.clientCountForTesting == 0 }
        }
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
        let events = EventBroadcaster(path: path, queue: queue)
        try events.start()
        defer { events.stop() }

        let fd = try connectUnixSocket(path)
        defer { close(fd) }
        try waitForCondition { events.clientCountForTesting == 1 }
        events.broadcast(.workspace("2"))

        #expect(try readAvailable(fd: fd) == "workspace>>2\n")
    }

    @Test func eventBroadcasterPrunesDisconnectedClient() throws {
        let owner = try ShortTemporaryDirectory()
        let path = owner.url.appendingPathComponent("vindu.events.sock").path
        let queue = DispatchQueue(label: "vindu.events.disconnect.test")
        let events = EventBroadcaster(path: path, queue: queue)
        try events.start()
        defer { events.stop() }

        var fd = try connectUnixSocket(path)
        defer {
            if fd >= 0 { close(fd) }
        }
        try waitForCondition { events.clientCountForTesting == 1 }
        #expect(shutdown(fd, SHUT_RDWR) == 0)
        close(fd)
        fd = -1

        events.broadcast(.workspace("2"))

        #expect(events.clientCountForTesting == 0)
    }

    @Test func eventBroadcasterStopsAndRestartsFromItsQueue() throws {
        let owner = try ShortTemporaryDirectory()
        let path = owner.url.appendingPathComponent("vindu.events.sock").path
        let queue = DispatchQueue(label: "vindu.events.restart.test")
        let events = EventBroadcaster(path: path, queue: queue)
        try events.start()

        try queue.sync {
            events.stop()
            try events.start()
        }
        events.stop()

        #expect(!FileManager.default.fileExists(atPath: path))
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

private func readUntilEOF(fd: Int32, timeoutMs: Int32 = 3_000) throws -> String {
    var data = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
        try waitUntilReadable(fd: fd, timeoutMs: timeoutMs)
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

private func readAvailable(fd: Int32, timeoutMs: Int32 = 3_000) throws -> String {
    try waitUntilReadable(fd: fd, timeoutMs: timeoutMs)
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

private func waitUntilReadable(fd: Int32, timeoutMs: Int32) throws {
    var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
    while true {
        let result = poll(&descriptor, 1, timeoutMs)
        if result > 0 {
            return
        }
        if result == 0 {
            throw SecureSocketError.socketFailed("read timed out")
        }
        if errno != EINTR {
            throw SecureSocketError.socketFailed("poll(): \(errno)")
        }
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
