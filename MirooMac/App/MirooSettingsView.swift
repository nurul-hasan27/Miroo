//
//  MirooSettingsView.swift
//  MirooMac
//
//  Phase 12: Production Native macOS SwiftUI Settings Window.
//  Provides interactive preferences for Framerate, Bitrate, Transport,
//  Orientation, SMAppService Launch at Login, and Pipeline Diagnostics.
//

import SwiftUI
#if canImport(MirooNetworking)
import MirooNetworking
#endif

public struct MirooSettingsView: View {
    @ObservedObject var engine: MirooEngine

    public init(engine: MirooEngine) {
        self.engine = engine
    }

    public var body: some View {
        TabView {
            devicesTab
                .tabItem {
                    Label("Devices", systemImage: "iphone.gen3")
                }

            generalTab
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            streamingTab
                .tabItem {
                    Label("Streaming", systemImage: "antenna.radiowaves.left.and.right")
                }

            diagnosticsTab
                .tabItem {
                    Label("Diagnostics", systemImage: "chart.xyaxis.line")
                }
        }
        .padding(20)
        .frame(width: 520, height: 420)
    }

    // MARK: - General Tab

    @ViewBuilder
    private var generalTab: some View {
        Form {
            Section(header: Text("Virtual Display").font(.headline)) {
                HStack {
                    Text("Display Mode:")
                    Spacer()
                    Text("\(engine.activeWidth) × \(engine.activeHeight) pt")
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Orientation:")
                    Spacer()
                    Button(action: {
                        Task {
                            let next: MirooOrientation = (engine.currentOrientation == .portrait) ? .landscape : .portrait
                            await engine.switchOrientation(to: next)
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text(engine.currentOrientation.rawValue.capitalized)
                        }
                    }
                }
            }

            Section(header: Text("Startup").font(.headline)) {
                Toggle("Launch Miroo at Login", isOn: $engine.launchAtLogin)
                    .help("Automatically launch the Miroo service when logging into your Mac.")
                Text("Enables instant secondary display connectivity as soon as your iPhone is connected via USB or Wi-Fi.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Streaming Tab

    @ViewBuilder
    private var streamingTab: some View {
        Form {
            Section(header: Text("Quality & Performance").font(.headline)) {
                Picker("Target Framerate:", selection: $engine.targetFPS) {
                    Text("30 FPS (Power Saver)").tag(30)
                    Text("60 FPS (Ultra Smooth)").tag(60)
                }
                .pickerStyle(.segmented)

                Picker("Target Bitrate:", selection: $engine.targetBitrateMbps) {
                    Text("4 Mbps (Efficient)").tag(4)
                    Text("8 Mbps (Recommended)").tag(8)
                    Text("12 Mbps (High Quality)").tag(12)
                    Text("16 Mbps (Maximum)").tag(16)
                }

                Picker("Preferred Transport:", selection: $engine.preferredTransport) {
                    Text("Auto (USB First, Wi-Fi Fallback)").tag("auto")
                    Text("Wi-Fi UDP").tag("udp")
                    Text("Wi-Fi TCP").tag("tcp")
                }
            }

            Section(header: Text("Pipeline Control").font(.headline)) {
                HStack {
                    Button(engine.isStreamingPaused ? "Resume Streaming" : "Pause Streaming") {
                        engine.togglePause()
                    }
                    .buttonStyle(.bordered)

                    Button("Force Keyframe (IDR)") {
                        engine.requestKeyframe()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Diagnostics Tab

    @ViewBuilder
    private var diagnosticsTab: some View {
        Form {
            Section(header: Text("Live Telemetry").font(.headline)) {
                HStack {
                    Text("Engine Status:")
                    Spacer()
                    Text(engine.statusMessage)
                        .fontWeight(.semibold)
                        .foregroundColor(engine.isRunning ? .green : .secondary)
                }

                HStack {
                    Text("Connected Device:")
                    Spacer()
                    Text(engine.connectedClientName ?? "None (Waiting)")
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Active Transport:")
                    Spacer()
                    Text(engine.activeTransport)
                        .fontWeight(.bold)
                        .foregroundColor(engine.activeTransport == "USB" ? .orange : .blue)
                }

                HStack {
                    Text("Throughput / FPS:")
                    Spacer()
                    Text(String(format: "%.1f FPS · %.1f Mbps", engine.currentFPS, engine.currentBitrateMbps))
                        .font(.system(.body, design: .monospaced))
                }

                HStack {
                    Text("Pipeline Latency (p50):")
                    Spacer()
                    Text(String(format: "%.1f ms", engine.currentPipelineLatencyMs))
                        .font(.system(.body, design: .monospaced))
                }
            }

            Section {
                Button("Export Benchmark JSON Report") {
                    try? PipelineBenchmark.shared.exportJSON(toPath: "pipeline_benchmark_report.json")
                    print("[Miroo] Benchmark exported to pipeline_benchmark_report.json")
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Devices Tab

    @ViewBuilder
    private var devicesTab: some View {
        Form {
            Section(header: Text("Nearby iPhones").font(.headline)) {
                if engine.nearbyPhones.isEmpty {
                    HStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Searching for nearby iPhones over Wi-Fi and USB...")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 8)
                } else {
                    ForEach(engine.nearbyPhones) { phone in
                        HStack {
                            Image(systemName: phone.isUSBAvailable ? "cable.connector" : "iphone")
                                .foregroundColor(phone.isUSBAvailable ? .orange : .blue)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(phone.displayName)
                                        .fontWeight(.semibold)
                                    if phone.isUSBAvailable {
                                        Text("USB")
                                            .font(.system(size: 9, weight: .bold))
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 2)
                                            .background(Color.orange.opacity(0.2))
                                            .foregroundColor(.orange)
                                            .cornerRadius(4)
                                    }
                                    if phone.isWiFiAvailable {
                                        Text("Wi-Fi")
                                            .font(.system(size: 9, weight: .bold))
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 2)
                                            .background(Color.blue.opacity(0.2))
                                            .foregroundColor(.blue)
                                            .cornerRadius(4)
                                    }
                                }
                                Text("\(phone.modelName)\(phone.osVersion != nil ? " · " + phone.osVersion! : "")")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if engine.isClientConnected && engine.connectedClientName == phone.displayName {
                                Button("Disconnect") {
                                    engine.disconnectClient()
                                }
                                .buttonStyle(.bordered)
                                .tint(.red)
                            } else {
                                Button("Connect") {
                                    engine.connect(to: phone)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(!engine.isRunning)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            Section(header: Text("Device Authorization & Pairing").font(.headline)) {
                Toggle("Auto-accept trusted devices", isOn: Binding(
                    get: { engine.authorizer.autoAcceptTrustedDevices },
                    set: { engine.authorizer.autoAcceptTrustedDevices = $0 }
                ))
                .help("When enabled, recognized devices that were previously allowed will connect automatically without prompting.")

                let trustedCount = engine.authorizer.trustedDeviceIDs.count
                HStack {
                    Text("Paired Trusted Devices:")
                    Spacer()
                    Text("\(trustedCount) saved")
                        .foregroundColor(.secondary)
                }

                if trustedCount > 0 {
                    Button(role: .destructive) {
                        engine.authorizer.clearAllTrustedDevices()
                    } label: {
                        Text("Clear All Paired Devices")
                    }
                }
            }

            Section(header: Text("Connection Guidance").font(.headline)) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "wifi")
                            .foregroundColor(.blue)
                        Text("For the smoothest experience, connect your Mac and iPhone to the same Wi-Fi network.")
                            .font(.caption)
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "cable.connector")
                            .foregroundColor(.orange)
                        Text("For ultra-low latency (< 10ms) and zero wireless interference, connect via Lightning / USB-C cable.")
                            .font(.caption)
                    }
                }
                .foregroundColor(.secondary)
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
    }
}
