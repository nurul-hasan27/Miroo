//
//  MirooDevice.swift
//  MirooNetworking
//
//  Production Device Discovery & Identity Model for Miroo.
//  Encapsulates stable device identity, device type, connection capabilities (USB/Wi-Fi),
//  availability state, and network endpoints.
//

import Foundation
import Network

// MARK: - Device Type

public enum MirooDeviceType: String, Codable, Sendable, CaseIterable {
    case mac
    case iphone

    public var displayTitle: String {
        switch self {
        case .mac: return "Mac"
        case .iphone: return "iPhone"
        }
    }
}

// MARK: - Device Availability

public enum MirooDeviceAvailability: String, Codable, Sendable, CaseIterable {
    case available
    case busy
    case requestPending
    case connected

    public var statusDescription: String {
        switch self {
        case .available: return "Available"
        case .busy: return "Busy"
        case .requestPending: return "Approval Pending"
        case .connected: return "Connected"
        }
    }
}

// MARK: - Production Miroo Device Model

public struct MirooDevice: Identifiable, Hashable, Sendable, Codable {
    public let id: String                    // Stable persistent device UUID
    public let deviceType: MirooDeviceType   // .mac or .iphone
    public var displayName: String          // e.g. "Nurul's iPhone"
    public var modelName: String            // e.g. "iPhone 11"
    public var osVersion: String?           // e.g. "iOS 18.0" / "macOS 15.0"
    public var isUSBAvailable: Bool
    public var isWiFiAvailable: Bool
    public var availability: MirooDeviceAvailability
    public var lastSeen: Date
    public var endpointDescription: String?

    public init(
        id: String,
        deviceType: MirooDeviceType,
        displayName: String,
        modelName: String,
        osVersion: String? = nil,
        isUSBAvailable: Bool = false,
        isWiFiAvailable: Bool = true,
        availability: MirooDeviceAvailability = .available,
        lastSeen: Date = Date(),
        endpointDescription: String? = nil
    ) {
        self.id = id
        self.deviceType = deviceType
        self.displayName = displayName
        self.modelName = modelName
        self.osVersion = osVersion
        self.isUSBAvailable = isUSBAvailable
        self.isWiFiAvailable = isWiFiAvailable
        self.availability = availability
        self.lastSeen = lastSeen
        self.endpointDescription = endpointDescription
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: MirooDevice, rhs: MirooDevice) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Stable Device Identity Manager

public final class DeviceIdentity: @unchecked Sendable {
    public static let shared = DeviceIdentity()
    public static let storageKey = "com.miroo.device.persistentID"

    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Returns a unique, persistent device UUID that survives restarts and reconnects.
    public var persistentID: String {
        lock.lock()
        defer { lock.unlock() }

        if let existing = defaults.string(forKey: Self.storageKey), !existing.isEmpty {
            return existing
        }
        let newID = UUID().uuidString
        defaults.set(newID, forKey: Self.storageKey)
        defaults.synchronize()
        return newID
    }

    /// Convenience static accessor for the persistent device ID
    public static var currentID: String {
        shared.persistentID
    }

    /// Returns a user-friendly model name without exposing unnecessary private details.
    public static func defaultModelName() -> String {
        #if os(macOS)
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let raw = String(cString: model)
        if raw.contains("MacBookAir") { return "MacBook Air" }
        if raw.contains("MacBookPro") { return "MacBook Pro" }
        if raw.contains("Macmini") { return "Mac mini" }
        if raw.contains("iMac") { return "iMac" }
        if raw.contains("MacPro") { return "Mac Pro" }
        if raw.contains("Mac") { return "Mac" }
        return raw.isEmpty ? "Mac" : raw
        #else
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
        if identifier.contains("iPhone12,1") { return "iPhone 11" }
        if identifier.contains("iPhone13,2") { return "iPhone 12" }
        if identifier.contains("iPhone14,2") { return "iPhone 13 Pro" }
        if identifier.contains("iPhone14,5") { return "iPhone 13" }
        if identifier.contains("iPhone15,2") { return "iPhone 14 Pro" }
        if identifier.contains("iPhone15,4") { return "iPhone 15" }
        if identifier.contains("iPhone16,1") { return "iPhone 15 Pro" }
        if identifier.contains("iPhone17") { return "iPhone 16" }
        if identifier.contains("iPhone") { return "iPhone" }
        if identifier.contains("iPad") { return "iPad" }
        return identifier.isEmpty ? "iPhone" : identifier
        #endif
    }

    /// Returns localized host/device name.
    public static func defaultDisplayName() -> String {
        #if os(macOS)
        return Host.current().localizedName ?? "Mac"
        #else
        return "iPhone"
        #endif
    }

    /// Returns clean OS version string.
    public static func currentOSVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        #if os(macOS)
        return "macOS \(v.majorVersion).\(v.minorVersion)"
        #else
        return "iOS \(v.majorVersion).\(v.minorVersion)"
        #endif
    }
}
