import Foundation
import VinduCore
import VinduDaemonSupport

let usage = """
vinductl — control the vindu window manager

USAGE: vinductl [-j] <command> [args…]

COMMANDS:
    dispatch <dispatcher> [args]   run a dispatcher (movefocus l, workspace 3, exec kitty…)
    config check [PATH]            validate TOML without contacting the daemon
    config status                  show active config state and diagnostics
    config reload                  reload the config file
    clients | workspaces | monitors | activewindow | activeworkspace | binds
    barplugin refresh <id>         queue a desktop bar plugin refresh
    cursorpos | version | splash
    notify <text>                  post a notification
    events                         stream the event socket (workspace>>2, …)

FLAGS:
    -j      JSON output

Sockets: \(VinduPaths.commandSocketPath)
         \(VinduPaths.eventSocketPath)
"""

func connectSocket(path: String) throws -> Int32 {
    try SocketSecurity.validateSocketPathForConnect(path)
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

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func printReplyAndExit(_ line: String) -> Never {
    let reply = request(line).trimmingCharacters(in: .whitespacesAndNewlines)
    print(reply)
    exit(reply.hasPrefix("err") || reply.hasPrefix("unknown") ? 1 : 0)
}

func offlineConfigCheck(path: String) -> Never {
    do {
        _ = try NativeConfigurationFileLoader().check(path: path)
        print("ok: \(path)")
        exit(0)
    } catch NativeConfigurationLoadError.invalid(let file, let failure) {
        for diagnostic in failure.diagnostics {
            var location = file
            if let line = diagnostic.line { location += ":\(line)" }
            if let keyPath = diagnostic.keyPath { location += " [\(keyPath)]" }
            FileHandle.standardError.write(Data("\(location): \(diagnostic.message)\n".utf8))
        }
        exit(1)
    } catch {
        die(String(describing: error))
    }
}

func request(_ line: String) -> String {
    let fd: Int32
    do {
        fd = try connectSocket(path: VinduPaths.commandSocketPath)
    } catch {
        die("cannot connect to \(VinduPaths.commandSocketPath) — is vindud running? (\(error))")
    }
    defer { close(fd) }
    guard writeAll(fd, data: Array(line.utf8)) else {
        die("cannot write request to \(VinduPaths.commandSocketPath)")
    }
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
    let fd: Int32
    do {
        fd = try connectSocket(path: VinduPaths.eventSocketPath)
    } catch {
        die("cannot connect to \(VinduPaths.eventSocketPath) — is vindud running? (\(error))")
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

if let route = ConfigurationCommandRouter.route(arguments: args,
                                                json: json,
                                                defaultPath: VinduPaths.defaultConfigPath) {
    switch route {
    case .offlineCheck(let path):
        offlineConfigCheck(path: path)
    case .socketRequest(let line):
        printReplyAndExit(line)
    case .invalid(let message):
        die(message)
    }
}

let line = (json ? "j/" : "") + args.joined(separator: " ")
printReplyAndExit(line)
