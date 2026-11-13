// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "lepak",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "LepakKit",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(name: "probe"),
        .executableTarget(
            name: "menubar",
            dependencies: ["LepakKit"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("IOKit"),
            ]
        ),
    ]
)
