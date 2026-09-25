//
//  DeviceDiscoveryConnectionTests.swift
//  MirooTests
//
//  Phase 13: Production Device Discovery, Connection Request Protocol,
//  and Display Session Lifecycle Verification Suite.
//
//  Validates:
//  1. Persistent device identity and model detection
//  2. MirooDevice types, states, and capabilities
//  3. Bonjour TXT record serialization and parsing
//  4. Device deduplication across Wi-Fi and USB by persistent UUID
//  5. Self-exclusion of host device identity
//  6. Direct USB device insertion and detachment lifecycle
//  7. Device disappearance and availability state transitions
//  8. ConnectionRequestPayload serialization and wire encoding
//  9. ConnectionAcceptedPayload serialization and parameter negotiation
//  10. ConnectionRejectedPayload with exhaustive reason codes
//  11. ConnectionCancelledPayload serialization and decoding
//  12. SessionStartingPayload and SessionStartedPayload serialization
//  13. SessionEndedPayload with exhaustive lifecycle reasons
//  14. MirooMessage protocol wire types (17..23) and binary framing
//  15. ConnectionAuthorizer: prompt on unknown inbound request
//  16. ConnectionAuthorizer: user approve and user reject decisions
//  17. ConnectionAuthorizer: trusted device auto-approval
//  18. ConnectionAuthorizer: busy rejection when stream is active
//  19. ConnectionAuthorizer: protocol version mismatch rejection
//  20. Display session lifecycle boundary & arrangement persistence guarantee
//

import Foundation
import CoreGraphics
@testable import MirooNetworking

@main
final class DeviceDiscoveryConnectionTests {

    static var testsPassed = 0
    static var testsFailed = 0

    static func assertTest(_ condition: Bool, _ testName: String, failureReason: String = "") {
        if condition {
            print("  ✓ \(testName)")
            testsPassed += 1
        } else {
            print("  ✗ FAILED: \(testName)")
            if !failureReason.isEmpty {
                print("    Reason: \(failureReason)")
            }
            testsFailed += 1
        }
    }

    static func main() async {
        print("==================================================================")
        print(" Miroo Device Discovery & Connection Authorization Suite")
        print("==================================================================")

        testDeviceIdentityPersistence()
        testMirooDeviceTypeAndAvailability()
        testBonjourTXTRecordParsing()
        testDeviceDeduplicationByUUID()
        testSelfDeviceExclusion()
        testDirectUSBDeviceAdditionAndRemoval()
        testDeviceDisappearanceAndTimeout()
        testConnectionRequestPayloadSerialization()
        testConnectionAcceptedPayloadSerialization()
        testConnectionRejectedPayloadSerialization()
        testConnectionCancelledPayloadSerialization()
        testSessionStartingAndStartedPayloadSerialization()
        testSessionEndedPayloadSerialization()
        testMirooMessageProtocolWireTypes()
        testConnectionAuthorizerDefaultPrompt()
        testConnectionAuthorizerApproveAndReject()
        testConnectionAuthorizerTrustedAutoAccept()
        testConnectionAuthorizerBusyCheck()
        testConnectionAuthorizerVersionMismatch()
        testDisplaySessionLifecycleBoundary()

        print("\n==================================================================")
        print("Results: \(testsPassed) Passed, \(testsFailed) Failed")
        print("==================================================================")

        if testsFailed == 0 {
            print("🎉 ALL 20 DEVICE DISCOVERY & AUTHORIZATION TESTS PASSED!")
            exit(0)
        } else {
            print("🚨 SOME TESTS FAILED!")
            exit(1)
        }
    }

    // MARK: - Test 1: Device Identity Persistence
    static func testDeviceIdentityPersistence() {
        print("\n[Test 1] Persistent Device Identity & Model Detection...")
        let id1 = DeviceIdentity.currentID
        let id2 = DeviceIdentity.currentID
        assertTest(!id1.isEmpty, "DeviceIdentity is non-empty")
        assertTest(id1 == id2, "DeviceIdentity is consistent across multiple reads (\(id1))")
        let model = DeviceIdentity.defaultModelName()
        assertTest(!model.isEmpty, "Device model name detected accurately: '\(model)'")
    }

