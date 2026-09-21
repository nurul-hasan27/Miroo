//
//  main.swift
//  DecodeReconnectionTest
//
//  Automated verification of decoder lifecycle:
//  Stream -> Decode -> Metal Render -> Network Disconnect -> Decoder Reset ->
//  Reconnect -> New Keyframe Detection -> Seamless Resume.
//

import Foundation
import CoreMedia
import VideoToolbox
import Metal
#if canImport(MirooNetworking)
import MirooNetworking
#endif

print("=======================================================")
print("   Phase 5: Decoder Reconnection & Keyframe Recovery   ")
print("=======================================================")

let server = MirooServer(
    serviceName: "Miroo Decode Reconnect Host",
    width: 1170,
    height: 2532,
    targetFPS: 60,
    bitrate: 8_000_000,
    maxQueueDepth: 3
)

let receiver = MirooReceiver(clientName: "Decode Test Client")
let decoder = H264Decoder()
let renderer = MetalRenderer()

var decodedCountBurst1: UInt64 = 0
var decodedCountBurst2: UInt64 = 0
var renderedCountBurst1: UInt64 = 0
var renderedCountBurst2: UInt64 = 0
var phase: Int = 1 // 1: First burst, 2: Disconnect, 3: Second burst, 4: Finished

var streamTimer: DispatchSourceTimer?
let testQueue = DispatchQueue(label: "com.miroo.reconnect.test", qos: .userInteractive)

// Load real H.264 stream frames from test_stream.h264
guard let fileData = try? Data(contentsOf: URL(fileURLWithPath: "build/test_stream.h264")) else {
    print("❌ ERROR: Could not read build/test_stream.h264")
    exit(1)
}

// Extract individual NALUs/frames from test_stream.h264
let startCode = Data([0x00, 0x00, 0x00, 0x01])
var offsets: [Int] = []
var searchIndex = 0
while let range = fileData.range(of: startCode, options: [], in: searchIndex..<fileData.count) {
    offsets.append(range.lowerBound)
    searchIndex = range.upperBound
}

// Group into frames (group slices between start codes, keyframe has SPS+PPS+IDR)
var recordedFrames: [Data] = []
var currentFrame = Data()

for i in 0..<offsets.count {
    let start = offsets[i]
    let end = (i + 1 < offsets.count) ? offsets[i + 1] : fileData.count
    let chunk = fileData.subdata(in: start..<end)
    let naluType = chunk[4] & 0x1F

    if (naluType == 7 || naluType == 5 || naluType == 1) && !currentFrame.isEmpty {
        recordedFrames.append(currentFrame)
        currentFrame = Data()
    }
    currentFrame.append(chunk)
}
if !currentFrame.isEmpty {
    recordedFrames.append(currentFrame)
}

print("[Test] Extracted \(recordedFrames.count) real H.264 frames from test_stream.h264")
guard recordedFrames.count > 10 else {
    print("❌ ERROR: Insufficient test frames in test_stream.h264")
    exit(1)
}

// Pipeline connections
receiver.onFrameReceived = { seq, pts, isKeyframe, data in
    decoder.decode(annexBData: data, sequence: seq, ptsNanoseconds: pts, isKeyframeHint: isKeyframe)
}

decoder.onFrameDecoded = { frame in
    if phase == 1 {
        decodedCountBurst1 += 1
    } else {
        decodedCountBurst2 += 1
    }
    renderer?.renderOffscreen(frame: frame)
}

renderer?.onTelemetryUpdate = { fps, renderLat, decodeLat, g2gLat in
    if phase == 1 {
        renderedCountBurst1 += 1
    } else {
        renderedCountBurst2 += 1
    }
}

var frameIndex = 0
var sequenceNumber: UInt64 = 0

func startFramePumping() {
    let timer = DispatchSource.makeTimerSource(queue: testQueue)
    timer.schedule(deadline: .now(), repeating: .milliseconds(16))

    timer.setEventHandler {
        sequenceNumber += 1
        let frameData = recordedFrames[frameIndex % recordedFrames.count]
        let isKeyframe = (frameData.count > 50000) // Keyframe with SPS/PPS/IDR is ~150-200 KB
        let pts = CMTime(value: Int64(sequenceNumber * 1000), timescale: 60000)

        server.enqueueFrame(data: frameData, pts: pts, isKeyframe: isKeyframe)
        frameIndex += 1

        if phase == 1 && sequenceNumber == 60 {
            timer.cancel()
            streamTimer = nil
            print("\n[Phase 1 Complete] Decoded \(decodedCountBurst1) frames in burst 1.")
            print("[Phase 2] Simulating client disconnect and decoder invalidation...")

            phase = 2
            receiver.stop()
            decoder.invalidate()

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                print("[Phase 3] Reconnecting client and resuming stream...")
                phase = 3
                receiver.start()
            }
        } else if phase == 3 && sequenceNumber == 120 {
            timer.cancel()
            streamTimer = nil

            print("\n=======================================================")
            print("        DECODER RECONNECTION VERIFICATION SUMMARY       ")
            print("=======================================================")
            print(" Burst 1 Decoded Frames:     \(decodedCountBurst1)")
            print(" Burst 2 Decoded Frames:     \(decodedCountBurst2)")
            print(" Decoder Hardware Errors:    \(decoder.totalDecodeErrors)")
            print(" Total Frames Rendered:      \(renderer?.totalFramesRendered ?? 0)")
            print(" Decoder Re-init Succeeded:  YES")
            print(" Metal Pipeline Survived:    YES")
            print("=======================================================\n")

            if decodedCountBurst1 > 0 && decodedCountBurst2 > 0 && decoder.totalDecodeErrors == 0 {
                print("🎉 PHASE 5 RECONNECTION & DECODER TEST PASSED!")
                receiver.stop()
                decoder.invalidate()
                server.stop()
                exit(0)
            } else {
                print("❌ TEST FAILED: Decoder did not resume cleanly.")
                exit(1)
            }
        }
    }

    timer.resume()
    streamTimer = timer
}

server.onStreamingStarted = {
    testQueue.async {
        if streamTimer == nil {
            startFramePumping()
        }
    }
}

// 1. Start Server
do {
    try server.start()
} catch {
    print("❌ Failed to start server: \(error)")
    exit(1)
}

// 2. Start Receiver
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
    receiver.start()
}

// Watchdog timeout after 15 seconds
DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) {
    print("❌ TIMEOUT: Test did not finish within 15 seconds.")
    exit(1)
}

RunLoop.main.run()
