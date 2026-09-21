//
//  VirtualDisplayManager.swift
//  MirooMac
//
//  Manages the lifecycle, mode selection, mirror detachment, and positioning
//  of the Miroo virtual display on macOS.
//

import Foundation
import CoreGraphics
import Cocoa
#if canImport(CGVirtualDisplayBridge)
import CGVirtualDisplayBridge
#endif

/// Manages the virtual display on macOS, coordinating between private CoreGraphics
/// creation APIs and public CoreGraphics display configuration APIs.
public final class VirtualDisplayManager {

    // MARK: - Display Specifications

    /// Target physical resolution (native iPhone OLED panel).
    public static let physicalWidth: UInt32 = 1170
    public static let physicalHeight: UInt32 = 2532

    /// Retina scale factor (@2x).
    public static let scaleFactor: UInt32 = 2

    /// Logical resolution in macOS points (1170 / 2 = 585, 2532 / 2 = 1266).
    public static let logicalWidth: UInt32 = physicalWidth / scaleFactor
    public static let logicalHeight: UInt32 = physicalHeight / scaleFactor

    /// Display Name exposed to macOS WindowServer and System Settings.
    public static let defaultDisplayName = "Miroo Extended iPhone"

    /// Unique vendor, product, and serial identifiers.
    /// vendorID: 0x5043 ('PC'), productID: 0x4F53 ('OS'), serialNum: 0x1001
    public static let defaultVendorID: UInt32 = 0x5043
    public static let defaultProductID: UInt32 = 0x4F53
    public static let defaultSerialNum: UInt32 = 0x1001

    /// Physical dimensions in millimeters (standard 6.1" iPhone screen: ~71.5mm x 146.7mm).
    public static let defaultSizeInMillimeters = CGSize(width: 71.5, height: 146.7)

    // MARK: - Properties

    private(set) var bridge: CGVirtualDisplayBridge?
    private(set) var isCreated = false

    public var displayID: CGDirectDisplayID {
        return bridge?.displayID ?? 0
    }

    public var isActive: Bool {
        guard let b = bridge, b.isValid else { return false }
        return CGDisplayIsActive(b.displayID) != 0
    }

    // MARK: - Lifecycle

    public init() {}

    deinit {
        destroy()
    }

    // MARK: - Display Creation & Configuration

