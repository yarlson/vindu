import Darwin
import Foundation

public enum UnixSocket {
    /// Fills a sockaddr_un for `path`, or nil if the path exceeds sun_path.
    public static func makeAddress(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard path.utf8.count <= maxLen else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            path.utf8CString.withUnsafeBytes { src in
                dst.copyBytes(from: src.prefix(maxLen + 1))
            }
        }
        return addr
    }

    /// connect(2) wrapper hiding the sockaddr pointer dance. Returns errno-style
    /// result of `connect`, or -1 if the path doesn't fit.
    public static func connect(_ fd: Int32, to path: String) -> Int32 {
        guard var addr = makeAddress(path) else { return -1 }
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    /// bind(2) wrapper. Returns the bind result, or -1 if the path doesn't fit.
    public static func bind(_ fd: Int32, to path: String) -> Int32 {
        guard var addr = makeAddress(path) else { return -1 }
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
}
