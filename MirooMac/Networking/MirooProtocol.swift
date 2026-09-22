//
//  MirooProtocol.swift
//  Miroo
//
//  Phase 4: Binary protocol definition and stream framing for Mac <-> iPhone transport.
//

import Foundation

// MARK: - Message Types

public enum MirooMessageType: UInt8, Sendable, CustomStringConvertible {
    case hello        = 1
    case displayInfo  = 2
    case streamConfig = 3
    case ready        = 4
    case videoFrame   = 5
    case ping               = 6
    case pong               = 7
    case goodbye            = 8
    case displayOrientation = 9
    case touchEvent         = 10
    case scrollEvent        = 11
    case rightClick         = 12
    case benchmarkReport    = 13
    case keyframeRequest    = 14
    case setTransport       = 15

    public var description: String {
        switch self {
        case .hello:              return "HELLO"
        case .displayInfo:        return "DISPLAY_INFO"
        case .streamConfig:       return "STREAM_CONFIG"
        case .ready:              return "READY"
        case .videoFrame:         return "VIDEO_FRAME"
        case .ping:               return "PING"
        case .pong:               return "PONG"
        case .goodbye:            return "GOODBYE"
        case .displayOrientation: return "DISPLAY_ORIENTATION"
        case .touchEvent:         return "TOUCH_EVENT"
        case .scrollEvent:        return "SCROLL_EVENT"
        case .rightClick:         return "RIGHT_CLICK"
        case .benchmarkReport:    return "BENCHMARK_REPORT"
        case .keyframeRequest:    return "KEYFRAME_REQUEST"
        case .setTransport:       return "SET_TRANSPORT"
        }
    }
}

// MARK: - Header Flags

public struct MirooHeaderFlags: OptionSet, Sendable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let none     = MirooHeaderFlags([])
    public static let keyframe = MirooHeaderFlags(rawValue: 1 << 0)
}

// MARK: - Fixed-Size Binary Header (28 Bytes)

/// Fixed 28-byte header layout (Big-Endian / Network Byte Order):
/// - 4 bytes: Magic (0x4D49524F = 'MIRO')
/// - 1 byte:  Protocol Version (1)
/// - 1 byte:  Message Type (MirooMessageType)
/// - 2 bytes: Flags (e.g. 0x0001 = Keyframe)
/// - 8 bytes: Sequence Number (UInt64)
/// - 8 bytes: Presentation Timestamp in nanoseconds (Int64)
/// - 4 bytes: Payload Length in bytes (UInt32)
public struct MirooHeader: Equatable, Sendable {
    public static let magicValue: UInt32 = 0x4D49524F // 'MIRO'
    public static let currentVersion: UInt8 = 1
    public static let headerSize: Int = 28

    public let magic: UInt32
    public let version: UInt8
    public let messageType: MirooMessageType
    public let flags: MirooHeaderFlags
    public let sequence: UInt64
    public let pts: Int64
    public let payloadLength: UInt32

    public var isKeyframe: Bool {
        flags.contains(.keyframe)
    }

    public init(
        magic: UInt32 = MirooHeader.magicValue,
        version: UInt8 = MirooHeader.currentVersion,
        messageType: MirooMessageType,
        flags: MirooHeaderFlags = .none,
        sequence: UInt64 = 0,
        pts: Int64 = 0,
        payloadLength: UInt32
    ) {
        self.magic = magic
        self.version = version
        self.messageType = messageType
        self.flags = flags
        self.sequence = sequence
        self.pts = pts
        self.payloadLength = payloadLength
    }

