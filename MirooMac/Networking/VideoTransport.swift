//
//  VideoTransport.swift
//  Miroo
//
//  Phase 8A: Minimal Transport Abstraction & UDP Video Transport with Explicit
//  Fragmentation, Bounded Jitter Buffer, and TCP Baseline Preservation.
//

import Foundation
import Network
import QuartzCore
import os.lock

// MARK: - Transport Types & States

public enum VideoTransportType: String, Codable, Sendable, CustomStringConvertible {
    case tcp = "TCP"
    case udp = "UDP"
    case usb = "USB"

    public var description: String { rawValue }
}

public enum TransportConnectionState: String, Sendable, CustomStringConvertible {
    case disconnected
    case connecting
    case connected
    case streaming
    case failed

    public var description: String { rawValue.capitalized }
}

// MARK: - Transport Metrics

public struct VideoTransportMetrics: Sendable {
    public var bytesSent: UInt64 = 0
    public var bytesReceived: UInt64 = 0
    public var packetsSent: UInt64 = 0
    public var packetsReceived: UInt64 = 0
    public var packetsLost: UInt64 = 0
    public var framesSent: UInt64 = 0
    public var framesReceived: UInt64 = 0
    public var framesReconstructed: UInt64 = 0
    public var incompleteFramesDropped: UInt64 = 0
    public var staleFramesDropped: UInt64 = 0
    public var currentJitterBufferDepth: Int = 0
    public var rttMs: Double = 0.0

    public init() {}
}

// MARK: - Transport Protocols

public protocol VideoSenderTransport: AnyObject, Sendable {
    var transportType: VideoTransportType { get }
    var state: TransportConnectionState { get }
    var onStateChanged: ((TransportConnectionState) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }

    func start()
    func stop()
    func sendFrame(
        sequence: UInt64,
        pts: Int64,
        isKeyframe: Bool,
        annexBData: Data,
        timing: VideoFrameTiming?,
        completion: @escaping (Result<Void, Error>) -> Void
    )
    func getMetrics() -> VideoTransportMetrics
}

public protocol VideoReceiverTransport: AnyObject, Sendable {
    var transportType: VideoTransportType { get }
    var state: TransportConnectionState { get }
    var onStateChanged: ((TransportConnectionState) -> Void)? { get set }
    var onFrameReceived: ((_ sequence: UInt64, _ pts: Int64, _ isKeyframe: Bool, _ data: Data, _ timing: VideoFrameTiming?, _ networkReceiveTimestampNs: UInt64, _ netTransitMs: Double, _ jitterMs: Double) -> Void)? { get set }
    var onKeyframeRequested: (() -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }

    func start()
    func stop()
    func getMetrics() -> VideoTransportMetrics
}

// MARK: - UDP Binary Packet Layout & Fragmentation

/// Binary UDP packet layout for Miroo video stream (76-byte header + up to 1200 bytes payload = max 1276 bytes, avoiding IP fragmentation).
public struct MirooUDPPacket: Sendable, Equatable {
    public static let magic: UInt32 = 0x4D554450 // 'MUDP'
    public static let version: UInt8 = 1
    public static let headerSize: Int = 76
    public static let maxFragmentPayload: Int = 1200

