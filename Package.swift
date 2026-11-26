// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RetouchPro",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "RetouchPro",
            path: "Sources/RetouchPro"
        )
    ]
)
