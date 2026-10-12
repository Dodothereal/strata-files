// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Strata",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Strata",
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