    /// Serializes the 28-byte header to Big-Endian Data.
    public func serialize() -> Data {
        var data = Data(capacity: MirooHeader.headerSize)
        var m = magic.bigEndian
        var v = version
        var t = messageType.rawValue
        var f = flags.rawValue.bigEndian
        var s = sequence.bigEndian
        var p = pts.bigEndian
        var l = payloadLength.bigEndian

        withUnsafeBytes(of: &m) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &t) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &f) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &s) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &p) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &l) { data.append(contentsOf: $0) }

        return data
    }

    /// Safely parses a 28-byte header handling unaligned memory buffers.
    public static func deserialize(from data: Data) -> MirooHeader? {
        guard data.count >= headerSize else { return nil }

        return data.withUnsafeBytes { rawBuffer -> MirooHeader? in
            guard let base = rawBuffer.baseAddress else { return nil }

            var m: UInt32 = 0
            var f: UInt16 = 0
            var s: UInt64 = 0
            var p: Int64 = 0
            var l: UInt32 = 0

            memcpy(&m, base, 4)
            let magic = UInt32(bigEndian: m)
            guard magic == magicValue else { return nil }

            let version = (base + 4).load(as: UInt8.self)
            let typeRaw = (base + 5).load(as: UInt8.self)
            guard let msgType = MirooMessageType(rawValue: typeRaw) else { return nil }

            memcpy(&f, base + 6, 2)
            memcpy(&s, base + 8, 8)
            memcpy(&p, base + 16, 8)
            memcpy(&l, base + 24, 4)

            let flags = MirooHeaderFlags(rawValue: UInt16(bigEndian: f))
            let sequence = UInt64(bigEndian: s)
            let pts = Int64(bigEndian: p)
            let payloadLength = UInt32(bigEndian: l)

            return MirooHeader(
                magic: magic,
                version: version,
                messageType: msgType,
                flags: flags,
                sequence: sequence,
                pts: pts,
                payloadLength: payloadLength
            )
        }
    }
}

// MARK: - High-Level Message

public struct MirooMessage: Equatable, Sendable {
    public let header: MirooHeader
    public let payload: Data

    public init(header: MirooHeader, payload: Data = Data()) {
        self.header = header
        self.payload = payload
    }

    public init(
        type: MirooMessageType,
        flags: MirooHeaderFlags = .none,
        sequence: UInt64 = 0,
        pts: Int64 = 0,
        payload: Data = Data()
    ) {
        self.header = MirooHeader(
            messageType: type,
            flags: flags,
            sequence: sequence,
            pts: pts,
            payloadLength: UInt32(payload.count)
        )
        self.payload = payload
    }

    /// Serializes header + payload into a single contiguous Data chunk.
    public func serialize() -> Data {
        var data = header.serialize()
        data.append(payload)
        return data
    }
}

// MARK: - Handshake Payloads (Codable)

public struct HelloPayload: Codable, Sendable {
    public let name: String
    public let role: String   // "sender" or "receiver"
    public let version: Int

    public init(name: String, role: String, version: Int = 1) {
        self.name = name
        self.role = role
        self.version = version
    }
}

public struct DisplayInfoPayload: Codable, Sendable {
    public let width: Int
    public let height: Int
    public let scaleFactor: Double
    public let name: String

    public init(width: Int, height: Int, scaleFactor: Double = 3.0, name: String = "Miroo Extended iPhone") {
        self.width = width
        self.height = height
        self.scaleFactor = scaleFactor
        self.name = name
    }
}

// MARK: - Orientation Support
public enum MirooOrientation: String, Codable, Sendable {
    case portrait
    case landscape
}

public struct DisplayOrientationPayload: Codable, Sendable {
    public let orientation: MirooOrientation
    public let width: Int
    public let height: Int

    public init(orientation: MirooOrientation, width: Int = 1170, height: Int = 2532) {
        self.orientation = orientation
        self.width = width
        self.height = height
    }
}

public struct StreamConfigPayload: Codable, Sendable {
    public let codec: String   // "H264"
    public let width: Int
    public let height: Int
    public let fps: Int
    public let bitrate: Int
    public let orientation: MirooOrientation
    public let transport: String   // "TCP" or "UDP"
    public let udpPort: UInt16
    public let sessionToken: UInt32
    public let serverHost: String?

    public init(
        codec: String = "H264",
        width: Int,
        height: Int,
        fps: Int = 60,
        bitrate: Int = 8_000_000,
        orientation: MirooOrientation = .portrait,
        transport: String = "TCP",
        udpPort: UInt16 = 51042,
        sessionToken: UInt32 = 0,
        serverHost: String? = nil
    ) {
        self.codec = codec
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrate = bitrate
        self.orientation = orientation
        self.transport = transport
        self.udpPort = udpPort
        self.sessionToken = sessionToken
        self.serverHost = serverHost
    }

