import Foundation
import CoreGraphics

/// Keeps a phone's virtual display alive for a short grace period after an unexpected disconnect (phone locked, app
/// switched, Wi-Fi hiccup). Windows stay where they were and reconnecting skips the ~0.5 s display creation.
@MainActor
public final class VirtualDisplayPool {
    public static let shared = VirtualDisplayPool()
    private var kept: [UInt32: (vd: VirtualDisplay, expire: Task<Void, Never>)] = [:]

    public func acquire(name: String, width: Int, height: Int, lookIndex: Int, serial: UInt32?) -> VirtualDisplay? {
        if let serial, let k = kept.removeValue(forKey: serial) {
            k.expire.cancel()
            if k.vd.displayID != 0, CGDisplayIsOnline(k.vd.displayID) != 0 {
                if k.vd.pixelWidth != width || k.vd.pixelHeight != height { _ = k.vd.resize(pixelWidth: width, pixelHeight: height) }
                k.vd.selectLook(lookIndex)
                return k.vd
            }
            k.vd.destroy()
        }
        return VirtualDisplay(name: name, pixelWidth: width, pixelHeight: height, lookIndex: lookIndex, stableSerial: serial)
    }

    /// `keepFor <= 0` destroys immediately.
    public func release(_ vd: VirtualDisplay, serial: UInt32?, keepFor: TimeInterval) {
        guard keepFor > 0, let serial else { vd.destroy(); return }
        kept[serial]?.expire.cancel()
        kept[serial]?.vd.destroy()
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(keepFor * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { if let k = self?.kept.removeValue(forKey: serial) { k.vd.destroy() } }
        }
        kept[serial] = (vd, task)
    }
}
