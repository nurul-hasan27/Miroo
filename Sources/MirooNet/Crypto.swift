import Foundation
import CryptoKit
import Security

public enum LinkRole: String, Sendable { case mac, phone }

/// Authenticated encryption of UDP datagrams (ChaCha20-Poly1305). The 24-byte header stays readable; bytes 0..<20 are
/// authenticated (the send timestamp at 20..<24 is patched at departure time and deliberately not covered).
/// Nonce = packet kind + packet sequence, unique per direction because each direction has its own key.
public final class PacketCipher: @unchecked Sendable {
    private let sendKey: SymmetricKey, recvKey: SymmetricKey
    public static let overhead = 16
    public init(sendKey: SymmetricKey, recvKey: SymmetricKey) { self.sendKey = sendKey; self.recvKey = recvKey }

    private static func nonce(kind: UInt8, seq: UInt32) throws -> ChaChaPoly.Nonce {
        var n = Data(count: 12)
        n[0] = kind
        n[4] = UInt8(seq & 0xFF); n[5] = UInt8((seq >> 8) & 0xFF); n[6] = UInt8((seq >> 16) & 0xFF); n[7] = UInt8(seq >> 24)
        return try ChaChaPoly.Nonce(data: n)
    }

    /// `datagram` = 24-byte header + plaintext body. Returns header + ciphertext + tag.
    public func seal(_ datagram: [UInt8]) -> [UInt8]? {
        guard datagram.count >= 24 else { return nil }
        let kind = datagram[1] & 0x0F
        let seq = UInt32(datagram[4]) | UInt32(datagram[5]) << 8 | UInt32(datagram[6]) << 16 | UInt32(datagram[7]) << 24
        guard let nonce = try? Self.nonce(kind: kind, seq: seq),
              let box = try? ChaChaPoly.seal(Data(datagram[24...]), using: sendKey, nonce: nonce, authenticating: Data(datagram[0..<20])) else { return nil }
        var out = Array(datagram[0..<24])
        out.append(contentsOf: box.ciphertext); out.append(contentsOf: box.tag)
        return out
    }

    /// Returns header + plaintext body, or nil if the datagram fails authentication.
    public func open(_ buf: UnsafeRawBufferPointer) -> [UInt8]? {
        guard buf.count >= 24 + Self.overhead else { return nil }
        let kind = buf[1] & 0x0F
        let seq = UInt32(buf[4]) | UInt32(buf[5]) << 8 | UInt32(buf[6]) << 16 | UInt32(buf[7]) << 24
        let ct = Data(buf[24..<(buf.count - Self.overhead)]), tag = Data(buf[(buf.count - Self.overhead)...])
        guard let nonce = try? Self.nonce(kind: kind, seq: seq),
              let box = try? ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ct, tag: tag),
              let plain = try? ChaChaPoly.open(box, using: recvKey, authenticating: Data(buf[0..<20])) else { return nil }
        var out = Array(buf[0..<24])
        out.append(contentsOf: plain)
        return out
    }
}

/// Authenticated encryption of control-channel messages after the handshake (counter nonces per direction).
public final class ControlCipher: @unchecked Sendable {
    private let sendKey: SymmetricKey, recvKey: SymmetricKey
    private var sendCounter: UInt64 = 0
    private let lock = NSLock()
    public init(sendKey: SymmetricKey, recvKey: SymmetricKey) { self.sendKey = sendKey; self.recvKey = recvKey }

    private static func nonce(_ c: UInt64) throws -> ChaChaPoly.Nonce {
        var n = Data(count: 12)
        for i in 0..<8 { n[4 + i] = UInt8((c >> UInt64(8 * i)) & 0xFF) }
        return try ChaChaPoly.Nonce(data: n)
    }
    /// 8-byte counter + ciphertext + tag
    public func seal(_ plain: Data) -> Data? {
        lock.lock(); sendCounter += 1; let c = sendCounter; lock.unlock()
        guard let n = try? Self.nonce(c), let box = try? ChaChaPoly.seal(plain, using: sendKey, nonce: n) else { return nil }
        var out = Data(); for i in 0..<8 { out.append(UInt8((c >> UInt64(8 * i)) & 0xFF)) }
        out.append(box.ciphertext); out.append(box.tag)
        return out
    }
    public func open(_ data: Data) -> Data? {
        guard data.count >= 8 + 16 else { return nil }
        let b = [UInt8](data)
        var c: UInt64 = 0
        for i in 0..<8 { c |= UInt64(b[i]) << UInt64(8 * i) }
        guard let n = try? Self.nonce(c), let box = try? ChaChaPoly.SealedBox(nonce: n, ciphertext: Data(b[8..<(b.count - 16)]), tag: Data(b[(b.count - 16)...])) else { return nil }
        return try? ChaChaPoly.open(box, using: recvKey)
    }
}

