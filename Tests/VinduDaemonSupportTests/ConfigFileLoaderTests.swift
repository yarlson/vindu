import Foundation
import Testing
import VinduCore
@testable import VinduDaemonSupport

struct ConfigFileLoaderTests {
    @Test func missingConfigWritesDefaultAndParsesIt() throws {
        let dir = try TemporaryDirectory()
        let path = dir.path("nested/vindu.conf")
        let loaded = try ConfigFileLoader().load(path: path, defaultText: "general:gaps_in = 17\n")

        #expect(loaded.wroteDefault)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "general:gaps_in = 17\n")
        #expect(loaded.document.settings.general.gapsIn == 17)
    }

    @Test func defaultWriteFailureThrowsInsteadOfPretendingSuccess() throws {
        let dir = try TemporaryDirectory()
        let blockedParent = dir.path("blocked")
        FileManager.default.createFile(atPath: blockedParent, contents: Data())

        #expect(throws: ConfigLoadError.self) {
            try ConfigFileLoader().load(path: "\(blockedParent)/vindu.conf", defaultText: "")
        }
    }

    @Test func existingInvalidUtf8ThrowsReadFailure() throws {
        let dir = try TemporaryDirectory()
        let path = dir.path("vindu.conf")
        try Data([0xff, 0xfe]).write(to: URL(fileURLWithPath: path))

        #expect(throws: ConfigLoadError.self) {
            try ConfigFileLoader().load(path: path, defaultText: "")
        }
    }

    @Test func configAtSourceByteLimitLoads() throws {
        let dir = try TemporaryDirectory()
        let path = dir.path("vindu.conf")
        let setting = "general:gaps_in = 19\n"
        let text = setting + "#" + String(repeating: "x",
                                           count: ConfigFileLoader.maxConfigBytes - setting.utf8.count - 2) + "\n"
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))

        let loaded = try ConfigFileLoader().load(path: path, defaultText: "")

        #expect(text.utf8.count == ConfigFileLoader.maxConfigBytes)
        #expect(loaded.document.settings.general.gapsIn == 19)
    }

    @Test func configOverSourceByteLimitThrowsReadFailure() throws {
        let dir = try TemporaryDirectory()
        let path = dir.path("vindu.conf")
        try Data(repeating: UInt8(ascii: "x"),
                 count: ConfigFileLoader.maxConfigBytes + 1)
            .write(to: URL(fileURLWithPath: path))

        #expect(throws: ConfigLoadError.self) {
            try ConfigFileLoader().load(path: path, defaultText: "")
        }
    }

    @Test func sourceFileAtByteLimitLoads() throws {
        let dir = try TemporaryDirectory()
        let rootPath = dir.path("vindu.conf")
        let sourcePath = dir.path("large.conf")
        let setting = "general:gaps_in = 21\n"
        let source = setting + "#" + String(repeating: "x",
                                             count: ConfigFileLoader.maxConfigBytes
                                                 - setting.utf8.count - 2) + "\n"
        try "source = large.conf\n".write(toFile: rootPath, atomically: true, encoding: .utf8)
        try Data(source.utf8).write(to: URL(fileURLWithPath: sourcePath))

        let loaded = try ConfigFileLoader().load(path: rootPath, defaultText: "")

        #expect(source.utf8.count == ConfigFileLoader.maxConfigBytes)
        #expect(loaded.document.errors.isEmpty)
        #expect(loaded.document.settings.general.gapsIn == 21)
    }

    @Test func oversizedSourceFileIsRejectedBeforeParsing() throws {
        let dir = try TemporaryDirectory()
        let rootPath = dir.path("vindu.conf")
        let sourcePath = dir.path("large.conf")
        try "source = large.conf\n".write(toFile: rootPath, atomically: true, encoding: .utf8)
        try Data(repeating: UInt8(ascii: "x"),
                 count: ConfigFileLoader.maxConfigBytes + 1)
            .write(to: URL(fileURLWithPath: sourcePath))

        let loaded = try ConfigFileLoader().load(path: rootPath, defaultText: "")

        #expect(loaded.document.errors.contains {
            $0.message == "cannot source \(sourcePath)"
        })
    }

    @Test func reloadReadFailureKeepsPreviousConfigAndAddsLoadError() throws {
        let dir = try TemporaryDirectory()
        let path = dir.path("vindu.conf")
        try Data([0xff]).write(to: URL(fileURLWithPath: path))
        var previous = ConfigParser().parse(text: "general:gaps_in = 23\n")
        previous.errors.append(ConfigError(line: 9, message: "old parse error"))

        let result = ConfigFileLoader().reload(path: path, defaultText: "", previous: previous)

        guard case .keptPrevious(let document, let error) = result else {
            Issue.record("reload should keep previous document on read failure")
            return
        }
        #expect(error.description.contains("cannot read config"))
        #expect(document.settings.general.gapsIn == 23)
        #expect(document.errors.contains(ConfigError(line: 9, message: "old parse error")))
        #expect(document.errors.contains {
            $0.line == 0 && $0.message.hasPrefix(ConfigLoadError.errorPrefix)
        })
    }
}

struct LaunchAgentPlistTests {
    @Test func plistPreservesConfigPathAndPrivateLogPath() throws {
        let logPath = VinduLogPaths.daemonLogPath(homeDirectory: "/Users/example")
        let data = try LaunchAgentPlist.data(binaryPath: "/usr/local/bin/vindud",
                                             configPath: "/tmp/custom.conf",
                                             logPath: logPath)
        let value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        let plist = try #require(value as? [String: Any])

        #expect(plist["ProgramArguments"] as? [String] == [
            "/usr/local/bin/vindud", "--config", "/tmp/custom.conf",
        ])
        #expect(plist["StandardOutPath"] as? String == logPath)
        #expect(plist["StandardErrorPath"] as? String == logPath)
        #expect(!logPath.hasPrefix("/tmp/"))
    }

    @Test func writeCreatesPrivateLogDirectoryAndAtomicPlistDestination() throws {
        let dir = try TemporaryDirectory()
        let plistPath = dir.path("LaunchAgents/com.vindu.daemon.plist")
        let logPath = dir.path("Logs/vindu/vindud.log")

        try LaunchAgentPlist.write(binaryPath: "/bin/vindud",
                                   configPath: "/tmp/vindu.conf",
                                   logPath: logPath,
                                   to: plistPath)

        #expect(FileManager.default.fileExists(atPath: plistPath))
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: (logPath as NSString).deletingLastPathComponent,
                                               isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: (logPath as NSString).deletingLastPathComponent)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }
}

struct ConfigWatcherTests {
    @Test func stopPreventsPendingReloadAndRearm() throws {
        let dir = try TemporaryDirectory()
        let path = dir.path("vindu.conf")
        try "general:gaps_in = 1\n".write(toFile: path, atomically: true, encoding: .utf8)

        let callback = DispatchSemaphore(value: 0)
        let watcher = ConfigWatcher(path: path) {
            callback.signal()
        }
        watcher.start()
        watcher.stop()
        try "general:gaps_in = 2\n".write(toFile: path, atomically: true, encoding: .utf8)

        #expect(callback.wait(timeout: .now() + 0.5) == .timedOut)
    }
}

private final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vindu-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func path(_ component: String) -> String {
        url.appendingPathComponent(component).path
    }
}