    public struct Flags: OptionSet, Sendable, Equatable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let none     = Flags([])
        public static let keyframe = Flags(rawValue: 1 << 0)
    }

    public let flags: Flags
    public let sessionToken: UInt32
    public let packetSequenceNumber: UInt32
    public let frameSequenceNumber: UInt64
    public let fragmentIndex: UInt16
    public let fragmentCount: UInt16
    public let ptsNanoseconds: Int64
    public let captureTimestampNs: UInt64
    public let encodeStartTimestampNs: UInt64
    public let encodeCompleteTimestampNs: UInt64
    public let networkSendTimestampNs: UInt64
    public let encodeDurationUs: UInt32
    public let macQueueDelayUs: UInt32
    public let payload: Data

    public var isKeyframe: Bool {
        flags.contains(.keyframe)
    }

    public init(
        flags: Flags = .none,
        sessionToken: UInt32,
        packetSequenceNumber: UInt32,
        frameSequenceNumber: UInt64,
        fragmentIndex: UInt16,
        fragmentCount: UInt16,
        ptsNanoseconds: Int64,
        captureTimestampNs: UInt64 = 0,
        encodeStartTimestampNs: UInt64 = 0,
        encodeCompleteTimestampNs: UInt64 = 0,
        networkSendTimestampNs: UInt64 = 0,
        encodeDurationUs: UInt32 = 0,
        macQueueDelayUs: UInt32 = 0,
        payload: Data
    ) {
        self.flags = flags
        self.sessionToken = sessionToken
        self.packetSequenceNumber = packetSequenceNumber
        self.frameSequenceNumber = frameSequenceNumber
        self.fragmentIndex = fragmentIndex
        self.fragmentCount = fragmentCount
        self.ptsNanoseconds = ptsNanoseconds
        self.captureTimestampNs = captureTimestampNs
        self.encodeStartTimestampNs = encodeStartTimestampNs
        self.encodeCompleteTimestampNs = encodeCompleteTimestampNs
        self.networkSendTimestampNs = networkSendTimestampNs
        self.encodeDurationUs = encodeDurationUs
        self.macQueueDelayUs = macQueueDelayUs
        self.payload = payload
    }

    public func serialize() -> Data {
        var data = Data(capacity: MirooUDPPacket.headerSize + payload.count)
        var m = MirooUDPPacket.magic.bigEndian
        var v = MirooUDPPacket.version
        var fl = flags.rawValue
        var pLen = UInt16(payload.count).bigEndian
        var sTok = sessionToken.bigEndian
        var pSeq = packetSequenceNumber.bigEndian
        var fSeq = frameSequenceNumber.bigEndian
        var fIdx = fragmentIndex.bigEndian
        var fCnt = fragmentCount.bigEndian
        var pts = ptsNanoseconds.bigEndian
        var cap = captureTimestampNs.bigEndian
        var encS = encodeStartTimestampNs.bigEndian
        var encC = encodeCompleteTimestampNs.bigEndian
        var netS = networkSendTimestampNs.bigEndian
        var encD = encodeDurationUs.bigEndian
        var qDel = macQueueDelayUs.bigEndian

        withUnsafeBytes(of: &m) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &fl) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &pLen) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &sTok) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &pSeq) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &fSeq) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &fIdx) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &fCnt) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &pts) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &cap) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &encS) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &encC) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &netS) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &encD) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &qDel) { data.append(contentsOf: $0) }
        data.append(payload)

        return data
    }

    public static func deserialize(from data: Data) -> MirooUDPPacket? {
        guard data.count >= headerSize else { return nil }

        return data.withUnsafeBytes { rawBuffer -> MirooUDPPacket? in
            guard let base = rawBuffer.baseAddress else { return nil }

            let magic = UInt32(bigEndian: base.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
            guard magic == MirooUDPPacket.magic else { return nil }

            let version = base.loadUnaligned(fromByteOffset: 4, as: UInt8.self)
            guard version == MirooUDPPacket.version else { return nil }

            let flagsRaw = base.loadUnaligned(fromByteOffset: 5, as: UInt8.self)
            let payloadLen = Int(UInt16(bigEndian: base.loadUnaligned(fromByteOffset: 6, as: UInt16.self)))

            guard data.count >= headerSize + payloadLen else { return nil }

            let sessionToken = UInt32(bigEndian: base.loadUnaligned(fromByteOffset: 8, as: UInt32.self))
            let packetSeq = UInt32(bigEndian: base.loadUnaligned(fromByteOffset: 12, as: UInt32.self))
            let frameSeq = UInt64(bigEndian: base.loadUnaligned(fromByteOffset: 16, as: UInt64.self))
            let fragmentIndex = UInt16(bigEndian: base.loadUnaligned(fromByteOffset: 24, as: UInt16.self))
            let fragmentCount = UInt16(bigEndian: base.loadUnaligned(fromByteOffset: 26, as: UInt16.self))
            let pts = Int64(bigEndian: base.loadUnaligned(fromByteOffset: 28, as: Int64.self))
            let capNs = UInt64(bigEndian: base.loadUnaligned(fromByteOffset: 36, as: UInt64.self))
            let encStartNs = UInt64(bigEndian: base.loadUnaligned(fromByteOffset: 44, as: UInt64.self))
            let encCompNs = UInt64(bigEndian: base.loadUnaligned(fromByteOffset: 52, as: UInt64.self))
            let netSendNs = UInt64(bigEndian: base.loadUnaligned(fromByteOffset: 60, as: UInt64.self))
            let encDurUs = UInt32(bigEndian: base.loadUnaligned(fromByteOffset: 68, as: UInt32.self))
            let qDelayUs = UInt32(bigEndian: base.loadUnaligned(fromByteOffset: 72, as: UInt32.self))

            let payloadStart = headerSize
            let payloadEnd = payloadStart + payloadLen
            let payloadData = data.subdata(in: payloadStart..<payloadEnd)

            return MirooUDPPacket(
                flags: Flags(rawValue: flagsRaw),
                sessionToken: sessionToken,
                packetSequenceNumber: packetSeq,
                frameSequenceNumber: frameSeq,
                fragmentIndex: fragmentIndex,
                fragmentCount: fragmentCount,
                ptsNanoseconds: pts,
                captureTimestampNs: capNs,
                encodeStartTimestampNs: encStartNs,
                encodeCompleteTimestampNs: encCompNs,
                networkSendTimestampNs: netSendNs,
                encodeDurationUs: encDurUs,
                macQueueDelayUs: qDelayUs,
                payload: payloadData
            )
        }
    }

    /// Splits an encoded video frame into conservative MTU-safe UDP datagram packets.
    public static func fragment(
        sequence: UInt64,
        pts: Int64,
        isKeyframe: Bool,
        annexBData: Data,
        timing: VideoFrameTiming?,
        sessionToken: UInt32,
        startPacketSeq: inout UInt32,
        maxPayload: Int = MirooUDPPacket.maxFragmentPayload
    ) -> [MirooUDPPacket] {
        let totalBytes = annexBData.count
        guard totalBytes > 0 else { return [] }

        let chunkCount = max(1, (totalBytes + maxPayload - 1) / maxPayload)
        guard chunkCount <= Int(UInt16.max) else { return [] }

        var packets: [MirooUDPPacket] = []
        packets.reserveCapacity(chunkCount)

        var flags: Flags = .none
        if isKeyframe { flags.insert(.keyframe) }

        let capNs = timing?.captureTimestampNs ?? 0
        let encStartNs = timing?.encodeStartTimestampNs ?? 0
        let encCompNs = timing?.encodeCompleteTimestampNs ?? 0
        let netSendNs = timing?.networkSendTimestampNs ?? UInt64(CACurrentMediaTime() * 1_000_000_000.0)
        let encDurUs = timing?.encodeDurationUs ?? 0
        let qDelayUs = timing?.macQueueDelayUs ?? 0

        for i in 0..<chunkCount {
            let offset = i * maxPayload
            let length = min(maxPayload, totalBytes - offset)
            let chunk = annexBData.subdata(in: offset..<(offset + length))

            let packet = MirooUDPPacket(
                flags: flags,
                sessionToken: sessionToken,
                packetSequenceNumber: startPacketSeq,
                frameSequenceNumber: sequence,
                fragmentIndex: UInt16(i),
                fragmentCount: UInt16(chunkCount),
                ptsNanoseconds: pts,
                captureTimestampNs: capNs,
                encodeStartTimestampNs: encStartNs,
                encodeCompleteTimestampNs: encCompNs,
                networkSendTimestampNs: netSendNs,
                encodeDurationUs: encDurUs,
                macQueueDelayUs: qDelayUs,
                payload: chunk
            )
            startPacketSeq &+= 1
            packets.append(packet)
        }

        return packets
    }
}

