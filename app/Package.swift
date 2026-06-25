// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "WeChatMulti",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "WeChatMulti",
            path: "Sources/WeChatMulti"
        )
    ],
    swiftLanguageModes: [.v5]
)
