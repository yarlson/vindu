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

    private final class Client {
        let fd: Int32
        let source: DispatchSourceRead
        let timer: DispatchSourceTimer
        var data = Data()
        var writeSource: DispatchSourceWrite?
        var writeData: [UInt8] = []
        var writeOffset = 0
        var finishedReading = false
        var closed = false

        init(fd: Int32, source: DispatchSourceRead, timer: DispatchSourceTimer) {
            self.fd = fd
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
    private var fd: Int32 = -1
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
    }

    public func start() throws {
        fd = try bindAndListen(path: path)
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptConnections() }
        src.setCancelHandler { [path, fd] in
            if fd >= 0 { Darwin.close(fd) }
            unlink(path)
        }
        source = src
        src.resume()
    }

    public func stop() {
        for client in Array(clients.values) {
            close(client)
        }
        clients.removeAll()
        source?.cancel()
        source = nil
        fd = -1
    }

    private func acceptConnections() {
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
        let readSource = DispatchSource.makeReadSource(fileDescriptor: conn, queue: queue)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let client = Client(fd: conn, source: readSource, timer: timer)
        clients[conn] = client

        readSource.setEventHandler { [weak self, weak client] in
            guard let self, let client else { return }
            self.read(client)
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
        client.source.cancel()

        let request = String(decoding: client.data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        startWrite(client, data: Array((handler(request) + "\n").utf8))
    }

    private func startWrite(_ client: Client, data: [UInt8]) {
        guard clients[client.fd] === client, !client.closed else { return }
        client.writeData = data
        let writeSource = DispatchSource.makeWriteSource(fileDescriptor: client.fd, queue: queue)
        client.writeSource = writeSource
        writeSource.setEventHandler { [weak self, weak client] in
            guard let self, let client else { return }
            self.write(client)
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
        Darwin.close(client.fd)
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
    private var fd: Int32 = -1
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
    }

    public func start() throws {
        fd = try bindAndListen(path: path)
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptConnections() }
        src.setCancelHandler { [path, fd] in
            if fd >= 0 { close(fd) }
            unlink(path)
        }
        source = src
        src.resume()
    }

    public func stop() {
        source?.cancel()
        source = nil
        for client in clients {
            close(client)
        }
        clients.removeAll()
        fd = -1
    }

    public func broadcast(_ event: WMEvent) {
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
        clients.count
    }
}
