#!/bin/bash
set -e

# Change to the Miroo root directory
cd "$(dirname "$0")/.."

echo "=== Building MirooMac Phase 4 (Display + Capture + H.264 + Network.framework) ==="
mkdir -p build

echo "[1/3] Compiling Objective-C bridge (CGVirtualDisplayBridge.m)..."
clang -fobjc-arc -c MirooMac/VirtualDisplay/CGVirtualDisplayBridge.m -o build/CGVirtualDisplayBridge.o

echo "[2/3] Compiling MirooMac executable..."
swiftc \
    -import-objc-header MirooMac/App/MirooMac-Bridging-Header.h \
    build/CGVirtualDisplayBridge.o \
    MirooMac/VirtualDisplay/VirtualDisplayManager.swift \
    MirooMac/Capture/DisplayStreamCapturer.swift \
    MirooMac/Encoder/VideoEncoder.swift \
    MirooMac/Networking/MirooProtocol.swift \
    MirooMac/Networking/FrameQueue.swift \
    MirooMac/Networking/MirooConnection.swift \
    MirooMac/Networking/NetworkMetrics.swift \
    MirooMac/Networking/MirooServer.swift \
    MirooMac/App/MirooMacApp.swift \
    -framework Cocoa \
    -framework CoreGraphics \
    -framework ScreenCaptureKit \
    -framework CoreMedia \
    -framework CoreVideo \
    -framework VideoToolbox \
    -framework Network \
    -framework QuartzCore \
    -o build/MirooMac

echo "[3/3] Compiling MirooReceiverCLI test tool..."
swiftc \
    MirooMac/Networking/MirooProtocol.swift \
    MirooMac/Networking/FrameQueue.swift \
    MirooMac/Networking/MirooConnection.swift \
    MirooMac/Networking/NetworkMetrics.swift \
    MirooMac/Networking/MirooBrowser.swift \
    MirooMac/Networking/MirooReceiver.swift \
    MirooMac/Networking/VideoFrame.swift \
    MirooMac/Networking/H264NALUParser.swift \
    MirooMac/Networking/H264Decoder.swift \
    MirooMac/Networking/MetalRenderer.swift \
    MirooMac/Networking/MirooMetalView.swift \
    MirooReceiverCLI/main.swift \
    -framework Foundation \
    -framework Network \
    -framework QuartzCore \
    -framework VideoToolbox \
    -framework CoreMedia \
    -framework CoreVideo \
    -framework Metal \
    -framework MetalKit \
    -framework AppKit \
    -o build/MirooReceiverCLI

echo "=== Build Complete ==="
echo "Artifacts produced:"
echo "  - build/MirooMac (macOS server with virtual display, SCK, encoder, Bonjour/TCP server)"
echo "  - build/MirooReceiverCLI (receiver client that discovers, handshakes, and receives live frames)"
echo ""
echo "To run MirooMac:"
echo "  ./build/MirooMac"
echo ""
echo "To run receiver in a separate terminal:"
echo "  ./build/MirooReceiverCLI"
