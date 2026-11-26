// swift-tools-version: 6.0
// Only for testing the code both apps share: `swift test`. The apps themselves are built by Clapless.xcodeproj.
import PackageDescription

let package = Package(
    name: "ClaplessKit",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "ClaplessKit", path: "Shared", exclude: ["Brand.swift"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "SharedTests", dependencies: ["ClaplessKit"], path: "Tests/SharedTests",
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
