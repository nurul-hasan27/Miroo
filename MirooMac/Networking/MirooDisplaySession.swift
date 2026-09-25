//
//  MirooDisplaySession.swift
//  MirooNetworking
//
//  Phase 13: Dedicated Multi-Device Display Session Architecture.
//  Each session independently manages:
//  - Persistent device identity and arrangement
//  - Dedicated virtual display allocation (CGDirectDisplayID)
//  - Hardware video encoder and ScreenCaptureKit pipeline
//  - Transport negotiation and runtime dynamic transport switching (USB / UDP / TCP)
//  - Display-targeted touch and trackpad input injection
//  - Real-time pipeline latency and quality telemetry
//

import Foundation
import CoreGraphics
import CoreMedia
import VideoToolbox
import ScreenCaptureKit
import Combine
import Network

public enum DisplaySessionState: String, Codable, Sendable {
    case connecting
    case active
    case paused
    case disconnected
    case failed
}

@MainActor
public final class MirooDisplaySession: ObservableObject, Identifiable {

    // MARK: - Identity
    public nonisolated var id: String { sessionID }
    public let sessionID: String
    public let device: MirooDevice

    // MARK: - State & Telemetry
    @Published public private(set) var state: DisplaySessionState = .connecting
    @Published public private(set) var currentTransportType: VideoTransportType = .tcp
    @Published public private(set) var activeTransportName: String = "TCP"
    @Published public private(set) var currentOrientation: MirooOrientation = .portrait
    @Published public private(set) var isPaused: Bool = false

    // Live Metrics
    @Published public private(set) var currentFPS: Double = 0.0
    @Published public private(set) var currentBitrateMbps: Double = 0.0
    @Published public private(set) var currentLatencyMs: Double = 0.0
    @Published public private(set) var rttMs: Double = 0.0
    @Published public private(set) var displayWidth: Int
    @Published public private(set) var displayHeight: Int

    // MARK: - Pipeline Components
    public private(set) var displayManager: VirtualDisplayManager?
    public private(set) var capturer: DisplayStreamCapturer?
    public private(set) var encoder: VideoEncoder?
    public private(set) var connection: MirooConnection?
    public private(set) var videoTransport: (any VideoSenderTransport)?
    public let frameQueue: FrameQueue
    public let inputController: MacInputController
    public let adaptiveController = AdaptiveStreamingController()

    // Internal timing & metrics
    private var sequenceCounter: UInt64 = 0
    private var isSending: Bool = false
    private var telemetryTimer: Timer?
    private var targetFPS: Int
    private var targetBitrateMbps: Int
    private var isSwitchingTransport: Bool = false
    private var lastTelemetryFramesSent: UInt64 = 0
    private var lastTelemetryBytesSent: UInt64 = 0
    private var lastTelemetryTime: CFTimeInterval = 0

    // Callbacks
    public var onSessionTerminated: ((_ sessionID: String, _ reason: SessionEndReason) -> Void)?

    public init(
        device: MirooDevice,
        sessionID: String = UUID().uuidString,
        width: Int = Int(VirtualDisplayManager.physicalWidth),
        height: Int = Int(VirtualDisplayManager.physicalHeight),
        targetFPS: Int = 60,
        targetBitrateMbps: Int = 8,
        preferredTransport: VideoTransportType = .tcp
    ) {
        self.device = device
        self.sessionID = sessionID
        self.displayWidth = width
        self.displayHeight = height
        self.targetFPS = targetFPS
        self.targetBitrateMbps = targetBitrateMbps
        self.currentTransportType = preferredTransport
        self.activeTransportName = preferredTransport.rawValue
        self.frameQueue = FrameQueue(maxDepth: 1)
        self.inputController = MacInputController()
    }

    deinit {
        telemetryTimer?.invalidate()
    }

    // MARK: - Session Lifecycle

