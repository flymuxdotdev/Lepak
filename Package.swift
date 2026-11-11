// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "vibe-key",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "VibeKeyKit",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(name: "probe"),
        .executableTarget(
            name: "menubar",
            dependencies: ["VibeKeyKit"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("IOKit"),
            ]
        ),
    ]
)
