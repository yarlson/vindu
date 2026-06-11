import Foundation

/// Splits on commas into at most `limit` parts; the last part keeps any
/// remaining commas verbatim (dispatcher args may contain commas).
/// All parts are whitespace-trimmed.
public func splitCSV(_ s: String, limit: Int) -> [String] {
    guard limit > 1 else { return [s.trimmingCharacters(in: .whitespaces)] }
    var parts: [String] = []
    var rest = Substring(s)
    while parts.count < limit - 1, let idx = rest.firstIndex(of: ",") {
        parts.append(rest[..<idx].trimmingCharacters(in: .whitespaces))
        rest = rest[rest.index(after: idx)...]
    }
    parts.append(rest.trimmingCharacters(in: .whitespaces))
    return parts
}

public struct ConfigError: Equatable {
    public let line: Int
    public let message: String

    public init(line: Int, message: String) {
        self.line = line
        self.message = message
    }
}

public struct WorkspaceRule: Equatable {
    public var target: WorkspaceTarget
    public var monitorName: String?

    public init(target: WorkspaceTarget, monitorName: String?) {
        self.target = target
        self.monitorName = monitorName
    }
}

/// Everything a config file (plus runtime `keyword` commands) produces.
public struct ConfigDocument {
    public var settings = Settings()
    public var binds: [Bind] = []
    public var rules: [WindowRule] = []
    public var exec: [String] = []
    public var execOnce: [String] = []
    public var envs: [(key: String, value: String)] = []
    /// `monitor =` lines are accepted for config compatibility; macOS owns
    /// display arrangement, so they are recorded but not applied.
    public var monitors: [String] = []
    public var workspaceRules: [WorkspaceRule] = []
    public var errors: [ConfigError] = []

    public init() {}
}

/// Parses the Hyprland config dialect: `key = value`, `section { … }`,
/// `$variables`, `source =`, `#` comments (`##` escapes a literal `#`),
/// and submap blocks delimited by `submap = name` / `submap = reset`.
public final class ConfigParser {
    public typealias FileLoader = (String) throws -> String

    private let loadFile: FileLoader

    public init(fileLoader: @escaping FileLoader = { try String(contentsOfFile: $0, encoding: .utf8) }) {
        self.loadFile = fileLoader
    }

    private struct ParseState {
        var vars: [String: String] = [:]
        var sections: [String] = []
        var submap = ""
    }

    public func parse(text: String, baseDir: String = NSHomeDirectory()) -> ConfigDocument {
        var doc = ConfigDocument()
        var state = ParseState()
        parseLines(text, into: &doc, state: &state, baseDir: baseDir, depth: 0)
        if !state.sections.isEmpty {
            doc.errors.append(ConfigError(line: 0, message: "unclosed section: \(state.sections.joined(separator: ":"))"))
        }
        return doc
    }

    /// Applies one live `keyword` command (e.g. `general:gaps_in 10`, or even
    /// `bind SUPER,T,exec,kitty`) to an existing document. Returns an error message or nil.
    public static func applyKeyword(_ key: String, _ value: String, to doc: inout ConfigDocument) -> String? {
        let parser = ConfigParser(fileLoader: { _ in throw CocoaError(.fileReadNoSuchFile) })
        var state = ParseState()
        let before = doc.errors.count
        parser.handleAssignment(key: key, value: value, doc: &doc, state: &state,
                                line: 0, baseDir: NSHomeDirectory(), depth: 0)
        if doc.errors.count > before {
            return doc.errors.removeLast().message
        }
        return nil
    }