    enum CodingKeys: String, CodingKey {
        case codec, width, height, fps, bitrate, orientation, transport, udpPort, sessionToken, serverHost
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        codec = try container.decode(String.self, forKey: .codec)
        width = try container.decode(Int.self, forKey: .width)
        height = try container.decode(Int.self, forKey: .height)
        fps = try container.decode(Int.self, forKey: .fps)
        bitrate = try container.decode(Int.self, forKey: .bitrate)
        orientation = try container.decodeIfPresent(MirooOrientation.self, forKey: .orientation) ?? (width > height ? .landscape : .portrait)
        transport = try container.decodeIfPresent(String.self, forKey: .transport) ?? "TCP"
        udpPort = try container.decodeIfPresent(UInt16.self, forKey: .udpPort) ?? 51042
        sessionToken = try container.decodeIfPresent(UInt32.self, forKey: .sessionToken) ?? 0
        serverHost = try container.decodeIfPresent(String.self, forKey: .serverHost)
    }
}

public struct KeyframeRequestPayload: Codable, Sendable {
    public let reason: String

    public init(reason: String = "recovery") {
        self.reason = reason
    }
}

public struct SetTransportPayload: Codable, Sendable {
    public let transport: String   // "TCP" or "UDP"
    public let udpPort: UInt16
    public let sessionToken: UInt32
    public let serverHost: String?

    public init(transport: String, udpPort: UInt16 = 51042, sessionToken: UInt32 = 0, serverHost: String? = nil) {
        self.transport = transport
        self.udpPort = udpPort
        self.sessionToken = sessionToken
        self.serverHost = serverHost
    }
}

public struct ReadyPayload: Codable, Sendable {
    public let status: String

    public init(status: String = "ready") {
        self.status = status
    }
}

public struct GoodbyePayload: Codable, Sendable {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }
}

// MARK: - Touch Input Payloads (Phase 6A)

public struct TouchEventPayload: Sendable, Equatable {
    public enum Phase: UInt8, Sendable, Codable {
        case began = 0
        case moved = 1
        case ended = 2
        case cancelled = 3
    }

    public let phase: Phase
    public let touchID: UInt32
    public let x: Float // 0.0 ... 1.0 normalized relative to usable contentRect
    public let y: Float // 0.0 ... 1.0 normalized relative to usable contentRect
    public let timestampNs: UInt64

    public init(phase: Phase, touchID: UInt32 = 0, x: Float, y: Float, timestampNs: UInt64 = 0) {
        self.phase = phase
        self.touchID = touchID
        self.x = x
        self.y = y
        self.timestampNs = timestampNs
    }

    /// Serializes touch payload to 21 bytes big-endian binary.
    public func serialize() -> Data {
        var data = Data(capacity: 21)
        var p = phase.rawValue
        var tid = touchID.bigEndian
        var xBits = x.bitPattern.bigEndian
        var yBits = y.bitPattern.bigEndian
        var ts = timestampNs.bigEndian

        withUnsafeBytes(of: &p) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &tid) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &xBits) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &yBits) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &ts) { data.append(contentsOf: $0) }

        return data
    }

    /// Safely parses a 21-byte binary touch payload.
    public static func deserialize(from data: Data) -> TouchEventPayload? {
        guard data.count >= 21 else { return nil }
        return data.withUnsafeBytes { rawBuffer -> TouchEventPayload? in
            guard let base = rawBuffer.baseAddress else { return nil }
            let phaseRaw = base.load(as: UInt8.self)
            guard let phase = Phase(rawValue: phaseRaw) else { return nil }

            var tid: UInt32 = 0
            var xBits: UInt32 = 0
            var yBits: UInt32 = 0
            var ts: UInt64 = 0

            memcpy(&tid, base + 1, 4)
            memcpy(&xBits, base + 5, 4)
            memcpy(&yBits, base + 9, 4)
            memcpy(&ts, base + 13, 8)

            let touchID = UInt32(bigEndian: tid)
            let x = Float(bitPattern: UInt32(bigEndian: xBits))
            let y = Float(bitPattern: UInt32(bigEndian: yBits))
            let timestampNs = UInt64(bigEndian: ts)

            return TouchEventPayload(
                phase: phase,
                touchID: touchID,
                x: x,
                y: y,
                timestampNs: timestampNs
            )
        }
    }
}

