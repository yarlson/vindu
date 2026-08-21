import Foundation
import Testing
import VinduCore
@testable import VinduDaemonSupport

struct NativeConfigurationFileLoaderTests {
    @Test func nativeConfigurationWinsWhenBothFilesExist() throws {
        let directory = try NativeTemporaryDirectory()
        let nativePath = directory.path("vindu.toml")
        let legacyPath = directory.path("vindu.conf")
        try Data("schema = 1\n[layout]\ninner_gap = 9\n".utf8).write(to: URL(fileURLWithPath: nativePath))
        let legacy = Data("general:gaps_in = 99\n".utf8)
        try legacy.write(to: URL(fileURLWithPath: legacyPath))

        let selection = try NativeConfigurationFileLoader().loadDefault(
            nativePath: nativePath,
            legacyPath: legacyPath,
            canonicalDefault: Data("schema = 1\n".utf8)
        )

        guard case .loaded(let loaded) = selection else {
            Issue.record("native configuration should win")
            return
        }
        #expect(loaded.path == nativePath)
        #expect(!loaded.wroteDefault)
        #expect(loaded.snapshot.layout.innerGap == 9)
        #expect(try Data(contentsOf: URL(fileURLWithPath: legacyPath)) == legacy)
    }

    @Test func legacyOnlyIsReportedAndLeftUntouched() throws {
        let directory = try NativeTemporaryDirectory()
        let nativePath = directory.path("vindu.toml")
        let legacyPath = directory.path("vindu.conf")
        let legacy = Data("general:gaps_in = 27\n".utf8)
        try legacy.write(to: URL(fileURLWithPath: legacyPath))

        let selection = try NativeConfigurationFileLoader().loadDefault(
            nativePath: nativePath,
            legacyPath: legacyPath,
            canonicalDefault: Data("schema = 1\n".utf8)
        )

        #expect(selection == .legacyOnly(nativePath: nativePath, legacyPath: legacyPath))
        #expect(!FileManager.default.fileExists(atPath: nativePath))
        #expect(try Data(contentsOf: URL(fileURLWithPath: legacyPath)) == legacy)
    }

