//
//  MirooServer.swift
//  Miroo
//
//  Phase 4: Low-latency Network.framework server with Bonjour advertisement (_miroo._tcp),
//  handshake orchestration, bounded frame queue backpressure pump, and reconnection resilience.
//

import Foundation
import Network
import CoreMedia
import QuartzCore

public final class MirooServer: @unchecked Sendable {

    // MARK: - Configuration
    public let serviceType = "_miroo._tcp"
    public let serviceName: String
    public private(set) var width: Int
    public private(set) var height: Int
    public private(set) var targetFPS: Int
    public private(set) var bitrate: Int

    // MARK: - Network Components
    private let queue = DispatchQueue(label: "com.miroo.server.network", qos: .userInteractive)
    private var listener: NWListener?
    private var activeConnection: MirooConnection?
    private var isSending: Bool = false

    // MARK: - Frame Queue & Telemetry
    public let frameQueue: FrameQueue
    public let metrics = NetworkMetrics()
    private var sequenceCounter: UInt64 = 0
    private var metricsTimer: DispatchSourceTimer?

    // Transport Abstraction (Phase 8A & 8B)
    public private(set) var currentTransportType: VideoTransportType = .tcp
    public private(set) var activeVideoTransport: (any VideoSenderTransport)?
    public var udpPort: UInt16 = 51042
    public private(set) var udpSessionToken: UInt32 = UInt32.random(in: 100000...999999)

    // USB Transport (Phase 8B)
    private let usbmuxClient = USBMuxClient()
    private var usbRetryTimer: DispatchSourceTimer?
    private var isConnectingUSB: Bool = false
    public private(set) var isUSBActive: Bool = false

    // Lifecycle Callbacks
    public var onClientConnected: ((String) -> Void)?
    public var onClientDisconnected: (() -> Void)?
    public var onStreamingStarted: (() -> Void)?
    public var onOrientationChangeRequested: ((MirooOrientation) -> Void)?
    public var onTouchEvent: ((TouchEventPayload) -> Void)?
    public var onScrollEvent: ((ScrollEventPayload) -> Void)?
    public var onRightClick: ((RightClickPayload) -> Void)?
    public var onRequestKeyframe: (() -> Void)?
    public let adaptiveController = AdaptiveStreamingController()
    public var onAdaptiveDecision: ((AdaptiveDecision) -> Void)?

    public init(
        serviceName: String = Host.current().localizedName ?? "Miroo Mac",
        width: Int = 1170,
        height: Int = 2532,
        targetFPS: Int = 60,
        bitrate: Int = 8_000_000,
        maxQueueDepth: Int = 1,
        initialTransport: VideoTransportType = .tcp
    ) {
        self.serviceName = serviceName
        self.currentTransportType = initialTransport
        self.width = width
        self.height = height
        self.targetFPS = targetFPS
        self.bitrate = bitrate
        self.frameQueue = FrameQueue(maxDepth: maxQueueDepth)
    }

    deinit {
        stop()
    }

    // MARK: - Server Lifecycle

    public func start() throws {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.enableFastOpen = true

        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = true
        params.serviceClass = .interactiveVideo

        guard let newListener = try? NWListener(using: params) else {
            fatalError("[Miroo Server] Failed to initialize NWListener.")
        }

        // Configure Bonjour advertisement
        var txtRecord = NWTXTRecord()
        txtRecord["version"] = "1"
        txtRecord["name"] = serviceName
        txtRecord["codec"] = "h264"
        txtRecord["width"] = String(width)
        txtRecord["height"] = String(height)
        txtRecord["fps"] = String(targetFPS)
        txtRecord["type"] = "mac"
        txtRecord["id"] = DeviceIdentity.currentID
        txtRecord["model"] = DeviceIdentity.defaultModelName()
        txtRecord["os"] = DeviceIdentity.currentOSVersion()
        txtRecord["usb"] = isUSBActive ? "1" : "0"
        txtRecord["state"] = MirooDeviceAvailability.available.rawValue

        newListener.service = NWListener.Service(
            name: serviceName,
            type: serviceType,
            domain: "local.",
            txtRecord: txtRecord
        )

        newListener.stateUpdateHandler = { [weak self] state in
            self?.handleListenerState(state)
        }

        newListener.newConnectionHandler = { [weak self] newNWConn in
            self?.handleNewConnection(newNWConn)
        }

        newListener.start(queue: self.queue)
        self.listener = newListener

        self.startMetricsTimer()
        self.startUSBMonitoring()
    }

