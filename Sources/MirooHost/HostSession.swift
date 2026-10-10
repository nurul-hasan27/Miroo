import Foundation
import Network
import CryptoKit
import CoreVideo
import MirooCore
import MirooMedia
import MirooNet
import MirooSession

/// One Mac -> phone connection: pairing/handshake, then a media pipeline whose three slow parts run in parallel
/// (encoder + UDP flow, virtual display + capture, phone decoder) so the picture appears as soon as the slowest is ready.
public final class HostSession: @unchecked Sendable {
    public enum State: Equatable { case connecting, handshake, pairing(code: String), starting, streaming, ended(String) }
    public var onState: ((State) -> Void)?
    public var onLog: ((String) -> Void)?
    /// The user picked another resolution in System Settings > Displays (index into `VirtualDisplay.lookSteps`).
    public var onLookChanged: ((Int) -> Void)?
    public private(set) var state: State = .connecting
    public var streamerStats: LinkStreamer.Stats? { streamer?.stats }
    public var peer: DeviceInfo? { info }
    /// Panel size currently streamed (pixels), for showing what the chosen resolution "looks like".
    public var streamSize: (width: Int, height: Int)? { cfg.map { ($0.width, $0.height) } }

    /// Switches the display's "looks like" resolution step while streaming.
    public func setLook(_ index: Int) {
        queue.async { [self] in
            guard let src = source else { return }
            Task { await src.setLook(index) }
        }
    }

    private let queue = DispatchQueue(label: "miroo.host.session", qos: .userInteractive)
    private let hostName: String, hostId: String
    private let maxBitrate: Int, fps: Int
    private let pairing: PairingStore
    private let makeSource: (Int, Int, DeviceInfo) async throws -> FrameSource

    // connection
    private var control: ControlChannel?
    private var info: DeviceInfo?
    private var cfg: StreamConfig?
    private var gen = 0
    // handshake
    private var eph: LinkCrypto.EphemeralKey?
    private var secret: SharedSecret?
    private var pubP = Data()
    private var existingPairingKey: Data?
    private var linkSession: LinkSession?
    // media pipeline (queue-confined)
    private var streamer: LinkStreamer?
    private var udp: UDPChannel?
    private var source: FrameSource?
    private var sourceTask: Task<FrameSource, Error>?
    private var sourceDims = (0, 0)
    private var injector: InputInjector?
    private var flowReady = false, sourceReady = false, phoneReady = false
    // startup timing
    private let t0 = LinkClock.nowUs()
    private var marks: [(String, Double)] = []

    public init(hostName: String, hostId: String, maxBitrate: Int = 30_000_000, fps: Int = 60, pairing: PairingStore = .shared,
                makeSource: @escaping (Int, Int, DeviceInfo) async throws -> FrameSource) {
        self.hostName = hostName; self.hostId = hostId; self.maxBitrate = maxBitrate; self.fps = fps
        self.pairing = pairing; self.makeSource = makeSource
    }

    private func log(_ s: String) { onLog?(s) }
    private func set(_ s: State) { state = s; onState?(s) }
    private func mark(_ name: String) { marks.append((name, Double(LinkClock.nowUs() &- t0) / 1000)) }

    // MARK: public

    public func connect(to endpoint: NWEndpoint) {
        queue.async { [self] in
            let conn = NWConnection(to: endpoint, using: ControlChannel.parameters())
            let ch = ControlChannel(connection: conn, queue: queue)
            control = ch
            ch.onMessage = { [weak self] m in self?.handle(m) }
            ch.onState = { [weak self] st in
                guard let self else { return }
                switch st {
                case .failed(let e): self.end("control failed: \(e)")
                case .cancelled: self.end("control closed")
                default: break
                }
            }
            ch.start()
            set(.connecting)
        }
    }

    public func stop(reason: String = "stopped by Mac") {
        queue.async { [self] in
            control?.send(.bye(reason: reason))
            end(reason, keepDisplay: false)             // the user ended it: remove the display now
        }
    }

    // MARK: handshake

