import Foundation

/// Window fields a rule (or `focuswindow`/`closewindow` matcher) can test.
public struct MatchTarget {
    public var clazz: String
    public var title: String
    public var initialClass: String
    public var initialTitle: String
    public var floating: Bool
    public var workspaceName: String
    public var pid: Int

    public init(clazz: String, title: String, initialClass: String = "", initialTitle: String = "",
                floating: Bool = false, workspaceName: String = "", pid: Int = 0) {
        self.clazz = clazz
        self.title = title
        self.initialClass = initialClass.isEmpty ? clazz : initialClass
        self.initialTitle = initialTitle.isEmpty ? title : initialTitle
        self.floating = floating
        self.workspaceName = workspaceName
        self.pid = pid
    }
}

public struct RuleMatcher {
    public enum Field: String {
        case clazz = "class"
        case title
        case initialClass = "initialclass"
        case initialTitle = "initialtitle"
        case floating
        case workspace
        case pid
        case address
    }

    public let field: Field
    public let pattern: String
    private let regex: NSRegularExpression?

    public init?(field: Field, pattern: String) {
        self.field = field
        self.pattern = pattern
        switch field {
        case .floating, .pid, .address:
            self.regex = nil
        default:
            guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
            self.regex = re
        }
    }

    /// Parses `field:pattern`. A bare pattern (no known field prefix) matches class,
    /// which covers Hyprland v1 rules and bare `focuswindow` arguments.
    public static func parse(_ raw: String) -> RuleMatcher? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if let idx = s.firstIndex(of: ":") {
            let fieldName = String(s[..<idx]).lowercased()
            let pattern = String(s[s.index(after: idx)...])
            if let field = Field(rawValue: fieldName) {
                return RuleMatcher(field: field, pattern: pattern)
            }
        }
        return RuleMatcher(field: .clazz, pattern: s)
    }

    public func matches(_ t: MatchTarget, address: WindowID = 0) -> Bool {
        func search(_ str: String) -> Bool {
            guard let regex else { return false }
            return regex.firstMatch(in: str, range: NSRange(str.startIndex..., in: str)) != nil
        }
        switch field {
        case .clazz: return search(t.clazz)
        case .title: return search(t.title)
        case .initialClass: return search(t.initialClass)
        case .initialTitle: return search(t.initialTitle)
        case .workspace: return search(t.workspaceName)
        case .floating: return (pattern == "1") == t.floating
        case .pid: return Int(pattern) == t.pid
        case .address:
            let hex = pattern.lowercased().removingPrefix("0x") ?? pattern.lowercased()
            return WindowID(hex, radix: 16) == address
        }
    }
}

extension RuleMatcher: Equatable {
    public static func == (lhs: RuleMatcher, rhs: RuleMatcher) -> Bool {
        lhs.field == rhs.field && lhs.pattern == rhs.pattern
    }
}

public enum RuleEffect: Equatable {
    case float
    case tile
    case fullscreen
    case maximize
    case center
    case pin
    case size(Delta, Delta)
    case move(Delta, Delta)
    case workspace(WorkspaceTarget, silent: Bool)
    case monitor(String)
    /// Hyprland effects with no macOS equivalent (opacity, noborder, …), accepted
    /// so existing configs load; ignored at apply time.
    case unsupported(String)

    static let unsupportedNames: Set<String> = [
        "opacity", "noborder", "rounding", "bordersize", "bordercolor", "animation",
        "noblur", "noshadow", "nodim", "noanim", "suppressevent", "idleinhibit",
        "nofocus", "keepaspectratio", "stayfocused", "group", "xray", "dimaround",
        "nomaxsize", "minsize", "maxsize", "pseudo", "forcergbx", "syncfullscreen",
        "immediate", "windowdance", "fakefullscreen",
    ]

    public static func parse(_ raw: String) -> Result<RuleEffect, ParseError> {
        let tokens = raw.split(separator: " ").map(String.init)
        guard let head = tokens.first?.lowercased() else {
            return .failure("empty rule effect")
        }
        let args = Array(tokens.dropFirst())

        func twoDeltas(_ make: (Delta, Delta) -> RuleEffect) -> Result<RuleEffect, ParseError> {
            guard args.count == 2, let a = Delta.parse(args[0]), let b = Delta.parse(args[1]) else {
                return .failure("\(head) needs two numeric args")
            }
            return .success(make(a, b))
        }

        switch head {
        case "float": return .success(.float)
        case "tile": return .success(.tile)
        case "fullscreen": return .success(.fullscreen)
        case "maximize": return .success(.maximize)
        case "center": return .success(.center)
        case "pin": return .success(.pin)
        case "size": return twoDeltas { .size($0, $1) }
        case "move": return twoDeltas { .move($0, $1) }
        case "monitor":
            guard let m = args.first else { return .failure("monitor rule needs a monitor") }
            return .success(.monitor(m))
        case "workspace":
            guard let t = args.first, let ws = WorkspaceTarget.parse(t) else {
                return .failure("workspace rule needs a workspace target")
            }
            return .success(.workspace(ws, silent: args.contains("silent")))
        default:
            if unsupportedNames.contains(head) {
                return .success(.unsupported(head))
            }
            return .failure("unknown rule effect: \(head)")
        }
    }
}

public struct WindowRule: Equatable {
    public var effect: RuleEffect
    public var matchers: [RuleMatcher]

    public init(effect: RuleEffect, matchers: [RuleMatcher]) {
        self.effect = effect
        self.matchers = matchers
    }

    public func matches(_ t: MatchTarget) -> Bool {
        !matchers.isEmpty && matchers.allSatisfy { $0.matches(t) }
    }

    /// `windowrule = float, ^(kitty)$` — single class regex.
    public static func parseV1(_ value: String) -> Result<WindowRule, ParseError> {
        let parts = splitCSV(value, limit: 2)
        guard parts.count == 2 else {
            return .failure("windowrule needs: effect, class-regex")
        }
        return RuleEffect.parse(parts[0]).flatMap { effect in
            guard let m = RuleMatcher(field: .clazz, pattern: parts[1]) else {
                return .failure("invalid regex: \(parts[1])")
            }
            return .success(WindowRule(effect: effect, matchers: [m]))
        }
    }

    /// `windowrulev2 = float, class:^(kitty)$, title:^(scratch)$`
    public static func parseV2(_ value: String) -> Result<WindowRule, ParseError> {
        let parts = splitCSV(value, limit: 64)
        guard parts.count >= 2 else {
            return .failure("windowrulev2 needs: effect, matcher[, matcher…]")
        }
        return RuleEffect.parse(parts[0]).flatMap { effect in
            var matchers: [RuleMatcher] = []
            for raw in parts.dropFirst() where !raw.isEmpty {
                guard let m = RuleMatcher.parse(raw) else {
                    return .failure("invalid matcher: \(raw)")
                }
                matchers.append(m)
            }
            guard !matchers.isEmpty else {
                return .failure("windowrulev2 needs at least one matcher")
            }
            return .success(WindowRule(effect: effect, matchers: matchers))
        }
    }
}