    public func stop() {
        stopUSBMonitoring()
        metricsTimer?.cancel()
        metricsTimer = nil

        queue.async { [weak self] in
            guard let self = self else { return }
            self.activeVideoTransport?.stop()
            self.activeVideoTransport = nil
            if let active = self.activeConnection {
                active.disconnect()
                self.activeConnection = nil
            }

            self.listener?.cancel()
            self.listener = nil
            self.frameQueue.clear()
            self.isSending = false
            self.isUSBActive = false
            print("[Miroo Server] Stopped.")
        }
    }

    // MARK: - Listener & Connection Handling

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            let port = listener?.port?.rawValue ?? 0
            print("[Miroo Server] Advertising Bonjour service '\(serviceType)' on port \(port). Waiting for iPhone...")
        case .failed(let error):
            print("[Miroo Server] Listener failed: \(error.localizedDescription)")
        case .cancelled:
            print("[Miroo Server] Listener cancelled.")
        case .waiting(let error):
            print("[Miroo Server] Listener waiting: \(error.localizedDescription)")
        case .setup:
            break
        @unknown default:
            break
        }
    }

    private func handleNewConnection(_ newNWConn: NWConnection) {
        print("[Miroo Server] Incoming connection detected from \(newNWConn.endpoint)...")

        // USB has higher priority: reject incoming Wi-Fi probe if USB is actively connected
        if isUSBActive {
            print("[Miroo Server] Active USB connection in progress; rejecting secondary Wi-Fi probe from \(newNWConn.endpoint)")
            newNWConn.cancel()
            return
        }

        // If an existing client is connecting, connected, or streaming, reject duplicate Happy Eyeballs probe
        if let existing = activeConnection {
            if existing.state == .streaming || existing.state == .connected || existing.state == .connecting {
                print("[Miroo Server] Active connection already in progress (\(existing.state)); rejecting redundant connection from \(newNWConn.endpoint)")
                newNWConn.cancel()
                return
            } else {
                print("[Miroo Server] Disconnecting stale previous connection in favor of new client...")
                existing.disconnect()
                activeConnection = nil
            }
        }

        frameQueue.clear()
        isSending = false

        let connection = MirooConnection(connection: newNWConn, queue: queue)
        self.activeConnection = connection

        connection.onStateChanged = { [weak self, weak connection] state in
            guard let self = self, let conn = connection else { return }
            print("[Miroo Server] Connection state: \(state)")
            if state == .connected {
                self.initiateHandshake(conn)
            }
        }

        connection.onMessageReceived = { [weak self, weak connection] message in
            guard let self = self, let conn = connection else { return }
            self.handleMessage(message, from: conn)
        }

        connection.onDisconnected = { [weak self, weak connection] error in
            guard let self = self else { return }
            if let error = error {
                print("[Miroo Server] Client disconnected with error: \(error.localizedDescription)")
            } else {
                print("[Miroo Server] Client disconnected cleanly.")
            }

            if self.activeConnection?.id == connection?.id {
                self.activeConnection = nil
                self.frameQueue.clear()
                self.isSending = false
                self.onClientDisconnected?()
                print("[Miroo Server] Ready for new connections.")
            }
        }

        connection.start()
    }

    // MARK: - Handshake State Machine

    private func initiateHandshake(_ conn: MirooConnection) {
        print("[Miroo Server] Initiating handshake: Sending HELLO...")
        let helloMsg = MirooMessage.hello(name: serviceName, role: "sender")
        conn.send(message: helloMsg)
    }

    private func getResolvedServerHost() -> String? {
        guard let conn = activeConnection else { return nil }
        if let local = conn.connection.currentPath?.localEndpoint, case .hostPort(let h, _) = local {
            switch h {
            case .ipv4(let ip):
                return "\(ip)"
            case .ipv6(let ip):
                return "\(ip)"
            default:
                break
            }
        }
        return nil
    }

    private func handleMessage(_ message: MirooMessage, from conn: MirooConnection) {
        switch message.header.messageType {
        case .hello:
            if let hello = message.decodePayload(HelloPayload.self) {
                print("[Miroo Server] Received HELLO from '\(hello.name)' (role: \(hello.role), v\(hello.version))")
                onClientConnected?(hello.name)
            }
            // Send display info & stream configuration
            print("[Miroo Server] Sending DISPLAY_INFO and STREAM_CONFIG...")
            let displayMsg = MirooMessage.displayInfo(width: width, height: height, scaleFactor: 3.0, name: "Miroo Extended iPhone")
            let streamMsg = MirooMessage.streamConfig(
                codec: "H264",
                width: width,
                height: height,
                fps: targetFPS,
                bitrate: bitrate,
                orientation: (width > height) ? .landscape : .portrait,
                transport: currentTransportType.rawValue,
                udpPort: udpPort,
                sessionToken: udpSessionToken,
                serverHost: getResolvedServerHost()
            )

            conn.send(message: displayMsg)
            conn.send(message: streamMsg)

        case .ready:
            print("[Miroo Server] Received READY from client. Handshake complete!")
            conn.transitionToStreaming()

            if currentTransportType == .udp {
                let udpSender = UDPVideoSenderTransport(port: udpPort, sessionToken: udpSessionToken)
                self.activeVideoTransport = udpSender
                udpSender.start()
            } else if currentTransportType == .usb {
                let usbSender = USBVideoSenderTransport(connection: conn)
                self.activeVideoTransport = usbSender
                usbSender.start()
            } else {
                let tcpSender = TCPVideoSenderTransport(connection: conn)
                self.activeVideoTransport = tcpSender
                tcpSender.start()
            }

            onStreamingStarted?()
            pumpQueue()

        case .ping:
            if let clientTs = message.decodePing() {
                let serverNow = Int64(CACurrentMediaTime() * 1_000_000_000.0)
                let pongMsg = MirooMessage.pong(clientTimestamp: clientTs, serverTimestamp: serverNow)
                conn.send(message: pongMsg)
            }

        case .goodbye:
            if let goodbye = message.decodePayload(GoodbyePayload.self) {
                print("[Miroo Server] Client sent GOODBYE: \(goodbye.reason)")
            }
            conn.disconnect()

        case .displayOrientation:
            if let payload = message.decodePayload(DisplayOrientationPayload.self) {
                print("[Miroo Server] Received DISPLAY_ORIENTATION from client: \(payload.orientation)")
                onOrientationChangeRequested?(payload.orientation)
            }

        case .touchEvent:
            if let payload = message.decodeTouchEvent() {
                onTouchEvent?(payload)
            }

        case .scrollEvent:
            if let payload = message.decodeScrollEvent() {
                onScrollEvent?(payload)
            }

        case .rightClick:
            if let payload = message.decodeRightClick() {
                onRightClick?(payload)
            }

        case .keyframeRequest:
            print("[Miroo Server] Received KEYFRAME_REQUEST from client -> forcing IDR frame...")
            onRequestKeyframe?()

        case .benchmarkReport:
            if let jsonString = String(data: message.payload, encoding: .utf8),
               let report = PipelineBenchmarkReport.fromJSON(jsonString) {
                print("\n[Miroo Server] Received Live Benchmark Report from Device:\n" + report.formattedSummary() + "\n")
                try? PipelineBenchmark.shared.exportJSON(toPath: "pipeline_benchmark_report.json", report: report)
            }

        case .adaptiveFeedback:
            if let feedback = message.decodeAdaptiveFeedback() {
                handleAdaptiveFeedback(feedback)
            }

        default:
            break
        }
    }

    private func handleAdaptiveFeedback(_ feedback: AdaptiveFeedbackPayload) {
        let snapshot = StreamingMetricsSnapshot(
            transportType: currentTransportType,
            rttMs: feedback.rttMs,
            oneWayTransitMs: feedback.networkTransitMs,
            packetLossRate: feedback.packetLossRate,
            sequenceGaps: feedback.sequenceGaps,
            queueDepth: frameQueue.currentDepth,
            frameDrops: feedback.staleDrops + feedback.decoderDrops + feedback.displayDrops,
            currentFPS: feedback.receiverFPS,
            timestamp: CACurrentMediaTime()
        )
        let decision = adaptiveController.evaluate(metrics: snapshot)
        if decision.targetBitrate != Int32(self.bitrate) || decision.targetFPS != Int32(self.targetFPS) {
            print("[Miroo Adaptive] State: \(decision.state.rawValue), Bitrate: \(decision.targetBitrate / 1_000_000) Mbps, Target FPS: \(decision.targetFPS) (\(decision.reason))")
            self.bitrate = Int(decision.targetBitrate)
            self.targetFPS = Int(decision.targetFPS)
            onAdaptiveDecision?(decision)
        }
    }

    /// Sends an updated STREAM_CONFIG message to the client upon resolution/orientation changes.
    public func sendStreamConfig(width: Int, height: Int, orientation: MirooOrientation) {
        self.width = width
        self.height = height
        guard let conn = activeConnection else { return }
        print("[Miroo Server] Sending updated STREAM_CONFIG: \(width)x\(height), \(orientation)...")
        let streamMsg = MirooMessage.streamConfig(
            codec: "H264",
            width: width,
            height: height,
            fps: targetFPS,
            bitrate: bitrate,
            orientation: orientation,
            transport: currentTransportType.rawValue,
            udpPort: udpPort,
            sessionToken: udpSessionToken,
            serverHost: getResolvedServerHost()
        )
        conn.send(message: streamMsg)
    }

    /// Dynamically switches video streaming transport between TCP and UDP at runtime.
    public func setVideoTransportType(_ type: VideoTransportType) {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard self.currentTransportType != type else { return }
            print("[Miroo Server] Switching video transport from \(self.currentTransportType) to \(type)...")
            self.currentTransportType = type
            self.activeVideoTransport?.stop()

            if type == .udp {
                let udpSender = UDPVideoSenderTransport(port: self.udpPort, sessionToken: self.udpSessionToken)
                self.activeVideoTransport = udpSender
                udpSender.start()
            } else if type == .usb {
                let usbSender = USBVideoSenderTransport(connection: self.activeConnection)
                self.activeVideoTransport = usbSender
                usbSender.start()
            } else {
                let tcpSender = TCPVideoSenderTransport(connection: self.activeConnection)
                self.activeVideoTransport = tcpSender
                tcpSender.start()
            }

            // Inform client of transport change over reliable TCP control channel
            if let conn = self.activeConnection, conn.state == .streaming || conn.state == .connected {
                let setMsg = MirooMessage.setTransport(
                    transport: type.rawValue,
                    udpPort: self.udpPort,
                    sessionToken: self.udpSessionToken,
                    serverHost: self.getResolvedServerHost()
                )
                conn.send(message: setMsg)
                self.onRequestKeyframe?()
            }
        }
    }

    // MARK: - Frame Ingestion & Backpressure Send Pump

    /// Enqueues an encoded H.264 Annex-B frame from VideoToolbox with full pipeline timing.
    public func enqueueFrame(
        data: Data,
        pts: CMTime,
        isKeyframe: Bool,
        captureTimestampNs: UInt64 = 0,
        encodeStartNs: UInt64 = 0,
        encodeCompleteNs: UInt64 = 0,
        encodeDurationUs: UInt32 = 0
    ) {
        metrics.recordFrameEncoded()
        sequenceCounter += 1

        let ptsNanoseconds: Int64
        if pts.timescale > 0 {
            ptsNanoseconds = Int64(Double(pts.value) / Double(pts.timescale) * 1_000_000_000.0)
        } else {
            ptsNanoseconds = Int64(captureTimestampNs)
        }

        let resolvedCapNs = (captureTimestampNs > 0) ? captureTimestampNs : UInt64(max(0, ptsNanoseconds))

        let queuedFrame = QueuedFrame(
            sequence: sequenceCounter,
            pts: ptsNanoseconds,
            isKeyframe: isKeyframe,
            data: data,
            encodeDurationUs: encodeDurationUs,
            captureTimestampNs: resolvedCapNs,
            encodeStartTimestampNs: encodeStartNs,
            encodeCompleteTimestampNs: encodeCompleteNs
        )

        let accepted = frameQueue.enqueue(queuedFrame)
        if !accepted {
            metrics.recordFrameDropped()
            PipelineBenchmark.shared.recordServerDrop(isKeyframe: isKeyframe)
        }

        queue.async { [weak self] in
            self?.pumpQueue()
        }
    }

    /// Backpressure sender loop. Sends strictly one frame at a time, awaiting .contentProcessed
    /// before taking the next freshest frame from the bounded queue.
    private func pumpQueue() {
        guard let conn = activeConnection, conn.state == .streaming else { return }
        guard !isSending else { return }
        guard let frame = frameQueue.dequeue() else { return }

        isSending = true

        let macSendTimestampNs = UInt64(CACurrentMediaTime() * 1_000_000_000.0)
        let queueDelaySeconds = max(0.0, CACurrentMediaTime() - frame.timestamp)
        let queueDelayUs = UInt32(min(Double(UInt32.max), queueDelaySeconds * 1_000_000.0))

        let timing = VideoFrameTiming(
            captureTimestampNs: frame.captureTimestampNs,
            encodeStartTimestampNs: frame.encodeStartTimestampNs,
            encodeCompleteTimestampNs: frame.encodeCompleteTimestampNs,
            networkSendTimestampNs: macSendTimestampNs,
            encodeDurationUs: frame.encodeDurationUs,
            macQueueDelayUs: queueDelayUs
        )

        if let transport = activeVideoTransport, transport.state == .streaming || transport.state == .connected {
            transport.sendFrame(
                sequence: frame.sequence,
                pts: frame.pts,
                isKeyframe: frame.isKeyframe,
                annexBData: frame.data,
                timing: timing
            ) { [weak self] result in
                guard let self = self else { return }
                self.queue.async {
                    self.isSending = false
                    switch result {
                    case .success:
                        self.metrics.recordFrameSent(bytes: frame.data.count)
                        PipelineBenchmark.shared.recordFrameTransmitted(sequence: frame.sequence)
                        self.pumpQueue()
                    case .failure(let err):
                        print("[Miroo Server] Transport sendFrame failed: \(err.localizedDescription)")
                    }
                }
            }
        } else {
            // Direct TCP fallback
            let msg = MirooMessage.videoFrame(
                sequence: frame.sequence,
                pts: frame.pts,
                isKeyframe: frame.isKeyframe,
                annexBData: frame.data,
                timing: timing
            )
            let serialized = msg.serialize()

            conn.send(data: serialized) { [weak self] error in
                guard let self = self else { return }
                self.queue.async {
                    self.isSending = false

                    if error == nil {
                        self.metrics.recordFrameSent(bytes: serialized.count)
                        PipelineBenchmark.shared.recordFrameTransmitted(sequence: frame.sequence)
                        self.pumpQueue()
                    }
                }
            }
        }
    }

    // MARK: - USB Management (Phase 8B)

    private func startUSBMonitoring() {
        usbmuxClient.onDeviceAttached = { [weak self] device in
            self?.handleUSBDeviceAttached(device)
        }
        usbmuxClient.onDeviceDetached = { [weak self] deviceID in
            self?.handleUSBDeviceDetached(deviceID)
        }
        usbmuxClient.startMonitoring()
    }

    private func stopUSBMonitoring() {
        stopUSBRetryTimer()
        usbmuxClient.stopMonitoring()
    }

    private func handleUSBDeviceAttached(_ device: USBMuxDevice) {
        queue.async { [weak self] in
            guard let self = self else { return }
            print("[Miroo Server] USB device attached: ID=\(device.deviceID), Serial=\(device.serialNumber)")
            self.attemptUSBConnection(deviceID: device.deviceID)
        }
    }

    private func handleUSBDeviceDetached(_ deviceID: UInt32) {
        queue.async { [weak self] in
            guard let self = self else { return }
            print("[Miroo Server] USB device detached: ID=\(deviceID)")
            self.stopUSBRetryTimer()
            if self.isUSBActive {
                print("[Miroo Server] Active USB connection detached -> disconnecting cleanly")
                self.isUSBActive = false
                self.activeConnection?.disconnect()
                self.activeConnection = nil
                self.activeVideoTransport?.stop()
                self.activeVideoTransport = nil
                self.frameQueue.clear()
                self.isSending = false
                self.onClientDisconnected?()
            }
        }
    }

    private func attemptUSBConnection(deviceID: UInt32) {
        guard !isConnectingUSB else { return }
        if isUSBActive && activeConnection?.state == .streaming { return }

        isConnectingUSB = true
        usbmuxClient.connectToDevice(deviceID: deviceID, port: USBMuxClient.targetDevicePort, timeoutSeconds: 3.0) { [weak self] result in
            guard let self = self else { return }
            self.queue.async {
                self.isConnectingUSB = false
                switch result {
                case .success(let nwConn):
                    print("[Miroo Server] USB tunnel established to iOS device ID=\(deviceID)!")
                    self.stopUSBRetryTimer()
                    self.handleNewUSBConnection(nwConn)
                case .failure:
                    // Receiver app on iPhone might not be open yet; schedule retry while device remains attached
                    if self.usbmuxClient.attachedDevices[deviceID] != nil && !self.isUSBActive {
                        self.scheduleUSBRetry(for: deviceID)
                    }
                }
            }
        }
    }

    private func scheduleUSBRetry(for deviceID: UInt32) {
        guard usbRetryTimer == nil, !isUSBActive else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1.5, repeating: 1.5)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            if self.isUSBActive || self.usbmuxClient.attachedDevices[deviceID] == nil {
                self.stopUSBRetryTimer()
                return
            }
            self.attemptUSBConnection(deviceID: deviceID)
        }
        timer.resume()
        self.usbRetryTimer = timer
    }

    private func stopUSBRetryTimer() {
        usbRetryTimer?.cancel()
        usbRetryTimer = nil
    }

    private func handleNewUSBConnection(_ newNWConn: NWConnection) {
        // Prioritize USB: Disconnect existing Wi-Fi connection if present
        if let existing = activeConnection {
            print("[Miroo Server] Prioritizing USB connection over existing connection (\(currentTransportType))...")
            existing.disconnect()
            activeConnection = nil
        }

        frameQueue.clear()
        isSending = false
        isUSBActive = true
        currentTransportType = .usb

        let connection = MirooConnection(connection: newNWConn, queue: queue)
        self.activeConnection = connection

        connection.onStateChanged = { [weak self, weak connection] state in
            guard let self = self, let conn = connection else { return }
            print("[Miroo Server] USB Connection state: \(state)")
            if state == .connected {
                self.initiateHandshake(conn)
            }
        }

        connection.onMessageReceived = { [weak self, weak connection] message in
            guard let self = self, let conn = connection else { return }
            self.handleMessage(message, from: conn)
        }

        connection.onDisconnected = { [weak self, weak connection] error in
            guard let self = self else { return }
            print("[Miroo Server] USB connection disconnected: \(error?.localizedDescription ?? "Clean close")")
            if self.activeConnection?.id == connection?.id {
                self.isUSBActive = false
                self.activeConnection = nil
                self.activeVideoTransport?.stop()
                self.activeVideoTransport = nil
                self.frameQueue.clear()
                self.isSending = false
                self.onClientDisconnected?()
                print("[Miroo Server] Ready for new connections.")

                // Check if any attached device is ready to reconnect
                if let dev = self.usbmuxClient.attachedDevices.values.first {
                    self.scheduleUSBRetry(for: dev.deviceID)
                }
            }
        }

        connection.start()
    }

    // MARK: - Metrics Reporting

    private func startMetricsTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 3.0, repeating: 3.0)
        timer.setEventHandler { [weak self] in
            self?.printMetricsSummary()
        }
        timer.resume()
        self.metricsTimer = timer
    }

    private func printMetricsSummary() {
        let snap = metrics.snapshot()
        let status = activeConnection?.state.description ?? "Disconnected"
        let queueDepth = frameQueue.count

        print("")
        print("------------- [Miroo Network] -------------")
        print(" Connection: \(status)")
        print(" Throughput: \(String(format: "%.2f", snap.sendThroughputMbps)) Mbps (~\(String(format: "%.1f", snap.sendFps)) FPS)")
        print(" Frames Sent: \(snap.framesSent) (Lifetime Encoded: \(snap.framesEncoded))")
        print(" Dropped: \(snap.framesDropped)")
        print(" Queue Depth: \(queueDepth) / \(frameQueue.maxDepth)")
        print("-------------------------------------------")
    }
}
