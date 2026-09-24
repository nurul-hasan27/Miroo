//
//  DisplayPositionManager.swift
//  MirooMac
//
//  Phase 13: Persistent Virtual Display Arrangement & Positioning.
//  Remembers, persists, and automatically restores the user's chosen
//  extended display layout across reconnects, reboots, orientations,
//  and multi-monitor configuration changes without hardcoded coordinates.
//

import Foundation
import CoreGraphics
import Cocoa

/// Relative docking edge of the virtual display with respect to the primary monitor.
public enum DockingEdge: String, Codable, Sendable {
    case left
    case right
    case top
    case bottom
    case custom
}

/// Persistent record of the virtual display's arrangement in the macOS display desktop topology.
public struct StoredDisplayPosition: Codable, Equatable, Sendable {
    public let x: CGFloat
    public let y: CGFloat
    public let orientation: MirooOrientation
    public let logicalWidth: CGFloat
    public let logicalHeight: CGFloat
    public let referenceMainBounds: CGRect
    public let relativeOffsetX: CGFloat
    public let relativeOffsetY: CGFloat
    public let dockingEdge: DockingEdge
    public let alignmentRatio: CGFloat
    public let timestamp: Date

    public init(
        x: CGFloat,
        y: CGFloat,
        orientation: MirooOrientation,
        logicalWidth: CGFloat,
        logicalHeight: CGFloat,
        referenceMainBounds: CGRect,
        relativeOffsetX: CGFloat,
        relativeOffsetY: CGFloat,
        dockingEdge: DockingEdge,
        alignmentRatio: CGFloat,
        timestamp: Date = Date()
    ) {
        self.x = x
        self.y = y
        self.orientation = orientation
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.referenceMainBounds = referenceMainBounds
        self.relativeOffsetX = relativeOffsetX
        self.relativeOffsetY = relativeOffsetY
        self.dockingEdge = dockingEdge
        self.alignmentRatio = alignmentRatio
        self.timestamp = timestamp
    }
}

/// Manages saving, recalculating, clamping, and applying the Miroo virtual display position.
public final class DisplayPositionManager: @unchecked Sendable {

    public static let shared = DisplayPositionManager()

    public let userDefaults: UserDefaults
    private let keyPrefix = "com.miroo.display.position."

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    // MARK: - Persistence Keys

    private func storageKey(for orientation: MirooOrientation) -> String {
        return "\(keyPrefix)\(orientation.rawValue)"
    }

    // MARK: - Position Saving

    /// Captures and persists the current arrangement of the virtual display.
    @discardableResult
    public func savePosition(
        for displayID: CGDirectDisplayID,
        orientation: MirooOrientation
    ) -> StoredDisplayPosition? {
        guard displayID != 0, CGDisplayIsOnline(displayID) != 0 else { return nil }

        let currentBounds = CGDisplayBounds(displayID)
        let mainID = CGMainDisplayID()
        let mainBounds = CGDisplayBounds(mainID)

        let relativeX = currentBounds.origin.x - mainBounds.origin.x
        let relativeY = currentBounds.origin.y - mainBounds.origin.y

        // Determine spatial docking edge relative to main screen
        let edge: DockingEdge
        let ratio: CGFloat

        if currentBounds.maxX <= mainBounds.minX + 5 {
            edge = .left
            ratio = (mainBounds.height > 0) ? (currentBounds.minY - mainBounds.minY) / mainBounds.height : 0.0
        } else if currentBounds.minX >= mainBounds.maxX - 5 {
            edge = .right
            ratio = (mainBounds.height > 0) ? (currentBounds.minY - mainBounds.minY) / mainBounds.height : 0.0
        } else if currentBounds.maxY <= mainBounds.minY + 5 {
            edge = .top
            ratio = (mainBounds.width > 0) ? (currentBounds.minX - mainBounds.minX) / mainBounds.width : 0.0
        } else if currentBounds.minY >= mainBounds.maxY - 5 {
            edge = .bottom
            ratio = (mainBounds.width > 0) ? (currentBounds.minX - mainBounds.minX) / mainBounds.width : 0.0
        } else {
            edge = .custom
            ratio = 0.0
        }

        let record = StoredDisplayPosition(
            x: currentBounds.origin.x,
            y: currentBounds.origin.y,
            orientation: orientation,
            logicalWidth: currentBounds.width,
            logicalHeight: currentBounds.height,
            referenceMainBounds: mainBounds,
            relativeOffsetX: relativeX,
            relativeOffsetY: relativeY,
            dockingEdge: edge,
            alignmentRatio: ratio,
            timestamp: Date()
        )

        if let data = try? JSONEncoder().encode(record) {
            userDefaults.set(data, forKey: storageKey(for: orientation))
            print("[DisplayPositionManager] Persisted \(orientation.rawValue) position: (\(Int(record.x)), \(Int(record.y))) [edge: \(edge.rawValue)]")
        }

        return record
    }

    /// Loads the stored position record for the requested orientation.
    public func loadSavedPosition(for orientation: MirooOrientation) -> StoredDisplayPosition? {
        guard let data = userDefaults.data(forKey: storageKey(for: orientation)),
              let record = try? JSONDecoder().decode(StoredDisplayPosition.self, from: data) else {
            return nil
        }
        return record
    }

    /// Clears any saved positions for the given orientation, or all if nil.
    public func clearSavedPosition(for orientation: MirooOrientation? = nil) {
        if let o = orientation {
            userDefaults.removeObject(forKey: storageKey(for: o))
        } else {
            userDefaults.removeObject(forKey: storageKey(for: .portrait))
            userDefaults.removeObject(forKey: storageKey(for: .landscape))
        }
    }