// MARK: - UDP Registration Datagram (Session Handshake)

/// Lightweight 8-byte UDP datagram sent by client to register its dynamic endpoint with server.
public struct UDPRegistrationPayload: Sendable, Equatable {
    public static let magic: UInt32 = 0x4D524547 // 'MREG'
    public let sessionToken: UInt32

    public init(sessionToken: UInt32) {
        self.sessionToken = sessionToken
    }

    public func serialize() -> Data {
        var data = Data(capacity: 8)
        var m = UDPRegistrationPayload.magic.bigEndian
        var s = sessionToken.bigEndian
        withUnsafeBytes(of: &m) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &s) { data.append(contentsOf: $0) }
        return data
    }

    public static func deserialize(from data: Data) -> UDPRegistrationPayload? {
        guard data.count >= 8 else { return nil }
        return data.withUnsafeBytes { raw in
            let m = UInt32(bigEndian: raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
            guard m == magic else { return nil }
            let s = UInt32(bigEndian: raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
            return UDPRegistrationPayload(sessionToken: s)
        }
    }
}

// MARK: - Bounded Jitter & Frame Reassembly Buffer

/// High-performance, bounded reassembly buffer for UDP video fragments.
/// Prioritizes freshness over completeness (fresh frame > stale frame).
public final class UDPBoundedJitterBuffer: @unchecked Sendable {
    private struct PendingFrame {
        let frameSequence: UInt64
        let pts: Int64
        let isKeyframe: Bool
        let fragmentCount: UInt16
        let firstPacketArrival: CFTimeInterval
        var fragments: [UInt16: Data] = [:]
        var timing: VideoFrameTiming?
    }

    private var lock = os_unfair_lock_s()
    public let maxPendingFrames: Int
    public let frameTimeoutSeconds: Double

    private var pendingFrames: [UInt64: PendingFrame] = [:]
    private var lastDeliveredSequence: UInt64 = 0
    private var lastPacketSequence: UInt32? = nil
    private var activeSessionToken: UInt32

    // Metrics
    public private(set) var packetsReceived: UInt64 = 0
    public private(set) var packetsLost: UInt64 = 0
    public private(set) var framesReconstructed: UInt64 = 0
    public private(set) var incompleteFramesDropped: UInt64 = 0
    public private(set) var staleFramesDropped: UInt64 = 0

    public var onFrameCompleted: ((_ sequence: UInt64, _ pts: Int64, _ isKeyframe: Bool, _ data: Data, _ timing: VideoFrameTiming?, _ networkReceiveTimestampNs: UInt64) -> Void)?
    public var onKeyframeNeeded: (() -> Void)?

    public init(sessionToken: UInt32, maxPendingFrames: Int = 4, frameTimeoutMs: Double = 35.0) {
        self.activeSessionToken = sessionToken
        self.maxPendingFrames = maxPendingFrames
        self.frameTimeoutSeconds = frameTimeoutMs / 1000.0
    }

    public func setSessionToken(_ token: UInt32) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        if self.activeSessionToken != token {
            self.activeSessionToken = token
            self.pendingFrames.removeAll()
            self.lastDeliveredSequence = 0
            self.lastPacketSequence = nil
        }
    }

    public func reset() {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        pendingFrames.removeAll()
        lastDeliveredSequence = 0
        lastPacketSequence = nil
        packetsReceived = 0
        packetsLost = 0
        framesReconstructed = 0
        incompleteFramesDropped = 0
        staleFramesDropped = 0
    }

    /// Ingests a raw UDP datagram. Returns true if packet was valid and processed.
    @discardableResult
    public func ingestPacket(data: Data, receiveTimestampNs: UInt64 = UInt64(CACurrentMediaTime() * 1_000_000_000.0)) -> Bool {
        guard let packet = MirooUDPPacket.deserialize(from: data) else {
            return false
        }

        os_unfair_lock_lock(&lock)

        // 1. Session validation: reject stale/unknown sessions
        guard packet.sessionToken == activeSessionToken else {
            os_unfair_lock_unlock(&lock)
            return false
        }

        packetsReceived += 1

        // 2. Missing packet detection (Packet sequence gaps)
        if let lastPkt = lastPacketSequence {
            let expected = lastPkt &+ 1
            if packet.packetSequenceNumber > expected {
                let diff = UInt64(packet.packetSequenceNumber - expected)
                if diff < 10_000 {
                    packetsLost += diff
                }
            }
        }
        lastPacketSequence = packet.packetSequenceNumber

        let now = CACurrentMediaTime()
        let seq = packet.frameSequenceNumber

        // 3. Stale frame check: do not process fragments of already delivered frames
        if seq <= lastDeliveredSequence && lastDeliveredSequence > 0 {
            staleFramesDropped += 1
            os_unfair_lock_unlock(&lock)
            return true
        }

        // 4. Clean up expired frames (deadline timeout)
        purgeExpiredFramesLocked(currentTime: now)

        // 5. Ingest into PendingFrame map
        if pendingFrames[seq] == nil {
            // Check capacity: bounded jitter buffer limit
            if pendingFrames.count >= maxPendingFrames {
                // Drop the oldest incomplete frame
                if let oldestSeq = pendingFrames.keys.min() {
                    let dropped = pendingFrames.removeValue(forKey: oldestSeq)
                    incompleteFramesDropped += 1
                    if dropped?.isKeyframe == true {
                        onKeyframeNeeded?()
                    }
                }
            }

            let timing = VideoFrameTiming(
                captureTimestampNs: packet.captureTimestampNs,
                encodeStartTimestampNs: packet.encodeStartTimestampNs,
                encodeCompleteTimestampNs: packet.encodeCompleteTimestampNs,
                networkSendTimestampNs: packet.networkSendTimestampNs,
                encodeDurationUs: packet.encodeDurationUs,
                macQueueDelayUs: packet.macQueueDelayUs
            )

            pendingFrames[seq] = PendingFrame(
                frameSequence: seq,
                pts: packet.ptsNanoseconds,
                isKeyframe: packet.isKeyframe,
                fragmentCount: packet.fragmentCount,
                firstPacketArrival: now,
                fragments: [:],
                timing: timing
            )
        }

        pendingFrames[seq]?.fragments[packet.fragmentIndex] = packet.payload

        // 6. Check for complete reassembly
        var completedFrame: (seq: UInt64, pts: Int64, isKeyframe: Bool, data: Data, timing: VideoFrameTiming?)? = nil

        if let frame = pendingFrames[seq], frame.fragments.count == Int(frame.fragmentCount) {
            // Reconstruct payload in fragment order
            var fullAnnexB = Data()
            for i in 0..<frame.fragmentCount {
                if let frag = frame.fragments[i] {
                    fullAnnexB.append(frag)
                }
            }

            // Detect sequence discontinuity before this frame
            if lastDeliveredSequence > 0 && frame.frameSequence > lastDeliveredSequence + 1 && !frame.isKeyframe {
                onKeyframeNeeded?()
            }

            // Remove this and all older pending frames (fresh > stale)
            pendingFrames.removeValue(forKey: seq)
            let staleKeys = pendingFrames.keys.filter { $0 < seq }
            for staleKey in staleKeys {
                pendingFrames.removeValue(forKey: staleKey)
                staleFramesDropped += 1
            }

            completedFrame = (
                seq: frame.frameSequence,
                pts: frame.pts,
                isKeyframe: frame.isKeyframe,
                data: fullAnnexB,
                timing: frame.timing
            )
            lastDeliveredSequence = seq
            framesReconstructed += 1
        }

        let depth = pendingFrames.count
        os_unfair_lock_unlock(&lock)

        // 7. Deliver complete frame outside lock
        if let comp = completedFrame {
            onFrameCompleted?(comp.seq, comp.pts, comp.isKeyframe, comp.data, comp.timing, receiveTimestampNs)
        }

        _ = depth
        return true
    }

    private func purgeExpiredFramesLocked(currentTime: CFTimeInterval) {
        let expiredSeqs = pendingFrames.filter { currentTime - $0.value.firstPacketArrival > frameTimeoutSeconds }.map { $0.key }
        for seq in expiredSeqs {
            let dropped = pendingFrames.removeValue(forKey: seq)
            incompleteFramesDropped += 1
            if dropped?.isKeyframe == true {
                onKeyframeNeeded?()
            }
        }
    }

    public var currentPendingCount: Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return pendingFrames.count
    }
}

