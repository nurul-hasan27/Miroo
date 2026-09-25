//
//  MirooDashboardWindowController.swift
//  MirooMac
//
//  Phase 13: Native macOS Dashboard Window Controller.
//  Hosts the primary Miroo multi-device control interface, manages window lifecycle,
//  and integrates with Dock identity.
//

import Cocoa
import SwiftUI

@MainActor
public final class MirooDashboardWindowController: NSWindowController, NSWindowDelegate {

    public static let shared = MirooDashboardWindowController()

    @MainActor
    public init(engine: MirooEngine? = nil) {
        let eng = engine ?? MirooEngine.shared
        let dashboardView = MirooDashboardView(engine: eng)
        let hostingController = NSHostingController(rootView: dashboardView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Miroo"
        window.minSize = NSSize(width: 620, height: 480)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.contentViewController = hostingController
        window.center()

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func showDashboard() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - NSWindowDelegate

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Hide window instead of terminating app, so background streaming continues
        sender.orderOut(nil)
        return false
    }
}
