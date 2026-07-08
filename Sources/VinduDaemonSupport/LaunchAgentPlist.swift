import Foundation

public enum VinduLogPaths {
    public static func daemonLogPath(homeDirectory: String = NSHomeDirectory()) -> String {
        (homeDirectory as NSString).appendingPathComponent("Library/Logs/vindu/vindud.log")
    }

    public static func ensureLogDirectory(for logPath: String,
                                          fileManager: FileManager = .default) throws {
        let dir = (logPath as NSString).deletingLastPathComponent
        try fileManager.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
    }
}

public enum LaunchAgentPlist {
    static func propertyList(binaryPath: String,
                             configPath: String,
                             logPath: String) -> [String: Any] {
        [
            "Label": "com.vindu.daemon",
            "ProgramArguments": [binaryPath, "--config", configPath],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
        ]
    }

    public static func data(binaryPath: String,
                            configPath: String,
                            logPath: String) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: propertyList(binaryPath: binaryPath,
                                           configPath: configPath,
                                           logPath: logPath),
            format: .xml,
            options: 0)
    }

    public static func write(binaryPath: String,
                             configPath: String,
                             logPath: String,
                             to path: String,
                             fileManager: FileManager = .default) throws {
        try VinduLogPaths.ensureLogDirectory(for: logPath, fileManager: fileManager)
        let dir = (path as NSString).deletingLastPathComponent
        try fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let plistData = try data(binaryPath: binaryPath, configPath: configPath, logPath: logPath)
        try plistData.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
