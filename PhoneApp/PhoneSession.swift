import SwiftUI
import Network
import UIKit
import CryptoKit
import MirooCore
import MirooMedia
import MirooNet
import MirooSession

enum PhonePhase: Equatable { case starting, waiting, asking(String, code: String), connecting(String), streaming(String) }
struct HUDStats { var fps = 0.0, mbps = 0.0, decodeMs = 0.0, queueMs = 0.0, repaired = 0, lost = 0, recoveries = 0, gapP95 = 0.0, gapMax = 0.0 }

/// SwiftUI-facing state. All networking lives in `PhoneEngine`.
@MainActor
final class PhoneSession: ObservableObject {
    @Published private(set) var phase: PhonePhase = .starting
    @Published var showHUD = ProcessInfo.processInfo.arguments.contains("--hud")
    @Published private(set) var hud = HUDStats()
    let deviceName = UIDevice.current.name
    let renderer = DisplayLayerRenderer()
    private let engine: PhoneEngine

    init() {
        engine = PhoneEngine(deviceName: UIDevice.current.name, renderer: renderer)
        engine.onPhase = { [weak self] p in Task { @MainActor in self?.phase = p } }
        engine.onHUD = { [weak self] h in Task { @MainActor in self?.hud = h } }
        engine.start()
    }

    var statusText: String {
        switch phase {
        case .starting: return "Starting…"
        case .connecting(let m): return "Connecting to \(m)…"
        default: return "Ready"
        }
    }
    func setActive(_ active: Bool) { engine.setActive(active) }
    func respond(allow: Bool) { engine.respond(allow: allow) }
    func sendInput(_ k: InputKind, _ x: Float, _ y: Float) { engine.sendInput(k, x: x, y: y) }
    func viewportChanged(points: CGSize) {
        let s = UIScreen.main.nativeScale
        engine.viewportChanged(px: CGSize(width: (points.width * s / 2).rounded() * 2, height: (points.height * s / 2).rounded() * 2))
    }
}

/// The phone is the *server*: it advertises itself, the Mac connects, video flows back over UDP.
/// Everything here is confined to `queue`.
final class PhoneEngine: @unchecked Sendable {
    var onPhase: ((PhonePhase) -> Void)?
    var onHUD: ((HUDStats) -> Void)?

    private let queue = DispatchQueue(label: "miroo.phone", qos: .userInteractive)
    private let deviceName: String
    private let renderer: DisplayLayerRenderer
    private let deviceId: String
    private let autoAccept = ProcessInfo.processInfo.arguments.contains("--auto-accept")
    private var advertiser: LinkAdvertiser?
    private var udp: UDPServer?
    private var udpPort: UInt16 = 0
    private var control: ControlChannel?
    private var receiver: LinkReceiver?
    private var pendingFlow: (UDPChannel, [UInt8], UInt64)?
    /// Flows waiting for their first authenticated datagram. Held strongly (nothing else owns them yet); at most a few.
    private var candidateFlows: [UDPChannel] = []
    private var hostName = "", hostId = ""
    private var viewportPx = CGSize(width: 828, height: 1636)
    private var lastSentViewport = CGSize.zero
    private var statsTimer: DispatchSourceTimer?
    private var phase: PhonePhase = .starting
    private let inputSender = InputSender(redundancy: 8)
    // handshake
    private var eph: LinkCrypto.EphemeralKey?
    private var secret: SharedSecret?
    private var pubM = Data()
    private var session: LinkSession?

    init(deviceName: String, renderer: DisplayLayerRenderer) {
        self.deviceName = deviceName; self.renderer = renderer
        let k = "miroo.deviceId"
        if let v = UserDefaults.standard.string(forKey: k) { deviceId = v }
        else { let v = UUID().uuidString; UserDefaults.standard.set(v, forKey: k); deviceId = v }
    }

    func start() {
        queue.async { [self] in
            do {
                let server = try UDPServer(queue: queue)
                server.onReady = { [weak self] port in self?.queue.async { self?.udpPort = port.rawValue; self?.advertise() } }
                server.onFlow = { [weak self] flow in self?.queue.async { self?.flowArrived(flow) } }
                udp = server
                server.start()
            } catch { print("[phone] UDP server failed: \(error)") }
        }
    }

    private func setPhase(_ p: PhonePhase) { phase = p; onPhase?(p) }

    private func advertise() {
        let adv = LinkAdvertiser(queue: queue)
        adv.onConnection = { [weak self] c in self?.queue.async { self?.accepted(c) } }
        do { try adv.start(name: deviceName, deviceId: deviceId) } catch { print("[phone] advertise failed: \(error)") }
        advertiser = adv
        setPhase(.waiting)
        print("[phone] advertising '\(deviceName)' udpPort=\(udpPort)")
    }