// MARK: - TCP Video Transports (Baseline Preservation)

public final class TCPVideoSenderTransport: VideoSenderTransport, @unchecked Sendable {
    public let transportType: VideoTransportType = .tcp
    public private(set) var state: TransportConnectionState = .disconnected {
        didSet { onStateChanged?(state) }
    }

    public var onStateChanged: ((TransportConnectionState) -> Void)?
    public var onError: ((Error) -> Void)?

    private weak var connection: MirooConnection?
    private var metrics = VideoTransportMetrics()

    public init(connection: MirooConnection?) {
        self.connection = connection
        self.state = (connection?.state == .streaming) ? .streaming : .connected
    }

    public func updateConnection(_ connection: MirooConnection?) {
        self.connection = connection
        self.state = (connection?.state == .streaming) ? .streaming : (connection != nil ? .connected : .disconnected)
    }

    public func start() {
        state = (connection?.state == .streaming) ? .streaming : .connected
    }

    public func stop() {
        state = .disconnected
    }

    public func sendFrame(
        sequence: UInt64,
        pts: Int64,
        isKeyframe: Bool,
        annexBData: Data,
        timing: VideoFrameTiming?,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let conn = connection, conn.state == .streaming else {
            completion(.failure(NSError(domain: "MirooTCP", code: -1, userInfo: [NSLocalizedDescriptionKey: "TCP connection not streaming."])))
            return
        }

        let msg = MirooMessage.videoFrame(
            sequence: sequence,
            pts: pts,
            isKeyframe: isKeyframe,
            annexBData: annexBData,
            timing: timing
        )
        let serialized = msg.serialize()

        metrics.framesSent += 1
        metrics.bytesSent += UInt64(serialized.count)

        conn.send(data: serialized) { [weak self] error in
            if let error = error {
                self?.onError?(error)
                completion(.failure(error))
            } else {
                completion(.success(()))
            }
        }
    }

