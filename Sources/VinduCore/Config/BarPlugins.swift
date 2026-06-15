import Foundation

public enum BarItem: Equatable {
    case builtin(BarIndicator)
    case plugin(String)

    public var text: String {
        switch self {
        case .builtin(let indicator): return indicator.rawValue
        case .plugin(let id): return "plugin:\(id)"
        }
    }

    public static func parse(_ raw: String) -> Result<BarItem, ParseError> {
        let name = raw.trimmingCharacters(in: .whitespaces)
        if let id = name.removingPrefix("plugin:") {
            guard BarPluginConfig.isValidID(id) else {
                return .failure("bad bar plugin id '\(id)' expected [A-Za-z0-9_-]+")
            }
            return .success(.plugin(id.lowercased()))
        }
        guard let indicator = BarIndicator.parse(name) else {
            let allowed = BarIndicator.allCases.map(\.rawValue).joined(separator: ",")
            return .failure("unknown indicator '\(name)' expected one of \(allowed) or plugin:<id>")
        }
        return .success(.builtin(indicator))
    }
}

public struct BarPluginConfig: Equatable {
    public static let defaultRefreshSeconds = 60
    public static let defaultTimeoutMs = 1000
    public static let allowedEvents: Set<String> = [
        "workspace", "workspacev2", "focusedmon", "activewindow", "activewindowv2",
        "openwindow", "closewindow", "movewindow", "fullscreen", "changefloatingmode",
        "createworkspace", "destroyworkspace", "renameworkspace", "submap",
        "configreloaded", "monitoradded", "monitorremoved", "pause",
    ]

    public var command = ""
    public var refreshSeconds = defaultRefreshSeconds
    public var events: [String] = []
    public var timeoutMs = defaultTimeoutMs

    public init(command: String = "",
                refreshSeconds: Int = defaultRefreshSeconds,
                events: [String] = [],
                timeoutMs: Int = defaultTimeoutMs) {
        self.command = command
        self.refreshSeconds = refreshSeconds
        self.events = events
        self.timeoutMs = timeoutMs
    }

    public static func isValidID(_ id: String) -> Bool {
        guard !id.isEmpty else { return false }
        return id.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) ||
                (48...57).contains($0) || $0 == 95 || $0 == 45
        }
    }
}

enum BarPluginKeywordResult {
    case notPlugin
    case applied
    case failed(String)
}

enum BarPluginKeyword {
    static func set(_ key: String, value: String, settings: inout Settings) -> BarPluginKeywordResult {
        let option: Option
        switch parse(key) {
        case .success(.none):
            return .notPlugin
        case .success(.some(let parsed)):
            option = parsed
        case .failure(let error):
            return .failed(error.message)
        }
        var config = settings.bar.plugins[option.id] ?? BarPluginConfig()
        switch option.name {
        case "command":
            guard !value.isEmpty else { return .failed("bar plugin command is empty") }
            config.command = value
        case "refresh_seconds":
            guard let seconds = Int(value) else { return .failed("invalid integer") }
            guard seconds == 0 || (5...3600).contains(seconds) else {
                return .failed("value out of range 0 or 5...3600")
            }
            config.refreshSeconds = seconds
        case "timeout_ms":
            guard let timeout = Int(value) else { return .failed("invalid integer") }
            guard (250...5000).contains(timeout) else {
                return .failed("value out of range 250...5000")
            }
            config.timeoutMs = timeout
        case "events":
            switch parseEvents(value) {
            case .success(let events): config.events = events
            case .failure(let error): return .failed(error.message)
            }
        default:
            return .failed("unknown bar plugin option: \(option.name)")
        }
        settings.bar.plugins[option.id] = config
        return .applied
    }

    static func get(_ key: String, settings: Settings) -> String? {
        guard case .success(.some(let option)) = parse(key),
              let config = settings.bar.plugins[option.id] else {
            return nil
        }
        switch option.name {
        case "command": return config.command
        case "refresh_seconds": return String(config.refreshSeconds)
        case "timeout_ms": return String(config.timeoutMs)
        case "events": return config.events.isEmpty ? "none" : config.events.joined(separator: ",")
        default: return nil
        }
    }

    static func validationErrors(settings: Settings) -> [String] {
        Set(settings.bar.pluginIDs).sorted().compactMap { id in
            let command = settings.bar.plugins[id]?.command
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return command.isEmpty ? "bar plugin '\(id)' needs command" : nil
        }
    }

    private struct Option {
        let id: String
        let name: String
    }

    private static func parse(_ key: String) -> Result<Option?, ParseError> {
        guard let rest = key.removingPrefix("bar:plugin:") else { return .success(nil) }
        let parts = rest.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else {
            return .failure("bar plugin option needs: bar:plugin:<id>:<key>")
        }
        let id = parts[0].lowercased()
        guard BarPluginConfig.isValidID(id) else {
            return .failure("bad bar plugin id '\(parts[0])' expected [A-Za-z0-9_-]+")
        }
        return .success(Option(id: id, name: parts[1]))
    }

    private static func parseEvents(_ value: String) -> Result<[String], ParseError> {
        let events = value.split(separator: ",", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        if events.isEmpty || (events.count == 1 && events[0] == "none") {
            return .success([])
        }
        for event in events where !BarPluginConfig.allowedEvents.contains(event) {
            return .failure("unknown bar plugin event '\(event)'")
        }
        return .success(events)
    }
}

public enum BarPluginColor: Equatable {
    case foreground
    case inactive
    case active
    case custom(MLColor)
}

public struct BarPluginValue: Equatable {
    public var text: String
    public var symbolNames: [String]
    public var color: BarPluginColor

    public init(text: String, symbolNames: [String] = [], color: BarPluginColor = .foreground) {
        self.text = text
        self.symbolNames = symbolNames
        self.color = color
    }
}

public enum BarPluginOutput {
    public static let maxBytes = 8 * 1024

    public static func parse(_ data: Data) -> Result<BarPluginValue?, ParseError> {
        guard data.count <= maxBytes else { return .failure("plugin output too large") }
        guard let raw = String(data: data, encoding: .utf8) else {
            return .failure("plugin output is not utf8")
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .success(nil) }
        if trimmed.hasPrefix("{") {
            return parseJSON(trimmed)
        }
        return .success(BarPluginValue(text: firstLine(trimmed)))
    }

    private static func parseJSON(_ raw: String) -> Result<BarPluginValue?, ParseError> {
        guard let data = raw.data(using: .utf8),
              let output = try? JSONDecoder().decode(JSONOutput.self, from: data) else {
            return .failure("invalid plugin json")
        }
        if output.visible == false { return .success(nil) }
        let text = firstLine(output.text ?? "")
        guard !text.isEmpty || !(output.symbols ?? []).isEmpty else {
            return .success(nil)
        }
        guard let color = parseColor(output.color) else {
            return .failure("invalid plugin color")
        }
        return .success(BarPluginValue(text: text,
                                       symbolNames: output.symbols ?? [],
                                       color: color))
    }

    private static func parseColor(_ raw: String?) -> BarPluginColor? {
        guard let raw, !raw.isEmpty else { return .foreground }
        switch raw.lowercased() {
        case "foreground": return .foreground
        case "inactive": return .inactive
        case "active": return .active
        default:
            return MLColor.parse(raw).map(BarPluginColor.custom)
        }
    }

    private static func firstLine(_ text: String) -> String {
        text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
    }

    private struct JSONOutput: Decodable {
        var text: String?
        var symbols: [String]?
        var color: String?
        var visible: Bool?
    }
}