    // MARK: - Position Resolution & Clamping

    /// Pure geometric function calculating the target position for the virtual display,
    /// seamlessly restoring user's chosen arrangement or gracefully clamping if monitor topology changed.
    public func calculateTargetOrigin(
        orientation: MirooOrientation,
        virtualWidth: CGFloat,
        virtualHeight: CGFloat,
        currentMainBounds: CGRect,
        activePhysicalDisplayBounds: [CGRect]
    ) -> CGPoint {
        guard let saved = loadSavedPosition(for: orientation) else {
            // First run / no saved position: dock cleanly to right of primary display
            return CGPoint(
                x: currentMainBounds.maxX,
                y: currentMainBounds.minY
            )
        }

        // 1. Calculate proposed absolute origin based on relative offset from current main display
        let proposedX = currentMainBounds.origin.x + saved.relativeOffsetX
        let proposedY = currentMainBounds.origin.y + saved.relativeOffsetY
        let proposedRect = CGRect(x: proposedX, y: proposedY, width: virtualWidth, height: virtualHeight)

        // 2. Validate adjacency: check if proposed rect touches or is within 20pt of any active physical display
        let isAdjacentToPhysicalDisplay = activePhysicalDisplayBounds.contains { physical in
            // Expands physical rect by 20pt to test if proposedRect shares a border or gap
            let expanded = physical.insetBy(dx: -20, dy: -20)
            return expanded.intersects(proposedRect)
        }

        if isAdjacentToPhysicalDisplay {
            return CGPoint(x: proposedX, y: proposedY)
        }

        // 3. Physical monitor topology changed (e.g. secondary external monitor was unplugged).
        // Gracefully recalculate position using saved docking edge and alignment ratio against current main display!
        print("[DisplayPositionManager] Saved position (\(Int(proposedX)), \(Int(proposedY))) is disjoint from active displays. Clamping to main display...")

        switch saved.dockingEdge {
        case .left:
            let clampedY = currentMainBounds.minY + (saved.alignmentRatio * currentMainBounds.height)
            return CGPoint(x: currentMainBounds.minX - virtualWidth, y: min(max(clampedY, currentMainBounds.minY - virtualHeight + 40), currentMainBounds.maxY - 40))

        case .right:
            let clampedY = currentMainBounds.minY + (saved.alignmentRatio * currentMainBounds.height)
            return CGPoint(x: currentMainBounds.maxX, y: min(max(clampedY, currentMainBounds.minY - virtualHeight + 40), currentMainBounds.maxY - 40))

        case .top:
            let clampedX = currentMainBounds.minX + (saved.alignmentRatio * currentMainBounds.width)
            return CGPoint(x: min(max(clampedX, currentMainBounds.minX - virtualWidth + 40), currentMainBounds.maxX - 40), y: currentMainBounds.minY - virtualHeight)

        case .bottom:
            let clampedX = currentMainBounds.minX + (saved.alignmentRatio * currentMainBounds.width)
            return CGPoint(x: min(max(clampedX, currentMainBounds.minX - virtualWidth + 40), currentMainBounds.maxX - 40), y: currentMainBounds.maxY)

        case .custom:
            // Fallback to right side
            return CGPoint(x: currentMainBounds.maxX, y: currentMainBounds.minY)
        }
    }

    // MARK: - CoreGraphics Application

    /// Applies the calculated position to the virtual display using public CoreGraphics APIs.
    @discardableResult
    public func applyRestoredPosition(
        to displayID: CGDirectDisplayID,
        orientation: MirooOrientation
    ) -> Bool {
        guard displayID != 0, CGDisplayIsOnline(displayID) != 0 else { return false }

        let mainID = CGMainDisplayID()
        let mainBounds = CGDisplayBounds(mainID)
        let virtualBounds = CGDisplayBounds(displayID)

        // Enumerate active physical displays excluding the virtual display
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var physicalBounds: [CGRect] = []
        if count > 0 {
            var activeList = [CGDirectDisplayID](repeating: 0, count: Int(count))
            CGGetActiveDisplayList(count, &activeList, &count)
            for id in activeList where id != displayID {
                physicalBounds.append(CGDisplayBounds(id))
            }
        }
        if physicalBounds.isEmpty {
            physicalBounds.append(mainBounds)
        }

        let targetOrigin = calculateTargetOrigin(
            orientation: orientation,
            virtualWidth: virtualBounds.width,
            virtualHeight: virtualBounds.height,
            currentMainBounds: mainBounds,
            activePhysicalDisplayBounds: physicalBounds
        )

        let targetX = Int32(round(targetOrigin.x))
        let targetY = Int32(round(targetOrigin.y))

        print("[DisplayPositionManager] Applying position (\(targetX), \(targetY)) for display ID \(displayID)...")

        var config: CGDisplayConfigRef?
        let beginErr = CGBeginDisplayConfiguration(&config)
        guard beginErr == .success, let configRef = config else {
            print("[DisplayPositionManager] Failed to begin display configuration: \(beginErr.rawValue)")
            return false
        }

        // Detach from mirroring
        CGConfigureDisplayMirrorOfDisplay(configRef, displayID, kCGNullDirectDisplay)

        // Configure origin
        CGConfigureDisplayOrigin(configRef, displayID, targetX, targetY)

        let completeErr = CGCompleteDisplayConfiguration(configRef, .forSession)
        if completeErr != .success {
            print("[DisplayPositionManager] CGCompleteDisplayConfiguration returned error: \(completeErr.rawValue)")
            return false
        }

        print("[DisplayPositionManager] Successfully restored display position to (\(targetX), \(targetY)).")
        return true
    }
}