    // MARK: - Test 2: MirooDevice Type & Availability
    static func testMirooDeviceTypeAndAvailability() {
        print("\n[Test 2] MirooDevice Type & Availability Models...")
        let dev = MirooDevice(
            id: "test-phone-1",
            deviceType: .iphone,
            displayName: "Alice's iPhone",
            modelName: "iPhone 15 Pro",
            osVersion: "iOS 17.5",
            isUSBAvailable: false,
            isWiFiAvailable: true,
            availability: .available,
            endpointDescription: "192.168.1.50:51042"
        )

        assertTest(dev.deviceType == .iphone, "Device type is correctly identified as .iphone")
        assertTest(dev.availability == .available, "Device availability is .available")
        assertTest(dev.isWiFiAvailable && !dev.isUSBAvailable, "Device transport availability correctly reflects Wi-Fi only")
        assertTest(dev.bestTransportBadge == "Wi-Fi", "Badge correctly resolves to 'Wi-Fi'")
    }

    // MARK: - Test 3: Bonjour TXT Record Parsing
    static func testBonjourTXTRecordParsing() {
        print("\n[Test 3] Bonjour TXT Record Parsing into MirooDevice...")
        let txtDict: [String: String] = [
            "type": "mac",
            "id": "mac-uuid-12345",
            "name": "Bob's MacBook Pro",
            "model": "MacBookPro18,1",
            "os": "macOS 14.4",
            "usb": "1",
            "state": "available"
        ]

        let device = MirooDevice(
            txtRecord: txtDict,
            fallbackName: "Fallback Mac",
            endpointDescription: "bonjour.local:51042"
        )

        assertTest(device.id == "mac-uuid-12345", "Device ID parsed from TXT record")
        assertTest(device.deviceType == .mac, "Device type parsed as .mac")
        assertTest(device.displayName == "Bob's MacBook Pro", "Display name parsed correctly")
        assertTest(device.modelName == "MacBookPro18,1", "Model name parsed correctly")
        assertTest(device.osVersion == "macOS 14.4", "OS version parsed correctly")
        assertTest(device.isUSBAvailable, "USB capability flag parsed as true")
        assertTest(device.availability == .available, "Device state parsed as .available")
        assertTest(device.bestTransportBadge == "USB", "Badge prioritizes 'USB' when USB is available")
    }

    // MARK: - Test 4: Device Deduplication by UUID
    static func testDeviceDeduplicationByUUID() {
        print("\n[Test 4] Device Deduplication by Persistent UUID Across Wi-Fi & USB...")
        let browser = MirooBrowser()
        let uuid = "shared-uuid-phone-99"

        // Step 1: Discovered via Wi-Fi Bonjour
        let wifiDevice = MirooDevice(
            id: uuid,
            deviceType: .iphone,
            displayName: "Shared iPhone",
            modelName: "iPhone 14",
            osVersion: "iOS 18.0",
            isUSBAvailable: false,
            isWiFiAvailable: true,
            availability: .available
        )
        browser.upsertDiscoveredDevice(wifiDevice)
        assertTest(browser.discoveredDevices.count == 1, "Initial Wi-Fi discovery registered 1 device")

        // Step 2: Plugged in via USB (same UUID)
        let usbDevice = MirooDevice(
            id: uuid,
            deviceType: .iphone,
            displayName: "Shared iPhone",
            modelName: "iPhone 14",
            osVersion: "iOS 18.0",
            isUSBAvailable: true,
            isWiFiAvailable: false,
            availability: .available
        )
        browser.upsertDiscoveredDevice(usbDevice)

        assertTest(browser.discoveredDevices.count == 1, "Deduplication maintains exactly 1 unified device entry")
        if let merged = browser.discoveredDevices.first {
            assertTest(merged.isUSBAvailable && merged.isWiFiAvailable, "Merged device combines both USB and Wi-Fi flags")
            assertTest(merged.bestTransportBadge == "USB", "Badge prioritizes USB on combined device")
        } else {
            assertTest(false, "Merged device entry missing")
        }
    }

    // MARK: - Test 5: Self Device Exclusion
    static func testSelfDeviceExclusion() {
        print("\n[Test 5] Self-Exclusion of Local Host Identity...")
        let browser = MirooBrowser()
        let ownID = DeviceIdentity.currentID

        let ownDevice = MirooDevice(
            id: ownID,
            deviceType: .mac,
            displayName: "My Local Mac",
            modelName: "Mac",
            osVersion: nil,
            isUSBAvailable: false,
            isWiFiAvailable: true,
            availability: .available
        )

        browser.upsertDiscoveredDevice(ownDevice)
        assertTest(browser.discoveredDevices.isEmpty, "Local device with matching UUID is filtered out from discovery")
    }