    /// Starts the independent virtual display, hardware encoder, capturer, and transport.
    public func start(
        connection: MirooConnection,
        negotiatedTransport: VideoTransportType = .tcp,
        udpPort: UInt16 = 51042,
        udpSessionToken: UInt32 = 0
    ) async throws {
        self.connection = connection
        self.currentTransportType = negotiatedTransport
        self.activeTransportName = negotiatedTransport.rawValue
        self.state = .connecting

        // 1. Allocate dedicated virtual display
        let manager = VirtualDisplayManager()
        self.displayManager = manager

        let displayName = "Miroo - \(device.displayName)"
        guard manager.create(deviceID: device.id, displayName: displayName) else {
            self.state = .failed
            throw CapturerError.captureFailed("Failed to create virtual display for \(device.displayName)")
        }

        self.displayWidth = (manager.currentOrientation == .landscape) ? Int(VirtualDisplayManager.physicalHeight) : Int(VirtualDisplayManager.physicalWidth)
        self.displayHeight = (manager.currentOrientation == .landscape) ? Int(VirtualDisplayManager.physicalWidth) : Int(VirtualDisplayManager.physicalHeight)
        self.currentOrientation = manager.currentOrientation

        PipelineLogger.log(.virtualDisplay, "Allocated virtual display ID \(manager.displayID), bounds: \(displayWidth)x\(displayHeight)", force: true)

        // 2. Hardware Video Encoder
        let enc = VideoEncoder(
            width: Int32(displayWidth),
            height: Int32(displayHeight),
            targetFPS: Int32(targetFPS),
            averageBitrate: Int32(targetBitrateMbps * 1_000_000),
            keyframeInterval: 180
        )
        self.encoder = enc
        try enc.setup()
        PipelineLogger.log(.videoEncoder, "VideoToolbox hardware encoder initialized (\(displayWidth)x\(displayHeight) @ \(targetFPS) FPS, \(targetBitrateMbps) Mbps)", force: true)

        enc.onEncodedFrame = { [weak self] data, pts, isKeyframe, captureNs, encStartNs, encCompNs, encodeDurationUs in
            guard let self = self, !self.isPaused else { return }
            self.enqueueFrame(
                data: data,
                pts: pts,
                isKeyframe: isKeyframe,
                captureTimestampNs: captureNs,
                encodeStartNs: encStartNs,
                encodeCompleteNs: encCompNs,
                encodeDurationUs: encodeDurationUs
            )
        }

        // 3. ScreenCaptureKit Capturer
        let cap = DisplayStreamCapturer()
        self.capturer = cap

        cap.onFrameCaptured = { [weak self] pixelBuffer, presentationTime, captureTimestampNs in
            guard let self = self, !self.isPaused else { return }
            let forceKey = self.frameQueue.needsImmediateKeyframe
            self.encoder?.encode(
                pixelBuffer: pixelBuffer,
                presentationTime: presentationTime,
                captureTimestampNs: captureTimestampNs,
                forceKeyframe: forceKey
            )
        }

        try await cap.startCapture(
            displayID: manager.displayID,
            displayName: displayName,
            targetWidth: displayWidth,
            targetHeight: displayHeight,
            targetFPS: targetFPS
        )
        PipelineLogger.log(.displayCapture, "ScreenCaptureKit capturing display \(manager.displayID) [\(displayName)]", force: true)

        // 4. Configure Video Transport
        setupVideoTransport(type: negotiatedTransport, connection: connection, udpPort: udpPort, sessionToken: udpSessionToken)

        // 5. Wire connection event handlers
        setupConnectionHandlers(connection)

        self.state = .active
        startTelemetryMonitoring()
        print("[MirooDisplaySession] Session started for device '\(device.displayName)' [ID: \(device.id), Display: \(manager.displayID)] over \(activeTransportName)")
        PipelineLogger.log(.transport, "Display session active for '\(device.displayName)' over \(activeTransportName)", force: true)
    }

