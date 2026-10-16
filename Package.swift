// swift-tools-version: 6.2
import PackageDescription

// Swift 6.3's hop-to-executor optimization drops the hop back to the caller's actor at the end of some nonisolated async
// functions (with NonisolatedNonsendingByDefault they run on their caller's actor, and must return there): code on the
// main actor that awaited one then carries on off it, and crashes (Refresh in a container's folder, after
// `LazyCopies.invalidate`). The pass is off with those compilers; the hops it would save cost nothing measurable.
#if compiler(>=6.3)
let compilerWorkarounds: [SwiftSetting] = [.unsafeFlags(["-Xllvm", "-sil-disable-pass=optimize-hop-to-executor"])]
#else
let compilerWorkarounds: [SwiftSetting] = []
#endif

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
            ] + compilerWorkarounds,
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