// MARK: - Trackpad Scrolling & Right Click (Phase 6B)

/// Binary payload for two-finger scrolling: 16 bytes fixed size.
/// - 4 bytes: Float deltaX (signed, Big-Endian)
/// - 4 bytes: Float deltaY (signed, Big-Endian)
/// - 8 bytes: UInt64 timestampNs (Big-Endian)
public struct ScrollEventPayload: Sendable, Equatable {
    public let deltaX: Float
    public let deltaY: Float
    public let timestampNs: UInt64

    public init(deltaX: Float, deltaY: Float, timestampNs: UInt64 = 0) {
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.timestampNs = timestampNs
    }

    /// Serializes scroll payload to 16 bytes big-endian binary.
    public func serialize() -> Data {
        var data = Data(capacity: 16)
        var xBits = deltaX.bitPattern.bigEndian
        var yBits = deltaY.bitPattern.bigEndian
        var ts = timestampNs.bigEndian

        withUnsafeBytes(of: &xBits) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &yBits) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &ts) { data.append(contentsOf: $0) }

        return data
    }

    /// Safely parses a 16-byte binary scroll payload.
    public static func deserialize(from data: Data) -> ScrollEventPayload? {
        guard data.count >= 16 else { return nil }
        return data.withUnsafeBytes { rawBuffer -> ScrollEventPayload? in
            guard let base = rawBuffer.baseAddress else { return nil }
            var xBits: UInt32 = 0
            var yBits: UInt32 = 0
            var ts: UInt64 = 0

            memcpy(&xBits, base, 4)
            memcpy(&yBits, base + 4, 4)
            memcpy(&ts, base + 8, 8)

            let deltaX = Float(bitPattern: UInt32(bigEndian: xBits))
            let deltaY = Float(bitPattern: UInt32(bigEndian: yBits))
            let timestampNs = UInt64(bigEndian: ts)

            return ScrollEventPayload(deltaX: deltaX, deltaY: deltaY, timestampNs: timestampNs)
        }
    }
}

/// Binary payload for two-finger tap right click: 8 bytes fixed size.
/// - 8 bytes: UInt64 timestampNs (Big-Endian)
public struct RightClickPayload: Sendable, Equatable {
    public let timestampNs: UInt64

    public init(timestampNs: UInt64 = 0) {
        self.timestampNs = timestampNs
    }

    /// Serializes right click payload to 8 bytes big-endian binary.
    public func serialize() -> Data {
        var data = Data(capacity: 8)
        var ts = timestampNs.bigEndian
        withUnsafeBytes(of: &ts) { data.append(contentsOf: $0) }
        return data
    }

    /// Safely parses an 8-byte binary right click payload.
    public static func deserialize(from data: Data) -> RightClickPayload? {
        guard data.count >= 8 else { return nil }
        return data.withUnsafeBytes { rawBuffer -> RightClickPayload? in
            guard let base = rawBuffer.baseAddress else { return nil }
            var ts: UInt64 = 0
            memcpy(&ts, base, 8)
            return RightClickPayload(timestampNs: UInt64(bigEndian: ts))
        }
    }
}

// MARK: - Video Frame Timing Metadata (Phase 6 & 7 Diagnostics)

public struct VideoFrameTiming: Sendable, Equatable {
    public static let magic: UInt32 = 0x54494D45 // 'TIME'
    public static let legacyHeaderLength: Int = 20
    public static let fullHeaderLength: Int = 44

    public let captureTimestampNs: UInt64
    public let encodeStartTimestampNs: UInt64
    public let encodeCompleteTimestampNs: UInt64
    public let networkSendTimestampNs: UInt64
    public let encodeDurationUs: UInt32
    public let macQueueDelayUs: UInt32

    // Backwards compatibility accessor
    public var macSendTimestampNs: Int64 {
        Int64(networkSendTimestampNs)
    }

