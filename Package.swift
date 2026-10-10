// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MirooLink",
    platforms: [.macOS(.v14), .iOS(.v16)],
    products: [
        .library(name: "MirooCore", targets: ["MirooCore"]),
        .library(name: "MirooMedia", targets: ["MirooMedia"]),
        .library(name: "MirooNet", targets: ["MirooNet"]),
        .library(name: "MirooSession", targets: ["MirooSession"]),
        .executable(name: "miroo-selftest", targets: ["miroo-selftest"]),
        .executable(name: "miroo-host", targets: ["miroo-host"]),
        .executable(name: "MirooApp", targets: ["MirooApp"]),
    ],
    targets: [
        .target(name: "MirooCore", path: "Sources/MirooCore"),
        .target(name: "MirooNet", dependencies: ["MirooCore"], path: "Sources/MirooNet"),
        .target(name: "MirooSession", dependencies: ["MirooCore", "MirooMedia", "MirooNet"], path: "Sources/MirooSession"),
        .target(name: "MirooTestKit", dependencies: ["MirooCore"], path: "Sources/MirooTestKit"),
        .executableTarget(name: "miroo-selftest", dependencies: ["MirooCore", "MirooMedia", "MirooNet", "MirooSession", "MirooTestKit"], path: "Sources/miroo-selftest"),
        .target(name: "CGVirtualDisplayBridge", path: "Sources/CGVirtualDisplayBridge", publicHeadersPath: "."),
        .target(name: "MirooHost", dependencies: ["MirooCore", "MirooMedia", "MirooNet", "MirooSession", "CGVirtualDisplayBridge"], path: "Sources/MirooHost"),
        .executableTarget(name: "miroo-host", dependencies: ["MirooCore", "MirooMedia", "MirooNet", "MirooSession", "MirooHost", "CGVirtualDisplayBridge"], path: "Sources/miroo-host"),
        .executableTarget(name: "MirooApp", dependencies: ["MirooCore", "MirooNet", "MirooSession", "MirooHost"], path: "Sources/MirooApp"),
        .target(name: "MirooMedia", dependencies: ["MirooCore"], path: "Sources/MirooMedia"),
        .testTarget(name: "MirooMediaTests", dependencies: ["MirooMedia", "MirooCore"], path: "Tests/MirooMediaTests"),
        .testTarget(name: "MirooNetTests", dependencies: ["MirooNet", "MirooCore"], path: "Tests/MirooNetTests"),
        .testTarget(name: "MirooCoreTests", dependencies: ["MirooCore"], path: "Tests/MirooCoreTests"),
    ]
)
