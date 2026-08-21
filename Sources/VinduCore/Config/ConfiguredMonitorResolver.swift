import Foundation

public enum ConfiguredMonitorResolution: Equatable {
    case matched(Int)
    case missing
    case ambiguous
}

public enum ConfiguredMonitorResolver {
    public static func resolve(_ configuredName: String,
                               in availableNames: [String]) -> ConfiguredMonitorResolution {
        let exact = availableNames.indices.filter {
            availableNames[$0].caseInsensitiveCompare(configuredName) == .orderedSame
        }
        if exact.count == 1 { return .matched(exact[0]) }
        if exact.count > 1 { return .ambiguous }

        let partial = availableNames.indices.filter {
            availableNames[$0].range(of: configuredName, options: .caseInsensitive) != nil
        }
        if partial.count == 1 { return .matched(partial[0]) }
        return partial.isEmpty ? .missing : .ambiguous
    }
}