    public init(
        captureTimestampNs: UInt64 = 0,
        encodeStartTimestampNs: UInt64 = 0,
        encodeCompleteTimestampNs: UInt64 = 0,
        networkSendTimestampNs: UInt64 = 0,
        encodeDurationUs: UInt32 = 0,
        macQueueDelayUs: UInt32 = 0
    ) {
        self.captureTimestampNs = captureTimestampNs
        self.encodeStartTimestampNs = encodeStartTimestampNs
        self.encodeCompleteTimestampNs = encodeCompleteTimestampNs
        self.networkSendTimestampNs = networkSendTimestampNs
        self.encodeDurationUs = encodeDurationUs
        self.macQueueDelayUs = macQueueDelayUs
    }

    public init(encodeDurationUs: UInt32, macQueueDelayUs: UInt32, macSendTimestampNs: Int64) {
        self.captureTimestampNs = 0
        self.encodeStartTimestampNs = 0
        self.encodeCompleteTimestampNs = 0
        self.networkSendTimestampNs = UInt64(max(0, macSendTimestampNs))
        self.encodeDurationUs = encodeDurationUs
        self.macQueueDelayUs = macQueueDelayUs
    }

    public func serialize() -> Data {
        var data = Data(capacity: VideoFrameTiming.fullHeaderLength)
        var m = VideoFrameTiming.magic.bigEndian
        var cap = captureTimestampNs.bigEndian
        var encStart = encodeStartTimestampNs.bigEndian
        var encComp = encodeCompleteTimestampNs.bigEndian
        var netSend = networkSendTimestampNs.bigEndian
        var encDur = encodeDurationUs.bigEndian
        var qDelay = macQueueDelayUs.bigEndian

        withUnsafeBytes(of: &m) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &cap) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &encStart) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &encComp) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &netSend) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &encDur) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &qDelay) { data.append(contentsOf: $0) }
        return data
    }

    public static func parse(from data: Data) -> (timing: VideoFrameTiming?, annexBData: Data) {
        guard data.count >= legacyHeaderLength else { return (nil, data) }
        let magicVal = UInt32(bigEndian: data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        guard magicVal == magic else { return (nil, data) }

        if data.count >= fullHeaderLength {
            let cap = UInt64(bigEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt64.self) })
            let encStart = UInt64(bigEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt64.self) })
            let encComp = UInt64(bigEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 20, as: UInt64.self) })
            let netSend = UInt64(bigEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 28, as: UInt64.self) })
            let encDur = UInt32(bigEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 36, as: UInt32.self) })
            let qDelay = UInt32(bigEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 40, as: UInt32.self) })

            let timing = VideoFrameTiming(
                captureTimestampNs: cap,
                encodeStartTimestampNs: encStart,
                encodeCompleteTimestampNs: encComp,
                networkSendTimestampNs: netSend,
                encodeDurationUs: encDur,
                macQueueDelayUs: qDelay
            )
            let annexB = data.subdata(in: fullHeaderLength..<data.count)
            return (timing, annexB)
        } else {
            let enc = UInt32(bigEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) })
            let q = UInt32(bigEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self) })
            let s = Int64(bigEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: Int64.self) })
            let timing = VideoFrameTiming(encodeDurationUs: enc, macQueueDelayUs: q, macSendTimestampNs: s)
            let annexB = data.subdata(in: legacyHeaderLength..<data.count)
            return (timing, annexB)
        }
    }
}

extension MirooMessage {
    public static func hello(name: String, role: String) -> MirooMessage {
        let payload = HelloPayload(name: name, role: role)
        let data = (try? JSONEncoder().encode(payload)) ?? Data()
        return MirooMessage(type: .hello, payload: data)
    }

    public static func displayInfo(width: Int, height: Int, scaleFactor: Double = 3.0, name: String = "Miroo Extended iPhone") -> MirooMessage {
        let payload = DisplayInfoPayload(width: width, height: height, scaleFactor: scaleFactor, name: name)
        let data = (try? JSONEncoder().encode(payload)) ?? Data()
        return MirooMessage(type: .displayInfo, payload: data)
    }