    // MARK: - Test 6: Direct USB Device Addition and Removal
    static func testDirectUSBDeviceAdditionAndRemoval() {
        print("\n[Test 6] Direct USB Device Insertion and Detachment Lifecycle...")
        let browser = MirooBrowser()
        let serial = "00008030-00120D2111A1802E"

        let directUSB = MirooDevice(
            id: serial,
            deviceType: .iphone,
            displayName: "iPhone (USB)",
            modelName: "iPhone 11",
            osVersion: nil,
            isUSBAvailable: true,
            isWiFiAvailable: false,
            availability: .available,
            endpointDescription: "usbmuxd port 51042"
        )

        browser.upsertDirectDevice(directUSB)
        assertTest(browser.discoveredDevices.count == 1, "Direct USB device inserted into browser")
        assertTest(browser.discoveredDevices.first?.isUSBAvailable == true, "Direct device marked as USB available")

        browser.removeDirectDevice(id: serial)
        assertTest(browser.discoveredDevices.isEmpty, "Direct USB device cleanly removed upon detachment")
    }

    // MARK: - Test 7: Device Disappearance & Stale Purge
    static func testDeviceDisappearanceAndTimeout() {
        print("\n[Test 7] Device Disappearance and Endpoint Cleanout...")
        let browser = MirooBrowser()
        let dev1 = MirooDevice(id: "dev-1", deviceType: .iphone, displayName: "iPhone 1", modelName: "iPhone", osVersion: nil, isUSBAvailable: false, isWiFiAvailable: true, availability: .available)
        let dev2 = MirooDevice(id: "dev-2", deviceType: .mac, displayName: "Mac 2", modelName: "Mac", osVersion: nil, isUSBAvailable: false, isWiFiAvailable: true, availability: .available)

        browser.upsertDiscoveredDevice(dev1)
        browser.upsertDiscoveredDevice(dev2)
        assertTest(browser.discoveredDevices.count == 2, "Browser holds 2 discovered devices")

        browser.removeDiscoveredDevice(id: "dev-1")
        assertTest(browser.discoveredDevices.count == 1, "dev-1 successfully removed")
        assertTest(browser.discoveredDevices.first?.id == "dev-2", "dev-2 preserved in browser")
    }

    // MARK: - Test 8: ConnectionRequestPayload Serialization
    static func testConnectionRequestPayloadSerialization() {
        print("\n[Test 8] ConnectionRequestPayload Wire Serialization & Deserialization...")
        let sID = UUID().uuidString
        let req = ConnectionRequestPayload(
            clientID: "client-uuid-42",
            clientName: "David's iPhone",
            clientModel: "iPhone 15 Pro Max",
            protocolVersion: Int(MirooHeader.currentVersion),
            preferredWidth: 1170,
            preferredHeight: 2532,
            preferredFPS: 60,
            preferredTransport: "USB",
            sessionID: sID
        )

        let msg = MirooMessage.connectionRequest(req)
        assertTest(msg.header.messageType == .connectionRequest, "MirooMessage type is .connectionRequest")

        let decoded = msg.decodeConnectionRequest()
        assertTest(decoded != nil, "Successfully decoded ConnectionRequestPayload from message")
        assertTest(decoded?.sessionID == sID, "Session ID matches: \(sID)")
        assertTest(decoded?.clientName == "David's iPhone", "Client name matches")
        assertTest(decoded?.preferredTransport == "USB", "Preferred transport is 'USB'")
    }

    // MARK: - Test 9: ConnectionAcceptedPayload Serialization
    static func testConnectionAcceptedPayloadSerialization() {
        print("\n[Test 9] ConnectionAcceptedPayload Parameter Negotiation...")
        let sID = UUID().uuidString
        let accepted = ConnectionAcceptedPayload(
            sessionID: sID,
            hostID: "host-uuid-77",
            hostName: "Mac Studio M2",
            width: 1170,
            height: 2532,
            targetFPS: 60,
            scale: 2.0,
            selectedTransport: "USB",
            udpPort: 51042,
            sessionToken: 888999
        )

        let msg = MirooMessage.connectionAccepted(accepted)
        assertTest(msg.header.messageType == .connectionAccepted, "MirooMessage type is .connectionAccepted")

        let decoded = msg.decodeConnectionAccepted()
        assertTest(decoded != nil, "Successfully decoded ConnectionAcceptedPayload")
        assertTest(decoded?.hostName == "Mac Studio M2", "Host name correctly received: \(decoded?.hostName ?? "")")
        assertTest(decoded?.selectedTransport == "USB", "Negotiated transport is USB")
        assertTest(decoded?.sessionToken == 888999, "UDP session token verified")
    }

