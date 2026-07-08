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

func setSocketNonBlocking(_ fd: Int32) {
    let flags = fcntl(fd, F_GETFL)
    if flags >= 0 {
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }
}

func bindAndListen(path: String) throws -> Int32 {
    try SocketSecurity.prepareSocketPath(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw SecureSocketError.socketFailed("socket(): \(errno)") }
    guard UnixSocket.bind(fd, to: path) == 0, listen(fd, 16) == 0 else {
        let e = errno
        close(fd)
        throw SecureSocketError.socketFailed("bind/listen failed for \(path): \(e)")
    }
    setSocketNonBlocking(fd)
    _ = chmod(path, S_IRUSR | S_IWUSR)
    return fd
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