    public static func streamConfig(
        codec: String = "H264",
        width: Int,
        height: Int,
        fps: Int = 60,
        bitrate: Int = 8_000_000,
        orientation: MirooOrientation = .portrait,
        transport: String = "TCP",
        udpPort: UInt16 = 51042,
        sessionToken: UInt32 = 0,
        serverHost: String? = nil
    ) -> MirooMessage {
        let payload = StreamConfigPayload(
            codec: codec,
            width: width,
            height: height,
            fps: fps,
            bitrate: bitrate,
            orientation: orientation,
            transport: transport,
            udpPort: udpPort,
            sessionToken: sessionToken,
            serverHost: serverHost
        )
        let data = (try? JSONEncoder().encode(payload)) ?? Data()
        return MirooMessage(type: .streamConfig, payload: data)
    }

    public static func keyframeRequest(reason: String = "recovery") -> MirooMessage {
        let payload = KeyframeRequestPayload(reason: reason)
        let data = (try? JSONEncoder().encode(payload)) ?? Data()
        return MirooMessage(type: .keyframeRequest, payload: data)
    }

    public static func setTransport(transport: String, udpPort: UInt16 = 51042, sessionToken: UInt32 = 0, serverHost: String? = nil) -> MirooMessage {
        let payload = SetTransportPayload(transport: transport, udpPort: udpPort, sessionToken: sessionToken, serverHost: serverHost)
        let data = (try? JSONEncoder().encode(payload)) ?? Data()
        return MirooMessage(type: .setTransport, payload: data)
    }

    public static func displayOrientation(orientation: MirooOrientation, width: Int = 1170, height: Int = 2532) -> MirooMessage {
        let payload = DisplayOrientationPayload(orientation: orientation, width: width, height: height)
        let data = (try? JSONEncoder().encode(payload)) ?? Data()
        return MirooMessage(type: .displayOrientation, payload: data)
    }

    public static func ready(status: String = "ready") -> MirooMessage {
        let payload = ReadyPayload(status: status)
        let data = (try? JSONEncoder().encode(payload)) ?? Data()
        return MirooMessage(type: .ready, payload: data)
    }

    public static func videoFrame(
        sequence: UInt64,
        pts: Int64,
        isKeyframe: Bool,
        annexBData: Data,
        timing: VideoFrameTiming? = nil
    ) -> MirooMessage {
        var payloadData: Data
        if let timing = timing {
            payloadData = timing.serialize()
            payloadData.append(annexBData)
        } else {
            payloadData = annexBData
        }
        return MirooMessage(
            type: .videoFrame,
            flags: isKeyframe ? .keyframe : .none,
            sequence: sequence,
            pts: pts,
            payload: payloadData
        )
    }

    public static func ping(timestamp: Int64) -> MirooMessage {
        var ts = timestamp.bigEndian
        var data = Data(capacity: 8)
        withUnsafeBytes(of: &ts) { data.append(contentsOf: $0) }
        return MirooMessage(type: .ping, payload: data)
    }

