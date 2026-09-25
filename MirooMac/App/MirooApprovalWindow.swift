//
//  MirooApprovalWindow.swift
//  MirooMac
//
//  Phase 13: Production Native macOS Connection Request Authorization Prompt.
//  Presents a clean, native Apple-styled floating approval card when an iPhone
//  requests to connect as a secondary display.
//

import Cocoa
import SwiftUI
#if canImport(MirooNetworking)
import MirooNetworking
#endif

@MainActor
public final class MirooApprovalWindowController: NSObject {

    public static let shared = MirooApprovalWindowController()

    private var window: NSPanel?
    private var currentSessionID: String?

    public var onDecision: ((_ sessionID: String, _ approved: Bool, _ rememberDevice: Bool) -> Void)?

    public override init() {
        super.init()
    }

    /// Shows the authorization prompt for an inbound connection request.
    public func showRequestPrompt(
        request: PendingConnectionRequest,
        onDecision: @escaping (_ sessionID: String, _ approved: Bool, _ rememberDevice: Bool) -> Void
    ) {
        self.onDecision = onDecision
        self.currentSessionID = request.payload.sessionID

        closeCurrentPrompt()

        let approvalView = MirooApprovalCardView(
            request: request,
            onAllow: { [weak self] remember in
                self?.handleUserDecision(approved: true, remember: remember)
            },
            onReject: { [weak self] in
                self?.handleUserDecision(approved: false, remember: false)
            }
        )

        let hostingController = NSHostingController(rootView: approvalView)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 210),
            styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.contentViewController = hostingController

        // Position at top-right of the main screen with safe inset
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.maxX - 400
            let y = screenFrame.maxY - 230
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            panel.center()
        }

        self.window = panel
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Dismisses the prompt if the session was cancelled or timed out.
    public func dismissPrompt(sessionID: String) {
        guard currentSessionID == sessionID else { return }
        closeCurrentPrompt()
    }

    private func handleUserDecision(approved: Bool, remember: Bool) {
        guard let sID = currentSessionID else { return }
        closeCurrentPrompt()
        onDecision?(sID, approved, remember)
    }

    private func closeCurrentPrompt() {
        window?.close()
        window = nil
        currentSessionID = nil
    }
}

// MARK: - SwiftUI Approval Card View

struct MirooApprovalCardView: View {
    let request: PendingConnectionRequest
    let onAllow: (Bool) -> Void
    let onReject: () -> Void

    @State private var rememberDevice: Bool = false

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: "iphone.badge.play")
                        .font(.system(size: 22))
                        .foregroundColor(.blue)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Connection Request")
                        .font(.headline)
                        .foregroundColor(.primary)

                    Text("\(request.payload.clientName) wants to connect as a secondary display.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Text(request.payload.clientModel)
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Text("·")
                            .foregroundColor(.secondary.opacity(0.5))

                        Text(request.transportType)
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(request.transportType == "USB" ? Color.orange.opacity(0.2) : Color.blue.opacity(0.12))
                            .foregroundColor(request.transportType == "USB" ? .orange : .blue)
                            .cornerRadius(4)
                    }
                    .padding(.top, 2)
                }

                Spacer()
            }

            Toggle("Always allow this device", isOn: $rememberDevice)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            HStack(spacing: 12) {
                Spacer()

                Button("Don't Allow") {
                    onReject()
                }
                .keyboardShortcut(.cancelAction)

                Button("Allow") {
                    onAllow(rememberDevice)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 380)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .behindWindow))
    }
}

// MARK: - AppKit Visual Effect Backdrop

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
