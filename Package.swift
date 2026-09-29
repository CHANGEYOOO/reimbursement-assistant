// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReimburseApp",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ReimburseApp", targets: ["ReimburseApp"]),
        .executable(name: "ReimburseMacApp", targets: ["ReimburseMacApp"]),
    ],
    targets: [
        .target(name: "ReimburseApp"),
        .executableTarget(name: "ReimburseMacApp", dependencies: ["ReimburseApp"]),
        .testTarget(name: "ReimburseAppTests", dependencies: ["ReimburseApp"]),
    ]
)