    public static func pong(clientTimestamp: Int64, serverTimestamp: Int64) -> MirooMessage {
        var clientTs = clientTimestamp.bigEndian
        var serverTs = serverTimestamp.bigEndian
        var data = Data(capacity: 16)
        withUnsafeBytes(of: &clientTs) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &serverTs) { data.append(contentsOf: $0) }
        return MirooMessage(type: .pong, payload: data)
    }

    public func decodePong() -> (clientTimestamp: Int64, serverTimestamp: Int64)? {
        guard payload.count >= 16 else { return nil }
        let clientTs = Int64(bigEndian: payload.withUnsafeBytes { $0.loadUnaligned(as: Int64.self) })
        let serverTs = Int64(bigEndian: payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: Int64.self) })
        return (clientTs, serverTs)
    }

    public func decodePing() -> Int64? {
        guard payload.count >= 8 else { return nil }
        return Int64(bigEndian: payload.withUnsafeBytes { $0.loadUnaligned(as: Int64.self) })
    }

    public static func goodbye(reason: String) -> MirooMessage {
        let payload = GoodbyePayload(reason: reason)
        let data = (try? JSONEncoder().encode(payload)) ?? Data()
        return MirooMessage(type: .goodbye, payload: data)
    }

    public static func touchEvent(_ payload: TouchEventPayload) -> MirooMessage {
        return MirooMessage(type: .touchEvent, payload: payload.serialize())
    }

    public func decodeTouchEvent() -> TouchEventPayload? {
        guard header.messageType == .touchEvent else { return nil }
        return TouchEventPayload.deserialize(from: payload)
    }

    public static func scrollEvent(_ payload: ScrollEventPayload) -> MirooMessage {
        return MirooMessage(type: .scrollEvent, payload: payload.serialize())
    }

    public func decodeScrollEvent() -> ScrollEventPayload? {
        guard header.messageType == .scrollEvent else { return nil }
        return ScrollEventPayload.deserialize(from: payload)
    }

    public static func rightClick(_ payload: RightClickPayload) -> MirooMessage {
        return MirooMessage(type: .rightClick, payload: payload.serialize())
    }

    public func decodeRightClick() -> RightClickPayload? {
        guard header.messageType == .rightClick else { return nil }
        return RightClickPayload.deserialize(from: payload)
    }

    public static func benchmarkReport(_ jsonString: String) -> MirooMessage {
        let payload = jsonString.data(using: .utf8) ?? Data()
        return MirooMessage(type: .benchmarkReport, payload: payload)
    }

    public func decodeKeyframeRequest() -> KeyframeRequestPayload? {
        guard header.messageType == .keyframeRequest else { return nil }
        return try? JSONDecoder().decode(KeyframeRequestPayload.self, from: payload)
    }

    public func decodeSetTransport() -> SetTransportPayload? {
        guard header.messageType == .setTransport else { return nil }
        return try? JSONDecoder().decode(SetTransportPayload.self, from: payload)
    }

    public func decodePayload<T: Decodable>(_ type: T.Type) -> T? {
        try? JSONDecoder().decode(type, from: payload)
    }
}

// MARK: - TCP Message Accumulator (De-fragmentation & De-coalescing)

/// Thread-safe accumulator that handles arbitrary TCP chunking, packet fragmentation,
/// packet concatenation, and recovery from stream desynchronization.
public final class MessageAccumulator {
    private var buffer = Data()
    private let lock = NSLock()

    public init() {}

    /// Appends incoming TCP bytes and extracts any complete MirooMessages.
    public func append(_ data: Data) -> [MirooMessage] {
        lock.lock()
        defer { lock.unlock() }

        buffer.append(data)
        var messages: [MirooMessage] = []

        while buffer.count >= MirooHeader.headerSize {
            // Check magic
            guard let header = MirooHeader.deserialize(from: buffer) else {
                // Header deserialization failed (e.g. invalid magic)
                // Search for magic within the buffer to re-sync
                resync()
                continue
            }

            let totalMessageSize = MirooHeader.headerSize + Int(header.payloadLength)
            guard buffer.count >= totalMessageSize else {
                // Incomplete payload; wait for more bytes from TCP stream
                break
            }

            let payloadRange = MirooHeader.headerSize..<totalMessageSize
            let payload = buffer.subdata(in: payloadRange)
            buffer.removeSubrange(0..<totalMessageSize)

            messages.append(MirooMessage(header: header, payload: payload))
        }

        return messages
    }

    /// Searches for the next occurrence of MirooHeader.magicValue (0x4D49524F) and discards invalid leading bytes.
    private func resync() {
        let magicBytes: [UInt8] = [0x4D, 0x49, 0x52, 0x4F] // 'MIRO'
        if let matchRange = buffer.range(of: Data(magicBytes), in: 1..<buffer.count) {
            print("[Miroo Accumulator] Warning: Protocol desynchronization detected. Discarding \(matchRange.lowerBound) corrupt bytes.")
            buffer.removeSubrange(0..<matchRange.lowerBound)
        } else {
            // Keep at most 3 bytes in case the magic is split across TCP reads
            if buffer.count > 3 {
                let bytesToDiscard = buffer.count - 3
                buffer.removeSubrange(0..<bytesToDiscard)
            }
        }
    }

    /// Clears the accumulator buffer.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        buffer.removeAll()
    }
}