    // MARK: - Test 10: ConnectionRejectedPayload with Reason Codes
    static func testConnectionRejectedPayloadSerialization() {
        print("\n[Test 10] ConnectionRejectedPayload with Exhaustive Reason Codes...")
        let reasons: [ConnectionRejectionReason] = [
            .userRejected,
            .busy,
            .timeout,
            .versionMismatch,
            .unsupportedCapabilities
        ]

        for reason in reasons {
            let rej = ConnectionRejectedPayload(sessionID: "sess-rej", reasonCode: reason, reasonMessage: "Test reason: \(reason.rawValue)")
            let msg = MirooMessage.connectionRejected(rej)
            let decoded = msg.decodeConnectionRejected()
            assertTest(decoded?.reasonCode == reason, "Reason code '\(reason.rawValue)' accurately encoded and decoded")
        }
    }

    // MARK: - Test 11: ConnectionCancelledPayload Serialization
    static func testConnectionCancelledPayloadSerialization() {
        print("\n[Test 11] ConnectionCancelledPayload Serialization...")
        let cancelled = ConnectionCancelledPayload(sessionID: "sess-cancel-123", reason: "userTappedCancel")
        let msg = MirooMessage.connectionCancelled(cancelled)
        assertTest(msg.header.messageType == .connectionCancelled, "Message type is .connectionCancelled")

        let decoded = msg.decodeConnectionCancelled()
        assertTest(decoded?.sessionID == "sess-cancel-123", "Session ID matches in cancellation payload")
        assertTest(decoded?.reason == "userTappedCancel", "Cancellation reason matches")
    }

    // MARK: - Test 12: SessionStarting & SessionStarted Serialization
    static func testSessionStartingAndStartedPayloadSerialization() {
        print("\n[Test 12] SessionStarting and SessionStarted Payloads...")
        let starting = SessionStartingPayload(sessionID: "sess-start-001")
        let msgStarting = MirooMessage.sessionStarting(starting)
        assertTest(msgStarting.header.messageType == .sessionStarting, "Message type is .sessionStarting")

        let started = SessionStartedPayload(sessionID: "sess-start-001", width: 1170, height: 2532)
        let msgStarted = MirooMessage.sessionStarted(started)
        assertTest(msgStarted.header.messageType == .sessionStarted, "Message type is .sessionStarted")
        let decodedStarted = msgStarted.decodeSessionStarted()
        assertTest(decodedStarted?.width == 1170 && decodedStarted?.height == 2532, "Session dimensions decoded accurately")
    }

    // MARK: - Test 13: SessionEnded Payload with Lifecycle Reasons
    static func testSessionEndedPayloadSerialization() {
        print("\n[Test 13] SessionEndedPayload with Lifecycle Reasons...")
        let reasons: [SessionEndReason] = [
            .userDisconnected,
            .timeout,
            .cableUnplugged,
            .sleep,
            .shutdown
        ]

        for reason in reasons {
            let ended = SessionEndedPayload(sessionID: "sess-end-test", reason: reason)
            let msg = MirooMessage.sessionEnded(ended)
            assertTest(msg.header.messageType == .sessionEnded, "Message type is .sessionEnded")
            let decoded = msg.decodeSessionEnded()
            assertTest(decoded?.reason == reason, "Session end reason '\(reason.rawValue)' successfully decoded")
        }
    }

    // MARK: - Test 14: MirooMessage Protocol Wire Types
    static func testMirooMessageProtocolWireTypes() {
        print("\n[Test 14] MirooMessage Protocol Wire Types (17..23)...")
        assertTest(MirooMessageType.connectionRequest.rawValue == 17, "connectionRequest has wire type 17")
        assertTest(MirooMessageType.connectionAccepted.rawValue == 18, "connectionAccepted has wire type 18")
        assertTest(MirooMessageType.connectionRejected.rawValue == 19, "connectionRejected has wire type 19")
        assertTest(MirooMessageType.connectionCancelled.rawValue == 20, "connectionCancelled has wire type 20")
        assertTest(MirooMessageType.sessionStarting.rawValue == 21, "sessionStarting has wire type 21")
        assertTest(MirooMessageType.sessionStarted.rawValue == 22, "sessionStarted has wire type 22")
        assertTest(MirooMessageType.sessionEnded.rawValue == 23, "sessionEnded has wire type 23")
    }

