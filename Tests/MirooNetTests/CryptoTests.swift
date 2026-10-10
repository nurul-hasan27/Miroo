import XCTest
import CryptoKit
@testable import MirooNet
@testable import MirooCore

final class CryptoTests: XCTestCase {
    private func handshake() -> (mac: LinkSession, phone: LinkSession, sas: (String, String), pk: (Data, Data), pubM: Data, pubP: Data) {
        let m = LinkCrypto.newEphemeral(), p = LinkCrypto.newEphemeral()
        let sm = LinkCrypto.sharedSecret(m, peerPub: p.pub)!, sp = LinkCrypto.sharedSecret(p, peerPub: m.pub)!
        let pkM = LinkCrypto.pairingKey(sm, pubM: m.pub, pubP: p.pub), pkP = LinkCrypto.pairingKey(sp, pubM: m.pub, pubP: p.pub)
        return (LinkCrypto.session(sm, pairingKey: pkM, pubM: m.pub, pubP: p.pub, role: .mac),
                LinkCrypto.session(sp, pairingKey: pkP, pubM: m.pub, pubP: p.pub, role: .phone),
                (LinkCrypto.sas(sm, pubM: m.pub, pubP: p.pub), LinkCrypto.sas(sp, pubM: m.pub, pubP: p.pub)), (pkM, pkP), m.pub, p.pub)
    }

    private func datagram(kind: PacketKind, seq: UInt32, body: [UInt8]) -> [UInt8] {
        var w = ByteWriter()
        PacketHeader(kind: kind, packetSeq: seq, frameId: 7, frameLen: UInt32(body.count), index: 1, k: 3, m: 1, sendTimeUs: 99).write(into: &w)
        w.raw(body)
        return w.bytes
    }

    func testBothSidesDeriveSameCodeAndKeys() {
        let h = handshake()
        XCTAssertEqual(h.sas.0, h.sas.1)
        XCTAssertEqual(h.sas.0.count, 4)
        XCTAssertEqual(h.pk.0, h.pk.1)
        // mac -> phone and phone -> mac both work
        let a = datagram(kind: .data, seq: 5, body: Array(repeating: 0xAB, count: 1000))
        let sealed = h.mac.udp.seal(a)!
        XCTAssertEqual(sealed.count, a.count + PacketCipher.overhead)
        XCTAssertNotEqual(Array(sealed[24..<64]), Array(a[24..<64]), "payload must be encrypted")
        XCTAssertEqual(sealed.withUnsafeBytes { h.phone.udp.open($0) }, a)
        let f = datagram(kind: .feedback, seq: 1, body: [1, 2, 3])
        XCTAssertEqual(h.phone.udp.seal(f)!.withUnsafeBytes { h.mac.udp.open($0) }, f)
    }

    func testTamperingWrongKeyAndWrongDirectionAreRejected() {
        let h = handshake(), other = handshake()
        let a = datagram(kind: .data, seq: 9, body: Array(repeating: 7, count: 300))
        var sealed = h.mac.udp.seal(a)!
        // flip a payload bit
        sealed[100] ^= 1
        XCTAssertNil(sealed.withUnsafeBytes { h.phone.udp.open($0) })
        // flip an authenticated header byte (frameId)
        var s2 = h.mac.udp.seal(a)!; s2[8] ^= 1
        XCTAssertNil(s2.withUnsafeBytes { h.phone.udp.open($0) })
        // the send timestamp (patched at departure) is intentionally not authenticated
        var s3 = h.mac.udp.seal(a)!; s3[20] ^= 0xFF
        XCTAssertNotNil(s3.withUnsafeBytes { h.phone.udp.open($0) })
        // a different session cannot decrypt
        XCTAssertNil(h.mac.udp.seal(a)!.withUnsafeBytes { other.phone.udp.open($0) })
        // a Mac cannot read its own datagram (reflection): receive key is the other direction
        XCTAssertNil(h.mac.udp.seal(a)!.withUnsafeBytes { h.mac.udp.open($0) })
    }

    func testProofBindsHandshakeAndKey() {
        let h = handshake()
        let proof = LinkCrypto.proof(pairingKey: h.pk.0, role: .mac, pubM: h.pubM, pubP: h.pubP, macId: "mac-1", phoneId: "phone-1")
        XCTAssertTrue(LinkCrypto.verify(proof, pairingKey: h.pk.1, role: .mac, pubM: h.pubM, pubP: h.pubP, macId: "mac-1", phoneId: "phone-1"))
        XCTAssertFalse(LinkCrypto.verify(proof, pairingKey: Data(repeating: 1, count: 32), role: .mac, pubM: h.pubM, pubP: h.pubP, macId: "mac-1", phoneId: "phone-1"))
        XCTAssertFalse(LinkCrypto.verify(proof, pairingKey: h.pk.1, role: .phone, pubM: h.pubM, pubP: h.pubP, macId: "mac-1", phoneId: "phone-1"), "roles must not be interchangeable")
        XCTAssertFalse(LinkCrypto.verify(proof, pairingKey: h.pk.1, role: .mac, pubM: h.pubM, pubP: h.pubP, macId: "mac-2", phoneId: "phone-1"))
    }

    func testManInTheMiddleSeesDifferentCodes() {
        let m = LinkCrypto.newEphemeral(), p = LinkCrypto.newEphemeral(), x1 = LinkCrypto.newEphemeral(), x2 = LinkCrypto.newEphemeral()
        // attacker substitutes its own keys in each direction
        let macSide = LinkCrypto.sharedSecret(m, peerPub: x1.pub)!, phoneSide = LinkCrypto.sharedSecret(p, peerPub: x2.pub)!
        let c1 = LinkCrypto.sas(macSide, pubM: m.pub, pubP: x1.pub), c2 = LinkCrypto.sas(phoneSide, pubM: x2.pub, pubP: p.pub)
        XCTAssertNotEqual(c1, c2)
    }

    func testControlCipherRoundTripAndReplayOrder() {
        let h = handshake()
        let msg = Data("{\"start\":{}}".utf8)
        let a = h.mac.control.seal(msg)!, b = h.mac.control.seal(msg)!
        XCTAssertNotEqual(a, b, "counter nonce changes every message")
        XCTAssertEqual(h.phone.control.open(a), msg)
        XCTAssertEqual(h.phone.control.open(b), msg)
        var bad = a; bad[10] ^= 1
        XCTAssertNil(h.phone.control.open(bad))
    }

    func testKeychainPairingStoreRoundTrip() {
        let store = PairingStore(service: "com.nurulhasan.miroo.pairing.tests")
        let id = "test-peer-\(UUID().uuidString)"
        XCTAssertNil(store.key(for: id))
        let k = Data((0..<32).map { UInt8($0) })
        store.save(k, for: id)
        XCTAssertEqual(store.key(for: id), k)
        store.forget(id)
        XCTAssertNil(store.key(for: id))
    }
}
