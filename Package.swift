// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ImageCompressor",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ImageCompressor",
            path: "Sources/ImageCompressor"
        )
    ]
)
