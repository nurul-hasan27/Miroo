//
//  DisplayArrangementStore.swift
//  MirooNetworking
//
//  Production Display Arrangement Persistence & Restoration for Miroo.
//  Captures, persists, and reconstructs relative display arrangement relationships
//  relative to the Mac's primary display across reconnect cycles, resolution changes,
//  orientation toggles, and display ID mutations.
//

import Foundation
import CoreGraphics
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Docking Edge

/// The geometric docking relationship of the Miroo display relative to the reference display.
public enum DisplayDockingEdge: String, Codable, Sendable, CaseIterable {
    case left
    case right
    case above
    case below
    case custom
}

// MARK: - Display Arrangement Relationship

/// Encapsulates the relative spatial relationship between the Miroo virtual display
/// and the reference display (typically the Mac's primary internal screen).
public struct DisplayArrangementRelationship: Codable, Sendable, Equatable {
    /// The docking edge relative to the reference screen
    public var dockingEdge: DisplayDockingEdge

    /// Fractional alignment along the docking axis (0.0 = top/left, 0.5 = center, 1.0 = bottom/right)
    public var alignmentRatio: Double

    /// Pixel offset along the docking axis (Y offset for left/right, X offset for above/below)
    public var offsetAlongEdge: Double

    /// Arbitrary relative offsets from reference display origin (used for custom / multi-monitor offsets)
    public var relativeOffsetX: Double
    public var relativeOffsetY: Double

    /// Bounds of the reference display at the time of recording
    public var referenceBounds: CGRect

    /// Size of the Miroo virtual display at the time of recording
    public var mirooSize: CGSize

    /// Orientation mode during recording
    public var orientation: MirooOrientation

    /// Timestamp of when this arrangement was saved
    public var timestamp: Date

    public init(
        dockingEdge: DisplayDockingEdge,
        alignmentRatio: Double,
        offsetAlongEdge: Double,
        relativeOffsetX: Double,
        relativeOffsetY: Double,
        referenceBounds: CGRect,
        mirooSize: CGSize,
        orientation: MirooOrientation,
        timestamp: Date = Date()
    ) {
        self.dockingEdge = dockingEdge
        self.alignmentRatio = alignmentRatio
        self.offsetAlongEdge = offsetAlongEdge
        self.relativeOffsetX = relativeOffsetX
        self.relativeOffsetY = relativeOffsetY
        self.referenceBounds = referenceBounds
        self.mirooSize = mirooSize
        self.orientation = orientation
        self.timestamp = timestamp
    }

