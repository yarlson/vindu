import Darwin
import Dispatch
import Foundation
import VinduCore

public typealias IPCError = SecureSocketError

/// Request/response socket, wire-compatible with Hyprland's socket1: one
/// plain-text command per connection, one reply, close. The handler runs on the
/// queue passed at initialization, the main queue in the daemon.
public final class IPCServer {
    public typealias Handler = (String) -> String

    private final class DescriptorLifetime {
        let fd: Int32
        private var sourceCount = 0
        private var closed = false

        init(fd: Int32) {
            self.fd = fd
        }

        func sourceCreated() {
            sourceCount += 1
        }

        func sourceCancelled() {
            guard sourceCount > 0 else { return }
            sourceCount -= 1
            if sourceCount == 0 {
                closeDescriptor()
            }
        }

        private func closeDescriptor() {
            guard !closed else { return }
            closed = true
            Darwin.close(fd)
        }

        deinit {
            closeDescriptor()
        }
    }

    private final class Client {
        let descriptor: DescriptorLifetime
        let source: DispatchSourceRead
        let timer: DispatchSourceTimer
        var data = Data()
        var writeSource: DispatchSourceWrite?
        var writeData: [UInt8] = []
        var writeOffset = 0
        var finishedReading = false
        var closed = false

        var fd: Int32 { descriptor.fd }

        init(descriptor: DescriptorLifetime,
             source: DispatchSourceRead,
             timer: DispatchSourceTimer) {
            self.descriptor = descriptor
            self.source = source
            self.timer = timer
        }
    }

    private let path: String
    private let queue: DispatchQueue
    private let handler: Handler
    private let peerValidator: PeerValidator
    private let idleTimeout: DispatchTimeInterval
    private let maxClients: Int
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let usesMainQueue: Bool
    private var listener: BoundSocket?
    private var source: DispatchSourceRead?
    private var clients: [Int32: Client] = [:]

    public init(path: String,
                queue: DispatchQueue = .main,
                idleTimeout: DispatchTimeInterval = .seconds(2),
                maxClients: Int = 64,
                peerValidator: @escaping PeerValidator = SocketSecurity.sameUserPeer,
                handler: @escaping Handler) {
        self.path = path
        self.queue = queue
        self.idleTimeout = idleTimeout
        self.maxClients = maxClients
        self.peerValidator = peerValidator
        self.handler = handler
        usesMainQueue = queue === DispatchQueue.main
        queue.setSpecific(key: queueKey, value: 1)
    }

    deinit {
        stop()
    }

    public func start() throws {
        try onQueue {
            guard listener == nil else {
                throw SecureSocketError.alreadyRunning(path)
            }
            let boundSocket = try bindAndListen(path: path)
            let src = DispatchSource.makeReadSource(fileDescriptor: boundSocket.fd, queue: queue)
            src.setEventHandler { [weak self] in self?.acceptConnections() }
            src.setCancelHandler {
                boundSocket.closeAndUnlink()
            }
            listener = boundSocket
            source = src
            src.resume()
        }
    }

    public func stop() {
        onQueue { stopOnQueue() }
    }

    private func stopOnQueue() {
        for client in Array(clients.values) {
            close(client)
        }
        clients.removeAll()
        source?.cancel()
        listener?.unlinkIfOwned()
        source = nil
        listener = nil
    }

    private func acceptConnections() {
        guard let fd = listener?.fd else { return }
        while true {
            let conn = accept(fd, nil, nil)
            guard conn >= 0 else {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                return
            }
            guard clients.count < maxClients, peerValidator(conn) else {
                Darwin.close(conn)
                continue
            }
            do {
                try setSocketNonBlocking(conn)
                track(conn)
            } catch {
                Darwin.close(conn)
            }
        }
    }

    private func track(_ conn: Int32) {
        let descriptor = DescriptorLifetime(fd: conn)
        descriptor.sourceCreated()
        let readSource = DispatchSource.makeReadSource(fileDescriptor: conn, queue: queue)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let client = Client(descriptor: descriptor, source: readSource, timer: timer)
        clients[conn] = client

        readSource.setEventHandler { [weak self, weak client] in
            guard let self, let client else { return }
            self.read(client)
        }
        readSource.setCancelHandler {
            descriptor.sourceCancelled()
        }

        timer.schedule(deadline: .now() + idleTimeout)
        timer.setEventHandler { [weak self, weak client] in
            guard let self, let client else { return }
            self.close(client)
        }

        readSource.resume()
        timer.resume()
    }