    /// Stops this display session cleanly, tears down its virtual display, and releases capturer/encoder.
    public func stop(reason: SessionEndReason = .userDisconnected) {
        guard state != .disconnected else { return }
        print("[MirooDisplaySession] Stopping display session '\(sessionID)' for '\(device.displayName)' (Reason: \(reason.rawValue))...")

        state = .disconnected
        telemetryTimer?.invalidate()
        telemetryTimer = nil

        // Notify client
        if let conn = connection, conn.state == .streaming || conn.state == .connected {
            conn.send(message: .sessionEnded(SessionEndedPayload(sessionID: sessionID, reason: reason)))
        }

        // Stop capture and encode
        capturer?.stopCaptureSync()
        capturer = nil

        encoder?.invalidate()
        encoder = nil

        // Tear down transport
        videoTransport?.stop()
        videoTransport = nil

        // Destroy virtual display and persist arrangement
        displayManager?.destroy()
        displayManager = nil

        connection?.disconnect()
        connection = nil

        frameQueue.clear()
        isSending = false

        onSessionTerminated?(sessionID, reason)
    }

    // MARK: - Dynamic Transport Switching (Part 12)

    /// Dynamically switches the active video transport (e.g. USB -> UDP or UDP -> TCP)
    /// WITHOUT tearing down or recreating the virtual display!
    public func switchTransport(to newTransport: VideoTransportType, udpPort: UInt16 = 51042, sessionToken: UInt32 = 0) {
        guard newTransport != currentTransportType else { return }
        guard !isSwitchingTransport else { return }

        print("[MirooDisplaySession] Switching transport from \(currentTransportType.rawValue) to \(newTransport.rawValue)...")
        isSwitchingTransport = true
        defer { isSwitchingTransport = false }

        // 1. Tell client to reconfigure transport if connected
        if let conn = connection {
            let targetHost = "127.0.0.1"
            conn.send(message: .setTransport(transport: newTransport.rawValue, udpPort: udpPort, sessionToken: sessionToken, serverHost: targetHost))

            // 2. Tear down current transport
            videoTransport?.stop()
            videoTransport = nil

            // 3. Setup new transport
            setupVideoTransport(type: newTransport, connection: conn, udpPort: udpPort, sessionToken: sessionToken)
        }

        self.currentTransportType = newTransport
        self.activeTransportName = newTransport.rawValue

        // 4. Request immediate keyframe to recover decode stream
        requestKeyframe()
    }

    private func setupVideoTransport(
        type: VideoTransportType,
        connection: MirooConnection,
        udpPort: UInt16,
        sessionToken: UInt32
    ) {
        switch type {
        case .usb:
            let usb = USBVideoSenderTransport(connection: connection)
            self.videoTransport = usb
            usb.start()

        case .udp:
            let udp = UDPVideoSenderTransport(port: udpPort, sessionToken: sessionToken)
            self.videoTransport = udp
            udp.start()

        case .tcp:
            let tcp = TCPVideoSenderTransport(connection: connection)
            self.videoTransport = tcp
            tcp.start()
        }
    }

    // MARK: - Orientation & Control Controls

    public func switchOrientation(to newOrientation: MirooOrientation) async {
        guard newOrientation != currentOrientation else { return }
        guard let mgr = displayManager else { return }

        print("[MirooDisplaySession] Switching orientation to \(newOrientation.rawValue)...")
        mgr.setOrientation(newOrientation)
        self.currentOrientation = newOrientation

        let newW = (newOrientation == .landscape) ? Int(VirtualDisplayManager.physicalHeight) : Int(VirtualDisplayManager.physicalWidth)
        let newH = (newOrientation == .landscape) ? Int(VirtualDisplayManager.physicalWidth) : Int(VirtualDisplayManager.physicalHeight)
        self.displayWidth = newW
        self.displayHeight = newH

        // Reconfigure encoder
        encoder?.invalidate()
        let enc = VideoEncoder(
            width: Int32(newW),
            height: Int32(newH),
            targetFPS: Int32(targetFPS),
            averageBitrate: Int32(targetBitrateMbps * 1_000_000),
            keyframeInterval: 180
        )
        self.encoder = enc
        try? enc.setup()

        enc.onEncodedFrame = { [weak self] data, pts, isKeyframe, captureNs, encStartNs, encCompNs, encodeDurationUs in
            guard let self = self, !self.isPaused else { return }
            self.enqueueFrame(
                data: data,
                pts: pts,
                isKeyframe: isKeyframe,
                captureTimestampNs: captureNs,
                encodeStartNs: encStartNs,
                encodeCompleteNs: encCompNs,
                encodeDurationUs: encodeDurationUs
            )
        }

        // Restart capture
        await capturer?.stopCapture()
        try? await capturer?.startCapture(
            displayID: mgr.displayID,
            displayName: "Miroo - \(device.displayName)",
            targetWidth: newW,
            targetHeight: newH,
            targetFPS: targetFPS
        )

        // Notify client
        let streamMsg = MirooMessage.streamConfig(
            codec: "H264",
            width: newW,
            height: newH,
            fps: targetFPS,
            bitrate: targetBitrateMbps * 1_000_000,
            orientation: newOrientation,
            transport: currentTransportType.rawValue
        )
        connection?.send(message: streamMsg)
        requestKeyframe()
    }