    /// Touch/gesture event from the UI. Sent immediately; terminal events are repeated to survive loss.
    func sendInput(_ kind: InputKind, x: Float, y: Float) {
        queue.async { [self] in
            guard case .streaming = phase, let r = receiver else { return }
            inputSender.add(kind, x: x, y: y)
            r.sendRaw(inputSender.packet(nowUs32: LinkClock.nowUs32()))
            if kind == .up || kind == .cancel || kind == .scrollEnd || kind == .secondaryClick {
                for ms in [6, 16, 40] {
                    queue.asyncAfter(deadline: .now() + .milliseconds(ms)) { [weak self] in
                        guard let self, let r = self.receiver else { return }
                        r.sendRaw(self.inputSender.packet(nowUs32: LinkClock.nowUs32()))
                    }
                }
            }
        }
    }

    func setActive(_ active: Bool) {
        if active {
            // Back in the foreground: refresh the Bonjour record so a Mac that was waiting notices immediately.
            queue.async { [self] in
                guard advertiser != nil else { return }
                advertiser?.stop(); advertiser = nil
                advertise()
            }
            return
        }
        queue.async { [self] in
            if case .streaming = phase { control?.send(.bye(reason: "iPhone app left the foreground")) }
            teardownStream(reason: "app inactive")
            if phase != .starting { setPhase(.waiting) }
        }
    }

    func viewportChanged(px: CGSize) {
        guard px.width > 0, px.height > 0 else { return }
        queue.async { [self] in
            viewportPx = px
            if case .streaming = phase, px != lastSentViewport {
                lastSentViewport = px
                control?.send(.orientation(width: Int(px.width), height: Int(px.height)))
            }
        }
    }

    // MARK: control channel + handshake

    private func accepted(_ conn: NWConnection) {
        // A healthy stream is not hijacked by a second Mac (or a stale client): turn the newcomer away politely.
        if case .streaming = phase, let r = receiver, r.lastMediaUs != 0, LinkClock.nowUs() &- r.lastMediaUs < 2_000_000 {
            let busy = ControlChannel(connection: conn, queue: queue)
            busy.start()
            busy.send(.reject(reason: "iPhone is already showing \(hostName)"))
            queue.asyncAfter(deadline: .now() + 0.5) { busy.cancel() }
            print("[phone] refused a second connection while streaming")
            return
        }
        teardownStream(reason: "new connection")
        control?.cancel()
        let ch = ControlChannel(connection: conn, queue: queue)
        control = ch
        ch.onMessage = { [weak self, weak ch] m in if let ch { self?.handle(m, from: ch) } }
        ch.onState = { [weak self, weak ch] st in
            guard let self, let ch, self.control === ch else { return }
            switch st {
            case .failed, .cancelled: self.teardownStream(reason: "control closed"); self.setPhase(.waiting)
            default: break
            }
        }
        ch.start()
        let e = LinkCrypto.newEphemeral()
        eph = e; secret = nil; session = nil
        ch.send(.welcome(DeviceInfo(name: deviceName, id: deviceId, pixelWidth: Int(viewportPx.width), pixelHeight: Int(viewportPx.height),
                                    scale: Int(UIScreen.main.nativeScale), maxFPS: 60, supportsHEVC: true, udpPort: udpPort), pub: e.pub))
    }

    private func handle(_ m: ControlMessage, from ch: ControlChannel) {
        switch m {
        case let .hello(name, id, macPub, proof):
            hostName = name; hostId = id
            guard let e = eph, let sec = LinkCrypto.sharedSecret(e, peerPub: macPub) else {
                ch.send(.reject(reason: "invalid key")); ch.cancel(); return
            }
            secret = sec; pubM = macPub
            if let pk = PairingStore.shared.key(for: "mac:" + id), let proof,
               LinkCrypto.verify(proof, pairingKey: pk, role: .mac, pubM: macPub, pubP: e.pub, macId: id, phoneId: deviceId) {
                complete(with: pk, control: ch)                       // a Mac we already paired with, proven by its key
            } else if autoAccept {
                pairNow(control: ch)                                   // development shortcut (--auto-accept)
            } else {
                setPhase(.asking(name, code: LinkCrypto.sas(sec, pubM: macPub, pubP: e.pub)))
            }
        case let .start(cfg), let .reconfigure(cfg):
            guard session != nil else { return }                       // never stream before the handshake completed
            startStream(cfg, control: ch)
        case let .bye(reason):
            print("[phone] bye: \(reason)")
            teardownStream(reason: "bye"); setPhase(.waiting)
        default: break
        }
    }

