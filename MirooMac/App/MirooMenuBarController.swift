//
//  MirooMenuBarController.swift
//  MirooMac
//
//  Phase 12: Production Native macOS Menu Bar Controller.
//  Coordinates NSStatusItem, dynamic status menu, telemetry indicators,
//  and presents the SwiftUI Preferences / Settings window.
//

import Cocoa
import SwiftUI
#if canImport(MirooNetworking)
import MirooNetworking
#endif

@MainActor
public final class MirooMenuBarController: NSObject, NSMenuDelegate {

    private let engine: MirooEngine
    private var statusItem: NSStatusItem?
    private var settingsWindowController: NSWindowController?

    public init(engine: MirooEngine) {
        self.engine = engine
        super.init()
        setupStatusItem()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = item

        if let button = item.button {
            if let image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "Miroo") {
                let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
                button.image = image.withSymbolConfiguration(config)
            } else {
                button.title = "Miroo"
            }
            button.toolTip = "Miroo — Secondary Display"
        }

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
    }

    // MARK: - Dynamic Menu Population

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // 1. Header / Status
        let statusTitle: String
        if !engine.isRunning {
            statusTitle = "Miroo: Stopped"
        } else if engine.isStreamingPaused {
            statusTitle = "Miroo: Paused"
        } else if engine.isClientConnected {
            statusTitle = "Miroo: Streaming (\(engine.activeTransport))"
        } else {
            statusTitle = "Miroo: Ready (Waiting for iPhone)"
        }

        let headerItem = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)

        // 2. Client Details
        if let client = engine.connectedClientName {
            let clientItem = NSMenuItem(title: "  Connected: \(client)", action: nil, keyEquivalent: "")
            clientItem.isEnabled = false
            menu.addItem(clientItem)
        }

        // 3. Live Stats
        if engine.isClientConnected && engine.currentFPS > 0 {
            let statsTitle = String(
                format: "  %.0f FPS · %.1f Mbps · %.0f ms",
                engine.currentFPS,
                engine.currentBitrateMbps,
                engine.currentPipelineLatencyMs
            )
            let statsItem = NSMenuItem(title: statsTitle, action: nil, keyEquivalent: "")
            statsItem.isEnabled = false
            menu.addItem(statsItem)
        }

        menu.addItem(NSMenuItem.separator())

        // 4. Nearby iPhones
        let phonesHeader = NSMenuItem(title: "Nearby iPhones", action: nil, keyEquivalent: "")
        phonesHeader.isEnabled = false
        menu.addItem(phonesHeader)

        if engine.nearbyPhones.isEmpty {
            let emptyItem = NSMenuItem(title: "  Searching for iPhones...", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            for phone in engine.nearbyPhones {
                let badge = phone.isUSBAvailable ? "USB" : "Wi-Fi"
                let isConnected = (engine.isClientConnected && engine.connectedClientName == phone.displayName)
                let statusText = isConnected ? "Connected" : phone.availability.rawValue.capitalized
                let title = "  \(phone.displayName) (\(phone.modelName)) [\(badge)] · \(statusText)"
                let item = NSMenuItem(title: title, action: #selector(deviceItemClicked(_:)), keyEquivalent: "")
                item.representedObject = phone
                item.target = self
                menu.addItem(item)
            }
        }

        let hintItem = NSMenuItem(title: "  Tip: Connect via USB or same Wi-Fi network", action: nil, keyEquivalent: "")
        hintItem.isEnabled = false
        menu.addItem(hintItem)

        menu.addItem(NSMenuItem.separator())

        // 5. Stream Controls
        let pauseItem = NSMenuItem(
            title: engine.isStreamingPaused ? "Resume Streaming" : "Pause Streaming",
            action: #selector(togglePauseAction),
            keyEquivalent: "p"
        )
        pauseItem.target = self
        pauseItem.isEnabled = engine.isRunning
        menu.addItem(pauseItem)

        let keyframeItem = NSMenuItem(
            title: "Force IDR Keyframe",
            action: #selector(forceKeyframeAction),
            keyEquivalent: "k"
        )
        keyframeItem.target = self
        keyframeItem.isEnabled = engine.isRunning
        menu.addItem(keyframeItem)

        let currentOrientationName = engine.currentOrientation.rawValue.capitalized
        let orientationItem = NSMenuItem(
            title: "Orientation: \(currentOrientationName) (Switch)",
            action: #selector(toggleOrientationAction),
            keyEquivalent: "r"
        )
        orientationItem.target = self
        orientationItem.isEnabled = engine.isRunning
        menu.addItem(orientationItem)

        menu.addItem(NSMenuItem.separator())

        // 5. Settings & Diagnostics
        let settingsItem = NSMenuItem(
            title: "Settings...",
            action: #selector(openSettingsAction),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        let benchItem = NSMenuItem(
            title: "Export Benchmark Report",
            action: #selector(exportBenchmarkAction),
            keyEquivalent: ""
        )
        benchItem.target = self
        menu.addItem(benchItem)

        menu.addItem(NSMenuItem.separator())

        // 6. Quit
        let quitItem = NSMenuItem(
            title: "Quit Miroo",
            action: #selector(quitAction),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
    }

    // MARK: - Actions

    @objc private func deviceItemClicked(_ sender: NSMenuItem) {
        if let device = sender.representedObject as? MirooDevice {
            if engine.isClientConnected && engine.connectedClientName == device.displayName {
                engine.disconnectClient()
            } else {
                engine.connect(to: device)
            }
        }
    }

    @objc private func togglePauseAction() {
        engine.togglePause()
    }

    @objc private func forceKeyframeAction() {
        engine.requestKeyframe()
    }

    @objc private func toggleOrientationAction() {
        Task {
            let next: MirooOrientation = (engine.currentOrientation == .portrait) ? .landscape : .portrait
            await engine.switchOrientation(to: next)
        }
    }

    @objc public func openSettingsAction() {
        if let window = settingsWindowController?.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = MirooSettingsView(engine: engine)
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Miroo Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.center()
        window.isReleasedWhenClosed = false

        let controller = NSWindowController(window: window)
        self.settingsWindowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func exportBenchmarkAction() {
        let report = PipelineBenchmark.shared.generateReport()
        print("\n" + report.formattedSummary() + "\n")
        try? PipelineBenchmark.shared.exportJSON(toPath: "pipeline_benchmark_report.json")
        print("[Miroo] Benchmark JSON saved to pipeline_benchmark_report.json")
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }
}
