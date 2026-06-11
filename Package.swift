// swift-tools-version: 6.0
import PackageDescription

// Language mode 5: the daemon talks to C APIs (AX, CGEvent taps) through
// callback pointers that Swift 6 strict concurrency cannot model usefully.
let lang: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "vindu",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "VinduCore", targets: ["VinduCore"]),
        .executable(name: "vindud", targets: ["vindud"]),
        .executable(name: "vinductl", targets: ["vinductl"]),
    ],
    targets: [
        .target(name: "VinduCore", swiftSettings: lang),
        .executableTarget(name: "vindud", dependencies: ["VinduCore"], swiftSettings: lang),
        .executableTarget(name: "vinductl", dependencies: ["VinduCore"], swiftSettings: lang),
        .testTarget(name: "VinduCoreTests", dependencies: ["VinduCore"], swiftSettings: lang),
    ]
)