    /// UI: the user pressed Allow / Not now on the pairing prompt.
    func respond(allow: Bool) {
        queue.async { [self] in
            guard let ch = control else { return }
            if allow { pairNow(control: ch) } else { ch.send(.reject(reason: "declined on iPhone")); ch.cancel(); setPhase(.waiting) }
        }
    }

    /// The user approved the code: remember this Mac (Keychain) and finish the handshake.
    private func pairNow(control ch: ControlChannel) {
        guard let e = eph, let s = secret else { return }
        let pk = LinkCrypto.pairingKey(s, pubM: pubM, pubP: e.pub)
        PairingStore.shared.save(pk, for: "mac:" + hostId)
        complete(with: pk, control: ch)
    }

    private func complete(with pk: Data, control ch: ControlChannel) {
        guard let e = eph, let s = secret else { return }
        let proof = LinkCrypto.proof(pairingKey: pk, role: .phone, pubM: pubM, pubP: e.pub, macId: hostId, phoneId: deviceId)
        let ls = LinkCrypto.session(s, pairingKey: pk, pubM: pubM, pubP: e.pub, role: .phone)
        ch.send(.accept(proof: proof))
        ch.cipher = ls.control                    // everything after `accept` is sealed
        session = ls
        setPhase(.connecting(hostName))
    }

    // MARK: streaming (queue)

    private func startStream(_ cfg: StreamConfig, control ch: ControlChannel) {
        if receiver == nil {
            let r = LinkReceiver(queue: queue)
            let layer = renderer
            r.onFrame = { pb in layer.show(pb) }
            r.cipher = session?.udp
            receiver = r
            if let (f, first, at) = pendingFlow { r.attach(f, first: first, firstAtUs: at); pendingFlow = nil }
            startStatsTimer()
        }
        lastSentViewport = CGSize(width: cfg.width, height: cfg.height)
        ch.send(.ready)
        setPhase(.streaming(hostName))
        print("[phone] stream start \(cfg.width)x\(cfg.height) codec=\(cfg.codec) fps=\(cfg.fps)")
    }

    /// A new UDP flow only becomes the video flow once its first datagram authenticates with this session's key.
    private func flowArrived(_ flow: UDPChannel) {
        guard let c = session?.udp else { flow.cancel(); return }
        candidateFlows.append(flow)
        if candidateFlows.count > 4 { candidateFlows.removeFirst().cancel() }       // stray traffic can't pile up
        flow.onDatagram = { [weak self, weak flow] buf, now in
            guard let self, let flow, c.open(buf) != nil else { return }            // forged / stray traffic never gets attached
            flow.onDatagram = nil
            self.candidateFlows.removeAll { $0 === flow }
            for other in self.candidateFlows { other.cancel() }
            self.candidateFlows.removeAll()
            let first = Array(buf)
            if let r = self.receiver { r.attach(flow, first: first, firstAtUs: now) } else { self.pendingFlow = (flow, first, now) }
        }
    }

    private func teardownStream(reason: String) {
        statsTimer?.cancel(); statsTimer = nil
        receiver?.stop(); receiver = nil
        pendingFlow?.0.cancel(); pendingFlow = nil
        candidateFlows.forEach { $0.cancel() }; candidateFlows.removeAll()
        session = nil
        print("[phone] stream torn down (\(reason))")
    }

    private func startStatsTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self, let r = self.receiver else { return }
            let s = r.stats
            print(String(format: "[phone] %.0f fps %.1f Mbps decode %.1f ms qdelay %.1f ms repaired %d lost %d recov %d | frame gap p50 %.1f p95 %.1f max %.0f ms",
                         s.fps, s.mbps, s.decodeMsAvg, s.queueDelayMs, s.framesRepaired, s.framesLost, s.recoveryRequests, s.gapP50Ms, s.gapP95Ms, s.gapMaxMs))
            let lp = r.lossProfile
            print(String(format: "[phone-net] pkts %d lost %d (%.2f%%) reordered %d dup %d bursts[1,2,3,4-7,8+]=%@ maxGap %.0f ms",
                         lp.received, lp.lost, lp.lossPct, lp.reordered, lp.duplicates, lp.bursts.map(String.init).joined(separator: ","), lp.maxArrivalGapMs))
            self.onHUD?(HUDStats(fps: s.fps, mbps: s.mbps, decodeMs: s.decodeMsAvg, queueMs: s.queueDelayMs,
                                 repaired: s.framesRepaired, lost: s.framesLost, recoveries: s.recoveryRequests, gapP95: s.gapP95Ms, gapMax: s.gapMaxMs))
        }
        t.resume(); statsTimer = t
    }
}