    /// Creates the virtual display and positions it as an independent extended desktop.
    @discardableResult
    public func create() -> Bool {
        guard !isCreated else {
            print("[Miroo] Virtual display already created.")
            return true
        }

        print("[Miroo] Creating virtual display '\(Self.defaultDisplayName)'...")

        var acquiredBridge: CGVirtualDisplayBridge?
        var lastError: Error?

        for attempt in 0..<10 {
            let serial = Self.defaultSerialNum + UInt32(attempt)
            do {
                acquiredBridge = try CGVirtualDisplayBridge(
                    name: Self.defaultDisplayName,
                    logicalWidth: Self.logicalWidth,
                    logicalHeight: Self.logicalHeight,
                    scaleFactor: Self.scaleFactor,
                    vendorID: Self.defaultVendorID,
                    productID: Self.defaultProductID,
                    serialNum: serial,
                    sizeInMillimeters: Self.defaultSizeInMillimeters,
                    queue: DispatchQueue.main
                )
                if acquiredBridge != nil {
                    break
                }
            } catch {
                lastError = error
            }
        }

        guard let newBridge = acquiredBridge else {
            let errorMsg = lastError?.localizedDescription ?? "Failed to allocate display descriptor"
            print("[Miroo] ERROR: Failed to instantiate virtual display bridge: \(errorMsg)")
            return false
        }

        self.bridge = newBridge
        self.isCreated = true

        let id = newBridge.displayID
        print("[Miroo] Virtual display created with Display ID: \(id)")

        // Allow WindowServer a moment to register the new display in the system list
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))

        // Step 1: Detach mirror and position beside primary display
        if !detachFromMirrorAndPositionBesidePrimary() {
            print("[Miroo] WARNING: Failed to configure display arrangement.")
        }

        // Step 2: Select HiDPI mode if available
        selectHiDPIMode()

        // Allow WindowServer to commit the mode switch
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))

        return true
    }

    /// Tears down and destroys the virtual display.
    public func destroy() {
        guard isCreated, let b = bridge else { return }
        print("[Miroo] Destroying virtual display (ID: \(b.displayID))...")
        b.destroy()
        self.bridge = nil
        self.isCreated = false
    }

    // MARK: - Public CoreGraphics Configuration

    /// Detaches the virtual display from any mirror sets and positions it
    /// immediately to the right of the primary display using public CoreGraphics APIs.
    @discardableResult
    public func detachFromMirrorAndPositionBesidePrimary() -> Bool {
        guard let bridge = bridge, bridge.displayID != 0 else { return false }
        let id = bridge.displayID

        var config: CGDisplayConfigRef?
        let beginErr = CGBeginDisplayConfiguration(&config)
        guard beginErr == .success, let configRef = config else {
            print("[Miroo] Failed to begin display configuration: \(beginErr.rawValue)")
            return false
        }

        // Public API: Detach display from mirroring any master display
        CGConfigureDisplayMirrorOfDisplay(configRef, id, kCGNullDirectDisplay)

        // Ensure no other screen is mirroring our virtual display
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        if count > 0 {
            var activeList = [CGDirectDisplayID](repeating: 0, count: Int(count))
            CGGetActiveDisplayList(count, &activeList, &count)
            for otherID in activeList where otherID != id {
                if CGDisplayMirrorsDisplay(otherID) == id {
                    CGConfigureDisplayMirrorOfDisplay(configRef, otherID, kCGNullDirectDisplay)
                }
            }
        }

        // Position to the right of the primary (main) display
        let mainID = CGMainDisplayID()
        let mainBounds = CGDisplayBounds(mainID)
        let targetX = Int32(mainBounds.origin.x + mainBounds.width)
        let targetY = Int32(mainBounds.origin.y)

        CGConfigureDisplayOrigin(configRef, id, targetX, targetY)

        // Commit configuration for the current user session
        let completeErr = CGCompleteDisplayConfiguration(configRef, .forSession)
        if completeErr != .success {
            print("[Miroo] CGCompleteDisplayConfiguration returned: \(completeErr.rawValue)")
            return false
        }

        return true
    }

    /// Selects the @2x Retina HiDPI mode (585x1266 logical with 1170x2532 backing pixels).
    @discardableResult
    public func selectHiDPIMode() -> Bool {
        guard let bridge = bridge, bridge.displayID != 0 else { return false }
        let id = bridge.displayID

        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modeList = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] else {
            return false
        }

        // Look for the HiDPI mode: width == logicalWidth, pixelWidth == physicalWidth
        if let hidpiMode = modeList.first(where: {
            $0.width == Int(Self.logicalWidth) && $0.pixelWidth == Int(Self.physicalWidth)
        }) {
            let err = CGDisplaySetDisplayMode(id, hidpiMode, nil)
            if err == .success {
                return true
            }
        }

        return false
    }

    // MARK: - Display Enumeration & Verification

    /// Prints a comprehensive verification report conforming to Phase 1 requirements.
    public func printVerificationReport() {
        guard let b = bridge, b.displayID != 0 else {
            print("Miroo Virtual Display: NOT INITIALIZED")
            return
        }

        let id = b.displayID
        let active = CGDisplayIsActive(id) != 0
        let online = CGDisplayIsOnline(id) != 0
        let bounds = CGDisplayBounds(id)
        let mode = CGDisplayCopyDisplayMode(id)

        let pixelW = mode?.pixelWidth ?? Int(Self.physicalWidth)
        let pixelH = mode?.pixelHeight ?? Int(Self.physicalHeight)
        let logW = mode?.width ?? Int(Self.logicalWidth)
        let logH = mode?.height ?? Int(Self.logicalHeight)

        print("")
        print("Miroo Virtual Display")
        print("---------------------")
        print("Display ID: \(id)")
        print("Name: \(b.name)")
        print("Resolution: \(pixelW)x\(pixelH)")
        print("Logical: \(logW)x\(logH)")
        print("Status: \(active ? "ACTIVE" : (online ? "ONLINE" : "INACTIVE"))")
        print("Bounds: origin=(\(Int(bounds.origin.x)), \(Int(bounds.origin.y))), size=(\(Int(bounds.width))x\(Int(bounds.height)))")
        print("")

        // Enumerate all active displays using public CoreGraphics APIs
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var activeList = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &activeList, &count)

        print("Displays detected: \(count)")
        print("")

        for (index, dispID) in activeList.enumerated() {
            let isMain = CGDisplayIsMain(dispID) != 0
            let isMirrored = CGDisplayIsInMirrorSet(dispID) != 0
            let dispBounds = CGDisplayBounds(dispID)
            let dispMode = CGDisplayCopyDisplayMode(dispID)
            let pW = dispMode?.pixelWidth ?? 0
            let pH = dispMode?.pixelHeight ?? 0
            let lW = dispMode?.width ?? 0
            let lH = dispMode?.height ?? 0

            // Query NSScreen localized name if available
            var screenName = (dispID == id) ? b.name : "Display"
            for screen in NSScreen.screens {
                if let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID, num == dispID {
                    screenName = screen.localizedName
                    break
                }
            }

            print("Display \(index + 1):")
            print("  ID: \(dispID)")
            print("  Name: \(screenName)")
            print("  Main Display: \(isMain ? "YES" : "NO")")
            print("  Mirrored: \(isMirrored ? "YES" : "NO")")
            print("  Physical Resolution: \(pW)x\(pH)")
            print("  Logical Resolution: \(lW)x\(lH)")
            print("  Bounds: (\(Int(dispBounds.origin.x)), \(Int(dispBounds.origin.y)), \(Int(dispBounds.width)), \(Int(dispBounds.height)))")
            print("")
        }
    }
}
