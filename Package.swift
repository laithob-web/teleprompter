// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Teleprompter",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Teleprompter",
            path: "Sources/Teleprompter",
            swiftSettings: [
                // AppKit delegate/view code is not Sendable-clean; Swift 5 mode keeps
                // strict-concurrency out of the way without changing runtime behavior.
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
