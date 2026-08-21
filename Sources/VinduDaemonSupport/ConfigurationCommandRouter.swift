import Foundation

public enum ConfigurationCommandRoute: Equatable {
    case offlineCheck(path: String)
    case socketRequest(String)
    case invalid(String)
}

public enum ConfigurationCommandRouter {
    public static func route(arguments: [String],
                             json: Bool,
                             defaultPath: String,
                             currentDirectory: String = FileManager.default.currentDirectoryPath,
                             homeDirectory: String = NSHomeDirectory()) -> ConfigurationCommandRoute? {
        guard arguments.first == "config" else { return nil }
        guard arguments.count >= 2 else {
            return .invalid("config needs check, status, or reload")
        }
        switch arguments[1] {
        case "check":
            guard arguments.count <= 3 else {
                return .invalid("config check takes at most one path")
            }
            let path = arguments.count == 3 ? arguments[2] : defaultPath
            return .offlineCheck(path: ConfigurationPathResolver.resolve(path,
                                                                         currentDirectory: currentDirectory,
                                                                         homeDirectory: homeDirectory))
        case "status", "reload":
            guard arguments.count == 2 else {
                return .invalid("config \(arguments[1]) takes no arguments")
            }
            return .socketRequest((json ? "j/" : "") + arguments.joined(separator: " "))
        default:
            return .invalid("unknown config command '\(arguments[1])'")
        }
    }
}
