// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CommanderCore",
    platforms: [.macOS(.v26)],
    products: [.library(name: "CommanderCore", targets: ["CommanderCore"])],
    targets: [
        .systemLibrary(name: "CArchive"),
        .target(name: "CommanderCore", dependencies: ["CArchive"]),
        .testTarget(name: "CommanderCoreTests", dependencies: ["CommanderCore", "CArchive"]),
    ]
)