    @Test func invalidNativeConfigurationDoesNotFallBackToLegacy() throws {
        let directory = try NativeTemporaryDirectory()
        let nativePath = directory.path("vindu.toml")
        let legacyPath = directory.path("vindu.conf")
        try Data("schema = 1\nunknown = true\n".utf8).write(to: URL(fileURLWithPath: nativePath))
        let legacy = Data("general:gaps_in = 27\n".utf8)
        try legacy.write(to: URL(fileURLWithPath: legacyPath))

        #expect(throws: NativeConfigurationLoadError.self) {
            try NativeConfigurationFileLoader().loadDefault(
                nativePath: nativePath,
                legacyPath: legacyPath,
                canonicalDefault: Data("schema = 1\n".utf8)
            )
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: legacyPath)) == legacy)
    }

    @Test func missingFilesWriteAndLoadCanonicalConfiguration() throws {
        let directory = try NativeTemporaryDirectory()
        let nativePath = directory.path("nested/vindu.toml")
        let canonical = Data("schema = 1\n[layout]\nouter_gap = 31\n".utf8)

        let selection = try NativeConfigurationFileLoader().loadDefault(
            nativePath: nativePath,
            legacyPath: directory.path("nested/vindu.conf"),
            canonicalDefault: canonical
        )

        guard case .loaded(let loaded) = selection else {
            Issue.record("canonical configuration should load")
            return
        }
        #expect(loaded.wroteDefault)
        #expect(loaded.snapshot.layout.outerGap == 31)
        #expect(try Data(contentsOf: URL(fileURLWithPath: nativePath)) == canonical)
    }

    @Test func invalidCanonicalConfigurationIsNeverWritten() throws {
        let directory = try NativeTemporaryDirectory()
        let nativePath = directory.path("nested/vindu.toml")

        #expect(throws: NativeConfigurationLoadError.self) {
            try NativeConfigurationFileLoader().loadDefault(
                nativePath: nativePath,
                legacyPath: directory.path("nested/vindu.conf"),
                canonicalDefault: Data("schema = 2\n".utf8)
            )
        }
        #expect(!FileManager.default.fileExists(atPath: nativePath))
    }

    @Test func explicitMissingConfigurationNeverWrites() throws {
        let directory = try NativeTemporaryDirectory()
        let path = directory.path("missing/named.toml")

        #expect(throws: NativeConfigurationLoadError.self) {
            try NativeConfigurationFileLoader().loadExplicit(path: path)
        }
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(!FileManager.default.fileExists(atPath: directory.path("missing")))
    }

    @Test func offlineCheckNeverWrites() throws {
        let directory = try NativeTemporaryDirectory()
        let missingPath = directory.path("missing.toml")
        #expect(throws: NativeConfigurationLoadError.self) {
            try NativeConfigurationFileLoader().check(path: missingPath)
        }
        #expect(!FileManager.default.fileExists(atPath: missingPath))

        let existingPath = directory.path("existing.toml")
        let data = Data("schema = 1\n".utf8)
        try data.write(to: URL(fileURLWithPath: existingPath))
        _ = try NativeConfigurationFileLoader().check(path: existingPath)
        #expect(try Data(contentsOf: URL(fileURLWithPath: existingPath)) == data)
    }

    @Test func exactByteLimitLoadsAndInvalidBytesFail() throws {
        let directory = try NativeTemporaryDirectory()
        let exactPath = directory.path("exact.toml")
        let prefix = "schema = 1\n#"
        let exact = Data((prefix + String(repeating: "x",
                                         count: ConfigurationCompiler.maximumBytes - prefix.utf8.count)).utf8)
        try exact.write(to: URL(fileURLWithPath: exactPath))

        let loaded = try NativeConfigurationFileLoader().check(path: exactPath)
        #expect(exact.count == ConfigurationCompiler.maximumBytes)
        #expect(loaded.schema == 1)

        let oversizedPath = directory.path("oversized.toml")
        try Data(repeating: UInt8(ascii: "x"), count: ConfigurationCompiler.maximumBytes + 1)
            .write(to: URL(fileURLWithPath: oversizedPath))
        #expect(throws: NativeConfigurationLoadError.self) {
            try NativeConfigurationFileLoader().check(path: oversizedPath)
        }

        let invalidUTF8Path = directory.path("invalid.toml")
        try Data([0xff]).write(to: URL(fileURLWithPath: invalidUTF8Path))
        #expect(throws: NativeConfigurationLoadError.self) {
            try NativeConfigurationFileLoader().check(path: invalidUTF8Path)
        }
    }
}

struct ConfigurationControllerTests {
    @Test func reportsOnlyTheLoadThatWritesTheCanonicalDefault() throws {
        let directory = try NativeTemporaryDirectory()
        let path = directory.path("vindu.toml")
        let controller = ConfigurationController(path: path)

        _ = controller.loadDefault(
            legacyPath: directory.path("vindu.conf"),
            canonicalDefault: Data("schema = 1\n".utf8)
        )
        #expect(controller.lastLoadWroteCanonicalDefault)

        _ = controller.reload()
        #expect(!controller.lastLoadWroteCanonicalDefault)
    }

    @Test func validReloadSwapsTheActiveSnapshot() throws {
        let directory = try NativeTemporaryDirectory()
        let path = directory.path("vindu.toml")
        try Data("schema = 1\n[layout]\ninner_gap = 7\n".utf8).write(to: URL(fileURLWithPath: path))
        let controller = ConfigurationController(path: path)
        _ = controller.loadDefault(
            legacyPath: directory.path("vindu.conf"),
            canonicalDefault: Data("schema = 1\n".utf8)
        )

        try Data("schema = 1\n[layout]\ninner_gap = 17\n".utf8).write(to: URL(fileURLWithPath: path))
        let result = controller.reload()

        guard case .activated(let snapshot) = result else {
            Issue.record("valid reload should activate")
            return
        }
        #expect(snapshot.layout.innerGap == 17)
        #expect(controller.activeSnapshot?.layout.innerGap == 17)
        #expect(controller.status(daemonState: .waitingForAccessibility).latestAttemptSucceeded)
        #expect(controller.status(daemonState: .waitingForAccessibility).rejectedDiagnostics.isEmpty)
    }

