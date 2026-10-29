// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Pauta",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Pauta",
            path: "Sources/Pauta",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
