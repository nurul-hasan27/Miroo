import SwiftUI
import UIKit
import MirooCore

struct RootView: View {
    @ObservedObject var session: PhoneSession

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // Full bleed: the picture covers the whole panel – notch, rounded corners and home-indicator area included –
            // in both orientations. The Mac display is created at exactly the panel's pixel size.
            GeometryReader { geo in
                content
                    .frame(width: geo.size.width, height: geo.size.height)
                    .onAppear { session.viewportChanged(points: geo.size) }
                    .onChange(of: geo.size) { session.viewportChanged(points: $0) }
            }
            .ignoresSafeArea()
        }
    }

    /// The real safe-area insets (the container ignores them so the picture can be full bleed; text UI must still avoid the notch).
    private var safeInsets: EdgeInsets {
        let w = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        let i = w?.safeAreaInsets ?? .zero
        return EdgeInsets(top: i.top, leading: i.left, bottom: i.bottom, trailing: i.right)
    }

    @ViewBuilder private var content: some View {
        switch session.phase {
        case .streaming:
            ZStack(alignment: .topLeading) {
                DisplayLayerView(layer: session.renderer.layer)
                TouchSurface(onEvent: { kind, x, y in session.sendInput(kind, x, y) }, onThreeFingers: { session.showHUD.toggle() })
                if session.showHUD { HUDView(stats: session.hud).padding(safeInsets).padding(8) }
            }
        case .asking(let mac, let code):
            VStack(spacing: 16) {
                Image(systemName: "display").font(.system(size: 44))
                Text("Use \(mac) to extend its display here?").font(.headline).multilineTextAlignment(.center)
                Text(code).font(.system(size: 52, weight: .bold, design: .rounded)).monospacedDigit()
                Text("Allow only if your Mac shows the same code.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack(spacing: 14) {
                    Button("Not now") { session.respond(allow: false) }.buttonStyle(.bordered)
                    Button("Allow") { session.respond(allow: true) }.buttonStyle(.borderedProminent)
                }
            }.padding().padding(safeInsets)
        default:
            VStack(spacing: 18) {
                Image(systemName: "display.and.arrow.down").font(.system(size: 52, weight: .light)).foregroundStyle(.tint)
                Text("Miroo").font(.largeTitle.weight(.bold))
                Text(session.statusText).font(.headline).foregroundStyle(.secondary)
                Text("Open Miroo on your Mac (menu bar) and choose “\(session.deviceName)”.\nIt connects by itself once you've approved it here.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.padding(28).padding(safeInsets)
        }
    }
}

struct HUDView: View {
    let stats: HUDStats
    var body: some View {
        Text(String(format: "%.0f fps  %.1f Mbps\ndecode %.1f ms  queue %.1f ms\nframe gap p95 %.0f  max %.0f ms\nrepaired %d  lost %d  recov %d",
                    stats.fps, stats.mbps, stats.decodeMs, stats.queueMs, stats.gapP95, stats.gapMax, stats.repaired, stats.lost, stats.recoveries))
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .padding(6).background(.black.opacity(0.6)).foregroundStyle(.green).cornerRadius(6)
            .allowsHitTesting(false)
    }
}
