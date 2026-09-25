// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Miroo",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MirooMac", targets: ["MirooMac"]),
        .executable(name: "MirooReceiverCLI", targets: ["MirooReceiverCLI"]),
        .executable(name: "Phase6ATests", targets: ["Phase6ATests"]),
        .executable(name: "Phase6BTests", targets: ["Phase6BTests"]),
        .executable(name: "Phase7Tests", targets: ["Phase7Tests"]),
        .executable(name: "Phase8ATests", targets: ["Phase8ATests"]),
        .executable(name: "Phase8BTests", targets: ["Phase8BTests"]),
        .executable(name: "Phase9Tests", targets: ["Phase9Tests"]),
        .executable(name: "Phase10Tests", targets: ["Phase10Tests"]),
        .executable(name: "Phase11Tests", targets: ["Phase11Tests"]),
        .executable(name: "EdgeToEdgeTests", targets: ["EdgeToEdgeTests"]),
        .executable(name: "Phase12Tests", targets: ["Phase12Tests"]),
        .executable(name: "DisplayArrangementTests", targets: ["DisplayArrangementTests"]),
        .executable(name: "DeviceDiscoveryConnectionTests", targets: ["DeviceDiscoveryConnectionTests"]),
        .executable(name: "Phase13Tests", targets: ["Phase13Tests"])
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
            dependencies: [
                "CGVirtualDisplayBridge"
            ],
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
                "PipelineBenchmark.swift",
                "VideoTransport.swift",
                "H264NALUParser.swift",
                "H264Decoder.swift",
                "MetalRenderer.swift",
                "MirooMetalView.swift",
                "MacInputController.swift",
                "USBMuxClient.swift",
                "AdaptiveStreamingController.swift",
                "ConnectionLifecycle.swift",
                "DisplayArrangementStore.swift",
                "MirooDevice.swift",
                "ConnectionAuthorizer.swift",
                "VirtualDisplayManager.swift",
                "DisplayStreamCapturer.swift",
                "VideoEncoder.swift",
                "MirooDisplaySession.swift"
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
                "Resources",
                "Networking"
            ],
            sources: [
                "App/MirooApprovalWindow.swift",
                "App/MirooEngine.swift",
                "App/MirooSettingsView.swift",
                "App/MirooMenuBarController.swift",
                "App/MirooDashboardView.swift",
                "App/MirooDashboardWindowController.swift",
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
        ),
        .executableTarget(
            name: "Phase6ATests",
            dependencies: [
                "MirooNetworking"
            ],
            path: "Tests",
            exclude: [
                "DisplayArrangementTests.swift",
                "DeviceDiscoveryConnectionTests.swift",
                "DecodeReconnectionTest",
                "IntegrationTest",
                "MovingContentTest.swift",
                "Phase6BTests.swift",
                "Phase7Tests.swift",
                "Phase8ATests.swift",
                "Phase8BTests.swift",
                "Phase9Tests.swift",
                "Phase10Tests.swift",
                "Phase11Tests.swift",
                "Phase13Tests.swift",
                "main.swift",
                "EdgeToEdgeTests.swift",
                "Phase12Tests.swift"
            ],
            sources: [
                "Phase6ATests.swift"
            ]
        ),
        .executableTarget(
            name: "Phase6BTests",
            dependencies: [
                "MirooNetworking"
            ],
            path: "Tests",
            exclude: [
                "DisplayArrangementTests.swift",
                "DeviceDiscoveryConnectionTests.swift",
                "DecodeReconnectionTest",
                "IntegrationTest",
                "MovingContentTest.swift",
                "Phase6ATests.swift",
                "Phase7Tests.swift",
                "Phase8ATests.swift",
                "Phase8BTests.swift",
                "Phase9Tests.swift",
                "Phase10Tests.swift",
                "Phase11Tests.swift",
                "Phase13Tests.swift",
                "main.swift",
                "EdgeToEdgeTests.swift",
                "Phase12Tests.swift"
            ],
            sources: [
                "Phase6BTests.swift"
            ]
        ),
        .executableTarget(
            name: "Phase7Tests",
            dependencies: [
                "MirooNetworking"
            ],
            path: "Tests",
            exclude: [
                "DisplayArrangementTests.swift",
                "DeviceDiscoveryConnectionTests.swift",
                "DecodeReconnectionTest",
                "IntegrationTest",
                "MovingContentTest.swift",
                "Phase6ATests.swift",
                "Phase6BTests.swift",
                "Phase8ATests.swift",
                "Phase8BTests.swift",
                "Phase9Tests.swift",
                "Phase10Tests.swift",
                "Phase11Tests.swift",
                "Phase13Tests.swift",
                "main.swift",
                "EdgeToEdgeTests.swift",
                "Phase12Tests.swift"
            ],
            sources: [
                "Phase7Tests.swift"
            ]
        ),
        .executableTarget(
            name: "Phase8ATests",
            dependencies: [
                "MirooNetworking"
            ],
            path: "Tests",
            exclude: [
                "DisplayArrangementTests.swift",
                "DeviceDiscoveryConnectionTests.swift",
                "DecodeReconnectionTest",
                "IntegrationTest",
                "MovingContentTest.swift",
                "Phase6ATests.swift",
                "Phase6BTests.swift",
                "Phase7Tests.swift",
                "Phase8BTests.swift",
                "Phase9Tests.swift",
                "Phase10Tests.swift",
                "Phase11Tests.swift",
                "Phase13Tests.swift",
                "main.swift",
                "EdgeToEdgeTests.swift",
                "Phase12Tests.swift"
            ],
            sources: [
                "Phase8ATests.swift"
            ]
        ),
        .executableTarget(
            name: "Phase8BTests",
            dependencies: [
                "MirooNetworking"
            ],
            path: "Tests",
            exclude: [
                "DisplayArrangementTests.swift",
                "DeviceDiscoveryConnectionTests.swift",
                "DecodeReconnectionTest",
                "IntegrationTest",
                "MovingContentTest.swift",
                "Phase6ATests.swift",
                "Phase6BTests.swift",
                "Phase7Tests.swift",
                "Phase8ATests.swift",
                "Phase9Tests.swift",
                "Phase10Tests.swift",
                "Phase11Tests.swift",
                "Phase13Tests.swift",
                "main.swift",
                "EdgeToEdgeTests.swift",
                "Phase12Tests.swift"
            ],
            sources: [
                "Phase8BTests.swift"
            ]
        ),
        .executableTarget(
            name: "Phase9Tests",
            dependencies: [
                "MirooNetworking"
            ],
            path: "Tests",
            exclude: [
                "DisplayArrangementTests.swift",
                "DeviceDiscoveryConnectionTests.swift",
                "DecodeReconnectionTest",
                "IntegrationTest",
                "MovingContentTest.swift",
                "Phase6ATests.swift",
                "Phase6BTests.swift",
                "Phase7Tests.swift",
                "Phase8ATests.swift",
                "Phase8BTests.swift",
                "Phase10Tests.swift",
                "Phase11Tests.swift",
                "Phase13Tests.swift",
                "main.swift",
                "EdgeToEdgeTests.swift",
                "Phase12Tests.swift"
            ],
            sources: [
                "Phase9Tests.swift"
            ]
        ),
        .executableTarget(
            name: "Phase10Tests",
            dependencies: [
                "MirooNetworking"
            ],
            path: "Tests",
            exclude: [
                "DisplayArrangementTests.swift",
                "DeviceDiscoveryConnectionTests.swift",
                "DecodeReconnectionTest",
                "IntegrationTest",
                "MovingContentTest.swift",
                "Phase6ATests.swift",
                "Phase6BTests.swift",
                "Phase7Tests.swift",
                "Phase8ATests.swift",
                "Phase8BTests.swift",
                "Phase9Tests.swift",
                "Phase11Tests.swift",
                "Phase13Tests.swift",
                "main.swift",
                "EdgeToEdgeTests.swift",
                "Phase12Tests.swift"
            ],
            sources: [
                "Phase10Tests.swift"
            ]
        ),
        .executableTarget(
            name: "Phase11Tests",
            dependencies: [
                "MirooNetworking"
            ],
            path: "Tests",
            exclude: [
                "DisplayArrangementTests.swift",
                "DeviceDiscoveryConnectionTests.swift",
                "DecodeReconnectionTest",
                "IntegrationTest",
                "MovingContentTest.swift",
                "Phase6ATests.swift",
                "Phase6BTests.swift",
                "Phase7Tests.swift",
                "Phase8ATests.swift",
                "Phase8BTests.swift",
                "Phase9Tests.swift",
                "Phase10Tests.swift",
                "Phase13Tests.swift",
                "main.swift",
                "EdgeToEdgeTests.swift",
                "Phase12Tests.swift"
            ],
            sources: [
                "Phase11Tests.swift"
            ]
        ),
        .executableTarget(
            name: "EdgeToEdgeTests",
            dependencies: [
                "MirooNetworking"
            ],
            path: "Tests",
            exclude: [
                "DisplayArrangementTests.swift",
                "DeviceDiscoveryConnectionTests.swift",
                "DecodeReconnectionTest",
                "IntegrationTest",
                "MovingContentTest.swift",
                "Phase6ATests.swift",
                "Phase6BTests.swift",
                "Phase7Tests.swift",
                "Phase8ATests.swift",
                "Phase8BTests.swift",
                "Phase9Tests.swift",
                "Phase10Tests.swift",
                "Phase11Tests.swift",
                "Phase12Tests.swift",
                "Phase13Tests.swift",
                "main.swift"
            ],
            sources: [
                "EdgeToEdgeTests.swift"
            ]
        ),
        .executableTarget(
            name: "Phase12Tests",
            dependencies: [
                "MirooNetworking"
            ],
            path: "Tests",
            exclude: [
                "DecodeReconnectionTest",
                "IntegrationTest",
                "MovingContentTest.swift",
                "Phase6ATests.swift",
                "Phase6BTests.swift",
                "Phase7Tests.swift",
                "Phase8ATests.swift",
                "Phase8BTests.swift",
                "Phase9Tests.swift",
                "Phase10Tests.swift",
                "Phase11Tests.swift",
                "EdgeToEdgeTests.swift",
                "DisplayArrangementTests.swift",
                "DeviceDiscoveryConnectionTests.swift",
                "Phase13Tests.swift",
                "main.swift"
            ],
            sources: [
                "Phase12Tests.swift"
            ]
        ),
        .executableTarget(
            name: "DisplayArrangementTests",
            dependencies: [
                "MirooNetworking"
            ],
            path: "Tests",
            exclude: [
                "DecodeReconnectionTest",
                "IntegrationTest",
                "MovingContentTest.swift",
                "Phase6ATests.swift",
                "Phase6BTests.swift",
                "Phase7Tests.swift",
                "Phase8ATests.swift",
                "Phase8BTests.swift",
                "Phase9Tests.swift",
                "Phase10Tests.swift",
                "Phase11Tests.swift",
                "EdgeToEdgeTests.swift",
                "Phase12Tests.swift",
                "DeviceDiscoveryConnectionTests.swift",
                "Phase13Tests.swift",
                "main.swift"
            ],
            sources: [
                "DisplayArrangementTests.swift"
            ]
        ),
        .executableTarget(
            name: "DeviceDiscoveryConnectionTests",
            dependencies: [
                "MirooNetworking"
            ],
            path: "Tests",
            exclude: [
                "DecodeReconnectionTest",
                "IntegrationTest",
                "MovingContentTest.swift",
                "Phase6ATests.swift",
                "Phase6BTests.swift",
                "Phase7Tests.swift",
                "Phase8ATests.swift",
                "Phase8BTests.swift",
                "Phase9Tests.swift",
                "Phase10Tests.swift",
                "Phase11Tests.swift",
                "EdgeToEdgeTests.swift",
                "Phase12Tests.swift",
                "DisplayArrangementTests.swift",
                "Phase13Tests.swift",
                "main.swift"
            ],
            sources: [
                "DeviceDiscoveryConnectionTests.swift"
            ]
        ),
        .executableTarget(
            name: "Phase13Tests",
            dependencies: [
                "CGVirtualDisplayBridge",
                "MirooNetworking"
            ],
            path: "Tests",
            exclude: [
                "DecodeReconnectionTest",
                "IntegrationTest",
                "MovingContentTest.swift",
                "Phase6ATests.swift",
                "Phase6BTests.swift",
                "Phase7Tests.swift",
                "Phase8ATests.swift",
                "Phase8BTests.swift",
                "Phase9Tests.swift",
                "Phase10Tests.swift",
                "Phase11Tests.swift",
                "EdgeToEdgeTests.swift",
                "Phase12Tests.swift",
                "DisplayArrangementTests.swift",
                "DeviceDiscoveryConnectionTests.swift",
                "main.swift"
            ],
            sources: [
                "Phase13Tests.swift"
            ]
        )
    ]
)
