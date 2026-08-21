import Darwin
import Foundation
import VinduCore

public enum SecureSocketError: Error, CustomStringConvertible, Equatable {
    case pathTooLong(String)
    case unsafeRuntimeDirectory(String)
    case unsafeSocketPath(String)
    case alreadyRunning(String)
    case socketFailed(String)
    case unauthorizedPeer

    public var description: String {
        switch self {
        case .pathTooLong(let path):
            return "socket path too long: \(path)"
        case .unsafeRuntimeDirectory(let message):
            return "unsafe runtime directory: \(message)"
        case .unsafeSocketPath(let message):
            return "unsafe socket path: \(message)"
        case .alreadyRunning(let path):
            return "another vindu instance owns \(path)"
        case .socketFailed(let message):
            return "socket error: \(message)"
        case .unauthorizedPeer:
            return "unauthorized socket peer"
        }
    }
}

public typealias PeerValidator = (Int32) -> Bool
public typealias SocketWriter = (Int32, [UInt8]) -> Int

public enum SocketSecurity {
    public static let requestLimit = 16 * 1024

    public static func sameUserPeer(_ fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { return false }
        return uid == getuid()
    }

    public static func prepareSocketPath(_ path: String) throws {
        guard UnixSocket.makeAddress(path) != nil else {
            throw SecureSocketError.pathTooLong(path)
        }
        let dir = (path as NSString).deletingLastPathComponent
        try ensurePrivateRuntimeDirectory(dir)
        try removeStaleSocket(at: path)
    }

    public static func validateSocketPathForConnect(_ path: String) throws {
        guard UnixSocket.makeAddress(path) != nil else {
            throw SecureSocketError.pathTooLong(path)
        }
        try validatePrivateRuntimeDirectory((path as NSString).deletingLastPathComponent)

        var st = stat()
        guard lstat(path, &st) == 0 else {
            throw SecureSocketError.unsafeSocketPath("cannot stat \(path): \(errno)")
        }
        guard st.st_uid == getuid() else {
            throw SecureSocketError.unsafeSocketPath("\(path) is not owned by this user")
        }
        guard fileType(st.st_mode) == S_IFSOCK else {
            throw SecureSocketError.unsafeSocketPath("\(path) is not a socket")
        }
    }

    public static func ensurePrivateRuntimeDirectory(_ path: String) throws {
        let created = mkdir(path, S_IRWXU)
        if created != 0 && errno != EEXIST {
            throw SecureSocketError.unsafeRuntimeDirectory("cannot create \(path): \(errno)")
        }
        try validatePrivateRuntimeDirectory(path)
    }

    private static func validatePrivateRuntimeDirectory(_ path: String) throws {
        var st = stat()
        guard lstat(path, &st) == 0 else {
            throw SecureSocketError.unsafeRuntimeDirectory("cannot stat \(path): \(errno)")
        }
        guard fileType(st.st_mode) == S_IFDIR else {
            throw SecureSocketError.unsafeRuntimeDirectory("\(path) is not a directory")
        }
        guard st.st_uid == getuid() else {
            throw SecureSocketError.unsafeRuntimeDirectory("\(path) is not owned by this user")
        }

        let unsafeBits = st.st_mode & (S_IRWXG | S_IRWXO)
        if unsafeBits != 0 {
            throw SecureSocketError.unsafeRuntimeDirectory("\(path) is group/world accessible")
        }
    }

    private static func removeStaleSocket(at path: String) throws {
        var st = stat()
        guard lstat(path, &st) == 0 else {
            if errno == ENOENT { return }
            throw SecureSocketError.unsafeSocketPath("cannot stat \(path): \(errno)")
        }
        guard st.st_uid == getuid() else {
            throw SecureSocketError.unsafeSocketPath("\(path) is not owned by this user")
        }
        guard fileType(st.st_mode) == S_IFSOCK else {
            throw SecureSocketError.unsafeSocketPath("\(path) is not a socket")
        }

        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else {
            throw SecureSocketError.socketFailed("socket(): \(errno)")
        }
        defer { close(probe) }
        if UnixSocket.connect(probe, to: path) == 0 {
            throw SecureSocketError.alreadyRunning(path)
        }
        if unlink(path) != 0 && errno != ENOENT {
            throw SecureSocketError.unsafeSocketPath("cannot unlink stale socket \(path): \(errno)")
        }
    }