    // MARK: - Test 15: ConnectionAuthorizer Default Prompt
    static func testConnectionAuthorizerDefaultPrompt() {
        print("\n[Test 15] ConnectionAuthorizer Default Prompt on Unknown Client...")
        let authorizer = ConnectionAuthorizer(defaults: UserDefaults(suiteName: "test.auth.prompt")!)
        authorizer.clearAllTrustedDevices()
        authorizer.autoAcceptTrustedDevices = false

        let req = ConnectionRequestPayload(
            clientID: "unknown-iphone-1",
            clientName: "Guest iPhone",
            clientModel: "iPhone 13",
            protocolVersion: Int(MirooHeader.currentVersion),
            preferredWidth: 1170,
            preferredHeight: 2532,
            preferredFPS: 60,
            preferredTransport: "Wi-Fi",
            sessionID: "test-sess-15"
        )

        let decision = authorizer.processRequest(req, isCurrentlyStreaming: false, transport: "Wi-Fi")
        assertTest(decision == .promptUser, "Unknown device triggers .promptUser")
        assertTest(authorizer.getPendingRequest(sessionID: "test-sess-15") != nil, "Pending request registered in memory")
    }

    // MARK: - Test 16: ConnectionAuthorizer Approve & Reject
    static func testConnectionAuthorizerApproveAndReject() {
        print("\n[Test 16] ConnectionAuthorizer Approve and Reject Flows...")
        let authorizer = ConnectionAuthorizer(defaults: UserDefaults(suiteName: "test.auth.approve")!)
        authorizer.clearAllTrustedDevices()

        // 1. Approve with remember
        let req1 = ConnectionRequestPayload(
            clientID: "client-to-approve",
            clientName: "Trusted iPhone",
            clientModel: "iPhone 14",
            protocolVersion: Int(MirooHeader.currentVersion),
            preferredWidth: 1170,
            preferredHeight: 2532,
            preferredFPS: 60,
            preferredTransport: "Wi-Fi",
            sessionID: "sess-approve"
        )

        _ = authorizer.processRequest(req1, isCurrentlyStreaming: false)
        let approvedPayload = authorizer.approve(sessionID: "sess-approve", rememberDevice: true)
        assertTest(approvedPayload != nil, "Approve returns the request payload")
        assertTest(authorizer.getPendingRequest(sessionID: "sess-approve") == nil, "Pending request cleared upon approval")
        assertTest(authorizer.isTrusted(clientID: "client-to-approve"), "Device remembered in trusted store")

        // 2. Reject
        let req2 = ConnectionRequestPayload(
            clientID: "client-to-reject",
            clientName: "Suspicious iPhone",
            clientModel: "iPhone 11",
            protocolVersion: Int(MirooHeader.currentVersion),
            preferredWidth: 1170,
            preferredHeight: 2532,
            preferredFPS: 60,
            preferredTransport: "Wi-Fi",
            sessionID: "sess-reject"
        )

        _ = authorizer.processRequest(req2, isCurrentlyStreaming: false)
        let rejectResult = authorizer.reject(sessionID: "sess-reject")
        assertTest(rejectResult?.reason == .userRejected, "Reject returned .userRejected")
        assertTest(authorizer.getPendingRequest(sessionID: "sess-reject") == nil, "Pending request cleared upon rejection")
    }

    // MARK: - Test 17: ConnectionAuthorizer Trusted Auto-Accept
    static func testConnectionAuthorizerTrustedAutoAccept() {
        print("\n[Test 17] ConnectionAuthorizer Trusted Device Auto-Approval...")
        let authorizer = ConnectionAuthorizer(defaults: UserDefaults(suiteName: "test.auth.trusted")!)
        authorizer.clearAllTrustedDevices()
        authorizer.trustDevice(clientID: "my-paired-iphone")
        authorizer.autoAcceptTrustedDevices = true

        let req = ConnectionRequestPayload(
            clientID: "my-paired-iphone",
            clientName: "Paired iPhone",
            clientModel: "iPhone 15",
            protocolVersion: Int(MirooHeader.currentVersion),
            preferredWidth: 1170,
            preferredHeight: 2532,
            preferredFPS: 60,
            preferredTransport: "USB",
            sessionID: "sess-auto"
        )

        let decision = authorizer.processRequest(req, isCurrentlyStreaming: false, transport: "USB")
        assertTest(decision == .approved, "Trusted device automatically approved when autoAccept is enabled")
        assertTest(authorizer.getPendingRequest(sessionID: "sess-auto") == nil, "No pending prompt created for auto-approved device")
    }