    public func getMetrics() -> VideoTransportMetrics {
        metrics
    }
}

public final class TCPVideoReceiverTransport: VideoReceiverTransport, @unchecked Sendable {
    public let transportType: VideoTransportType = .tcp
    public private(set) var state: TransportConnectionState = .disconnected {
        didSet { onStateChanged?(state) }
    }

    public var onStateChanged: ((TransportConnectionState) -> Void)?
    public var onFrameReceived: ((_ sequence: UInt64, _ pts: Int64, _ isKeyframe: Bool, _ data: Data, _ timing: VideoFrameTiming?, _ networkReceiveTimestampNs: UInt64, _ netTransitMs: Double, _ jitterMs: Double) -> Void)?
    public var onKeyframeRequested: (() -> Void)?
    public var onError: ((Error) -> Void)?

    private var metrics = VideoTransportMetrics()

    public init() {}

    public func start() {
        state = .streaming
    }

    public func stop() {
        state = .disconnected
    }

    public func ingestTCPMessage(header: MirooHeader, payload: Data, receiveTimestampNs: UInt64, netTransitMs: Double, jitterMs: Double) {
        metrics.packetsReceived += 1
        metrics.framesReceived += 1
        metrics.bytesReceived += UInt64(MirooHeader.headerSize + payload.count)

        let (timing, annexB) = VideoFrameTiming.parse(from: payload)
        onFrameReceived?(header.sequence, header.pts, header.isKeyframe, annexB, timing, receiveTimestampNs, netTransitMs, jitterMs)
    }

    public func getMetrics() -> VideoTransportMetrics {
        metrics
    }
}

// MARK: - USB Video Transports (Phase 8B)

public final class USBVideoSenderTransport: VideoSenderTransport, @unchecked Sendable {
    public let transportType: VideoTransportType = .usb
    public private(set) var state: TransportConnectionState = .disconnected {
        didSet { onStateChanged?(state) }
    }

    public var onStateChanged: ((TransportConnectionState) -> Void)?
    public var onError: ((Error) -> Void)?

    private weak var connection: MirooConnection?
    private var metrics = VideoTransportMetrics()

    public init(connection: MirooConnection?) {
        self.connection = connection
        self.state = (connection?.state == .streaming) ? .streaming : .connected
    }

