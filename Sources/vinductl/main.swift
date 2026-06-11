import Foundation
import VinduCore

let usage = """
vinductl — control the vindu window manager

USAGE: vinductl [-j] <command> [args…]

COMMANDS:
    dispatch <dispatcher> [args]   run a dispatcher (movefocus l, workspace 3, exec kitty…)
    keyword <name> <value>         set a config keyword live (general:gaps_in 10)
    reload                         reload the config file
    clients | workspaces | monitors | activewindow | activeworkspace | binds
    getoption <keyword>            read a config value
    configerrors                   show config parse errors
    cursorpos | version | splash
    notify <text>                  post a notification
    events                         stream the event socket (workspace>>2, …)

FLAGS:
    -j      JSON output

Sockets: \(VinduPaths.commandSocketPath)
         \(VinduPaths.eventSocketPath)
"""

func connectSocket(path: String) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    guard UnixSocket.connect(fd, to: path) == 0 else {
        close(fd)
        return nil
    }
    return fd
}

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func request(_ line: String) -> String {
    guard let fd = connectSocket(path: VinduPaths.commandSocketPath) else {
        die("cannot connect to \(VinduPaths.commandSocketPath) — is vindud running?")
    }
    defer { close(fd) }
    Array(line.utf8).withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
    shutdown(fd, SHUT_WR)
    var out = Data()
    var buf = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let n = read(fd, &buf, buf.count)
        guard n > 0 else { break }
        out.append(contentsOf: buf[0..<n])
    }
    return String(decoding: out, as: UTF8.self)
}

func streamEvents() -> Never {
    guard let fd = connectSocket(path: VinduPaths.eventSocketPath) else {
        die("cannot connect to \(VinduPaths.eventSocketPath) — is vindud running?")
    }
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fd, &buf, buf.count)
        guard n > 0 else { exit(0) }
        FileHandle.standardOutput.write(Data(buf[0..<n]))
    }
}

var args = Array(CommandLine.arguments.dropFirst())
var json = false
args.removeAll { arg in
    if arg == "-j" || arg == "--json" {
        json = true
        return true
    }
    return false
}

guard let first = args.first else {
    print(usage)
    exit(0)
}

switch first {
case "-h", "--help", "help":
    print(usage)
    exit(0)
case "--version":
    print("vinductl \(VinduVersion.string)")
    exit(0)
case "events":
    streamEvents()
default:
    break
}

let line = (json ? "j/" : "") + args.joined(separator: " ")
let reply = request(line).trimmingCharacters(in: .whitespacesAndNewlines)
print(reply)
exit(reply.hasPrefix("err") || reply.hasPrefix("unknown") ? 1 : 0)