    /// Computes the target origin for the Miroo display relative to current reference display bounds
    /// and current Miroo display dimensions.
    public func computeOrigin(referenceBounds currentRef: CGRect, currentMirooSize: CGSize) -> CGPoint {
        var targetX: CGFloat = 0
        var targetY: CGFloat = 0

        let refW = currentRef.width
        let refH = currentRef.height
        let mirW = currentMirooSize.width
        let mirH = currentMirooSize.height

        // Minimum pixel contact overlap required by WindowServer so mouse can traverse screens
        let minContact: CGFloat = 30.0

        switch dockingEdge {
        case .left:
            targetX = currentRef.minX - mirW
            if abs(refH - referenceBounds.height) < 1.0 {
                targetY = currentRef.minY + CGFloat(offsetAlongEdge)
            } else {
                targetY = currentRef.minY + CGFloat(alignmentRatio) * (refH - mirH)
            }
            // Clamp Y to ensure cursor transit contact with reference screen
            let minY = currentRef.minY - mirH + minContact
            let maxY = currentRef.maxY - minContact
            targetY = min(max(targetY, minY), maxY)

        case .right:
            targetX = currentRef.maxX
            if abs(refH - referenceBounds.height) < 1.0 {
                targetY = currentRef.minY + CGFloat(offsetAlongEdge)
            } else {
                targetY = currentRef.minY + CGFloat(alignmentRatio) * (refH - mirH)
            }
            let minY = currentRef.minY - mirH + minContact
            let maxY = currentRef.maxY - minContact
            targetY = min(max(targetY, minY), maxY)

        case .above:
            targetY = currentRef.minY - mirH
            if abs(refW - referenceBounds.width) < 1.0 {
                targetX = currentRef.minX + CGFloat(offsetAlongEdge)
            } else {
                targetX = currentRef.minX + CGFloat(alignmentRatio) * (refW - mirW)
            }
            let minX = currentRef.minX - mirW + minContact
            let maxX = currentRef.maxX - minContact
            targetX = min(max(targetX, minX), maxX)

        case .below:
            targetY = currentRef.maxY
            if abs(refW - referenceBounds.width) < 1.0 {
                targetX = currentRef.minX + CGFloat(offsetAlongEdge)
            } else {
                targetX = currentRef.minX + CGFloat(alignmentRatio) * (refW - mirW)
            }
            let minX = currentRef.minX - mirW + minContact
            let maxX = currentRef.maxX - minContact
            targetX = min(max(targetX, minX), maxX)

        case .custom:
            let scaleX = refW > 0 && referenceBounds.width > 0 ? (refW / referenceBounds.width) : 1.0
            let scaleY = refH > 0 && referenceBounds.height > 0 ? (refH / referenceBounds.height) : 1.0
            targetX = currentRef.minX + (CGFloat(relativeOffsetX) * scaleX)
            targetY = currentRef.minY + (CGFloat(relativeOffsetY) * scaleY)
        }

        return CGPoint(x: round(targetX), y: round(targetY))
    }
}

// MARK: - Display Arrangement Store

/// Thread-safe persistence and arrangement reconciliation store.
/// Manages loading, saving, and verifying Miroo virtual display positioning relative
/// to the primary Mac screen across session and reconnect lifecycles.
public final class DisplayArrangementStore: @unchecked Sendable {

    public static let shared = DisplayArrangementStore()

    // MARK: - Storage Keys
    public static let portraitKey = "Miroo.DisplayArrangement.Portrait"
    public static let landscapeKey = "Miroo.DisplayArrangement.Landscape"
    public static let lastOrientationKey = "Miroo.DisplayArrangement.LastOrientation"

    // Miroo Display Identity Constants
    public static let mirooVendorID: UInt32 = 0x5043   // 'PC'
    public static let mirooProductID: UInt32 = 0x4F53  // 'OS'
    public static let mirooDisplayNamePrefix = "Miroo"

    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Persistence API

    /// Saves the current arrangement of the Miroo display relative to the reference display.
    @discardableResult
    public func saveArrangement(
        mirooBounds: CGRect,
        referenceBounds: CGRect,
        orientation: MirooOrientation
    ) -> DisplayArrangementRelationship {
        lock.lock()
        defer { lock.unlock() }

        let relationship = analyzeRelationship(
            mirooBounds: mirooBounds,
            referenceBounds: referenceBounds,
            orientation: orientation
        )

        let key = (orientation == .landscape) ? Self.landscapeKey : Self.portraitKey
        if let encoded = try? JSONEncoder().encode(relationship) {
            defaults.set(encoded, forKey: key)
            defaults.set(orientation.rawValue, forKey: Self.lastOrientationKey)
            defaults.synchronize()
        }

        return relationship
    }

    /// Loads the stored arrangement for the specified orientation, if available.
    public func loadArrangement(for orientation: MirooOrientation) -> DisplayArrangementRelationship? {
        lock.lock()
        defer { lock.unlock() }

        let key = (orientation == .landscape) ? Self.landscapeKey : Self.portraitKey
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(DisplayArrangementRelationship.self, from: data)
    }

    /// The last orientation used by Miroo.
    public var lastSavedOrientation: MirooOrientation? {
        lock.lock()
        defer { lock.unlock() }

        guard let raw = defaults.string(forKey: Self.lastOrientationKey) else { return nil }
        return MirooOrientation(rawValue: raw)
    }

