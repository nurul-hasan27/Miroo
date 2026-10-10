import Foundation
import CoreGraphics
import CGVirtualDisplayBridge

/// A virtual Mac display sized to the phone's panel (full screen, notch included).
///
/// The display publishes several "looks like" resolutions in the phone's aspect ratio, all HiDPI (a 2x framebuffer that is
/// captured down to the panel, so text stays sharp). They appear in System Settings > Displays and in Miroo's menu.
/// macOS only offers HiDPI modes from about 1210x558 points upward, which gives these steps for an iPhone 11 panel:
/// 1210x558 · 1344x622 · 1434x662 · 1524x704 · 1650x762 · 1792x828 (smallest = biggest text, largest = most room).
public final class VirtualDisplay {
    /// Long side of each "looks like" step as a fraction of the panel's long side (in pixels).
    public static let lookSteps: [Double] = [0.675, 0.75, 0.8, 0.85, 0.92, 1.0]

    public private(set) var pixelWidth: Int, pixelHeight: Int
    public private(set) var displayID: CGDirectDisplayID = 0
    /// Index into `lookSteps` that should be active (kept across rotation).
    public private(set) var lookIndex: Int
    private var bridge: CGVirtualDisplayBridge?

    /// Logical (point) sizes of every "looks like" step for a panel of the given pixel size.
    public static func logicalSizes(pixelWidth: Int, pixelHeight: Int) -> [CGSize] {
        lookSteps.map { f in
            CGSize(width: ((Double(pixelWidth) * f) / 2).rounded() * 2, height: ((Double(pixelHeight) * f) / 2).rounded() * 2)
        }
    }

    /// - Parameters:
    ///   - pixelWidth/pixelHeight: the panel's pixels in the current orientation (e.g. 1792x828 landscape).
    ///   - lookIndex: which "looks like" step to start in.
    public init?(name: String, pixelWidth: Int, pixelHeight: Int, lookIndex: Int = 0, stableSerial: UInt32? = nil, queue: DispatchQueue = .main) {
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        self.lookIndex = max(0, min(Self.lookSteps.count - 1, lookIndex))
        let sizes = Self.logicalSizes(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        let start = sizes[self.lookIndex]
        // framebuffer cap: 2x the largest step, so every step stays selectable in either orientation
        let cap = UInt32(max(sizes.last!.width, sizes.last!.height) * 2)
        // A stable serial per phone lets macOS remember where the user placed this display (Displays settings).
        let base = stableSerial.map { 0x10000 + ($0 & 0xFFFFFF) } ?? ((UInt32(Date().timeIntervalSince1970) & 0x3FFF) + 0x2000)
        for attempt in 0..<15 {
            guard let b = try? CGVirtualDisplayBridge(
                name: name, logicalWidth: UInt32(start.width), logicalHeight: UInt32(start.height),
                scaleFactor: 2, vendorID: 0x5043, productID: 0x4F54, serialNum: base + UInt32(attempt),
                sizeInMillimeters: CGSize(width: 140, height: 65), maxPixels: cap, queue: queue), b.displayID != 0 else { continue }
            // WindowServer registers the display asynchronously: poll instead of sleeping a fixed time
            var online = false
            for _ in 0..<40 {
                if CGDisplayIsOnline(b.displayID) != 0 { online = true; break }
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
            }
            if online { bridge = b; displayID = b.displayID; break }
            b.destroy()
        }
        guard let bridge else { return nil }
        publishModes(bridge)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    }

    public var bounds: CGRect { CGDisplayBounds(displayID) }

    /// Publishes all "looks like" sizes (preferred one first) and activates the preferred one.
    private func publishModes(_ b: CGVirtualDisplayBridge) {
        let sizes = Self.logicalSizes(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        var ordered = sizes
        let pref = ordered.remove(at: lookIndex)
        ordered.insert(pref, at: 0)
        _ = b.applyLogicalSizes(ordered.map { NSValue(size: NSSize(width: $0.width, height: $0.height)) })
        selectLook(lookIndex, wait: true)
    }

    /// Switches to a "looks like" step (smaller index = bigger text). Returns false if macOS did not accept the mode.
    @discardableResult
    public func selectLook(_ index: Int, wait: Bool = false) -> Bool {
        guard displayID != 0 else { return false }
        let i = max(0, min(Self.lookSteps.count - 1, index))
        lookIndex = i
        let target = Self.logicalSizes(pixelWidth: pixelWidth, pixelHeight: pixelHeight)[i]
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        // the mode list can lag a moment behind applySettings
        for _ in 0..<(wait ? 40 : 1) {
            let modes = (CGDisplayCopyAllDisplayModes(displayID, opts) as? [CGDisplayMode]) ?? []
            if let m = modes.first(where: { $0.width == Int(target.width) && $0.height == Int(target.height) && $0.pixelWidth == 2 * $0.width }) {
                if let cur = CGDisplayCopyDisplayMode(displayID), cur.width == m.width, cur.pixelWidth == m.pixelWidth { return true }
                return CGDisplaySetDisplayMode(displayID, m, nil) == .success
            }
            if !wait { break }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.025))
        }
        return false
    }

    /// Records the step the user chose in System Settings so it survives rotation and reconnects.
    public func noteLook(_ index: Int) { lookIndex = max(0, min(Self.lookSteps.count - 1, index)) }

    /// The "looks like" step the display is currently in (the user may have changed it in System Settings), if it is one of ours.
    public var currentLookIndex: Int? {
        guard displayID != 0, let cur = CGDisplayCopyDisplayMode(displayID), cur.pixelWidth == 2 * cur.width else { return nil }
        return Self.logicalSizes(pixelWidth: pixelWidth, pixelHeight: pixelHeight).firstIndex { Int($0.width) == cur.width && Int($0.height) == cur.height }
    }

    /// Re-targets the display to a new panel size (rotation). Windows and the display's position are kept; the preferred
    /// "looks like" step is kept (or the one the user last chose in System Settings).
    @discardableResult
    public func resize(pixelWidth w: Int, pixelHeight h: Int) -> Bool {
        guard let bridge else { return false }
        if let cur = currentLookIndex { lookIndex = cur }
        pixelWidth = w; pixelHeight = h
        publishModes(bridge)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        return true
    }

    public func destroy() { bridge?.destroy(); bridge = nil; displayID = 0 }
    deinit { destroy() }
}
