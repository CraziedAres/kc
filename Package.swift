// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "kc",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "kc", targets: ["kc"]),
        .library(name: "KeychainKit", targets: ["KeychainKit"]),
    ],
    targets: [
        .target(name: "KeychainKit"),
        .executableTarget(name: "kc", dependencies: ["KeychainKit"]),
    ]
)
