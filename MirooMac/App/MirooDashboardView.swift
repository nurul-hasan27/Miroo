//
//  MirooDashboardView.swift
//  MirooMac
//
//  Phase 13: Production macOS Dashboard & Multi-Device Control Interface.
//  Presents discovered Miroo devices, multi-device selection, "Extend Display",
//  active display sessions with runtime dynamic transport switching, and live telemetry.
//

import SwiftUI
#if canImport(MirooNetworking)
import MirooNetworking
#endif

public struct MirooDashboardView: View {
    @ObservedObject var engine: MirooEngine
    @State private var showSettingsSheet: Bool = false
    @State private var isExtending: Bool = false

    @MainActor
    public init(engine: MirooEngine? = nil) {
        self.engine = engine ?? MirooEngine.shared
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            headerBar
            Divider()

            ScrollView {
                VStack(spacing: 20) {
                    // Wi-Fi Guidance Card (Part 3)
                    wifiGuidanceBanner

                    // Active Display Sessions (Part 11 & 12)
                    if !engine.sessions.isEmpty {
                        activeSessionsSection
                    }

                    // Available Displays Section (Part 4)
                    availableDisplaysSection
                }
                .padding(20)
            }

            Divider()
            // Bottom Action Bar
            bottomActionBar
        }
        .frame(minWidth: 620, minHeight: 480)
        .sheet(isPresented: $showSettingsSheet) {
            MirooSettingsView(engine: engine)
                .frame(width: 450, height: 350)
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 12) {
            // Miroo App Icon & Identity
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 32, height: 32)
                .cornerRadius(7)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Miroo")
                        .font(.system(size: 16, weight: .bold))
                    Text("v1.0")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }

                Text(Host.current().localizedName ?? "Mac Host")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Status Indicator Badge
            HStack(spacing: 6) {
                Circle()
                    .fill(engine.isRunning ? (engine.isClientConnected ? Color.green : Color.yellow) : Color.gray)
                    .frame(width: 8, height: 8)
                Text(engine.statusMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)

            // Settings Button
            Button(action: { showSettingsSheet = true }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .padding(6)
            .help("Preferences")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Wi-Fi Guidance Banner (Part 3)

    private var wifiGuidanceBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "wifi")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.blue)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text("Wireless & USB Setup")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.primary)

                Text("For the smoothest wireless experience, connect your Mac and iPhone to the same Wi-Fi network. USB connection works automatically when connected via cable.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(12)
        .background(Color.blue.opacity(0.08))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.blue.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - Active Sessions Section (Part 11 & 12)

    private var activeSessionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("ACTIVE DISPLAYS (\(engine.sessions.count))")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)

                Spacer()
            }

            VStack(spacing: 10) {
                ForEach(engine.sessions) { session in
                    ActiveSessionCard(session: session, engine: engine)
                }
            }
        }
    }

    // MARK: - Available Displays Section (Part 4)

    private var availableDisplaysSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("AVAILABLE IPHONES")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)

                Spacer()

                if !engine.nearbyPhones.isEmpty {
                    Button("Select All") {
                        engine.selectAllDevices()
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.link)

                    Text("·")
                        .foregroundColor(.secondary)

                    Button("Deselect") {
                        engine.deselectAllDevices()
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.link)
                }
            }

            if engine.nearbyPhones.isEmpty {
                VStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                        .padding(.top, 6)
                    Text("Looking for Miroo iPhones on Wi-Fi and USB...")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                    Text("Launch the Miroo app on your iPhone to discover it here.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.8))
                }
                .frame(maxWidth: .infinity, minHeight: 110)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.gray.opacity(0.15), lineWidth: 1)
                )
            } else {
                VStack(spacing: 8) {
                    ForEach(engine.nearbyPhones) { phone in
                        let isSelected = engine.selectedDeviceIDs.contains(phone.id)
                        let isActive = engine.activeSessions[phone.id] != nil

                        HStack(spacing: 12) {
                            // Checkbox selection
                            Button(action: {
                                if !isActive {
                                    engine.toggleSelection(for: phone.id)
                                }
                            }) {
                                Image(systemName: isActive ? "checkmark.circle.fill" : (isSelected ? "checkmark.circle.fill" : "circle"))
                                    .font(.system(size: 18))
                                    .foregroundColor(isActive ? .green : (isSelected ? .blue : .secondary.opacity(0.5)))
                            }
                            .buttonStyle(.plain)
                            .disabled(isActive)

                            // Phone Icon
                            Image(systemName: "iphone")
                                .font(.system(size: 24))
                                .foregroundColor(isActive ? .green : .blue)

                            // Details
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(phone.displayName)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(.primary)

                                    if isActive {
                                        Text("Connected")
                                            .font(.system(size: 10, weight: .bold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.green.opacity(0.15))
                                            .foregroundColor(.green)
                                            .cornerRadius(4)
                                    } else {
                                        Text("● Available")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundColor(.green)
                                    }
                                }

                                Text("\(phone.modelName)\(phone.osVersion != nil ? " · iOS " + phone.osVersion! : "")")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            // Transport Badges (Distinguish USB vs Wi-Fi, only show USB when actually detected)
                            HStack(spacing: 6) {
                                if phone.isUSBAvailable {
                                    HStack(spacing: 3) {
                                        Image(systemName: "cable.connector")
                                            .font(.system(size: 10))
                                        Text("USB")
                                            .font(.system(size: 10, weight: .bold))
                                    }
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Color.green.opacity(0.15))
                                    .foregroundColor(.green)
                                    .cornerRadius(6)
                                }

                                if phone.isWiFiAvailable {
                                    HStack(spacing: 3) {
                                        Image(systemName: "wifi")
                                            .font(.system(size: 10))
                                        Text("Wi-Fi")
                                            .font(.system(size: 10, weight: .bold))
                                    }
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Color.blue.opacity(0.12))
                                    .foregroundColor(.blue)
                                    .cornerRadius(6)
                                }
                            }
                        }
                        .padding(12)
                        .background(isSelected ? Color.blue.opacity(0.06) : Color(NSColor.controlBackgroundColor))
                        .cornerRadius(10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(isSelected ? Color.blue.opacity(0.5) : Color.gray.opacity(0.15), lineWidth: 1.5)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if !isActive {
                                engine.toggleSelection(for: phone.id)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Bottom Action Bar (Part 4 & 5)

    private var bottomActionBar: some View {
        HStack(spacing: 12) {
            let selectedCount = engine.selectedDeviceIDs.count

            if selectedCount > 0 {
                Text("\(selectedCount) \(selectedCount == 1 ? "iPhone" : "iPhones") selected")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            } else {
                Text("Select an iPhone above to extend your desktop")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: {
                let targets = engine.nearbyPhones.filter { engine.selectedDeviceIDs.contains($0.id) }
                guard !targets.isEmpty else { return }
                isExtending = true
                Task {
                    await engine.extendDisplay(to: targets)
                    isExtending = false
                    engine.selectedDeviceIDs.removeAll()
                }
            }) {
                HStack(spacing: 6) {
                    if isExtending {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "plus.rectangle.on.rectangle")
                    }
                    Text(selectedCount > 1 ? "Extend Display (\(selectedCount))" : "Extend Display")
                        .fontWeight(.semibold)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .disabled(engine.selectedDeviceIDs.isEmpty || isExtending)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// MARK: - Active Session Card (Part 11 & 12)

struct ActiveSessionCard: View {
    @ObservedObject var session: MirooDisplaySession
    @ObservedObject var engine: MirooEngine

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                // Device Icon
                Image(systemName: "display.2")
                    .font(.system(size: 22))
                    .foregroundColor(.green)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(session.device.displayName)
                            .font(.system(size: 14, weight: .bold))
                        Text("(\(session.displayWidth) × \(session.displayHeight))")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.secondary)
                    }

                    HStack(spacing: 8) {
                        Text(session.currentOrientation == .landscape ? "Landscape" : "Portrait")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)

                        Text("·")
                            .foregroundColor(.secondary)

                        // Live Telemetry
                        Text(String(format: "%.0f FPS · %.1f Mbps · %.1f ms", session.currentFPS, session.currentBitrateMbps, session.currentLatencyMs))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                // Orientation Switch Button
                Button(action: {
                    Task {
                        let next: MirooOrientation = (session.currentOrientation == .portrait) ? .landscape : .portrait
                        await session.switchOrientation(to: next)
                    }
                }) {
                    Image(systemName: "rotate.right")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .help("Rotate Display")

                // Disconnect Button
                Button("Disconnect") {
                    engine.stopSession(for: session.device.id)
                }
                .font(.system(size: 12, weight: .medium))
                .buttonStyle(.bordered)
                .foregroundColor(.red)
            }

            Divider()

            // Dynamic Transport Switcher (Part 12)
            HStack(spacing: 12) {
                Text("Transport:")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)

                Picker("", selection: Binding<VideoTransportType>(
                    get: { session.currentTransportType },
                    set: { newTransport in
                        session.switchTransport(to: newTransport)
                    }
                )) {
                    Text("USB").tag(VideoTransportType.usb)
                        .disabled(!session.device.isUSBAvailable)
                    Text("UDP").tag(VideoTransportType.udp)
                    Text("TCP").tag(VideoTransportType.tcp)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)

                Spacer()

                Text("Dynamic switching without display reset")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.8))
            }
        }
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.green.opacity(0.3), lineWidth: 1.5)
        )
    }
}