    public func updateConnection(_ connection: MirooConnection?) {
        self.connection = connection
        self.state = (connection?.state == .streaming) ? .streaming : (connection != nil ? .connected : .disconnected)
    }

    public func start() {
        state = (connection?.state == .streaming) ? .streaming : .connected
    }

    public func stop() {
        state = .disconnected
    }

    public func sendFrame(
        sequence: UInt64,
        pts: Int64,
        isKeyframe: Bool,
        annexBData: Data,
        timing: VideoFrameTiming?,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let conn = connection, conn.state == .streaming else {
            completion(.failure(NSError(domain: "MirooUSB", code: -1, userInfo: [NSLocalizedDescriptionKey: "USB connection not streaming."])))
            return
        }

        let msg = MirooMessage.videoFrame(
            sequence: sequence,
            pts: pts,
            isKeyframe: isKeyframe,
            annexBData: annexBData,
            timing: timing
        )
        let serialized = msg.serialize()

        metrics.framesSent += 1
        metrics.bytesSent += UInt64(serialized.count)

        conn.send(data: serialized) { [weak self] error in
            if let error = error {
                self?.onError?(error)
                completion(.failure(error))
            } else {
                completion(.success(()))
            }
        }
    }

    public func getMetrics() -> VideoTransportMetrics {
        metrics
    }
}

public final class USBVideoReceiverTransport: VideoReceiverTransport, @unchecked Sendable {
    public let transportType: VideoTransportType = .usb
    public private(set) var state: TransportConnectionState = .disconnected {
        didSet { onStateChanged?(state) }
    }

    public var onStateChanged: ((TransportConnectionState) -> Void)?
    public var onFrameReceived: ((_ sequence: UInt64, _ pts: Int64, _ isKeyframe: Bool, _ data: Data, _ timing: VideoFrameTiming?, _ networkReceiveTimestampNs: UInt64, _ netTransitMs: Double, _ jitterMs: Double) -> Void)?
    public var onKeyframeRequested: (() -> Void)?
    public var onError: ((Error) -> Void)?

    private var metrics = VideoTransportMetrics()

    public init() {}

    public func start() {
        state = .streaming
    }

    public func stop() {
        state = .disconnected
    }

    public func ingestUSBMessage(header: MirooHeader, payload: Data, receiveTimestampNs: UInt64, netTransitMs: Double, jitterMs: Double) {
        metrics.packetsReceived += 1
        metrics.framesReceived += 1
        metrics.bytesReceived += UInt64(MirooHeader.headerSize + payload.count)

        let (timing, annexB) = VideoFrameTiming.parse(from: payload)
        onFrameReceived?(header.sequence, header.pts, header.isKeyframe, annexB, timing, receiveTimestampNs, netTransitMs, jitterMs)
    }

    public func getMetrics() -> VideoTransportMetrics {
        metrics
    }
}

// MARK: - UDP Video Transports (Phase 8A)

public final class UDPVideoSenderTransport: VideoSenderTransport, @unchecked Sendable {
    public let transportType: VideoTransportType = .udp
    public private(set) var state: TransportConnectionState = .disconnected {
        didSet { onStateChanged?(state) }
    }

    public var onStateChanged: ((TransportConnectionState) -> Void)?
    public var onError: ((Error) -> Void)?

    public let port: UInt16
    public let sessionToken: UInt32
    private let queue = DispatchQueue(label: "com.miroo.udp.sender", qos: .userInteractive)

    private var listener: NWListener?
    private var activeUDPConnection: NWConnection?
    private var packetSequenceCounter: UInt32 = 0
    private var metrics = VideoTransportMetrics()

    public init(port: UInt16 = 51042, sessionToken: UInt32 = UInt32.random(in: 100000...999999)) {
        self.port = port
        self.sessionToken = sessionToken
    }