    private func parseLines(_ text: String, into doc: inout ConfigDocument,
                            state: inout ParseState, baseDir: String, depth: Int) {
        var lineNo = 0
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNo += 1
            // A line starting with '#' is a comment, banner lines of hashes
            // included; the '##' escape applies inline only.
            let raw = String(rawLine)
            if raw.trimmingCharacters(in: .whitespaces).hasPrefix("#") { continue }
            var line = stripComment(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            line = substitute(line, vars: state.vars)

            if line == "}" {
                if state.sections.isEmpty {
                    doc.errors.append(ConfigError(line: lineNo, message: "unmatched '}'"))
                } else {
                    state.sections.removeLast()
                }
                continue
            }
            if line.hasSuffix("{") {
                let name = String(line.dropLast()).trimmingCharacters(in: .whitespaces).lowercased()
                if name.isEmpty || name.contains("=") {
                    doc.errors.append(ConfigError(line: lineNo, message: "bad section header: \(line)"))
                } else {
                    state.sections.append(name)
                }
                continue
            }
            guard let eq = line.firstIndex(of: "=") else {
                doc.errors.append(ConfigError(line: lineNo, message: "expected 'key = value': \(line)"))
                continue
            }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)

            if key.hasPrefix("$") {
                state.vars[String(key.dropFirst())] = value
                continue
            }

            let fullKey = (state.sections + [key]).joined(separator: ":")
            handleAssignment(key: fullKey, value: value, doc: &doc, state: &state,
                             line: lineNo, baseDir: baseDir, depth: depth)
        }
    }

    private func handleAssignment(key: String, value: String, doc: inout ConfigDocument,
                                  state: inout ParseState, line: Int, baseDir: String, depth: Int) {
        let k = key.lowercased()

        func record<T>(_ result: Result<T, ParseError>, _ append: (T) -> Void) {
            switch result {
            case .success(let v): append(v)
            case .failure(let err): doc.errors.append(ConfigError(line: line, message: err.message))
            }
        }

        switch k {
        case "source":
            guard depth < 10 else {
                doc.errors.append(ConfigError(line: line, message: "source nesting too deep"))
                return
            }
            let expanded = (value as NSString).expandingTildeInPath
            let path = expanded.hasPrefix("/") ? expanded : (baseDir as NSString).appendingPathComponent(expanded)
            do {
                let text = try loadFile(path)
                let dir = (path as NSString).deletingLastPathComponent
                parseLines(text, into: &doc, state: &state, baseDir: dir, depth: depth + 1)
            } catch {
                doc.errors.append(ConfigError(line: line, message: "cannot source \(path)"))
            }
        case "submap":
            state.submap = (value == "reset") ? "" : value
        case "exec-once":
            doc.execOnce.append(value)
        case "exec":
            doc.exec.append(value)
        case "env":
            let parts = splitCSV(value, limit: 2)
            if parts.count == 2 {
                doc.envs.append((key: parts[0], value: parts[1]))
            } else {
                doc.errors.append(ConfigError(line: line, message: "env needs: NAME,value"))
            }
        case "monitor":
            doc.monitors.append(value)
        case "workspace":
            let parts = splitCSV(value, limit: 16)
            guard let target = WorkspaceTarget.parse(parts[0]) else {
                doc.errors.append(ConfigError(line: line, message: "bad workspace rule target: \(parts[0])"))
                return
            }
            let monitor = parts.dropFirst()
                .compactMap { $0.removingPrefix("monitor:") }
                .first
            doc.workspaceRules.append(WorkspaceRule(target: target, monitorName: monitor))
        case "windowrule":
            record(WindowRule.parseV1(value)) { doc.rules.append($0) }
        case "windowrulev2":
            record(WindowRule.parseV2(value)) { doc.rules.append($0) }
        case "unbind":
            let parts = splitCSV(value, limit: 2)
            guard parts.count == 2, let mods = Modifiers.parse(parts[0]) else {
                doc.errors.append(ConfigError(line: line, message: "unbind needs: mods, key"))
                return
            }
            let bindKey = parts[1].lowercased()
            doc.binds.removeAll { $0.mods == mods && $0.key == bindKey && $0.submap == state.submap }
        case "layerrule", "animation", "bezier", "blurls", "plugin", "debug", "windowrulev1":
            break // Hyprland keywords with no macOS counterpart; tolerated
        default:
            if k.hasPrefix("bind"), isBindKeyword(k) {
                let suffix = String(k.dropFirst("bind".count))
                record(BindParser.parse(flagsSuffix: suffix, value: value, submap: state.submap)) {
                    doc.binds.append($0)
                }
                return
            }
            if let err = doc.settings.set(key, value) {
                doc.errors.append(ConfigError(line: line, message: err))
            }
        }
    }

    /// True for `bind` plus any valid flag suffix — but not for the `binds`
    /// settings section (`binds:…` keys fall through to Settings).
    private func isBindKeyword(_ k: String) -> Bool {
        let suffix = k.dropFirst("bind".count)
        if suffix.contains(":") { return false }
        return BindFlags.parse(String(suffix)) != nil
    }

    /// Strips `#` comments; `##` produces a literal `#`.
    func stripComment(_ line: String) -> String {
        var out = ""
        var i = line.startIndex
        while i < line.endIndex {
            if line[i] == "#" {
                let next = line.index(after: i)
                if next < line.endIndex, line[next] == "#" {
                    out.append("#")
                    i = line.index(after: next)
                    continue
                }
                break
            }
            out.append(line[i])
            i = line.index(after: i)
        }
        return out
    }

    /// Longest-name-first so `$mainModShift` is not clobbered by `$mainMod`.
    private func substitute(_ line: String, vars: [String: String]) -> String {
        guard line.contains("$") else { return line }
        var out = line
        for (name, value) in vars.sorted(by: { $0.key.count > $1.key.count }) {
            out = out.replacingOccurrences(of: "$" + name, with: value)
        }
        return out
    }
}