/// Everything derived from one handshake.
public struct LinkSession: @unchecked Sendable {
    public let udp: PacketCipher
    public let control: ControlCipher
}

public enum LinkCrypto {
    public struct EphemeralKey { public let priv: Curve25519.KeyAgreement.PrivateKey; public var pub: Data { priv.publicKey.rawRepresentation } }
    public static func newEphemeral() -> EphemeralKey { EphemeralKey(priv: Curve25519.KeyAgreement.PrivateKey()) }

    public static func sharedSecret(_ k: EphemeralKey, peerPub: Data) -> SharedSecret? {
        guard let p = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPub) else { return nil }
        return try? k.priv.sharedSecretFromKeyAgreement(with: p)
    }

    private static func salt(_ pubM: Data, _ pubP: Data) -> Data { pubM + pubP }

    /// 4-digit code both screens show during first-time pairing; a man-in-the-middle ends up with different codes.
    public static func sas(_ s: SharedSecret, pubM: Data, pubP: Data) -> String {
        let k = s.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt(pubM, pubP), sharedInfo: Data("miroo sas".utf8), outputByteCount: 4)
        let v = k.withUnsafeBytes { $0.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } } % 10_000
        return String(format: "%04d", v)
    }

    /// Long-term key stored by both sides after the user approved a pairing.
    public static func pairingKey(_ s: SharedSecret, pubM: Data, pubP: Data) -> Data {
        s.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt(pubM, pubP), sharedInfo: Data("miroo pairing".utf8), outputByteCount: 32).withUnsafeBytes { Data($0) }
    }

    /// Proof of holding the pairing key, bound to this handshake (both ephemeral keys and both ids).
    public static func proof(pairingKey: Data, role: LinkRole, pubM: Data, pubP: Data, macId: String, phoneId: String) -> Data {
        var m = Data(role.rawValue.utf8); m += pubM; m += pubP; m += Data(macId.utf8); m += Data([0]); m += Data(phoneId.utf8)
        return Data(HMAC<SHA256>.authenticationCode(for: m, using: SymmetricKey(data: pairingKey)))
    }
    public static func verify(_ proof: Data, pairingKey: Data, role: LinkRole, pubM: Data, pubP: Data, macId: String, phoneId: String) -> Bool {
        var m = Data(role.rawValue.utf8); m += pubM; m += pubP; m += Data(macId.utf8); m += Data([0]); m += Data(phoneId.utf8)
        return HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: m, using: SymmetricKey(data: pairingKey))
    }

    /// Session ciphers; `role` selects which direction is "send".
    public static func session(_ s: SharedSecret, pairingKey: Data, pubM: Data, pubP: Data, role: LinkRole) -> LinkSession {
        func key(_ info: String) -> SymmetricKey {
            // mix the pairing key into the salt so a passive observer who learned only the ECDH share still cannot derive keys
            s.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt(pubM, pubP) + pairingKey, sharedInfo: Data(info.utf8), outputByteCount: 32)
        }
        let m2p = key("miroo udp m2p"), p2m = key("miroo udp p2m"), cm2p = key("miroo ctl m2p"), cp2m = key("miroo ctl p2m")
        return role == .mac
            ? LinkSession(udp: PacketCipher(sendKey: m2p, recvKey: p2m), control: ControlCipher(sendKey: cm2p, recvKey: cp2m))
            : LinkSession(udp: PacketCipher(sendKey: p2m, recvKey: m2p), control: ControlCipher(sendKey: cp2m, recvKey: cm2p))
    }
}

/// Long-term pairing keys, one per peer, in the Keychain.
public final class PairingStore: @unchecked Sendable {
    public static let shared = PairingStore(service: "com.nurulhasan.miroo.pairing")
    private let service: String
    public init(service: String) { self.service = service }

    public func key(for peerId: String) -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: peerId, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }
    public func save(_ key: Data, for peerId: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: peerId]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = key
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
    /// This device's own stable identity (created once, kept in the Keychain so every Miroo binary on the Mac shares it).
    public func localIdentity() -> String {
        if let d = key(for: "self:identity"), let s = String(data: d, encoding: .utf8) { return s }
        let id = UUID().uuidString
        save(Data(id.utf8), for: "self:identity")
        return id
    }

    public func forget(_ peerId: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: peerId] as CFDictionary)
    }
}
