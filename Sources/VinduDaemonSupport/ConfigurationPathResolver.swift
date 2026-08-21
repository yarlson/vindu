import Foundation

public enum ConfigurationPathResolver {
    public static func resolve(_ path: String,
                               currentDirectory: String = FileManager.default.currentDirectoryPath,
                               homeDirectory: String = NSHomeDirectory()) -> String {
        let expanded: String
        if path == "~" {
            expanded = homeDirectory
        } else if path.hasPrefix("~/") {
            expanded = (homeDirectory as NSString).appendingPathComponent(String(path.dropFirst(2)))
        } else {
            expanded = path
        }
        if (expanded as NSString).isAbsolutePath {
            return (expanded as NSString).standardizingPath
        }
        return ((currentDirectory as NSString).appendingPathComponent(expanded) as NSString).standardizingPath
    }
}
