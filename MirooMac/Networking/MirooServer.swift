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
    public let targetFPS: Int
    public let bitrate: Int

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

    // Lifecycle Callbacks
    public var onClientConnected: ((String) -> Void)?
    public var onClientDisconnected: (() -> Void)?
    public var onStreamingStarted: (() -> Void)?
    public var onOrientationChangeRequested: ((MirooOrientation) -> Void)?
    public var onTouchEvent: ((TouchEventPayload) -> Void)?

    public init(
        serviceName: String = Host.current().localizedName ?? "Miroo Mac",
        width: Int = 1170,
        height: Int = 2532,
        targetFPS: Int = 60,
        bitrate: Int = 8_000_000,
        maxQueueDepth: Int = 1
    ) {
        self.serviceName = serviceName
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
    }

    public func stop() {
        metricsTimer?.cancel()
        metricsTimer = nil

        queue.async { [weak self] in
            guard let self = self else { return }
            if let active = self.activeConnection {
                active.disconnect()
                self.activeConnection = nil
            }

            self.listener?.cancel()
            self.listener = nil
            self.frameQueue.clear()
            self.isSending = false
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

        // If an existing client was connected, gracefully disconnect it to allow immediate reconnection
        if let existing = activeConnection {
            print("[Miroo Server] Disconnecting previous connection in favor of new client...")
            existing.disconnect()
            activeConnection = nil
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
            let streamMsg = MirooMessage.streamConfig(codec: "H264", width: width, height: height, fps: targetFPS, bitrate: bitrate)

            conn.send(message: displayMsg)
            conn.send(message: streamMsg)

        case .ready:
            print("[Miroo Server] Received READY from client. Handshake complete!")
            conn.transitionToStreaming()
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

        default:
            break
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
            orientation: orientation
        )
        conn.send(message: streamMsg)
    }

    // MARK: - Frame Ingestion & Backpressure Send Pump

    /// Enqueues an encoded H.264 Annex-B frame from VideoToolbox.
    public func enqueueFrame(data: Data, pts: CMTime, isKeyframe: Bool, encodeDurationUs: UInt32 = 0) {
        metrics.recordFrameEncoded()
        sequenceCounter += 1

        let ptsNanoseconds: Int64
        if pts.timescale > 0 {
            ptsNanoseconds = Int64(Double(pts.value) / Double(pts.timescale) * 1_000_000_000.0)
        } else {
            ptsNanoseconds = 0
        }

        let queuedFrame = QueuedFrame(
            sequence: sequenceCounter,
            pts: ptsNanoseconds,
            isKeyframe: isKeyframe,
            data: data,
            encodeDurationUs: encodeDurationUs
        )

        let accepted = frameQueue.enqueue(queuedFrame)
        if !accepted {
            metrics.recordFrameDropped()
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

        let macSendTimestampNs = Int64(CACurrentMediaTime() * 1_000_000_000.0)
        let queueDelaySeconds = max(0.0, CACurrentMediaTime() - frame.timestamp)
        let queueDelayUs = UInt32(min(Double(UInt32.max), queueDelaySeconds * 1_000_000.0))

        let timing = VideoFrameTiming(
            encodeDurationUs: frame.encodeDurationUs,
            macQueueDelayUs: queueDelayUs,
            macSendTimestampNs: macSendTimestampNs
        )

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
                    // Immediately check if another frame is waiting
                    self.pumpQueue()
                }
            }
        }
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
