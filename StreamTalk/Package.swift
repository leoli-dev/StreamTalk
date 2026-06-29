// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StreamTalk",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "StreamTalk",
            path: "Sources/StreamTalk",
            swiftSettings: [
                // Pragmatic: AVAudioEngine/Speech callbacks fight strict
                // Swift-6 data-race checking; v5 mode keeps this tractable.
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