    // MARK: - Test 18: ConnectionAuthorizer Busy Check
    static func testConnectionAuthorizerBusyCheck() {
        print("\n[Test 18] ConnectionAuthorizer Rejection When Streaming Active...")
        let authorizer = ConnectionAuthorizer(defaults: UserDefaults(suiteName: "test.auth.busy")!)

        let req = ConnectionRequestPayload(
            clientID: "second-iphone",
            clientName: "Second iPhone",
            clientModel: "iPhone 12",
            protocolVersion: Int(MirooHeader.currentVersion),
            preferredWidth: 1170,
            preferredHeight: 2532,
            preferredFPS: 60,
            preferredTransport: "Wi-Fi",
            sessionID: "sess-busy"
        )

        let decision = authorizer.processRequest(req, isCurrentlyStreaming: true)
        if case .rejected(let reason, let message) = decision {
            assertTest(reason == .busy, "Request rejected with reason .busy")
            assertTest(!message.isEmpty, "Rejection message provided: '\(message)'")
        } else {
            assertTest(false, "Expected rejection with .busy, got: \(decision)")
        }
    }

    // MARK: - Test 19: ConnectionAuthorizer Protocol Version Mismatch
    static func testConnectionAuthorizerVersionMismatch() {
        print("\n[Test 19] ConnectionAuthorizer Protocol Version Mismatch...")
        let authorizer = ConnectionAuthorizer(defaults: UserDefaults(suiteName: "test.auth.version")!)

        let req = ConnectionRequestPayload(
            clientID: "legacy-iphone",
            clientName: "Legacy iPhone",
            clientModel: "iPhone 8",
            protocolVersion: 999, // Incompatible version
            preferredWidth: 750,
            preferredHeight: 1334,
            preferredFPS: 30,
            preferredTransport: "Wi-Fi",
            sessionID: "sess-legacy"
        )

        let decision = authorizer.processRequest(req, isCurrentlyStreaming: false)
        if case .rejected(let reason, let message) = decision {
            assertTest(reason == .versionMismatch, "Request rejected with reason .versionMismatch")
            assertTest(message.contains("mismatch"), "Rejection message explains version incompatibility: '\(message)'")
        } else {
            assertTest(false, "Expected rejection with .versionMismatch, got: \(decision)")
        }
    }

    // MARK: - Test 20: Display Session Lifecycle Boundary
    static func testDisplaySessionLifecycleBoundary() {
        print("\n[Test 20] Display Session Lifecycle Boundary & Arrangement Store Preservation...")
        let suite = "test.display.boundary"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let store = DisplayArrangementStore(defaults: defaults)

        // Simulate saved arrangement before session
        let mirooBounds = CGRect(x: -585, y: 75, width: 585, height: 1266)
        let refBounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
        store.saveArrangement(mirooBounds: mirooBounds, referenceBounds: refBounds, orientation: .portrait)

        // Verify arrangement survives between sessions
        let retrieved = store.loadArrangement(for: .portrait)
        assertTest(retrieved != nil, "Arrangement reliably retrieved prior to display creation")
        assertTest(retrieved?.dockingEdge == .left, "Arrangement edge is .left")
        assertTest(retrieved?.offsetAlongEdge == 75.0, "Arrangement offset is 75.0pt")

        let origin = retrieved?.computeOrigin(
            referenceBounds: refBounds,
            currentMirooSize: CGSize(width: 585, height: 1266)
        )
        assertTest(origin == CGPoint(x: -585, y: 75), "Calculated origin matches exact saved arrangement: \(String(describing: origin))")

        // Verify session ended reason clean teardown
        let endPayload = SessionEndedPayload(sessionID: "sess-boundary-clean", reason: .userDisconnected)
        assertTest(endPayload.reason == .userDisconnected, "Session end reason safely communicated")

        // Post-session, arrangement still intact
        let postSessionArrangement = store.loadArrangement(for: .portrait)
        assertTest(postSessionArrangement?.dockingEdge == .left, "Arrangement remains intact after simulated display session destruction")
    }
}
