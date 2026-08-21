import Foundation
import Testing
@testable import VinduDaemonSupport

struct LaunchAgentPlistTests {
    @Test func defaultServiceUsesNativePathSelectionAtStartup() throws {
        let data = try LaunchAgentPlist.data(
            binaryPath: "/usr/local/bin/vindud",
            configPath: nil,
            logPath: "/Users/example/Library/Logs/vindu/vindud.log"
        )
        let value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        let plist = try #require(value as? [String: Any])

        #expect(plist["ProgramArguments"] as? [String] == ["/usr/local/bin/vindud"])
    }

    @Test func customServicePreservesItsExplicitConfiguration() throws {
        let logPath = VinduLogPaths.daemonLogPath(homeDirectory: "/Users/example")
        let data = try LaunchAgentPlist.data(
            binaryPath: "/usr/local/bin/vindud",
            configPath: "/tmp/custom.toml",
            logPath: logPath
        )
        let value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        let plist = try #require(value as? [String: Any])

        #expect(plist["ProgramArguments"] as? [String] == [
            "/usr/local/bin/vindud", "--config", "/tmp/custom.toml",
        ])
        #expect(plist["StandardOutPath"] as? String == logPath)
        #expect(plist["StandardErrorPath"] as? String == logPath)
        #expect(!logPath.hasPrefix("/tmp/"))
    }

    @Test func writeCreatesPrivateLogDirectoryAndAtomicPlistDestination() throws {
        let directory = try DaemonSupportTemporaryDirectory()
        let plistPath = directory.path("LaunchAgents/com.vindu.daemon.plist")
        let logPath = directory.path("Logs/vindu/vindud.log")

        try LaunchAgentPlist.write(binaryPath: "/bin/vindud",
                                   configPath: nil,
                                   logPath: logPath,
                                   to: plistPath)

        #expect(FileManager.default.fileExists(atPath: plistPath))
        var isDirectory: ObjCBool = false
        let logDirectory = (logPath as NSString).deletingLastPathComponent
        #expect(FileManager.default.fileExists(atPath: logDirectory, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        let attributes = try FileManager.default.attributesOfItem(atPath: logDirectory)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }
}

struct ConfigWatcherTests {
    @Test func creatingMissingConfigurationTriggersReload() throws {
        let directory = try DaemonSupportTemporaryDirectory()
        let path = directory.path("vindu.toml")
        let callback = DispatchSemaphore(value: 0)
        let watcher = ConfigWatcher(path: path) {
            callback.signal()
        }
        watcher.start()
        defer { watcher.stop() }

        try "schema = 1\n".write(toFile: path, atomically: true, encoding: .utf8)

        #expect(callback.wait(timeout: .now() + 3) == .success)
    }

    @Test func stopPreventsPendingReloadAndRearm() throws {
        let directory = try DaemonSupportTemporaryDirectory()
        let path = directory.path("vindu.toml")
        try "schema = 1\n".write(toFile: path, atomically: true, encoding: .utf8)

        let callback = DispatchSemaphore(value: 0)
        let watcher = ConfigWatcher(path: path) {
            callback.signal()
        }
        watcher.start()
        watcher.stop()
        try "schema = 1\n[layout]\ninner_gap = 2\n".write(
            toFile: path,
            atomically: true,
            encoding: .utf8
        )

        #expect(callback.wait(timeout: .now() + 0.5) == .timedOut)
    }
}

private final class DaemonSupportTemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vindu-support-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func path(_ component: String) -> String {
        url.appendingPathComponent(component).path
    }
}
