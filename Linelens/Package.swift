// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Linelens",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Linelens",
            path: "Sources/Linelens"
        )
    ]
)
