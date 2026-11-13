// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "FastNarrate",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic (layout, timing, captions, re-anchoring). No AppKit, fully unit-tested.
        .target(name: "FastNarrateCore"),
        // The menu-bar app.
        .executableTarget(
            name: "FastNarrate",
            dependencies: ["FastNarrateCore"],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision"),
            ]
        ),
        .testTarget(name: "FastNarrateCoreTests", dependencies: ["FastNarrateCore"]),
    ]
)
