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
#if canImport(MirooNetworking)
import MirooNetworking
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
    public private(set) var currentOrientation: MirooOrientation = .portrait

    private var screenParamsObserver: Any?
    private let stateLock = os_unfair_lock_t.allocate(capacity: 1)
    private var _isApplyingArrangement: Bool = false

    private func setIsApplyingArrangement(_ value: Bool) {
        os_unfair_lock_lock(stateLock)
        _isApplyingArrangement = value
        os_unfair_lock_unlock(stateLock)
    }

    private func getIsApplyingArrangement() -> Bool {
        os_unfair_lock_lock(stateLock)
        defer { os_unfair_lock_unlock(stateLock) }
        return _isApplyingArrangement
    }

    public var displayID: CGDirectDisplayID {
        return bridge?.displayID ?? 0
    }

    public var isActive: Bool {
        guard let b = bridge, b.isValid else { return false }
        return CGDisplayIsActive(b.displayID) != 0
    }

    /// Dynamically reconfigures the existing virtual display for portrait or landscape orientation.
    @discardableResult
    public func setOrientation(_ orientation: MirooOrientation) -> Bool {
        guard orientation != currentOrientation else { return true }
        guard let b = bridge, b.displayID != 0 else { return false }

        // Block screen reconfiguration notification from treating mode switch as user rearrangement
        setIsApplyingArrangement(true)
        defer {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.setIsApplyingArrangement(false)
            }
        }

        // Capture current arrangement before switching orientation
        if CGDisplayIsOnline(b.displayID) != 0 {
            let currentBounds = CGDisplayBounds(b.displayID)
            let mainBounds = CGDisplayBounds(CGMainDisplayID())
            if currentBounds.width > 0 && currentBounds.height > 0 {
                DisplayArrangementStore.shared.saveArrangement(
                    mirooBounds: currentBounds,
                    referenceBounds: mainBounds,
                    orientation: currentOrientation
                )
            }
        }

        let targetLogW: UInt32
        let targetLogH: UInt32
        if orientation == .landscape {
            targetLogW = Self.logicalHeight // 1266
            targetLogH = Self.logicalWidth  // 585
        } else {
            targetLogW = Self.logicalWidth  // 585
            targetLogH = Self.logicalHeight // 1266
        }

        print("[Miroo] Switching virtual display to \(orientation) (\(targetLogW)x\(targetLogH) logical)...")
        let ok = b.applyMode(withWidth: targetLogW, height: targetLogH)
        if ok {
            self.currentOrientation = orientation
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
            applyDisplayArrangement(restoreSaved: true)
            print("[Miroo] Virtual display successfully switched to \(orientation) (\(CGDisplayPixelsWide(b.displayID))x\(CGDisplayPixelsHigh(b.displayID)) physical).")
            return true
        } else {
            print("[Miroo] ERROR: Failed to apply \(orientation) mode to virtual display.")
            return false
        }
    }

    // MARK: - Lifecycle

    public init(initialOrientation: MirooOrientation? = nil) {
        stateLock.initialize(to: os_unfair_lock())
        if let initOri = initialOrientation {
            self.currentOrientation = initOri
        } else if let saved = DisplayArrangementStore.shared.lastSavedOrientation {
            self.currentOrientation = saved
        }
        startObservingScreenParameters()
    }

    deinit {
        stopObservingScreenParameters()
        destroy()
        stateLock.deallocate()
    }

    // MARK: - Screen Parameter Reconfiguration Observers

    private static let displayReconfigCallback: CGDisplayReconfigurationCallBack = { displayID, flags, userInfo in
        guard let userInfo = userInfo else { return }
        let manager = Unmanaged<VirtualDisplayManager>.fromOpaque(userInfo).takeUnretainedValue()
        manager.handleDisplayReconfiguration(displayID: displayID, flags: flags)
    }

    private func startObservingScreenParameters() {
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback(Self.displayReconfigCallback, pointer)

        #if canImport(AppKit)
        screenParamsObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleScreenParametersChanged()
        }
        #endif
    }

    private func stopObservingScreenParameters() {
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRemoveReconfigurationCallback(Self.displayReconfigCallback, pointer)

        #if canImport(AppKit)
        if let obs = screenParamsObserver {
            NotificationCenter.default.removeObserver(obs)
            screenParamsObserver = nil
        }
        #endif
    }

    private func handleDisplayReconfiguration(displayID: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags) {
        guard let b = bridge, b.displayID != 0 else { return }
        guard DisplayArrangementStore.shouldProcessReconfiguration(
            displayID: displayID,
            targetMirooID: b.displayID,
            flags: flags,
            isApplyingArrangement: getIsApplyingArrangement()
        ) else { return }
        handleScreenParametersChanged()
    }


    private func handleScreenParametersChanged() {
        guard !getIsApplyingArrangement() else { return }
        guard let b = bridge, b.displayID != 0, CGDisplayIsOnline(b.displayID) != 0 else { return }

        let mirooBounds = CGDisplayBounds(b.displayID)
        let mainID = CGMainDisplayID()
        let mainBounds = CGDisplayBounds(mainID)

        guard mirooBounds.width > 0, mirooBounds.height > 0, mainBounds.width > 0, mainBounds.height > 0 else { return }

        let rel = DisplayArrangementStore.shared.saveArrangement(
            mirooBounds: mirooBounds,
            referenceBounds: mainBounds,
            orientation: currentOrientation
        )
        print("[Miroo] User rearranged display in System Settings: edge=\(rel.dockingEdge), offset=(\(Int(rel.relativeOffsetX)), \(Int(rel.relativeOffsetY)))")
    }

    // MARK: - Display Creation & Configuration

    /// Creates the virtual display and positions it as an independent extended desktop.
    @discardableResult
    public func create() -> Bool {
        guard !isCreated else {
            print("[Miroo] Virtual display already created.")
            return true
        }

        // Prevent initial creation notifications from overwriting saved arrangement
        setIsApplyingArrangement(true)
        defer {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.setIsApplyingArrangement(false)
            }
        }

        print("[Miroo] Creating virtual display '\(Self.defaultDisplayName)' in \(currentOrientation)...")

        let targetLogW = (currentOrientation == .landscape) ? Self.logicalHeight : Self.logicalWidth
        let targetLogH = (currentOrientation == .landscape) ? Self.logicalWidth : Self.logicalHeight

        var acquiredBridge: CGVirtualDisplayBridge?
        var lastError: Error?

        let baseSerial = (UInt32(Date().timeIntervalSince1970) & 0x3FFF) + 0x2000
        for attempt in 0..<15 {
            let serial = baseSerial + UInt32(attempt)
            do {
                let candidate = try CGVirtualDisplayBridge(
                    name: Self.defaultDisplayName,
                    logicalWidth: targetLogW,
                    logicalHeight: targetLogH,
                    scaleFactor: Self.scaleFactor,
                    vendorID: Self.defaultVendorID,
                    productID: Self.defaultProductID,
                    serialNum: serial,
                    sizeInMillimeters: Self.defaultSizeInMillimeters,
                    queue: DispatchQueue.main
                )
                if candidate.displayID != 0 {
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
                    if CGDisplayIsOnline(candidate.displayID) != 0 {
                        acquiredBridge = candidate
                        break
                    }
                    candidate.destroy()
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

        // Step 1: Detach mirror and restore user's saved position (or position beside primary if first time)
        if !applyDisplayArrangement(restoreSaved: true) {
            print("[Miroo] WARNING: Failed to configure display arrangement.")
        }

        // Step 2: Select HiDPI mode if available
        selectHiDPIMode()

        // Allow WindowServer to commit the mode switch
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))

        // Step 3: Re-apply arrangement after HiDPI mode switch to guarantee exact placement
        applyDisplayArrangement(restoreSaved: true)

        return true
    }

    /// Tears down and destroys the virtual display.
    public func destroy() {
        guard isCreated, let b = bridge else { return }

        setIsApplyingArrangement(true)
        defer {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.setIsApplyingArrangement(false)
            }
        }

        // Save last known position before destroying
        if CGDisplayIsOnline(b.displayID) != 0 {
            let currentBounds = CGDisplayBounds(b.displayID)
            let mainBounds = CGDisplayBounds(CGMainDisplayID())
            if currentBounds.width > 0 && currentBounds.height > 0 {
                DisplayArrangementStore.shared.saveArrangement(
                    mirooBounds: currentBounds,
                    referenceBounds: mainBounds,
                    orientation: currentOrientation
                )
            }
        }

        print("[Miroo] Destroying virtual display (ID: \(b.displayID))...")
        b.destroy()
        self.bridge = nil
        self.isCreated = false
    }

    // MARK: - Public CoreGraphics Configuration

    /// Restores the user's previously saved display arrangement, or docks beside the primary display.
    @discardableResult
    public func restoreSavedArrangement() -> Bool {
        return applyDisplayArrangement(restoreSaved: true)
    }

    /// Detaches the virtual display from any mirror sets and positions it
    /// according to the user's persisted arrangement using public CoreGraphics APIs.
    @discardableResult
    public func detachFromMirrorAndPositionBesidePrimary() -> Bool {
        return applyDisplayArrangement(restoreSaved: true)
    }

    /// Positions the virtual display relative to the Mac's primary display.
    /// When restoreSaved is true, loads the user's saved arrangement from DisplayArrangementStore.
    @discardableResult
    public func applyDisplayArrangement(restoreSaved: Bool = true) -> Bool {
        guard let bridge = bridge, bridge.displayID != 0 else { return false }
        let id = bridge.displayID

        setIsApplyingArrangement(true)
        defer {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.setIsApplyingArrangement(false)
            }
        }

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
        var activeRects: [CGRect] = []
        if count > 0 {
            var activeList = [CGDirectDisplayID](repeating: 0, count: Int(count))
            CGGetActiveDisplayList(count, &activeList, &count)
            for otherID in activeList where otherID != id {
                if CGDisplayMirrorsDisplay(otherID) == id {
                    CGConfigureDisplayMirrorOfDisplay(configRef, otherID, kCGNullDirectDisplay)
                }
                activeRects.append(CGDisplayBounds(otherID))
            }
        }

        let mainID = CGMainDisplayID()
        let mainBounds = CGDisplayBounds(mainID)

        let logW = (currentOrientation == .landscape) ? Self.logicalHeight : Self.logicalWidth
        let logH = (currentOrientation == .landscape) ? Self.logicalWidth : Self.logicalHeight
        let mirooSize = CGSize(width: Double(logW), height: Double(logH))

        let targetOrigin: CGPoint
        if restoreSaved {
            targetOrigin = DisplayArrangementStore.shared.targetOrigin(
                for: currentOrientation,
                mirooSize: mirooSize,
                referenceBounds: mainBounds,
                activeDisplayBounds: activeRects
            )
        } else {
            targetOrigin = CGPoint(x: mainBounds.maxX, y: mainBounds.minY)
        }

        print("[Miroo] Positioning virtual display ID \(id) at (\(Int(targetOrigin.x)), \(Int(targetOrigin.y))) relative to main display [\(Int(mainBounds.width))x\(Int(mainBounds.height))]...")
        CGConfigureDisplayOrigin(configRef, id, Int32(targetOrigin.x), Int32(targetOrigin.y))

        // Commit configuration permanently for this user session and WindowServer cache
        let completeErr = CGCompleteDisplayConfiguration(configRef, .permanently)
        if completeErr != .success {
            print("[Miroo] CGCompleteDisplayConfiguration returned: \(completeErr.rawValue). Retrying with .forSession...")
            var fallbackConfig: CGDisplayConfigRef?
            if CGBeginDisplayConfiguration(&fallbackConfig) == .success, let fb = fallbackConfig {
                CGConfigureDisplayMirrorOfDisplay(fb, id, kCGNullDirectDisplay)
                CGConfigureDisplayOrigin(fb, id, Int32(targetOrigin.x), Int32(targetOrigin.y))
                let fbErr = CGCompleteDisplayConfiguration(fb, .forSession)
                if fbErr != .success {
                    print("[Miroo] Fallback .forSession also failed: \(fbErr.rawValue). Cancelling configuration transaction...")
                    CGCancelDisplayConfiguration(fb)
                    return false
                }
            } else {
                return false
            }
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
