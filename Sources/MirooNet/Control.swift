import Foundation
import Network
import MirooCore

/// Setup / teardown messages. Rare and reliable (TCP). Everything real-time travels over UDP.
public struct DeviceInfo: Codable, Equatable, Sendable {
    public var name: String
    public var id: String
    public var pixelWidth: Int          // native panel pixels, portrait orientation (e.g. 828 x 1792)
    public var pixelHeight: Int
    public var scale: Int               // 2 for iPhone 11
    public var maxFPS: Int
    public var supportsHEVC: Bool
    public var udpPort: UInt16
    public init(name: String, id: String, pixelWidth: Int, pixelHeight: Int, scale: Int, maxFPS: Int,
                supportsHEVC: Bool, udpPort: UInt16) {
        self.name = name; self.id = id; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        self.scale = scale; self.maxFPS = maxFPS; self.supportsHEVC = supportsHEVC; self.udpPort = udpPort
    }
}

public struct StreamConfig: Codable, Equatable, Sendable {
    public var codec: UInt8             // Codec.rawValue
    public var width: Int               // current orientation pixels
    public var height: Int
    public var fps: Int
    public var sessionId: UInt32
    public var key: [UInt8]             // 32-byte session key (AEAD) – empty = plaintext
    public init(codec: UInt8, width: Int, height: Int, fps: Int, sessionId: UInt32, key: [UInt8] = []) {
        self.codec = codec; self.width = width; self.height = height; self.fps = fps; self.sessionId = sessionId; self.key = key
    }
}

public enum ControlMessage: Codable, Equatable, Sendable {
    case welcome(DeviceInfo, pub: Data)         // phone -> mac, first message (+ ephemeral X25519 key)
    /// mac -> phone. `proof` is present when the Mac already holds a pairing key for this phone.
    case hello(hostName: String, hostId: String, pub: Data, proof: Data?)
    /// phone -> mac. HMAC proving the phone holds the (new or existing) pairing key; everything after is encrypted.
    case accept(proof: Data)
    case reject(reason: String)
    case start(StreamConfig)                    // mac -> phone
    case ready                                  // phone -> mac: decoder + UDP up
    case orientation(width: Int, height: Int)   // phone -> mac (viewport changed)
    case reconfigure(StreamConfig)              // mac -> phone
    case bye(reason: String)
}

/// Length-prefixed JSON messages over TCP.
public final class ControlChannel: @unchecked Sendable {
    public let connection: NWConnection
    private let queue: DispatchQueue
    private var buffer = Data()
    /// Set once the handshake is complete: all later messages are sealed.
    public var cipher: ControlCipher?
    public var onMessage: ((ControlMessage) -> Void)?
    public var onState: ((NWConnection.State) -> Void)?

    public init(connection: NWConnection, queue: DispatchQueue) { self.connection = connection; self.queue = queue }

    public static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2; tcp.keepaliveInterval = 1; tcp.keepaliveCount = 3
        let p = NWParameters(tls: nil, tcp: tcp)
        p.includePeerToPeer = true
        p.serviceClass = .interactiveVoice
        return p
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] s in self?.onState?(s) }
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self else { return }
            if let data { self.buffer.append(data); self.drain() }
            if done || err != nil { return }
            self.receive()
        }
    }

    private func drain() {
        while buffer.count >= 4 {
            let len = Int(buffer[buffer.startIndex]) | Int(buffer[buffer.startIndex + 1]) << 8
                | Int(buffer[buffer.startIndex + 2]) << 16 | Int(buffer[buffer.startIndex + 3]) << 24
            guard len < 1_000_000 else { cancel(); return }
            guard buffer.count >= 4 + len else { return }
            let body = buffer.subdata(in: (buffer.startIndex + 4)..<(buffer.startIndex + 4 + len))
            buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + 4 + len))
            var plain: Data? = body
            if let c = cipher { plain = c.open(body) }
            if let plain, let m = try? JSONDecoder().decode(ControlMessage.self, from: plain) { onMessage?(m) }
        }
    }

    public func send(_ m: ControlMessage) {
        guard var body = try? JSONEncoder().encode(m) else { return }
        if let c = cipher { guard let sealed = c.seal(body) else { return }; body = sealed }
        var framed = Data()
        var w = ByteWriter(); w.u32(UInt32(body.count)); framed.append(contentsOf: w.bytes); framed.append(body)
        connection.send(content: framed, completion: .idempotent)
    }

    public func cancel() { connection.cancel() }
}