    private func handle(_ m: ControlMessage) {
        switch m {
        case .welcome(let d, let peerPub):
            mark("welcome")
            info = d
            log("phone: \(d.name) viewport \(d.pixelWidth)x\(d.pixelHeight) @\(d.scale)x udp:\(d.udpPort) hevc:\(d.supportsHEVC)")
            let e = LinkCrypto.newEphemeral()
            guard let s = LinkCrypto.sharedSecret(e, peerPub: peerPub) else { end("invalid key from phone"); return }
            eph = e; secret = s; pubP = peerPub
            existingPairingKey = pairing.key(for: "phone:" + d.id)
            var proof: Data?
            if let pk = existingPairingKey {
                proof = LinkCrypto.proof(pairingKey: pk, role: .mac, pubM: e.pub, pubP: peerPub, macId: hostId, phoneId: d.id)
                set(.handshake)
            } else {
                // first time with this phone: both screens show the same code; the user approves on the phone
                let code = LinkCrypto.sas(s, pubM: e.pub, pubP: peerPub)
                log("pairing with a new iPhone, code \(code)")
                set(.pairing(code: code))
            }
            control?.send(.hello(hostName: hostName, hostId: hostId, pub: e.pub, proof: proof))

        case .accept(let proof):
            guard let info, let e = eph, let s = secret else { return }
            // a phone we already paired with must prove it still holds that key (no silent re-pairing / impersonation)
            let key = existingPairingKey ?? LinkCrypto.pairingKey(s, pubM: e.pub, pubP: pubP)
            guard LinkCrypto.verify(proof, pairingKey: key, role: .phone, pubM: e.pub, pubP: pubP, macId: hostId, phoneId: info.id) else {
                end(existingPairingKey != nil ? "this iPhone no longer recognizes this Mac – forget it in Miroo and pair again" : "pairing failed", keepDisplay: false)
                return
            }
            if existingPairingKey == nil { pairing.save(key, for: "phone:" + info.id); existingPairingKey = key; log("paired with \(info.name)") }
            let ls = LinkCrypto.session(s, pairingKey: key, pubM: e.pub, pubP: pubP, role: .mac)
            linkSession = ls
            control?.cipher = ls.control               // everything from here on is authenticated + encrypted
            mark("accepted")
            log("phone accepted (encrypted)")
            startStreaming(width: info.pixelWidth, height: info.pixelHeight)

        case .reject(let r):
            end("rejected: \(r)", keepDisplay: false)

        case .ready:
            mark("phone ready")
            phoneReady = true
            maybeGo()

        case .orientation(let w, let h):
            guard let cfg, w != cfg.width || h != cfg.height else { return }
            log("viewport changed -> \(w)x\(h)")
            startStreaming(width: w, height: h)

        case .bye(let r):
            end("phone said bye: \(r)")

        default: break
        }
    }

    // MARK: media pipeline

