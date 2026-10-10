import SwiftUI

struct MenuView: View {
    @ObservedObject var model: MacModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            devices
            Divider()
            settings
            Divider()
            permissions
            Divider()
            HStack {
                Spacer()
                Button("Quit Miroo") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    @ViewBuilder private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "display.and.arrow.down").font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Miroo").font(.headline)
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        if case .pairing(let name, let code) = model.link {
            VStack(spacing: 4) {
                Text(code).font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
                Text("Tap Allow on \(name) only if it shows the same code.").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity).padding(.vertical, 8).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var statusText: String {
        switch model.link {
        case .idle: return model.phones.isEmpty ? "Open Miroo on your iPhone" : "Ready"
        case .connecting(let n): return "Connecting to \(n)…"
        case .pairing(let n, let code): return "Pairing with \(n) — code \(code)"
        case .streaming(let n): return "\(n) · \(model.statsLine)"
        case .failed(let r): return "Disconnected — \(r)"
        }
    }

    @ViewBuilder private var devices: some View {
        if model.phones.isEmpty {
            Label("No iPhone found. Keep Miroo open on your iPhone, on the same Wi-Fi.", systemImage: "wifi.exclamationmark")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            ForEach(model.phones) { phone in
                HStack {
                    Image(systemName: "iphone").foregroundStyle(isActive(phone) ? Color.green : .secondary)
                    Text(phone.name)
                    Spacer()
                    if isActive(phone) { Button("Disconnect") { model.disconnect() } }
                    else { Button("Extend Display") { model.connect(phone) }.disabled(isBusy) }
                    if model.isPaired(phone), !isActive(phone) {
                        Button { model.forget(phone) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain).help("Forget this iPhone (requires pairing again)")
                    }
                }
            }
        }
    }

    private func isActive(_ p: MacModel.Phone) -> Bool {
        switch model.link {
        case .streaming(let n), .connecting(let n), .pairing(let n, _): return n == p.name
        default: return false
        }
    }
    private var isBusy: Bool { if case .idle = model.link { return false }; if case .failed = model.link { return false }; return true }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Connect automatically when my iPhone is nearby", isOn: model.$autoConnect)
            Picker("Frame rate", selection: model.$fps) { Text("60 fps").tag(60); Text("30 fps").tag(30) }.pickerStyle(.segmented)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Larger text").font(.caption2).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { Double(model.lookIndex) }, set: { model.lookIndex = Int($0.rounded()) }), in: model.lookRange, step: 1)
                    Text("More room").font(.caption2).foregroundStyle(.secondary)
                }
                Text(model.lookLabel.isEmpty ? "Resolution of the iPhone display (also in System Settings › Displays)" : model.lookLabel + " · also in System Settings › Displays")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            HStack {
                Text("Max bitrate"); Slider(value: model.$maxBitrateMbps, in: 8...60, step: 2); Text("\(Int(model.maxBitrateMbps)) Mbps").monospacedDigit().frame(width: 70, alignment: .trailing)
            }
            Toggle("Open at login", isOn: model.$launchAtLogin)
            Text("Frame rate and bitrate apply the next time you connect.").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 6) {
            permissionRow("Screen Recording (shows the display on iPhone)", ok: model.screenOK, action: model.requestScreenRecording)
            permissionRow("Accessibility (touch controls the Mac)", ok: model.accessibilityOK, action: model.requestAccessibility)
        }
    }

    private func permissionRow(_ title: String, ok: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(ok ? Color.green : .orange)
            Text(title).font(.callout)
            Spacer()
            if !ok { Button("Allow…", action: action) }
        }
    }
}