    private func read(_ client: Client) {
        guard clients[client.fd] === client,
              !client.finishedReading,
              !client.closed else { return }
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.read(client.fd, &buf, buf.count)
            if n > 0 {
                client.data.append(contentsOf: buf[0..<n])
                if client.data.count > SocketSecurity.requestLimit {
                    close(client)
                    return
                }
                continue
            }
            if n == 0 {
                finish(client)
                return
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            }
            if errno == EINTR {
                continue
            }
            close(client)
            return
        }
    }

    private func finish(_ client: Client) {
        guard clients[client.fd] === client, !client.finishedReading else { return }
        client.finishedReading = true

        let request = String(decoding: client.data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        startWrite(client, data: Array((handler(request) + "\n").utf8))
        client.source.cancel()
    }

    private func startWrite(_ client: Client, data: [UInt8]) {
        guard clients[client.fd] === client, !client.closed else { return }
        client.writeData = data
        client.descriptor.sourceCreated()
        let writeSource = DispatchSource.makeWriteSource(fileDescriptor: client.fd, queue: queue)
        client.writeSource = writeSource
        let descriptor = client.descriptor
        writeSource.setEventHandler { [weak self, weak client] in
            guard let self, let client else { return }
            self.write(client)
        }
        writeSource.setCancelHandler {
            descriptor.sourceCancelled()
        }
        writeSource.resume()
    }

    private func write(_ client: Client) {
        guard clients[client.fd] === client, !client.closed else { return }
        while client.writeOffset < client.writeData.count {
            let n = client.writeData.withUnsafeBytes { ptr -> Int in
                guard let base = ptr.baseAddress else { return -1 }
                return Darwin.write(client.fd,
                                    base.advanced(by: client.writeOffset),
                                    client.writeData.count - client.writeOffset)
            }
            if n > 0 {
                client.writeOffset += n
                continue
            }
            if n < 0 && errno == EINTR {
                continue
            }
            if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                return
            }
            close(client)
            return
        }
        close(client)
    }

    private func close(_ client: Client) {
        guard !client.closed else { return }
        client.closed = true
        if clients[client.fd] === client {
            clients.removeValue(forKey: client.fd)
        }
        client.timer.cancel()
        client.source.cancel()
        client.writeSource?.cancel()
    }

    private func onQueue<T>(_ operation: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) == 1 ||
            (usesMainQueue && Thread.isMainThread) {
            return try operation()
        }
        return try queue.sync(execute: operation)
    }
}

/// Event stream socket, wire-compatible with Hyprland's socket2:
/// `EVENT>>DATA\n` pushed to every connected same-UID client.
public final class EventBroadcaster {
    private let path: String
    private let queue: DispatchQueue
    private let peerValidator: PeerValidator
    private let writer: SocketWriter
    private let maxClients: Int
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let usesMainQueue: Bool
    private var listener: BoundSocket?
    private var source: DispatchSourceRead?
    private var clients: [Int32] = []

    public init(path: String,
                queue: DispatchQueue = .main,
                maxClients: Int = 64,
                peerValidator: @escaping PeerValidator = SocketSecurity.sameUserPeer,
                writer: @escaping SocketWriter = writeOnce) {
        self.path = path
        self.queue = queue
        self.maxClients = maxClients
        self.peerValidator = peerValidator
        self.writer = writer
        usesMainQueue = queue === DispatchQueue.main
        queue.setSpecific(key: queueKey, value: 1)
    }

    deinit {
        stop()
    }

    public func start() throws {
        try onQueue {
            guard listener == nil else {
                throw SecureSocketError.alreadyRunning(path)
            }
            let boundSocket = try bindAndListen(path: path)
            let src = DispatchSource.makeReadSource(fileDescriptor: boundSocket.fd, queue: queue)
            src.setEventHandler { [weak self] in self?.acceptConnections() }
            src.setCancelHandler {
                boundSocket.closeAndUnlink()
            }
            listener = boundSocket
            source = src
            src.resume()
        }
    }

    public func stop() {
        onQueue { stopOnQueue() }
    }

    private func stopOnQueue() {
        source?.cancel()
        listener?.unlinkIfOwned()
        source = nil
        for client in clients {
            close(client)
        }
        clients.removeAll()
        listener = nil
    }

    public func broadcast(_ event: WMEvent) {
        onQueue { broadcastOnQueue(event) }
    }

    private func broadcastOnQueue(_ event: WMEvent) {
        guard !clients.isEmpty else { return }
        let data = Array((event.line + "\n").utf8)
        clients.removeAll { conn in
            let n = writer(conn, data)
            if n == data.count {
                return false
            }
            close(conn)
            return true
        }
    }

    private func acceptConnections() {
        guard let fd = listener?.fd else { return }
        while true {
            let conn = accept(fd, nil, nil)
            guard conn >= 0 else {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                return
            }
            guard clients.count < maxClients, peerValidator(conn) else {
                close(conn)
                continue
            }
            do {
                try setSocketNonBlocking(conn)
                clients.append(conn)
            } catch {
                close(conn)
            }
        }
    }

    var clientCountForTesting: Int {
        onQueue { clients.count }
    }

    private func onQueue<T>(_ operation: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) == 1 ||
            (usesMainQueue && Thread.isMainThread) {
            return try operation()
        }
        return try queue.sync(execute: operation)
    }
}
