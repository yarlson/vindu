import Foundation

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
