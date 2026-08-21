import Foundation

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
            regex = nil
        default:
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
            regex = expression
        }
    }

    public static func parse(_ raw: String) -> RuleMatcher? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if let separator = value.firstIndex(of: ":") {
            let fieldName = String(value[..<separator]).lowercased()
            let pattern = String(value[value.index(after: separator)...])
            if let field = Field(rawValue: fieldName) {
                return RuleMatcher(field: field, pattern: pattern)
            }
        }
        return RuleMatcher(field: .clazz, pattern: value)
    }

    public func matches(_ target: MatchTarget, address: WindowID = 0) -> Bool {
        func search(_ value: String) -> Bool {
            guard let regex else { return false }
            return regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
        }
        switch field {
        case .clazz: return search(target.clazz)
        case .title: return search(target.title)
        case .initialClass: return search(target.initialClass)
        case .initialTitle: return search(target.initialTitle)
        case .workspace: return search(target.workspaceName)
        case .floating: return (pattern == "1") == target.floating
        case .pid: return Int(pattern) == target.pid
        case .address:
            let value = pattern.lowercased().removingPrefix("0x") ?? pattern.lowercased()
            return WindowID(value, radix: 16) == address
        }
    }
}

extension RuleMatcher: Equatable {
    public static func == (lhs: RuleMatcher, rhs: RuleMatcher) -> Bool {
        lhs.field == rhs.field && lhs.pattern == rhs.pattern
    }
}