    public func start() {
        queue.async { [weak self] in
            guard let self = self else { return }
            do {
                let params = NWParameters.udp
                params.allowLocalEndpointReuse = true
                let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: self.port)!)

                l.newConnectionHandler = { [weak self] newConn in
                    guard let self = self else { return }
                    self.queue.async {
                        self.handleNewInboundUDP(newConn)
                    }
                }

                l.stateUpdateHandler = { [weak self] lState in
                    guard let self = self else { return }
                    if case .ready = lState {
                        print("[Miroo UDP Sender] Listening for client UDP registration on port \(self.port) (Session: \(self.sessionToken))...")
                        self.state = .connecting
                    }
                }

                l.start(queue: self.queue)
                self.listener = l
            } catch {
                print("[Miroo UDP Sender] Failed to start listener on port \(self.port): \(error.localizedDescription)")
                self.onError?(error)
                self.state = .failed
            }
        }
    }

    private func handleNewInboundUDP(_ conn: NWConnection) {
        conn.stateUpdateHandler = { [weak self, weak conn] st in
            guard let self = self, let conn = conn else { return }
            if st == .ready {
                self.receiveRegistration(conn: conn)
            }
        }
        conn.start(queue: queue)
    }

    private func receiveRegistration(conn: NWConnection) {
        conn.receiveMessage { [weak self, weak conn] content, context, isComplete, err in
            guard let self = self, let conn = conn else { return }
            if let data = content, let reg = UDPRegistrationPayload.deserialize(from: data) {
                if reg.sessionToken == self.sessionToken {
                    print("[Miroo UDP Sender] Registered valid client UDP endpoint: \(conn.endpoint) for session \(reg.sessionToken)")
                    self.activeUDPConnection = conn
                    self.state = .streaming
                    return
                } else {
                    print("[Miroo UDP Sender] Rejected UDP registration with invalid token \(reg.sessionToken) (expected \(self.sessionToken))")
                }
            }
            if err == nil && self.state != .disconnected {
                self.receiveRegistration(conn: conn)
            }
        }
    }

    /// Sets client UDP destination endpoint directly (e.g. if known from TCP control channel).
    public func setTargetEndpoint(_ endpoint: NWEndpoint) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.activeUDPConnection?.cancel()

            let params = NWParameters.udp
            params.allowLocalEndpointReuse = true
            let conn = NWConnection(to: endpoint, using: params)
            conn.stateUpdateHandler = { [weak self] st in
                guard let self = self else { return }
                if st == .ready {
                    print("[Miroo UDP Sender] Connected to client UDP endpoint: \(endpoint)")
                    self.state = .streaming
                }
            }
            conn.start(queue: self.queue)
            self.activeUDPConnection = conn
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.listener?.cancel()
            self.listener = nil
            self.activeUDPConnection?.cancel()
            self.activeUDPConnection = nil
            self.state = .disconnected
            print("[Miroo UDP Sender] Stopped.")
        }
    }

    public func sendFrame(
        sequence: UInt64,
        pts: Int64,
        isKeyframe: Bool,
        annexBData: Data,
        timing: VideoFrameTiming?,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard let conn = self.activeUDPConnection, self.state == .streaming else {
                completion(.failure(NSError(domain: "MirooUDP", code: -2, userInfo: [NSLocalizedDescriptionKey: "UDP target endpoint not ready/registered."])))
                return
            }

            let packets = MirooUDPPacket.fragment(
                sequence: sequence,
                pts: pts,
                isKeyframe: isKeyframe,
                annexBData: annexBData,
                timing: timing,
                sessionToken: self.sessionToken,
                startPacketSeq: &self.packetSequenceCounter
            )

            guard !packets.isEmpty else {
                completion(.success(()))
                return
            }

            var sentBytes: UInt64 = 0
            let totalPackets = packets.count
            var processedPackets = 0
            var sendError: Error? = nil

            for (idx, packet) in packets.enumerated() {
                let bytes = packet.serialize()
                sentBytes += UInt64(bytes.count)
                self.metrics.packetsSent += 1

                let isLast = (idx == totalPackets - 1)
                conn.send(content: bytes, isComplete: true, completion: .contentProcessed { [weak self] err in
                    guard let self = self else { return }
                    if let err = err {
                        sendError = err
                    }
                    processedPackets += 1
                    if processedPackets == totalPackets {
                        self.queue.async {
                            self.metrics.framesSent += 1
                            self.metrics.bytesSent += sentBytes
                            if let err = sendError {
                                completion(.failure(err))
                            } else {
                                completion(.success(()))
                            }
                        }
                    }
                })
                _ = isLast
            }
        }
    }

    public func getMetrics() -> VideoTransportMetrics {
        metrics
    }
}

public final class UDPVideoReceiverTransport: VideoReceiverTransport, @unchecked Sendable {
    public let transportType: VideoTransportType = .udp
    public private(set) var state: TransportConnectionState = .disconnected {
        didSet { onStateChanged?(state) }
    }

    public var onStateChanged: ((TransportConnectionState) -> Void)?
    public var onFrameReceived: ((_ sequence: UInt64, _ pts: Int64, _ isKeyframe: Bool, _ data: Data, _ timing: VideoFrameTiming?, _ networkReceiveTimestampNs: UInt64, _ netTransitMs: Double, _ jitterMs: Double) -> Void)?
    public var onKeyframeRequested: (() -> Void)?
    public var onError: ((Error) -> Void)?

    public let targetHost: NWEndpoint.Host
    public let targetPort: UInt16
    public let sessionToken: UInt32
    private let queue = DispatchQueue(label: "com.miroo.udp.receiver", qos: .userInteractive)

    private var connection: NWConnection?
    private let jitterBuffer: UDPBoundedJitterBuffer
    private var metrics = VideoTransportMetrics()

    private var lastFrameArrivalTime: CFTimeInterval = 0
    private var smoothedJitterMs: Double = 0.5