    public func requestKeyframe() {
        encoder?.requestKeyframe()
    }

    public func togglePause() {
        isPaused.toggle()
        state = isPaused ? .paused : .active
    }

    // MARK: - Input Forwarding

    public func handleTouchEvent(_ payload: TouchEventPayload) {
        guard let mgr = displayManager, mgr.displayID != 0 else { return }
        inputController.handleTouchEvent(payload, displayID: mgr.displayID)
    }

    public func handleScrollEvent(_ payload: ScrollEventPayload) {
        inputController.scroll(deltaX: payload.deltaX, deltaY: payload.deltaY)
    }

    public func handleRightClick(_ payload: RightClickPayload) {
        inputController.rightClick()
    }

    // MARK: - Frame Pump & Ingestion

    private func enqueueFrame(
        data: Data,
        pts: CMTime,
        isKeyframe: Bool,
        captureTimestampNs: UInt64,
        encodeStartNs: UInt64,
        encodeCompleteNs: UInt64,
        encodeDurationUs: UInt32
    ) {
        sequenceCounter &+= 1
        let seq = sequenceCounter

        let ptsNanoseconds: Int64
        if pts.timescale > 0 {
            ptsNanoseconds = Int64(Double(pts.value) / Double(pts.timescale) * 1_000_000_000.0)
        } else {
            ptsNanoseconds = Int64(captureTimestampNs)
        }

        let frame = QueuedFrame(
            sequence: seq,
            pts: ptsNanoseconds,
            isKeyframe: isKeyframe,
            data: data,
            encodeDurationUs: encodeDurationUs,
            captureTimestampNs: captureTimestampNs,
            encodeStartTimestampNs: encodeStartNs,
            encodeCompleteTimestampNs: encodeCompleteNs
        )

        let accepted = frameQueue.enqueue(frame)
        if !accepted {
            encoder?.requestKeyframe()
        }

        pumpFrameQueue()
    }

