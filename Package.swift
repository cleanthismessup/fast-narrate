// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Narrate",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Narrate",
            path: "Sources/Narrate",
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
