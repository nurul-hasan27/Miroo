//
//  MirooMacApp.swift
//  MirooMac
//
//  Phase 12: Production Native macOS Menu Bar Application.
//  Coordinates MirooEngine, native NSStatusItem Menu Bar UI,
//  SwiftUI Preferences, and interactive terminal controls.
//

import Cocoa
import CoreGraphics
#if canImport(MirooNetworking)
import MirooNetworking
#endif

@main
final class MirooMacApp: NSObject, NSApplicationDelegate {

    private var menuBarController: MirooMenuBarController?

    static func main() {
        let app = NSApplication.shared
        let delegate = MirooMacApp()
        app.delegate = delegate

        // Graceful signal handlers
        signal(SIGINT) { _ in
            print("\n[Miroo] Caught SIGINT. Gracefully shutting down...")
            Task { @MainActor in
                MirooEngine.shared.stop()
                exit(0)
            }
        }

        signal(SIGTERM) { _ in
            print("\n[Miroo] Caught SIGTERM. Gracefully shutting down...")
            Task { @MainActor in
                MirooEngine.shared.stop()
                exit(0)
            }
        }

        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("=======================================================")
        print("          Miroo macOS Production App (Phase 12)        ")
        print("=======================================================")

        let engine = MirooEngine.shared
        self.menuBarController = MirooMenuBarController(engine: engine)

        // Parse launch flags for transport override
        if CommandLine.arguments.contains("--udp") || ProcessInfo.processInfo.environment["MIROO_TRANSPORT"]?.lowercased() == "udp" {
            engine.preferredTransport = "udp"
            print("[Miroo] Preferred transport set to UDP via command-line argument.")
        } else if CommandLine.arguments.contains("--tcp") || ProcessInfo.processInfo.environment["MIROO_TRANSPORT"]?.lowercased() == "tcp" {
            engine.preferredTransport = "tcp"
            print("[Miroo] Preferred transport set to TCP via command-line argument.")
        }

        // Start MirooEngine in background task
        Task {
            do {
                try await engine.start()
            } catch {
                print("[Miroo] Initialization error: \(error.localizedDescription)")
                if let capturerErr = error as? CapturerError, case .permissionDenied = capturerErr {
                    print("----------------------------------------------------------------------")
                    print(" ACTION REQUIRED: Screen Recording Permission Needed")
                    print(" 1. Open System Settings -> Privacy & Security -> Screen Recording")
                    print(" 2. Enable permission for 'MirooMac' (or Terminal)")
                    print(" 3. Relaunch Miroo")
                    print("----------------------------------------------------------------------")
                }
            }
        }

        // Check if running interactively inside a terminal TTY
        let isInteractiveTerminal = isatty(fileno(stdin)) != 0
        if isInteractiveTerminal {
            startTerminalListener(engine: engine)
            print("-------------------------------------------------------")
            print(" Miroo Menu Bar App active.")
            print(" Terminal interactive controls active:")
            print(" 'p'/'l'/'r' (orientation), 'u' (UDP), 't' (TCP), 'k' (keyframe), 'b' (benchmark), 'q' (quit)")
            print("-------------------------------------------------------")
        } else {
            print("Miroo running in background menu bar mode.")
        }
    }

    private func startTerminalListener(engine: MirooEngine) {
        DispatchQueue.global(qos: .userInitiated).async { [weak engine] in
            let stdinHandle = FileHandle.standardInput
            while true {
                let data = stdinHandle.availableData
                guard !data.isEmpty, let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
                    break
                }
                Task { @MainActor in
                    guard let engine = engine else { return }
                    if line == "p" || line == "portrait" {
                        await engine.switchOrientation(to: .portrait)
                    } else if line == "l" || line == "landscape" {
                        await engine.switchOrientation(to: .landscape)
                    } else if line == "r" || line == "rotate" {
                        let next: MirooOrientation = (engine.currentOrientation == .portrait) ? .landscape : .portrait
                        await engine.switchOrientation(to: next)
                    } else if line == "u" || line == "udp" {
                        engine.selectTransportMode("udp")
                        print("[Miroo] Switched transport to UDP.")
                    } else if line == "t" || line == "tcp" {
                        engine.selectTransportMode("tcp")
                        print("[Miroo] Switched transport to TCP.")
                    } else if line == "s" || line == "usb" {
                        if engine.isUSBAvailable {
                            engine.selectTransportMode("usb")
                            print("[Miroo] Switched transport to USB.")
                        } else {
                            print("[Miroo] USB unavailable: Device is not physically connected.")
                        }
                    } else if line == "a" || line == "auto" {
                        engine.selectTransportMode("auto")
                        print("[Miroo] Switched transport to Auto.")
                    } else if line == "k" || line == "key" {
                        engine.requestKeyframe()
                        print("[Miroo] Forced IDR Keyframe on next capture.")
                    } else if line == "b" || line == "benchmark" {
                        let report = PipelineBenchmark.shared.generateReport()
                        print("\n" + report.formattedSummary() + "\n")
                        try? PipelineBenchmark.shared.exportJSON(toPath: "pipeline_benchmark_report.json")
                        print("[Miroo] Benchmark JSON saved to pipeline_benchmark_report.json")
                    } else if line == "reset" {
                        PipelineBenchmark.shared.reset()
                        print("[Miroo] Pipeline benchmark statistics reset to zero.")
                    } else if line == "q" || line == "quit" {
                        NSApp.terminate(nil)
                    }
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        print("[Miroo] Application terminating. Cleaning up engine...")
        MirooEngine.shared.stop()
    }
}
