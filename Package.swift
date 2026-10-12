// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Strata",
    platforms: [.macOS(.v26)],
    dependencies: [
        // Updates (Check for Updates…, automatic checks), pinned to a release and verified by its checksum.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "Strata",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Strata",
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("NetFS"),
                .linkedFramework("Quartz"),
                .linkedFramework("QuickLookThumbnailing"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),
        .executableTarget(
            name: "StrataCLI",
            path: "Sources/StrataCLI",
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .testTarget(
            name: "StrataTests",
            dependencies: ["Strata"],
            path: "Tests/StrataTests",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
    ]
)
