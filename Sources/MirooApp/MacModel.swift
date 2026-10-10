import SwiftUI
import AppKit
import Network
import ServiceManagement
import MirooCore
import MirooNet
import CryptoKit
import MirooSession
import MirooHost
import MirooMedia

@MainActor
final class MacModel: ObservableObject {
    struct Phone: Identifiable, Equatable {
        var id: String; var name: String; var endpoint: NWEndpoint
        static func == (a: Phone, b: Phone) -> Bool { a.id == b.id && a.name == b.name }
    }
    enum Link: Equatable { case idle, connecting(String), pairing(String, code: String), streaming(String), failed(String) }

    @Published private(set) var phones: [Phone] = []
    @Published private(set) var link: Link = .idle
    @Published private(set) var statsLine = ""
    @Published private(set) var lookLabel = ""
    @Published private(set) var screenOK = CGPreflightScreenCaptureAccess()
    @Published private(set) var accessibilityOK = AXIsProcessTrusted()

    // settings (UserDefaults-backed)
    @AppStorage("autoConnect") var autoConnect = true
    @AppStorage("maxBitrateMbps") var maxBitrateMbps = 30.0
    @AppStorage("fps") var fps = 60
    /// "Looks like" step of the iPhone display: 0 = biggest text … 5 = most room. Also changeable in System Settings > Displays.
    @AppStorage("lookIndex") var lookIndex = 0 { didSet { if oldValue != lookIndex { session?.setLook(lookIndex) } } }
    var lookRange: ClosedRange<Double> { 0...Double(VirtualDisplay.lookSteps.count - 1) }
    @AppStorage("launchAtLogin") var launchAtLogin = false { didSet { applyLaunchAtLogin() } }
    @AppStorage("knownPhones") private var knownPhonesRaw = ""

    private let browser = LinkBrowser(queue: DispatchQueue(label: "miroo.mac.browse"))
    private var session: HostSession?
    private var activePhone: Phone?
    private var userStopped = false
    private var retryTask: Task<Void, Never>?
    private var retryDelay: Double = 1
    private var timer: Timer?
    private let hostId = PairingStore.shared.localIdentity()

    init() {
        Task.detached(priority: .utility) { LinkEncoder.warmUp() }
        if CGPreflightScreenCaptureAccess() { ScreenCapturer.warmUp() }
        browser.onChange = { [weak self] found in
            Task { @MainActor in self?.found(found) }
        }
        browser.start()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    // MARK: discovery

    private var knownPhones: Set<String> {
        get { Set(knownPhonesRaw.split(separator: ",").map(String.init)) }
        set { knownPhonesRaw = newValue.sorted().joined(separator: ",") }
    }

    private func found(_ list: [LinkBrowser.Found]) {
        let before = Set(phones.map(\.id))
        phones = list.map { Phone(id: $0.id, name: $0.name, endpoint: $0.endpoint) }.sorted { $0.name < $1.name }
        // A paired phone that just (re)appeared – e.g. the app came back to the foreground after the phone was locked –
        // connects right away instead of waiting for the retry timer.
        if phones.contains(where: { !before.contains($0.id) && isPaired($0) }) {
            retryTask?.cancel(); retryTask = nil; retryDelay = 1
        }
        maybeAutoConnect()
    }

    private func maybeAutoConnect() {
        guard autoConnect, !userStopped, session == nil, retryTask == nil else { return }
        // Only phones that were paired (approved once, key in the Keychain) connect by themselves.
        if let c = phones.first(where: { isPaired($0) }) { connect(c, automatic: true) }
    }

    func isPaired(_ p: Phone) -> Bool { PairingStore.shared.key(for: "phone:" + p.id) != nil }

    /// Removes the stored pairing key: the next connection to this iPhone needs a new approval on the phone.
    func forget(_ p: Phone) {
        PairingStore.shared.forget("phone:" + p.id)
        var k = knownPhones; k.remove(p.id); knownPhones = k
        objectWillChange.send()
    }

    // MARK: connect / disconnect

    func connect(_ phone: Phone, automatic: Bool = false) {
        guard session == nil else { return }
        userStopped = false
        retryTask?.cancel(); retryTask = nil
        activePhone = phone
        link = .connecting(phone.name)
        let hostName = Host.current().localizedName ?? "Mac"
        let opts = (maxBitrate: Int(maxBitrateMbps * 1_000_000), fps: fps, look: lookIndex)
        let s = HostSession(hostName: hostName, hostId: hostId, maxBitrate: opts.maxBitrate, fps: opts.fps) { w, h, info in
            try await DisplayFrameSource(name: info.name, width: w, height: h, lookIndex: opts.look, serial: Self.serial(for: info.id))
        }
        s.onLog = { print("[host] \($0)") }
        s.onState = { [weak self] st in Task { @MainActor in self?.sessionState(st, phone: phone) } }
        s.onLookChanged = { [weak self] i in Task { @MainActor in if self?.lookIndex != i { self?.lookIndex = i } } }
        session = s
        s.connect(to: phone.endpoint)
    }

    func disconnect() {
        userStopped = true
        retryTask?.cancel(); retryTask = nil
        session?.stop(reason: "disconnected on Mac")
    }

    private func sessionState(_ st: HostSession.State, phone: Phone) {
        switch st {
        case .connecting, .handshake, .starting: link = .connecting(phone.name)
        case .pairing(let code): link = .pairing(phone.name, code: code)
        case .streaming:
            link = .streaming(phone.name); retryDelay = 1
            var k = knownPhones; k.insert(phone.id); knownPhones = k
        case .ended(let reason):
            session = nil; statsLine = ""
            if userStopped { link = .idle; return }
            link = .failed(reason)
            if reason.contains("already showing") { retryDelay = 15 }     // another Mac has the phone: don't hammer it
            scheduleRetry()
        }
    }

    private func scheduleRetry() {
        guard autoConnect, retryTask == nil else { return }
        let delay = retryDelay
        retryDelay = min(3, retryDelay * 1.7)          // short cap: a returning phone is picked up within a few seconds
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.retryTask = nil
            self.maybeAutoConnect()
            if self.session == nil { self.scheduleRetry() }
        }
    }

    // MARK: periodic

    private func tick() {
        screenOK = CGPreflightScreenCaptureAccess()
        accessibilityOK = AXIsProcessTrusted()
        if case .streaming = link, let st = session?.streamerStats {
            statsLine = String(format: "%.0f fps · %.1f Mbps · %.0f ms", st.fps, st.sentMbps, st.glassMs)
        }
        if let size = session?.streamSize {
            let l = VirtualDisplay.logicalSizes(pixelWidth: size.width, pixelHeight: size.height)[min(lookIndex, VirtualDisplay.lookSteps.count - 1)]
            lookLabel = "Looks like \(Int(l.width))×\(Int(l.height))"
        } else { lookLabel = "" }
    }

    // MARK: permissions & login item

    func requestScreenRecording() { _ = CGRequestScreenCaptureAccess(); open("Privacy_ScreenCapture") }
    func requestAccessibility() { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary); open("Privacy_Accessibility") }
    private func open(_ pane: String) {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(u) }
    }
    private func applyLaunchAtLogin() {
        do { if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { print("[host] login item: \(error)") }
    }

    nonisolated static func serial(for id: String) -> UInt32 {
        var h: UInt32 = 2166136261
        for b in id.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return h
    }
}