    /// Clears any saved arrangements (useful for tests and resetting to defaults).
    public func clearArrangements() {
        lock.lock()
        defer { lock.unlock() }

        defaults.removeObject(forKey: Self.portraitKey)
        defaults.removeObject(forKey: Self.landscapeKey)
        defaults.removeObject(forKey: Self.lastOrientationKey)
        defaults.synchronize()
    }

    // MARK: - Geometric Relationship Analysis

    /// Determines the docking edge, alignment ratio, and relative offsets from raw rectangles.
    public func analyzeRelationship(
        mirooBounds: CGRect,
        referenceBounds: CGRect,
        orientation: MirooOrientation
    ) -> DisplayArrangementRelationship {
        let tolerance: CGFloat = 16.0 // pixel tolerance for docking detection

        let isLeft = abs(mirooBounds.maxX - referenceBounds.minX) <= tolerance
        let isRight = abs(mirooBounds.minX - referenceBounds.maxX) <= tolerance
        let isAbove = abs(mirooBounds.maxY - referenceBounds.minY) <= tolerance
        let isBelow = abs(mirooBounds.minY - referenceBounds.maxY) <= tolerance

        let dockingEdge: DisplayDockingEdge
        let alignmentRatio: Double
        let offsetAlongEdge: Double

        if isLeft {
            dockingEdge = .left
            offsetAlongEdge = Double(mirooBounds.minY - referenceBounds.minY)
            let denom = max(1.0, referenceBounds.height - mirooBounds.height)
            alignmentRatio = Double((mirooBounds.minY - referenceBounds.minY) / denom)
        } else if isRight {
            dockingEdge = .right
            offsetAlongEdge = Double(mirooBounds.minY - referenceBounds.minY)
            let denom = max(1.0, referenceBounds.height - mirooBounds.height)
            alignmentRatio = Double((mirooBounds.minY - referenceBounds.minY) / denom)
        } else if isAbove {
            dockingEdge = .above
            offsetAlongEdge = Double(mirooBounds.minX - referenceBounds.minX)
            let denom = max(1.0, referenceBounds.width - mirooBounds.width)
            alignmentRatio = Double((mirooBounds.minX - referenceBounds.minX) / denom)
        } else if isBelow {
            dockingEdge = .below
            offsetAlongEdge = Double(mirooBounds.minX - referenceBounds.minX)
            let denom = max(1.0, referenceBounds.width - mirooBounds.width)
            alignmentRatio = Double((mirooBounds.minX - referenceBounds.minX) / denom)
        } else {
            // Detached or diagonal: analyze closest border or mark as custom
            let distLeft = abs(mirooBounds.maxX - referenceBounds.minX)
            let distRight = abs(mirooBounds.minX - referenceBounds.maxX)
            let distAbove = abs(mirooBounds.maxY - referenceBounds.minY)
            let distBelow = abs(mirooBounds.minY - referenceBounds.maxY)

            let minDist = min(distLeft, distRight, distAbove, distBelow)
            if minDist < 100.0 {
                if minDist == distLeft {
                    dockingEdge = .left
                    offsetAlongEdge = Double(mirooBounds.minY - referenceBounds.minY)
                    alignmentRatio = Double((mirooBounds.minY - referenceBounds.minY) / max(1.0, referenceBounds.height - mirooBounds.height))
                } else if minDist == distRight {
                    dockingEdge = .right
                    offsetAlongEdge = Double(mirooBounds.minY - referenceBounds.minY)
                    alignmentRatio = Double((mirooBounds.minY - referenceBounds.minY) / max(1.0, referenceBounds.height - mirooBounds.height))
                } else if minDist == distAbove {
                    dockingEdge = .above
                    offsetAlongEdge = Double(mirooBounds.minX - referenceBounds.minX)
                    alignmentRatio = Double((mirooBounds.minX - referenceBounds.minX) / max(1.0, referenceBounds.width - mirooBounds.width))
                } else {
                    dockingEdge = .below
                    offsetAlongEdge = Double(mirooBounds.minX - referenceBounds.minX)
                    alignmentRatio = Double((mirooBounds.minX - referenceBounds.minX) / max(1.0, referenceBounds.width - mirooBounds.width))
                }
            } else {
                dockingEdge = .custom
                offsetAlongEdge = 0
                alignmentRatio = 0
            }
        }

        let relX = Double(mirooBounds.minX - referenceBounds.minX)
        let relY = Double(mirooBounds.minY - referenceBounds.minY)

        return DisplayArrangementRelationship(
            dockingEdge: dockingEdge,
            alignmentRatio: alignmentRatio,
            offsetAlongEdge: offsetAlongEdge,
            relativeOffsetX: relX,
            relativeOffsetY: relY,
            referenceBounds: referenceBounds,
            mirooSize: mirooBounds.size,
            orientation: orientation,
            timestamp: Date()
        )
    }

