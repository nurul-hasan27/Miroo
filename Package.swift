// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Miroo",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MirooMac", targets: ["MirooMac"]),
        .executable(name: "MirooReceiverCLI", targets: ["MirooReceiverCLI"])
    ],
    targets: [
        .target(
            name: "CGVirtualDisplayBridge",
            path: "MirooMac/VirtualDisplay",
            sources: ["CGVirtualDisplayBridge.m"],
            publicHeadersPath: "."
        ),
        .target(
            name: "MirooNetworking",
            path: "MirooMac/Networking",
            sources: [
                "MirooProtocol.swift",
                "FrameQueue.swift",
                "MirooConnection.swift",
                "NetworkMetrics.swift",
                "MirooServer.swift",
                "MirooBrowser.swift",
                "MirooReceiver.swift",
                "VideoFrame.swift",
                "H264NALUParser.swift",
                "H264Decoder.swift",
                "MetalRenderer.swift",
                "MirooMetalView.swift"
            ]
        ),
        .executableTarget(
            name: "MirooMac",
            dependencies: [
                "CGVirtualDisplayBridge",
                "MirooNetworking"
            ],
            path: "MirooMac",
            exclude: [
                "VirtualDisplay/CGVirtualDisplayBridge.m",
                "App/MirooMac-Bridging-Header.h",
                "Resources/Info.plist",
                "Networking"
            ],
            sources: [
                "VirtualDisplay/VirtualDisplayManager.swift",
                "Capture/DisplayStreamCapturer.swift",
                "Encoder/VideoEncoder.swift",
                "App/MirooMacApp.swift"
            ]
        ),
        .executableTarget(
            name: "MirooReceiverCLI",
            dependencies: [
                "MirooNetworking"
            ],
            path: "MirooReceiverCLI",
            sources: [
                "main.swift"
            ]
        )
    ]
)