    private static func fileType(_ mode: mode_t) -> mode_t {
        mode & S_IFMT
    }
}

func setSocketNonBlocking(_ fd: Int32) throws {
    let flags = fcntl(fd, F_GETFL)
    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
        throw SecureSocketError.socketFailed("fcntl(O_NONBLOCK): \(errno)")
    }
}

public func setSocketNoSigPipe(_ fd: Int32) throws {
    var enabled: Int32 = 1
    guard setsockopt(fd,
                     SOL_SOCKET,
                     SO_NOSIGPIPE,
                     &enabled,
                     socklen_t(MemoryLayout.size(ofValue: enabled))) == 0 else {
        throw SecureSocketError.socketFailed("setsockopt(SO_NOSIGPIPE): \(errno)")
    }
}

final class BoundSocket {
    let fd: Int32

    private let path: String
    private let device: dev_t
    private let inode: ino_t
    private var closed = false

    init(fd: Int32, path: String, stat: stat) {
        self.fd = fd
        self.path = path
        device = stat.st_dev
        inode = stat.st_ino
    }

    func closeDescriptor() {
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
    }

    func unlinkIfOwned() {
        var current = stat()
        guard lstat(path, &current) == 0,
              current.st_uid == getuid(),
              current.st_dev == device,
              current.st_ino == inode,
              (current.st_mode & S_IFMT) == S_IFSOCK else { return }
        _ = unlink(path)
    }

    func closeAndUnlink() {
        unlinkIfOwned()
        closeDescriptor()
    }

    deinit {
        closeDescriptor()
    }
}

func bindAndListen(
    path: String,
    makeNonBlocking: (Int32) throws -> Void = setSocketNonBlocking,
    setPermissions: (String, mode_t) -> Int32 = { chmod($0, $1) }
) throws -> BoundSocket {
    try SocketSecurity.prepareSocketPath(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw SecureSocketError.socketFailed("socket(): \(errno)") }

    guard UnixSocket.bind(fd, to: path) == 0 else {
        let e = errno
        close(fd)
        throw SecureSocketError.socketFailed("bind failed for \(path): \(e)")
    }

    var socketStat = stat()
    guard lstat(path, &socketStat) == 0 else {
        let e = errno
        close(fd)
        throw SecureSocketError.socketFailed("cannot stat bound socket \(path): \(e)")
    }

    let boundSocket = BoundSocket(fd: fd, path: path, stat: socketStat)
    do {
        guard listen(fd, 16) == 0 else {
            throw SecureSocketError.socketFailed("listen failed for \(path): \(errno)")
        }
        try makeNonBlocking(fd)
        guard setPermissions(path, S_IRUSR | S_IWUSR) == 0 else {
            throw SecureSocketError.socketFailed("chmod failed for \(path): \(errno)")
        }
        return boundSocket
    } catch {
        boundSocket.closeAndUnlink()
        throw error
    }
}

public func writeAll(_ fd: Int32, data: [UInt8]) -> Bool {
    var offset = 0
    while offset < data.count {
        let n = data.withUnsafeBytes { ptr -> Int in
            guard let base = ptr.baseAddress else { return -1 }
            return write(fd, base.advanced(by: offset), data.count - offset)
        }
        if n > 0 {
            offset += n
            continue
        }
        if n < 0 && errno == EINTR {
            continue
        }
        return false
    }
    return true
}

public func writeOnce(_ fd: Int32, data: [UInt8]) -> Int {
    data.withUnsafeBytes { ptr -> Int in
        guard let base = ptr.baseAddress else { return -1 }
        return write(fd, base, data.count)
    }
}
