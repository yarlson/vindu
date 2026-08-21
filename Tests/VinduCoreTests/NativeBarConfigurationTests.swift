import Testing
@testable import VinduCore

struct NativeBarConfigurationTests {
    @Test func itemQueriesCoverEveryConfiguredZoneInOrder() {
        let configuration = NativeBarConfiguration(
            enabled: true,
            position: .top,
            height: .automatic,
            left: [.workspaces, .plugin("left")],
            center: [.layout, .weather],
            right: [.plugin("right"), .date],
            colors: colors,
            weather: nil,
            plugins: [:]
        )

        #expect(configuration.allItems == [
            .workspaces, .plugin("left"), .layout, .weather, .plugin("right"), .date,
        ])
        #expect(configuration.contains(.weather))
        #expect(configuration.pluginIDs == ["left", "right"])
    }

    private var colors: NativeBarColors {
        let color = ConfigurationColor(red: 0, green: 0, blue: 0, alpha: 1)
        return NativeBarColors(background: color, foreground: color,
                               inactive: color, active: color)
    }
}
