//
//  MirooReceiver.swift
//  Miroo
//
//  Phase 4 & 6: iPhone client-side network receiver with microsecond ping/pong
//  latency probing, frame timing parsing, and inter-arrival jitter estimation.
//

import Foundation
import Network
import QuartzCore

public final class MirooReceiver: @unchecked Sendable {

    // MARK: - Properties
    public let clientName: String
    private let queue = DispatchQueue(label: "com.miroo.receiver.network", qos: .userInteractive)

    private let browser = MirooBrowser()
    private var connection: MirooConnection?
    public let metrics = NetworkMetrics()

    // Stream Configuration received during handshake
    private(set) public var displayInfo: DisplayInfoPayload?
    private(set) public var streamConfig: StreamConfigPayload?

    // Transport Abstraction (Phase 8A)
    public private(set) var activeVideoTransport: (any VideoReceiverTransport)?
    public private(set) var currentTransportType: VideoTransportType = .tcp

    // Sequence continuity tracking
    private var lastSequenceNumber: UInt64 = 0
    private var totalDetectedGaps: UInt64 = 0
    private var framesLoggedCount: Int = 0

    // RTT & Jitter tracking
    private(set) public var smoothedRTTMs: Double = 3.0
    private var minRTTMs: Double = 3.0
    private var lastFrameArrivalTime: CFTimeInterval = 0
    private(set) public var smoothedJitterMs: Double = 0.5

    // Timers
    private var telemetryTimer: DispatchSourceTimer?
    private var pingTimer: DispatchSourceTimer?
    private var isAutoReconnectEnabled = true

    // Callbacks
    public var onConnected: ((String) -> Void)?
    public var onDisconnected: ((Error?) -> Void)?
    public var onStreamConfigUpdated: ((StreamConfigPayload) -> Void)?
    public var onFrameReceived: ((_ seq: UInt64, _ pts: Int64, _ isKeyframe: Bool, _ data: Data, _ timing: VideoFrameTiming?, _ networkReceiveTimestampNs: UInt64, _ netTransitMs: Double, _ jitterMs: Double) -> Void)?

    public init(clientName: String = "Miroo iPhone") {
        self.clientName = clientName
    }

    deinit {
        stop()
    }

    // MARK: - Discovery & Connection

    public func start() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.startTelemetryTimer()

            print("[Miroo Receiver] Starting Bonjour service discovery for '_miroo._tcp'...")
            self.browser.onServicesUpdated = { [weak self] services in
                guard let self = self else { return }
                self.queue.async {
                    if (self.connection == nil || self.connection?.state == .disconnected),
                       let first = services.first {
                        print("[Miroo Receiver] Found Miroo host: '\(first.name)'. Connecting...")
                        self.connect(to: first.endpoint)
                    }
                }
            }
            self.browser.start()