    /// (Re)starts the pipeline for the given pixel size. Called after the handshake and on every viewport change.
    private func startStreaming(width: Int, height: Int) {
        guard let info else { return }
        set(.starting)
        tearDownMedia(keepSource: source != nil)
        gen += 1
        let myGen = gen
        flowReady = false; phoneReady = false; sourceReady = false
        let codec: Codec = info.supportsHEVC ? .hevc : .h264
        let c = StreamConfig(codec: codec.rawValue, width: width, height: height, fps: min(fps, info.maxFPS), sessionId: UInt32.random(in: 1...UInt32.max))
        cfg = c
        control?.send(.start(c))

        // A) encoder + UDP flow (heavy hardware-encoder setup happens off the session queue)
        let remoteHost: NWEndpoint.Host?
        let iface: NWInterface?
        if let conn = control?.connection, let remote = conn.currentPath?.remoteEndpoint, case let .hostPort(h, _) = remote {
            remoteHost = h; iface = conn.currentPath?.availableInterfaces.first
        } else { remoteHost = nil; iface = nil }
        guard let remoteHost else { end("cannot resolve phone address"); return }
        let udpPort = info.udpPort, cipher = linkSession?.udp, maxBitrate = self.maxBitrate
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                let tEnc = LinkClock.nowUs()
                let ch = UDPChannel.connect(host: remoteHost, port: NWEndpoint.Port(rawValue: udpPort)!, interface: iface, queue: self.queue)
                let s = try LinkStreamer(config: .init(width: c.width, height: c.height, fps: c.fps, codec: codec, maxBitrate: maxBitrate),
                                         channel: ch, cipher: cipher)
                s.onLog = { [weak self] in self?.log($0) }
                self.log("encoder session created in \(Int(Double(LinkClock.nowUs() &- tEnc) / 1000)) ms")
                self.queue.async {
                    guard self.gen == myGen else { s.stop(); return }
                    self.streamer = s; self.udp = ch
                    self.mark("encoder ready")
                    ch.start()
                    self.log("udp -> \(remoteHost):\(udpPort) via \(iface?.name ?? "default")")
                }
                // knock until the phone's first authenticated datagram arrives (opens the flow on its side)
                var tries = 0
                while !s.isConnected, tries < 400 { s.knock(); try? await Task.sleep(nanoseconds: 10_000_000); tries += 1
                    if tries % 20 == 0, await self.isStale(myGen) { return } }
                self.queue.async {
                    guard self.gen == myGen else { return }
                    guard s.isConnected else { self.end("UDP flow never established"); return }
                    self.mark("udp up"); self.log("udp flow established after ~\(tries * 10) ms")
                    self.flowReady = true; self.maybeGo()
                }
            } catch { self.queue.async { self.end("streamer failed: \(error)") } }
        }

        // B) virtual display + capture (reused across rotations)
        let existing = source
        if existing == nil, sourceTask == nil {
            sourceDims = (width, height)
            sourceTask = Task { [makeSource] in try await makeSource(width, height, info) }
        }
        let early = sourceTask, earlyDims = sourceDims
        if early != nil { sourceTask = nil }
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                let src: FrameSource
                if let t = early {
                    let e = try await t.value
                    if earlyDims == (width, height) { src = e }
                    else if await e.resize(width: width, height: height) { src = e }
                    else { await e.stop(); src = try await self.makeSource(width, height, info) }
                } else if let e = existing, await e.resize(width: width, height: height) { src = e }
                else {
                    if let e = existing { await e.stop() }
                    src = try await self.makeSource(width, height, info)
                }
                self.queue.async {
                    guard self.gen == myGen else { if self.source == nil { Task { await src.stop() } }; return }
                    self.source = src; self.sourceReady = true
                    self.mark("source ready"); self.maybeGo()
                }
            } catch { self.queue.async { self.end("source failed: \(error)") } }
        }
    }

    private func isStale(_ g: Int) async -> Bool { await withCheckedContinuation { c in queue.async { c.resume(returning: self.gen != g) } } }

    /// Starts the picture once the encoder/flow, the display capture and the phone's decoder are all ready.
    private func maybeGo() {
        guard flowReady, sourceReady, phoneReady, state != .streaming, let s = streamer, let src = source else { return }
        src.onLookChanged = { [weak self] i in self?.onLookChanged?(i) }
        var first = true
        src.onFrame = { [weak s, weak self] pb, cap in
            if first { first = false; self?.queue.async { self?.mark("first frame"); self?.logStartup() } }
            s?.submit(pb, captureUs: cap)
        }
        if src.inputBounds != nil {
            if !InputInjector.hasAccessibility(prompt: true) { log("Accessibility permission missing: touches will not move the cursor until it is granted") }
            let inj = InputInjector(displayBounds: { [weak src] in src?.inputBounds ?? .zero })
            injector = inj
            s.onInput = { inj.apply($0) }
        }
        set(.streaming)
    }

    private func logStartup() { log("startup: " + marks.map { "\($0.0) \(Int($0.1)) ms" }.joined(separator: " → ")) }

    // MARK: teardown

    private func tearDownMedia(keepSource: Bool = false, suspendSource: Bool = false) {
        injector?.releaseAll(); injector = nil
        streamer?.stop(); streamer = nil
        udp?.cancel(); udp = nil
        if let src = source {
            src.onFrame = nil
            if !keepSource { source = nil; Task { if suspendSource { await src.suspend() } else { await src.stop() } } }
        }
        flowReady = false; phoneReady = false
        if !keepSource { sourceReady = false }
    }

    /// `keepDisplay`: after an unexpected end (phone locked, Wi-Fi drop) the virtual display lingers briefly so a reconnect is instant.
    private func end(_ reason: String, keepDisplay: Bool = true) {
        if case .ended = state { return }
        gen += 1
        if let t = sourceTask { sourceTask = nil; Task { if let s = try? await t.value { if keepDisplay { await s.suspend() } else { await s.stop() } } } }
        tearDownMedia(suspendSource: keepDisplay)
        control?.cancel(); control = nil
        set(.ended(reason))
    }
}