    public init(host: NWEndpoint.Host, port: UInt16 = 51042, sessionToken: UInt32) {
        self.targetHost = host
        self.targetPort = port
        self.sessionToken = sessionToken
        self.jitterBuffer = UDPBoundedJitterBuffer(sessionToken: sessionToken, maxPendingFrames: 4, frameTimeoutMs: 35.0)

        self.setupJitterBufferCallbacks()
    }

    private func setupJitterBufferCallbacks() {
        jitterBuffer.onFrameCompleted = { [weak self] seq, pts, isKeyframe, data, timing, recvNs in
            guard let self = self else { return }
            self.metrics.framesReconstructed += 1

            let now = CACurrentMediaTime()
            if self.lastFrameArrivalTime > 0 {
                let delta = now - self.lastFrameArrivalTime
                let jitter = abs(delta - 0.01667) * 1000.0
                self.smoothedJitterMs = (0.9 * self.smoothedJitterMs) + (0.1 * min(50.0, jitter))
            }
            self.lastFrameArrivalTime = now

            let netTransitMs: Double
            if let t = timing, t.networkSendTimestampNs > 0 {
                let macSendOnPhoneNs = Int64(t.networkSendTimestampNs) - PipelineBenchmark.shared.clockOffsetNs
                let diffMs = Double(Int64(recvNs) - macSendOnPhoneNs) / 1_000_000.0
                if diffMs > 0.05 && diffMs < 200.0 {
                    netTransitMs = diffMs
                } else {
                    netTransitMs = 5.0
                }
            } else {
                netTransitMs = 5.0
            }

            self.onFrameReceived?(seq, pts, isKeyframe, data, timing, recvNs, netTransitMs, self.smoothedJitterMs)
        }

        jitterBuffer.onKeyframeNeeded = { [weak self] in
            print("[Miroo UDP Receiver] Jitter buffer detected lost keyframe/timeout -> requesting IDR recovery.")
            self?.onKeyframeRequested?()
        }
    }

    public func start() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.state = .connecting

            let params = NWParameters.udp
            params.allowLocalEndpointReuse = true
            let endpoint = NWEndpoint.hostPort(host: self.targetHost, port: NWEndpoint.Port(rawValue: self.targetPort)!)
            let conn = NWConnection(to: endpoint, using: params)

            conn.stateUpdateHandler = { [weak self, weak conn] st in
                guard let self = self, let conn = conn else { return }
                if st == .ready {
                    print("[Miroo UDP Receiver] UDP connection ready to \(endpoint). Sending session registration...")
                    self.state = .streaming

                    // Send session registration handshake datagram with periodic retries until traffic flows
                    self.startRegistrationLoop(conn: conn)

                    self.receiveLoop(conn: conn)
                } else if case .failed(let err) = st {
                    print("[Miroo UDP Receiver] UDP connection error: \(err.localizedDescription)")
                    self.onError?(err)
                    self.state = .failed
                }
            }

            conn.start(queue: self.queue)
            self.connection = conn
        }
    }

    private var registrationTimer: DispatchSourceTimer?

    private func startRegistrationLoop(conn: NWConnection) {
        registrationTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 0.25)
        timer.setEventHandler { [weak self, weak conn] in
            guard let self = self, let conn = conn else { return }
            if self.metrics.packetsReceived > 0 || self.state != .streaming {
                self.registrationTimer?.cancel()
                self.registrationTimer = nil
                return
            }
            let reg = UDPRegistrationPayload(sessionToken: self.sessionToken)
            conn.send(content: reg.serialize(), isComplete: true, completion: .idempotent)
        }
        timer.resume()
        self.registrationTimer = timer
    }

    private func receiveLoop(conn: NWConnection) {
        conn.receiveMessage { [weak self, weak conn] content, context, isComplete, error in
            guard let self = self, let conn = conn else { return }

            if let data = content, !data.isEmpty {
                let recvNs = UInt64(CACurrentMediaTime() * 1_000_000_000.0)
                self.metrics.packetsReceived += 1
                self.metrics.bytesReceived += UInt64(data.count)

                self.jitterBuffer.ingestPacket(data: data, receiveTimestampNs: recvNs)
            }

            if let error = error {
                print("[Miroo UDP Receiver] Receive error: \(error.localizedDescription)")
                self.onError?(error)
            } else if self.state == .streaming {
                self.receiveLoop(conn: conn)
            }
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.registrationTimer?.cancel()
            self.registrationTimer = nil
            self.connection?.cancel()
            self.connection = nil
            self.jitterBuffer.reset()
            self.state = .disconnected
            print("[Miroo UDP Receiver] Stopped.")
        }
    }

    public func getMetrics() -> VideoTransportMetrics {
        var m = metrics
        m.packetsLost = jitterBuffer.packetsLost
        m.incompleteFramesDropped = jitterBuffer.incompleteFramesDropped
        m.staleFramesDropped = jitterBuffer.staleFramesDropped
        m.currentJitterBufferDepth = jitterBuffer.currentPendingCount
        return m
    }
}
