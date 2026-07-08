import Foundation
import VinduCore

public struct ConfigFileLoad {
    public let document: ConfigDocument
    public let wroteDefault: Bool

    public init(document: ConfigDocument, wroteDefault: Bool) {
        self.document = document
        self.wroteDefault = wroteDefault
    }
}

public enum ConfigLoadError: Error, Equatable, CustomStringConvertible {
    public static let errorPrefix = "config file load failed: "

    case defaultWriteFailed(path: String, reason: String)
    case readFailed(path: String, reason: String)

    public var description: String {
        switch self {
        case .defaultWriteFailed(let path, let reason):
            return "cannot write default config \(path): \(reason)"
        case .readFailed(let path, let reason):
            return "cannot read config \(path): \(reason)"
        }
    }

    var configErrorMessage: String {
        Self.errorPrefix + description
    }
}

public enum ConfigReloadResult {
    case loaded(ConfigFileLoad)
    case keptPrevious(document: ConfigDocument, error: ConfigLoadError)
}

public struct ConfigFileLoader {
    private let fileManager: FileManager
    private let parser: ConfigParser

    public init(fileManager: FileManager = .default, parser: ConfigParser = ConfigParser()) {
        self.fileManager = fileManager
        self.parser = parser
    }

    public func load(path: String, defaultText: String) throws -> ConfigFileLoad {
        let text: String
        let wroteDefault: Bool
        if fileManager.fileExists(atPath: path) {
            do {
                text = try String(contentsOfFile: path, encoding: .utf8)
                wroteDefault = false
            } catch {
                throw ConfigLoadError.readFailed(path: path, reason: error.localizedDescription)
            }
        } else {
            do {
                let dir = (path as NSString).deletingLastPathComponent
                try fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try defaultText.write(toFile: path, atomically: true, encoding: .utf8)
                text = defaultText
                wroteDefault = true
            } catch {
                throw ConfigLoadError.defaultWriteFailed(path: path, reason: error.localizedDescription)
            }
        }

        let document = parser.parse(text: text, baseDir: (path as NSString).deletingLastPathComponent)
        return ConfigFileLoad(document: document, wroteDefault: wroteDefault)
    }

    public func reload(path: String, defaultText: String, previous: ConfigDocument) -> ConfigReloadResult {
        do {
            return .loaded(try load(path: path, defaultText: defaultText))
        } catch let error as ConfigLoadError {
            return .keptPrevious(document: previous.withConfigLoadError(error), error: error)
        } catch {
            let loadError = ConfigLoadError.readFailed(path: path, reason: error.localizedDescription)
            return .keptPrevious(document: previous.withConfigLoadError(loadError), error: loadError)
        }
    }
}

private extension ConfigDocument {
    func withConfigLoadError(_ error: ConfigLoadError) -> ConfigDocument {
        var next = self
        next.errors.removeAll {
            $0.line == 0 && $0.message.hasPrefix(ConfigLoadError.errorPrefix)
        }
        next.errors.append(ConfigError(line: 0, message: error.configErrorMessage))
        return next
    }
}
