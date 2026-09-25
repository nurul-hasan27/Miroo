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

    // Transport Abstraction (Phase 8A & 8B)
    public private(set) var activeVideoTransport: (any VideoReceiverTransport)?
    public private(set) var currentTransportType: VideoTransportType = .tcp

    // USB Transport (Phase 8B)
    public static let usbPort: UInt16 = 51065
    private var usbListener: NWListener?
    public private(set) var isUSBActive: Bool = false

    // Sequence continuity tracking
    private var lastSequenceNumber: UInt64 = 0
    public private(set) var totalDetectedGaps: UInt64 = 0
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
    private var isUserInitiatedStop = false

    // Phase 10: Lifecycle & Host Management
    public let lifecycle = ConnectionStateMachine(initialState: .idle)
    public let reconnectPolicy = ReconnectPolicy()
    public private(set) var reconnectAttempt: Int = 0
    public private(set) var activeHostName: String?
    public private(set) var activeSessionID: String? = nil
    public private(set) var activeConnectingHost: DiscoveredHost?
    public private(set) var discoveredHosts: [DiscoveredHost] = []
    public var onLifecycleChanged: ((ConnectionLifecycleState) -> Void)?
    public var onDiscoveredHostsUpdated: (([DiscoveredHost]) -> Void)?

    // Callbacks
    public var onConnected: ((String) -> Void)?
    public var onDisconnected: ((Error?) -> Void)?
    public var onStreamConfigUpdated: ((StreamConfigPayload) -> Void)?
    public var onFrameReceived: ((_ seq: UInt64, _ pts: Int64, _ isKeyframe: Bool, _ data: Data, _ timing: VideoFrameTiming?, _ networkReceiveTimestampNs: UInt64, _ netTransitMs: Double, _ jitterMs: Double) -> Void)?
    public let keyframeDebouncer = KeyframeDebouncer(cooldownSeconds: 0.500)
    public let adaptiveController = AdaptiveStreamingController()
    public private(set) var totalKeyframeRequestsSent: UInt64 = 0

    public init(clientName: String = "Miroo iPhone") {
        self.clientName = clientName
        self.lifecycle.onStateTransition = { [weak self] oldState, newState in
            self?.onLifecycleChanged?(newState)
        }
    }

    deinit {
        stop()
    }

    public var autoConnectOnDiscovery: Bool = false

    public var discoveredMacs: [MirooDevice] {
        browser.discoveredMacs
    }
    public var onDiscoveredMacsUpdated: (([MirooDevice]) -> Void)?

    // MARK: - Discovery & Connection

    public func startDiscovery() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.startTelemetryTimer()
            self.startUSBListener()

            if self.lifecycle.currentState == .idle || self.lifecycle.currentState == .disconnected(reason: nil) {
                _ = self.lifecycle.transition(to: .searching)
            }

            print("[Miroo Receiver] Starting Bonjour service discovery for '_miroo._tcp'...")
            self.browser.onDevicesUpdated = { [weak self] devices in
                guard let self = self else { return }
                let macs = devices.filter { $0.deviceType == .mac }
                self.onDiscoveredMacsUpdated?(macs)
            }
            self.browser.onServicesUpdated = { [weak self] services in
                guard let self = self else { return }
                self.queue.async {
                    var hosts: [DiscoveredHost] = []
                    for s in services {
                        let isUSB = self.isUSBActive
                        hosts.append(DiscoveredHost(
                            name: s.name,
                            endpoint: s.endpoint,
                            isUSB: isUSB,
                            lastSeen: Date(),
                            txtRecord: s.txtRecord
                        ))
                    }
                    self.discoveredHosts = hosts
                    self.onDiscoveredHostsUpdated?(hosts)

                    // If reconnecting or autoConnectOnDiscovery is enabled:
                    if (self.lifecycle.currentState.isReconnecting || self.autoConnectOnDiscovery) && !self.isUSBActive {
                        if self.connection == nil || self.connection?.state == .disconnected {
                            let target = self.activeConnectingHost ?? hosts.first
                            if let target = target {
                                print("[Miroo Receiver] Auto-connecting to '\(target.name)'...")
                                self.startReceiving(targetHost: target)
                            }
                        }
                    }
                }
            }
            self.browser.start()

            // Check cached services
            if !self.browser.discoveredServices.isEmpty {
                var hosts: [DiscoveredHost] = []
                for s in self.browser.discoveredServices {
                    hosts.append(DiscoveredHost(name: s.name, endpoint: s.endpoint, isUSB: self.isUSBActive, lastSeen: Date(), txtRecord: s.txtRecord))
                }
                self.discoveredHosts = hosts
                self.onDiscoveredHostsUpdated?(hosts)
            }
        }
    }

    public func start() {
        startDiscovery()
    }

    public func startReceiving(targetHost: DiscoveredHost? = nil) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.isUserInitiatedStop = false
            self.isAutoReconnectEnabled = true

            // If USB is already active and connected, transition to connected immediately
            if self.isUSBActive, let conn = self.connection, conn.state == .streaming || conn.state == .connected {
                let name = targetHost?.name ?? self.activeHostName ?? "Mac (USB)"
                self.activeHostName = name
                _ = self.lifecycle.transition(to: .connected(host: name, transport: .usb))
                return
            }

            let target = targetHost ?? self.discoveredHosts.first
            guard let selectedHost = target ?? (self.isUSBActive ? DiscoveredHost(name: "Mac (USB)", endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.usbPort)!), isUSB: true) : nil) else {
                _ = self.lifecycle.transition(to: .error(message: "Mac Not Found"))
                return
            }

            self.activeConnectingHost = selectedHost
            self.activeHostName = selectedHost.name
            let transport = TransportSelector.resolveTransport(isUSBActive: self.isUSBActive)
            _ = self.lifecycle.transition(to: .connecting(target: selectedHost.name, transport: transport))

            self.connect(to: selectedHost.endpoint)
        }
    }

    public func stopReceiving() {
        self.isUserInitiatedStop = true
        self.isAutoReconnectEnabled = false
        queue.async { [weak self] in
            guard let self = self else { return }
            self.stopPingTimer()
            if let sID = self.activeSessionID {
                if self.connection?.state == .streaming {
                    self.connection?.send(message: .sessionEnded(SessionEndedPayload(sessionID: sID, reason: .userDisconnected)))
                } else {
                    self.connection?.send(message: .connectionCancelled(ConnectionCancelledPayload(sessionID: sID, reason: "userCancelled")))
                }
                self.activeSessionID = nil
            }
            self.activeVideoTransport?.stop()
            self.activeVideoTransport = nil
            self.connection?.disconnect()
            self.connection = nil
            self.streamConfig = nil
            self.reconnectAttempt = 0
            _ = self.lifecycle.transition(to: .disconnected(reason: "Stopped by user"))
            print("[Miroo Receiver] Receiving stopped by user.")
        }
    }

    public func connect(to endpoint: NWEndpoint) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.isUSBActive {
                print("[Miroo Receiver] Ignoring Wi-Fi discovery connect because USB is active.")
                return
            }
            self.connection?.disconnect()

            let conn = MirooConnection(to: endpoint, queue: self.queue)
            self.connection = conn

            conn.onStateChanged = { [weak self, weak conn] state in
                guard let self = self, let conn = conn else { return }
                print("[Miroo Receiver] Connection state: \(state)")
                if state == .connected {
                    print("[Miroo Receiver] Connected to transport. Sending CONNECTION_REQUEST...")
                    let sID = UUID().uuidString
                    self.activeSessionID = sID
                    let req = ConnectionRequestPayload(
                        clientID: DeviceIdentity.currentID,
                        clientName: self.clientName,
                        clientModel: DeviceIdentity.defaultModelName(),
                        protocolVersion: Int(MirooHeader.currentVersion),
                        preferredWidth: 1170,
                        preferredHeight: 2532,
                        preferredFPS: 60,
                        preferredTransport: self.isUSBActive ? "USB" : "auto",
                        sessionID: sID
                    )
                    conn.send(message: .connectionRequest(req))
                    _ = self.lifecycle.transition(to: .waitingForApproval(host: self.activeHostName ?? "Mac"))
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
                self.activeVideoTransport?.stop()
                self.activeVideoTransport = nil
                self.onDisconnected?(error)

                if self.isUserInitiatedStop {
                    _ = self.lifecycle.transition(to: .disconnected(reason: "Stopped by user"))
                    return
                }

                if self.isAutoReconnectEnabled && !self.isUSBActive {
                    self.reconnectAttempt += 1
                    if self.reconnectPolicy.canRetry(attempt: self.reconnectAttempt) {
                        let reason = error?.localizedDescription ?? "Connection Lost"
                        _ = self.lifecycle.transition(to: .reconnecting(reason: reason, attempt: self.reconnectAttempt))
                        let delay = self.reconnectPolicy.delay(forAttempt: self.reconnectAttempt)
                        print("[Miroo Receiver] Scheduling auto-reconnect attempt #\(self.reconnectAttempt) in \(delay)s...")
                        self.queue.asyncAfter(deadline: .now() + delay) {
                            if let target = self.activeConnectingHost ?? self.discoveredHosts.first {
                                self.startReceiving(targetHost: target)
                            } else {
                                self.startDiscovery()
                            }
                        }
                    } else {
                        _ = self.lifecycle.transition(to: .error(message: "Unable to reconnect to Mac after \(self.reconnectAttempt) attempts"))
                    }
                } else if !self.isUSBActive {
                    _ = self.lifecycle.transition(to: .disconnected(reason: error?.localizedDescription))
                }
            }

            conn.start()
        }
    }

    public func stop() {
        self.isUserInitiatedStop = true
        self.isAutoReconnectEnabled = false
        queue.async { [weak self] in
            guard let self = self else { return }
            self.stopPingTimer()
            self.telemetryTimer?.cancel()
            self.telemetryTimer = nil
            self.activeVideoTransport?.stop()
            self.activeVideoTransport = nil
            self.browser.stop()
            self.usbListener?.cancel()
            self.usbListener = nil
            self.isUSBActive = false
            self.connection?.disconnect()
            self.connection = nil
            self.streamConfig = nil
            self.lastSequenceNumber = 0
            self.totalDetectedGaps = 0
            self.framesLoggedCount = 0
            self.reconnectAttempt = 0
            _ = self.lifecycle.transition(to: .disconnected(reason: "Stopped"))
            print("[Miroo Receiver] Stopped.")
        }
    }

    /// Asynchronously sends a KEYFRAME_REQUEST to the Mac server over the reliable TCP control channel.
    /// Debounces requests under cooldown to prevent keyframe request storms.
    public func requestKeyframe(reason: String = "client_request") {
        queue.async { [weak self] in
            guard let self = self, let conn = self.connection else { return }
            guard self.keyframeDebouncer.shouldRequest() else {
                return
            }
            self.totalKeyframeRequestsSent += 1
            print("[Miroo Receiver] Requesting IDR keyframe from server (reason: \(reason), request #\(self.totalKeyframeRequestsSent))...")
            conn.send(message: MirooMessage.keyframeRequest(reason: reason))
        }
    }

    /// Sends periodic adaptive streaming feedback to the Mac server.
    public func sendAdaptiveFeedback(_ feedback: AdaptiveFeedbackPayload) {
        queue.async { [weak self] in
            guard let self = self, let conn = self.connection, conn.state == .streaming else { return }
            conn.send(message: .adaptiveFeedback(feedback))
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
        case .connectionAccepted:
            if let accepted = message.decodeConnectionAccepted() {
                print("[Miroo Receiver] Connection accepted by Mac '\(accepted.hostName)' (session: \(accepted.sessionID))")
                self.activeHostName = accepted.hostName
                _ = self.lifecycle.transition(to: .connected(host: accepted.hostName, transport: self.currentTransportType))
            }

        case .connectionRejected:
            if let rejected = message.decodeConnectionRejected() {
                print("[Miroo Receiver] Connection rejected by Mac: \(rejected.reasonCode.rawValue) - \(rejected.reasonMessage)")
                _ = self.lifecycle.transition(to: .declined(host: self.activeHostName ?? "Mac", reason: rejected.reasonMessage))
                self.connection?.disconnect()
            }

        case .sessionStarting:
            print("[Miroo Receiver] Mac is allocating virtual display session...")

        case .sessionStarted:
            if let started = message.decodeSessionStarted() {
                print("[Miroo Receiver] Mac display session started: \(started.width)x\(started.height)")
            }

        case .sessionEnded:
            if let ended = message.decodeSessionEnded() {
                print("[Miroo Receiver] Session ended by Mac: \(ended.reason.rawValue)")
                stopReceiving()
            }

        case .hello:
            if let hello = message.decodePayload(HelloPayload.self) {
                print("[Miroo Receiver] Received HELLO from '\(hello.name)' (role: \(hello.role))")
                self.activeHostName = hello.name
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

                self.reconnectAttempt = 0
                _ = self.lifecycle.transition(to: .connected(host: self.activeHostName ?? "Miroo Mac", transport: self.currentTransportType))

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
                if let remoteHost = conn.resolvedRemoteHost {
                    host = .name(remoteHost, nil)
                } else if let remote = conn.connection.currentPath?.remoteEndpoint, case .hostPort(let h, _) = remote {
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
        } else if type == .usb {
            print("[Miroo Receiver] Active transport is USB (zero-latency direct cable).")
            let usb = USBVideoReceiverTransport()
            usb.onFrameReceived = { [weak self] seq, pts, isKeyframe, data, timing, recvNs, netTransitMs, jitterMs in
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
            self.activeVideoTransport = usb
            usb.start()
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
            guard let self = self, let conn = conn, conn.state == .streaming else { return }
            let nowNs = Int64(CACurrentMediaTime() * 1_000_000_000)
            conn.send(message: .ping(timestamp: nowNs))

            // Phase 9: Transmit live telemetry to Mac server for adaptive regulation
            let snap = self.metrics.snapshot()
            let bench = PipelineBenchmark.shared.generateReport()
            let lossRate: Double = (snap.framesReceived > 0) ? Double(self.totalDetectedGaps) / Double(snap.framesReceived + self.totalDetectedGaps) : 0.0
            let metricsSnapshot = StreamingMetricsSnapshot(
                transportType: self.currentTransportType,
                rttMs: self.smoothedRTTMs,
                oneWayTransitMs: max(0.5, self.smoothedRTTMs / 2.0),
                packetLossRate: lossRate,
                sequenceGaps: self.totalDetectedGaps,
                queueDepth: 0,
                frameDrops: bench.counters.staleDrops + bench.counters.decoderDrops + bench.counters.displayDrops,
                currentFPS: snap.recvFps > 0 ? snap.recvFps : 60.0
            )
            _ = self.adaptiveController.evaluate(metrics: metricsSnapshot)
            let feedback = AdaptiveFeedbackPayload(
                rttMs: self.smoothedRTTMs,
                oneWayTransitMs: max(0.5, self.smoothedRTTMs / 2.0),
                jitterMs: self.smoothedJitterMs,
                packetLossRate: lossRate,
                sequenceGaps: self.totalDetectedGaps,
                staleDrops: bench.counters.staleDrops,
                decoderDrops: bench.counters.decoderDrops,
                displayDrops: bench.counters.displayDrops,
                receiverFPS: snap.recvFps > 0 ? snap.recvFps : 60.0,
                currentFrameAgeMs: bench.frameAge.p50,
                transport: self.currentTransportType.rawValue
            )
            conn.send(message: .adaptiveFeedback(feedback))
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

    // MARK: - USB Listener & Connection (Phase 8B)

    private func startUSBListener() {
        guard usbListener == nil else { return }
        do {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.noDelay = true
            tcpOptions.enableFastOpen = true
            let params = NWParameters(tls: nil, tcp: tcpOptions)
            params.allowLocalEndpointReuse = true
            params.serviceClass = .interactiveVideo

            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.usbPort)!)
            var txtRecord = NWTXTRecord()
            txtRecord["version"] = "1"
            txtRecord["type"] = "iphone"
            txtRecord["id"] = DeviceIdentity.currentID
            txtRecord["name"] = clientName
            txtRecord["model"] = DeviceIdentity.defaultModelName()
            txtRecord["os"] = DeviceIdentity.currentOSVersion()
            txtRecord["usb"] = isUSBActive ? "1" : "0"
            txtRecord["state"] = MirooDeviceAvailability.available.rawValue

            l.service = NWListener.Service(
                name: clientName,
                type: "_miroo._tcp",
                domain: "local.",
                txtRecord: txtRecord
            )
            l.newConnectionHandler = { [weak self] newConn in
                self?.handleInboundUSBConnection(newConn)
            }
            l.stateUpdateHandler = { state in
                if case .ready = state {
                    print("[Miroo Receiver] USB listener active on port \(Self.usbPort). Ready for Mac USB tunnel.")
                }
            }
            l.start(queue: queue)
            self.usbListener = l
        } catch {
            print("[Miroo Receiver] Failed to start USB listener on port \(Self.usbPort): \(error.localizedDescription)")
        }
    }

    private func handleInboundUSBConnection(_ newNWConn: NWConnection) {
        queue.async { [weak self] in
            guard let self = self else { return }

            let isLoopback: Bool
            if case .hostPort(let host, _) = newNWConn.endpoint {
                let hostStr = "\(host)".lowercased()
                isLoopback = hostStr.contains("127.0.0.1") || hostStr.contains("::1") || hostStr.contains("localhost")
            } else {
                isLoopback = false
            }

            print("[Miroo Receiver] Incoming connection from Mac (Endpoint: \(newNWConn.endpoint), isUSB: \(isLoopback))...")

            if isLoopback {
                // USB has highest priority: disconnect any active Wi-Fi connection
                if let existing = self.connection {
                    print("[Miroo Receiver] Prioritizing USB connection over existing connection. Disconnecting old connection...")
                    existing.disconnect()
                    self.connection = nil
                }
                self.isUSBActive = true
                self.currentTransportType = .usb
                self.browser.stop() // Pause Bonjour browsing while on USB
            } else {
                self.isUSBActive = false
                self.currentTransportType = .tcp
            }
            self.reconnectAttempt = 0

            let hostName = self.activeHostName ?? (isLoopback ? "Mac (USB)" : "Miroo Mac")
            _ = self.lifecycle.transition(to: .connected(host: hostName, transport: self.currentTransportType))

            let conn = MirooConnection(connection: newNWConn, queue: self.queue)
            self.connection = conn

            conn.onStateChanged = { state in
                print("[Miroo Receiver] Inbound connection state: \(state) (USB: \(isLoopback))")
            }

            conn.onMessageReceived = { [weak self, weak conn] message in
                guard let self = self, let conn = conn else { return }
                self.handleMessage(message, from: conn)
            }

            conn.onDisconnected = { [weak self] error in
                guard let self = self else { return }
                print("[Miroo Receiver] USB disconnected: \(error?.localizedDescription ?? "Clean close")")
                self.isUSBActive = false
                self.stopPingTimer()
                self.connection = nil
                self.streamConfig = nil
                self.activeVideoTransport?.stop()
                self.activeVideoTransport = nil
                self.onDisconnected?(error)

                if self.isUserInitiatedStop {
                    _ = self.lifecycle.transition(to: .disconnected(reason: "Stopped by user"))
                    return
                }

                // Disconnect safety: fall back to Wi-Fi auto-reconnect if enabled
                if self.isAutoReconnectEnabled {
                    self.reconnectAttempt += 1
                    _ = self.lifecycle.transition(to: .reconnecting(reason: "USB Disconnected", attempt: self.reconnectAttempt))
                    print("[Miroo Receiver] USB disconnected. Attempting Wi-Fi fallback...")
                    self.queue.asyncAfter(deadline: .now() + 0.5) {
                        self.startDiscovery()
                        if let wifiHost = self.discoveredHosts.first(where: { !$0.isUSB }) ?? self.discoveredHosts.first {
                            print("[Miroo Receiver] Found Wi-Fi fallback host: '\(wifiHost.name)'. Connecting...")
                            self.startReceiving(targetHost: wifiHost)
                        }
                    }
                } else {
                    _ = self.lifecycle.transition(to: .disconnected(reason: "USB Disconnected"))
                }
            }

            conn.start()
        }
    }
}
