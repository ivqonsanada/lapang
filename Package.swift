// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Lapang",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Lapang", targets: ["Lapang"]),
        .library(name: "LapangCore", targets: ["LapangCore"]),
    ],
    targets: [
        // Everything that is not a view: free space, the folder scanner, the
        // rules, the deleter and the command runner. Every path is injectable,
        // so the tests run on temp folders and never on the real home folder.
        .target(name: "LapangCore"),
        // The window (SwiftUI).
        .executableTarget(name: "Lapang", dependencies: ["LapangCore"]),
        .testTarget(name: "LapangCoreTests", dependencies: ["LapangCore"]),
    ]
)