    @Test func invalidReloadRetainsActiveSnapshotAndRuntimeWarnings() throws {
        let directory = try NativeTemporaryDirectory()
        let path = directory.path("vindu.toml")
        try Data("schema = 1\n[layout]\ninner_gap = 7\n".utf8).write(to: URL(fileURLWithPath: path))
        let controller = ConfigurationController(path: path)
        _ = controller.loadDefault(
            legacyPath: directory.path("vindu.conf"),
            canonicalDefault: Data("schema = 1\n".utf8)
        )
        let warning = LocatedConfigDiagnostic(file: path,
                                              schemaPath: "workspaces.assignments[0]",
                                              message: "monitor is not connected")
        controller.replaceRuntimeWarnings([warning])

        try Data("schema = 1\nunknown = true\n".utf8).write(to: URL(fileURLWithPath: path))
        let result = controller.reload()

        guard case .rejected(let diagnostics) = result else {
            Issue.record("invalid reload should be rejected")
            return
        }
        #expect(!diagnostics.isEmpty)
        #expect(controller.activeSnapshot?.layout.innerGap == 7)
        #expect(!controller.status(daemonState: .running).latestAttemptSucceeded)
        #expect(controller.status(daemonState: .running).runtimeWarnings == [warning])
        #expect(controller.status(daemonState: .running).daemonState == .running)
        #expect(controller.status(daemonState: .running).activeSchema == 1)
    }

    @Test func legacyOnlyStartsInConfigurationOnlyState() throws {
        let directory = try NativeTemporaryDirectory()
        let path = directory.path("vindu.toml")
        let legacyPath = directory.path("vindu.conf")
        try Data("legacy".utf8).write(to: URL(fileURLWithPath: legacyPath))
        let controller = ConfigurationController(path: path)

        let result = controller.loadDefault(
            legacyPath: legacyPath,
            canonicalDefault: Data("schema = 1\n".utf8)
        )

        guard case .configurationOnly(let diagnostics) = result else {
            Issue.record("legacy-only startup should enter configuration-only state")
            return
        }
        #expect(diagnostics.first?.message.contains("legacy configuration") == true)
        #expect(controller.activeSnapshot == nil)
        #expect(controller.status(daemonState: .configurationOnly).daemonState == .configurationOnly)
    }
}

struct ConfigurationCommandRouteTests {
    @Test func configCheckRoutesOfflineAndStatusReloadUseTheSocket() {
        #expect(ConfigurationCommandRouter.route(arguments: ["config", "check"],
                                                 json: false,
                                                 defaultPath: "/default/vindu.toml") ==
            .offlineCheck(path: "/default/vindu.toml"))
        #expect(ConfigurationCommandRouter.route(arguments: ["config", "check", "/tmp/custom.toml"],
                                                 json: false,
                                                 defaultPath: "/default/vindu.toml") ==
            .offlineCheck(path: "/tmp/custom.toml"))
        #expect(ConfigurationCommandRouter.route(arguments: ["config", "status"],
                                                 json: true,
                                                 defaultPath: "/default/vindu.toml") ==
            .socketRequest("j/config status"))
        #expect(ConfigurationCommandRouter.route(arguments: ["config", "reload"],
                                                 json: false,
                                                 defaultPath: "/default/vindu.toml") ==
            .socketRequest("config reload"))
        #expect(ConfigurationCommandRouter.route(arguments: ["config", "check", "../vindu.toml"],
                                                 json: false,
                                                 defaultPath: "/default/vindu.toml",
                                                 currentDirectory: "/tmp/config",
                                                 homeDirectory: "/Users/test") ==
            .offlineCheck(path: "/tmp/vindu.toml"))
        #expect(ConfigurationCommandRouter.route(arguments: ["config", "check", "~/.config/vindu/vindu.toml"],
                                                 json: false,
                                                 defaultPath: "/default/vindu.toml",
                                                 currentDirectory: "/tmp",
                                                 homeDirectory: "/Users/test") ==
            .offlineCheck(path: "/Users/test/.config/vindu/vindu.toml"))
        #expect(ConfigurationCommandRouter.route(arguments: ["config"],
                                                 json: false,
                                                 defaultPath: "/default/vindu.toml") ==
            .invalid("config needs check, status, or reload"))
        #expect(ConfigurationCommandRouter.route(arguments: ["config", "old"],
                                                 json: false,
                                                 defaultPath: "/default/vindu.toml") ==
            .invalid("unknown config command 'old'"))
    }
}

private final class NativeTemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vindu-native-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func path(_ component: String) -> String {
        url.appendingPathComponent(component).path
    }
}