    private func pumpFrameQueue() {
        guard !isSending, let transport = videoTransport, transport.state == .streaming || transport.state == .connected else { return }
        guard let frame = frameQueue.dequeue() else { return }

        let macSendTimestampNs = UInt64(CACurrentMediaTime() * 1_000_000_000.0)
        let queueDelayUs = (frame.timestamp > 0) ? UInt32(max(0, (CACurrentMediaTime() - frame.timestamp) * 1_000_000.0)) : 0

        let timing = VideoFrameTiming(
            captureTimestampNs: frame.captureTimestampNs,
            encodeStartTimestampNs: frame.encodeStartTimestampNs,
            encodeCompleteTimestampNs: frame.encodeCompleteTimestampNs,
            networkSendTimestampNs: macSendTimestampNs,
            encodeDurationUs: frame.encodeDurationUs,
            macQueueDelayUs: queueDelayUs
        )

        isSending = true
        if frame.sequence == 1 || frame.sequence % 60 == 0 {
            print("[MirooDisplaySession] Transmitting frame #\(frame.sequence) via \(transport.transportType.rawValue) (bytes=\(frame.data.count), isKeyframe=\(frame.isKeyframe))")
        }
        transport.sendFrame(
            sequence: frame.sequence,
            pts: frame.pts,
            isKeyframe: frame.isKeyframe,
            annexBData: frame.data,
            timing: timing
        ) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.isSending = false
                self.pumpFrameQueue()
            }
        }
    }

    // MARK: - Connection & Telemetry Setup

    private func setupConnectionHandlers(_ conn: MirooConnection) {
        conn.onMessageReceived = { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                switch message.header.messageType {
                case .ready:
                    print("[MirooDisplaySession] Received READY from client for session '\(self.sessionID)'. Transitioning to streaming.")
                    conn.transitionToStreaming()
                    self.videoTransport?.start()
                    self.requestKeyframe()
                    self.pumpFrameQueue()
                case .ping:
                    if let clientTs = message.decodePing() {
                        let serverNow = Int64(CACurrentMediaTime() * 1_000_000_000.0)
                        conn.send(message: .pong(clientTimestamp: clientTs, serverTimestamp: serverNow))
                    }
                case .adaptiveFeedback:
                    if let feedback = message.decodePayload(AdaptiveFeedbackPayload.self) {
                        self.rttMs = feedback.rttMs
                        self.currentLatencyMs = max(3.0, feedback.rttMs / 2.0)
                    }
                case .benchmarkReport:
                    if let report = message.decodePayload(PipelineBenchmarkReport.self) {
                        if report.glassToRender.p50 > 0 {
                            self.currentLatencyMs = report.glassToRender.p50
                        }
                    }
                case .touchEvent:
                    if let touch = message.decodeTouchEvent() {
                        self.handleTouchEvent(touch)
                    }
                case .scrollEvent:
                    if let scroll = message.decodeScrollEvent() {
                        self.handleScrollEvent(scroll)
                    }
                case .rightClick:
                    if let right = message.decodeRightClick() {
                        self.handleRightClick(right)
                    }
                case .keyframeRequest:
                    self.requestKeyframe()
                case .displayOrientation:
                    if let oriPayload = message.decodePayload(DisplayOrientationPayload.self) {
                        await self.switchOrientation(to: oriPayload.orientation)
                    }
                case .sessionEnded:
                    if let ended = message.decodeSessionEnded() {
                        self.stop(reason: ended.reason)
                    }
                case .pong:
                    if let pong = message.decodePong() {
                        let nowNs = Int64(CACurrentMediaTime() * 1_000_000_000)
                        let rtt = max(0.5, Double(nowNs - pong.clientTimestamp) / 1_000_000.0)
                        self.rttMs = rtt
                    }
                default:
                    break
                }
            }
        }

        conn.onDisconnected = { [weak self] error in
            Task { @MainActor [weak self] in
                self?.stop(reason: .userDisconnected)
            }
        }
    }

    private func startTelemetryMonitoring() {
        lastTelemetryTime = CACurrentMediaTime()
        telemetryTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let now = CACurrentMediaTime()
                let elapsed = now - self.lastTelemetryTime
                if let metrics = self.videoTransport?.getMetrics(), elapsed > 0 {
                    let dFrames = metrics.framesSent >= self.lastTelemetryFramesSent ? metrics.framesSent - self.lastTelemetryFramesSent : 0
                    let dBytes = metrics.bytesSent >= self.lastTelemetryBytesSent ? metrics.bytesSent - self.lastTelemetryBytesSent : 0
                    self.currentFPS = Double(dFrames) / elapsed
                    self.currentBitrateMbps = (Double(dBytes * 8) / elapsed) / 1_000_000.0
                    self.currentLatencyMs = max(3.0, self.rttMs / 2.0)
                    self.lastTelemetryFramesSent = metrics.framesSent
                    self.lastTelemetryBytesSent = metrics.bytesSent
                    self.lastTelemetryTime = now
                    if metrics.framesSent > 0 {
                        print("[MirooDisplaySession] Telemetry: \(String(format: "%.1f", self.currentFPS)) FPS, \(String(format: "%.2f", self.currentBitrateMbps)) Mbps, RTT: \(String(format: "%.1f", self.rttMs)) ms (Total Sent: \(metrics.framesSent))")
                    }
                }
            }
        }
    }
}