    // MARK: - Restoration Target Origin Calculation

    /// Computes the restored target origin for the Miroo display.
    /// Clamps against active display geometry so windows/cursors are never lost off-screen.
    public func targetOrigin(
        for orientation: MirooOrientation,
        mirooSize: CGSize,
        referenceBounds explicitRef: CGRect? = nil,
        activeDisplayBounds: [CGRect] = []
    ) -> CGPoint {
        var refBounds: CGRect
        if let explicit = explicitRef {
            refBounds = explicit
        } else {
            #if canImport(AppKit)
            if NSScreen.main != nil {
                let mainID = CGMainDisplayID()
                refBounds = CGDisplayBounds(mainID)
            } else {
                refBounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
            }
            #else
            refBounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
            #endif
        }

        // Validate reference dimensions to prevent division by zero, negative, or degenerate bounds
        if refBounds.size.width <= 100 || refBounds.size.height <= 100 || refBounds.width <= 100 || refBounds.height <= 100 {
            refBounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
        }


        // Cross-orientation inheritance: if no arrangement saved for current orientation,
        // inherit docking edge from the opposite orientation if the user previously arranged it.
        let oppositeOri: MirooOrientation = (orientation == .portrait) ? .landscape : .portrait
        let savedRelationship = loadArrangement(for: orientation) ?? loadArrangement(for: oppositeOri)

        guard let saved = savedRelationship else {
            // Default first-connection arrangement: immediately to the right of the reference display, top-aligned
            return CGPoint(x: refBounds.maxX, y: refBounds.minY)
        }

        let candidateOrigin = saved.computeOrigin(referenceBounds: refBounds, currentMirooSize: mirooSize)
        let candidateRect = CGRect(origin: candidateOrigin, size: mirooSize)

        // Topology validation: verify candidate touches or intersects at least one active screen boundary
        let screens = activeDisplayBounds.isEmpty ? [refBounds] : activeDisplayBounds
        let touchesActiveScreen = screens.contains { screen in
            candidateRect.intersects(screen.insetBy(dx: -16, dy: -16))
        }

        if !touchesActiveScreen {
            // If disjoint (e.g. an external monitor was unplugged), fall back to docking beside reference display
            return CGPoint(x: refBounds.maxX, y: refBounds.minY)
        }

        return candidateOrigin
    }

    // MARK: - Display Identification

    /// Reliable heuristic to determine if a display ID corresponds to the Miroo virtual display.
    /// Checks vendor/product IDs, display localized name, and metadata.
    public func isMirooDisplay(displayID: CGDirectDisplayID) -> Bool {
        guard displayID != 0 && displayID != kCGNullDirectDisplay else { return false }

        // 1. Direct hardware vendor/product identification
        let vendor = CGDisplayVendorNumber(displayID)
        let product = CGDisplayModelNumber(displayID)
        if vendor == Self.mirooVendorID && product == Self.mirooProductID {
            return true
        }

        // 2. Localized screen name matching
        #if canImport(AppKit)
        for screen in NSScreen.screens {
            if let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
               num == displayID {
                let name = screen.localizedName
                if name.localizedCaseInsensitiveContains(Self.mirooDisplayNamePrefix) {
                    return true
                }
            }
        }
        #endif

        return false
    }

}