            // Check if service was already discovered
            if (self.connection == nil || self.connection?.state == .disconnected),
               let cached = self.browser.discoveredServices.first {
                print("[Miroo Receiver] Using previously discovered Miroo host: '\(cached.name)'. Connecting...")
                self.connect(to: cached.endpoint)
            }
        }
    }

    public func connect(to endpoint: NWEndpoint) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.connection?.disconnect()

            let conn = MirooConnection(to: endpoint, queue: self.queue)
            self.connection = conn

            conn.onStateChanged = { state in
                print("[Miroo Receiver] Connection state: \(state)")
                if state == .connected {
                    print("[Miroo Receiver] Connected to transport. Awaiting server HELLO...")
                }
            }

            conn.onMessageReceived = { [weak self, weak conn] message in
                guard let self = self, let conn = conn else { return }
                self.handleMessage(message, from: conn)
            }

            conn.onDisconnected = { [weak self] error in
                guard let self = self else { return }
                print("[Miroo Receiver] Disconnected from server: \(error?.localizedDescription ?? "Normal close")")
                self.stopPingTimer()
                self.connection = nil
                self.streamConfig = nil
                self.onDisconnected?(error)

                if self.isAutoReconnectEnabled {
                    print("[Miroo Receiver] Scheduling auto-reconnect in 1.5s...")
                    self.queue.asyncAfter(deadline: .now() + 1.5) {
                        self.start()
                    }
                }
            }

            conn.start()
        }
    }

    public func stop() {
        isAutoReconnectEnabled = false
        queue.async { [weak self] in
            guard let self = self else { return }
            self.stopPingTimer()
            self.telemetryTimer?.cancel()
            self.telemetryTimer = nil
            self.activeVideoTransport?.stop()
            self.activeVideoTransport = nil
            self.browser.stop()
            self.connection?.disconnect()
            self.connection = nil
            self.streamConfig = nil
            self.lastSequenceNumber = 0
            self.totalDetectedGaps = 0
            self.framesLoggedCount = 0
            print("[Miroo Receiver] Stopped.")
        }
    }

    /// Asynchronously sends a KEYFRAME_REQUEST to the Mac server over the reliable TCP control channel.
    public func requestKeyframe(reason: String = "client_request") {
        queue.async { [weak self] in
            guard let self = self, let conn = self.connection else { return }
            print("[Miroo Receiver] Requesting IDR keyframe from server (reason: \(reason))...")
            conn.send(message: MirooMessage.keyframeRequest(reason: reason))
        }
    }

    /// Sends a serialized benchmark report back to the Mac server.
    public func sendBenchmarkReport(_ jsonString: String) {
        queue.async { [weak self] in
            guard let self = self, let conn = self.connection, conn.state == .streaming else { return }
            let msg = MirooMessage.benchmarkReport(jsonString)
            conn.send(message: msg)
        }
    }

    /// Request dynamic orientation change on Mac virtual display
    public func sendOrientation(_ orientation: MirooOrientation) {
        queue.async { [weak self] in
            guard let self = self, let conn = self.connection else { return }
            let width: Int = (orientation == .landscape) ? 2532 : 1170
            let height: Int = (orientation == .landscape) ? 1170 : 2532
            let msg = MirooMessage.displayOrientation(orientation: orientation, width: width, height: height)
            conn.send(message: msg)
            print("[Miroo Receiver] Sent DISPLAY_ORIENTATION: \(orientation.rawValue) (\(width)x\(height))")
        }
    }

    /// Sends a touch event directly to the Mac server.
    public func sendTouchEvent(_ payload: TouchEventPayload) {
        guard let conn = self.connection, conn.state == .streaming else { return }
        let msg = MirooMessage.touchEvent(payload)
        conn.send(message: msg)
    }

    /// Sends a two-finger scroll event directly to the Mac server.
    public func sendScrollEvent(_ payload: ScrollEventPayload) {
        guard let conn = self.connection, conn.state == .streaming else { return }
        let msg = MirooMessage.scrollEvent(payload)
        conn.send(message: msg)
    }

    /// Sends a right click event directly to the Mac server.
    public func sendRightClick(_ payload: RightClickPayload) {
        guard let conn = self.connection, conn.state == .streaming else { return }
        let msg = MirooMessage.rightClick(payload)
        conn.send(message: msg)
    }

    // MARK: - Handshake Flow

    private func handleMessage(_ message: MirooMessage, from conn: MirooConnection) {
        switch message.header.messageType {
        case .hello:
            if let hello = message.decodePayload(HelloPayload.self) {
                print("[Miroo Receiver] Received HELLO from '\(hello.name)' (role: \(hello.role))")
                onConnected?(hello.name)
            }
            let reply = MirooMessage.hello(name: clientName, role: "receiver")
            conn.send(message: reply)

        case .displayInfo:
            if let info = message.decodePayload(DisplayInfoPayload.self) {
                self.displayInfo = info
                print("[Miroo Receiver] Received DISPLAY_INFO: \(info.name) (\(info.width)x\(info.height), scale: \(info.scaleFactor))")
            }

        case .streamConfig:
            if let config = message.decodePayload(StreamConfigPayload.self) {
                let isAlreadyStreaming = (conn.state == .streaming)
                self.streamConfig = config
                print("")
                print("===========================================")
                print(" Stream Config \(isAlreadyStreaming ? "Updated" : "Initialized")")
                print(" Dimensions: \(config.width)x\(config.height) (\(config.orientation))")
                print(" Frame Rate: \(config.fps) FPS (\(config.codec))")
                print(" Bitrate: \(Double(config.bitrate) / 1_000_000.0) Mbps")
                print("===========================================")
                print("")

                if !isAlreadyStreaming {
                    print("[Miroo Receiver] Sending READY...")
                    conn.send(message: MirooMessage.ready())
                    conn.transitionToStreaming()

                    // Start 250ms ping loop for precise RTT measurement
                    self.startPingTimer(conn: conn)
                }

                self.setupTransport(
                    type: VideoTransportType(rawValue: config.transport) ?? .tcp,
                    serverHost: config.serverHost,
                    udpPort: config.udpPort,
                    sessionToken: config.sessionToken
                )

                onStreamConfigUpdated?(config)
            }

        case .videoFrame:
            handleVideoFrame(header: message.header, payload: message.payload)

        case .setTransport:
            if let payload = message.decodeSetTransport() {
                print("[Miroo Receiver] Server commanded transport switch to: \(payload.transport)")
                self.setupTransport(
                    type: VideoTransportType(rawValue: payload.transport) ?? .tcp,
                    serverHost: payload.serverHost,
                    udpPort: payload.udpPort,
                    sessionToken: payload.sessionToken
                )
            }

        case .pong:
            if let pong = message.decodePong() {
                let nowNs = Int64(CACurrentMediaTime() * 1_000_000_000)
                let rttNs = max(0, nowNs - pong.clientTimestamp)
                let rttMs = Double(rttNs) / 1_000_000.0
                if minRTTMs <= 0 || rttMs < minRTTMs {
                    minRTTMs = max(0.5, rttMs)
                } else {
                    minRTTMs = 0.95 * minRTTMs + 0.05 * min(25.0, rttMs)
                }
                smoothedRTTMs = minRTTMs

                // Phase 7: Clock synchronization update for cross-device glass-to-render accuracy
                PipelineBenchmark.shared.updateClockOffset(
                    clientTimestamp: pong.clientTimestamp,
                    serverTimestamp: pong.serverTimestamp,
                    receiveTimestamp: nowNs
                )
            }

        case .ping:
            conn.send(message: MirooMessage(type: .pong, payload: message.payload))

        case .goodbye:
            if let goodbye = message.decodePayload(GoodbyePayload.self) {
                print("[Miroo Receiver] Server sent GOODBYE: \(goodbye.reason)")
            }
            conn.disconnect()

        default:
            break
        }
    }

    // MARK: - Transport Setup & Lifecycle

    private func setupTransport(type: VideoTransportType, serverHost: String? = nil, udpPort: UInt16, sessionToken: UInt32) {
        if self.currentTransportType == type && self.activeVideoTransport != nil {
            return
        }

        print("[Miroo Receiver] Configuring video transport: \(type.rawValue)...")
        self.activeVideoTransport?.stop()
        self.activeVideoTransport = nil
        self.currentTransportType = type

        if type == .udp {
            var host: NWEndpoint.Host = .name("localhost", nil)
            if let sh = serverHost, !sh.isEmpty {
                host = .name(sh, nil)
            } else if let conn = connection {
                if let remote = conn.connection.currentPath?.remoteEndpoint, case .hostPort(let h, _) = remote {
                    host = h
                } else if case .hostPort(let h, _) = conn.connection.endpoint {
                    host = h
                }
            }

            print("[Miroo Receiver] Starting UDP Video Receiver Transport to \(host):\(udpPort) (Session: \(sessionToken))...")
            let udp = UDPVideoReceiverTransport(host: host, port: udpPort, sessionToken: sessionToken)
            udp.onFrameReceived = { [weak self] seq, pts, isKeyframe, data, timing, recvNs, netTransitMs, jitterMs in
                self?.deliverFrame(
                    seq: seq,
                    pts: pts,
                    isKeyframe: isKeyframe,
                    annexBData: data,
                    timing: timing,
                    networkReceiveTimestampNs: recvNs,
                    netTransitMs: netTransitMs,
                    jitterMs: jitterMs
                )
            }
            udp.onKeyframeRequested = { [weak self] in
                print("[Miroo Receiver] Jitter buffer requested keyframe -> forwarding to Mac over TCP")
                self?.requestKeyframe(reason: "udp_packet_loss")
            }
            self.activeVideoTransport = udp
            udp.start()
        } else {
            print("[Miroo Receiver] Active transport is TCP (baseline).")
            let tcp = TCPVideoReceiverTransport()
            tcp.onFrameReceived = { [weak self] seq, pts, isKeyframe, data, timing, recvNs, netTransitMs, jitterMs in
                self?.deliverFrame(
                    seq: seq,
                    pts: pts,
                    isKeyframe: isKeyframe,
                    annexBData: data,
                    timing: timing,
                    networkReceiveTimestampNs: recvNs,
                    netTransitMs: netTransitMs,
                    jitterMs: jitterMs
                )
            }
            self.activeVideoTransport = tcp
            tcp.start()
        }
    }

    // MARK: - Video Frame Processing & Verification

    private func handleVideoFrame(header: MirooHeader, payload: Data) {
        let networkReceiveTimestampNs = UInt64(CACurrentMediaTime() * 1_000_000_000.0)
        let seq = header.sequence
        let pts = header.pts
        let isKeyframe = header.isKeyframe

        // Parse timing prefix if present
        let (timing, annexBData) = VideoFrameTiming.parse(from: payload)

        let now = CACurrentMediaTime()
        if lastFrameArrivalTime > 0 {
            let delta = now - lastFrameArrivalTime
            let jitter = abs(delta - 0.01667) * 1000.0
            smoothedJitterMs = (0.9 * smoothedJitterMs) + (0.1 * min(50.0, jitter))
        }
        lastFrameArrivalTime = now

        let netTransitMs: Double
        if let t = timing, t.networkSendTimestampNs > 0 {
            let macSendOnPhoneNs = Int64(t.networkSendTimestampNs) - PipelineBenchmark.shared.clockOffsetNs
            let diffMs = Double(Int64(networkReceiveTimestampNs) - macSendOnPhoneNs) / 1_000_000.0
            if diffMs > 0.05 && diffMs < 200.0 {
                netTransitMs = diffMs
            } else {
                netTransitMs = max(0.5, smoothedRTTMs / 2.0)
            }
        } else {
            netTransitMs = max(0.5, smoothedRTTMs / 2.0)
        }

        deliverFrame(
            seq: seq,
            pts: pts,
            isKeyframe: isKeyframe,
            annexBData: annexBData,
            timing: timing,
            networkReceiveTimestampNs: networkReceiveTimestampNs,
            netTransitMs: netTransitMs,
            jitterMs: smoothedJitterMs
        )
    }

    private func deliverFrame(
        seq: UInt64,
        pts: Int64,
        isKeyframe: Bool,
        annexBData: Data,
        timing: VideoFrameTiming?,
        networkReceiveTimestampNs: UInt64,
        netTransitMs: Double,
        jitterMs: Double
    ) {
        metrics.recordFrameReceived(bytes: MirooHeader.headerSize + annexBData.count)
        PipelineBenchmark.shared.recordFrameReceived(sequence: seq)

        // Verify sequence continuity
        if lastSequenceNumber > 0 && seq > lastSequenceNumber + 1 {
            let gap = seq - (lastSequenceNumber + 1)
            totalDetectedGaps += gap
            PipelineBenchmark.shared.recordSequenceGap(gap: gap)
            print("[Miroo Receiver] Sequence gap detected! Expected: \(lastSequenceNumber + 1), got: \(seq) (dropped: \(gap) frames)")
        }
        lastSequenceNumber = seq

        if framesLoggedCount < 10 || isKeyframe {
            let tag = isKeyframe ? "KEYFRAME" : ""
            print("Frame #\(seq)\t\(annexBData.count) bytes\t\(tag)")
            framesLoggedCount += 1
        }

        onFrameReceived?(seq, pts, isKeyframe, annexBData, timing, networkReceiveTimestampNs, netTransitMs, jitterMs)
    }

    // MARK: - Ping Timer

    private func startPingTimer(conn: MirooConnection) {
        stopPingTimer()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self, weak conn] in
            guard let _ = self, let conn = conn, conn.state == .streaming else { return }
            let nowNs = Int64(CACurrentMediaTime() * 1_000_000_000)
            conn.send(message: .ping(timestamp: nowNs))
        }
        timer.resume()
        self.pingTimer = timer
    }

    private func stopPingTimer() {
        pingTimer?.cancel()
        pingTimer = nil
    }

    // MARK: - Telemetry Logging

    private func startTelemetryTimer() {
        guard telemetryTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 3.0, repeating: 3.0)
        timer.setEventHandler { [weak self] in
            self?.printTelemetrySummary()
        }
        timer.resume()
        self.telemetryTimer = timer
    }

    private func printTelemetrySummary() {
        guard connection?.state == .streaming else { return }

        let snap = metrics.snapshot()
        print("")
        print("------------- [Miroo Receiver] -------------")
        print(" Status: Streaming")
        print(" Throughput: \(String(format: "%.2f", snap.recvThroughputMbps)) Mbps (~\(String(format: "%.1f", snap.recvFps)) FPS)")
        print(" Total Frames Received: \(snap.framesReceived)")
        print(" Sequence Gaps (Loss): \(totalDetectedGaps)")
        print(" Smoothed RTT: \(String(format: "%.2f", smoothedRTTMs)) ms (1-way Net: ~\(String(format: "%.2f", smoothedRTTMs / 2.0)) ms)")
        print(" Frame Jitter: \(String(format: "%.2f", smoothedJitterMs)) ms")
        print("--------------------------------------------")
    }
}
