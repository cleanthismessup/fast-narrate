// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "FastNarrate",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "FastNarrate",
            path: "Sources/FastNarrate",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("NaturalLanguage"),
                .linkedFramework("Carbon"),
            ]
        ),
    ]
)
