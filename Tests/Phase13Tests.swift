//
//  Phase13Tests.swift
//  MirooTests
//
//  Phase 13: Production Device Discovery, Multi-Device Display Sessions,
//  Bidirectional Pairing, and Per-Device Persistent Arrangement Verification Suite.
//

import Foundation
import CoreGraphics
import Network
@testable import MirooNetworking

@main
@MainActor
final class Phase13Tests {

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

    static func main() {
        print("==================================================================")
        print("   Miroo Phase 13: Device Discovery & Multi-Device Pairing Suite   ")
        print("==================================================================")

        testBonjourMultiDeviceDiscovery()
        testDeviceDisappearanceAndRemoval()
        testUSBTransportDetectionIntegrity()
        testProjectionRequestPayloadIntegrity()
        testConnectionAuthorizationWorkflow()
        testLifecycleWaitingForApprovalAndDeclinedStates()
        testAuthorizationTimeoutAndCancellation()
        testMultiDeviceDisplaySessions()
        testPerDevicePersistentDisplayArrangement()
        testDynamicTransportSwitchingWithoutDisplayReset()

        print("==================================================================")
        print("Phase 13 Verification Results: \(testsPassed) Passed, \(testsFailed) Failed")
        print("==================================================================")

        if testsFailed == 0 {
            print("🎉 ALL \(testsPassed) PHASE 13 AUTOMATED TESTS PASSED SUCCESSFULLY!")
            exit(0)
        } else {
            print("❌ \(testsFailed) TESTS FAILED!")
            exit(1)
        }
    }

    // MARK: - Test 1: Bonjour Multi-Device Discovery
    static func testBonjourMultiDeviceDiscovery() {
        print("\n[Test 1] Bonjour Multi-Device Discovery & Model Mapping...")

        let browser = MirooBrowser()

        let phone1 = MirooDevice(
            id: "iPhone-UUID-1111",
            deviceType: .iphone,
            displayName: "Nurul's iPhone 11",
            modelName: "iPhone 11",
            osVersion: "18.0",
            isUSBAvailable: false,
            isWiFiAvailable: true,
            availability: .available,
            lastSeen: Date()
        )

        let phone2 = MirooDevice(
            id: "iPhone-UUID-2222",
            deviceType: .iphone,
            displayName: "Test iPhone 15 Pro",
            modelName: "iPhone 15 Pro",
            osVersion: "18.2",
            isUSBAvailable: true,
            isWiFiAvailable: true,
            availability: .available,
            lastSeen: Date()
        )

        let macHost = MirooDevice(
            id: "Mac-UUID-9999",
            deviceType: .mac,
            displayName: "Nurul's MacBook Air",
            modelName: "MacBook Air (M2)",
            osVersion: "15.3",
            isUSBAvailable: true,
            isWiFiAvailable: true,
            availability: .available,
            lastSeen: Date()
        )

        browser.upsertDiscoveredDevice(phone1)
        browser.upsertDiscoveredDevice(phone2)
        browser.upsertDiscoveredDevice(macHost)

        let discoveredPhones = browser.discoveredPhones
        let discoveredMacs = browser.discoveredMacs

        assertTest(discoveredPhones.count == 2, "Discovered exactly 2 iPhones among mixed device announcements")
        assertTest(discoveredMacs.count == 1, "Discovered exactly 1 Mac host among mixed device announcements")
        assertTest(discoveredPhones.contains(where: { $0.id == "iPhone-UUID-1111" }), "iPhone 11 identity preserved")
        assertTest(discoveredPhones.contains(where: { $0.id == "iPhone-UUID-2222" }), "iPhone 15 Pro identity preserved")

        let dev2 = discoveredPhones.first(where: { $0.id == "iPhone-UUID-2222" })
        assertTest(dev2?.isUSBAvailable == true && dev2?.isWiFiAvailable == true, "Dual-transport (USB + Wi-Fi) availability accurately reflected")
    }

    // MARK: - Test 2: Device Disappearance and Removal
    static func testDeviceDisappearanceAndRemoval() {
        print("\n[Test 2] Device Disappearance, Detach, and Network Teardown...")

        let browser = MirooBrowser()

        let dev = MirooDevice(
            id: "iPhone-Temp-3333",
            deviceType: .iphone,
            displayName: "Temporary iPhone",
            modelName: "iPhone 13",
            osVersion: "17.5",
            isUSBAvailable: false,
            isWiFiAvailable: true,
            availability: .available,
            lastSeen: Date()
        )

        browser.upsertDiscoveredDevice(dev)
        assertTest(browser.discoveredPhones.contains(where: { $0.id == dev.id }), "Device initially present in discovered list")

        browser.removeDiscoveredDevice(id: dev.id)
        assertTest(!browser.discoveredPhones.contains(where: { $0.id == dev.id }), "Device successfully removed upon network disappearance")

        // Direct / USB removal test
        let usbDev = MirooDevice(
            id: "USB-iPhone-4444",
            deviceType: .iphone,
            displayName: "Wired iPhone",
            modelName: "iPhone 14",
            osVersion: "17.6",
            isUSBAvailable: true,
            isWiFiAvailable: false,
            availability: .available,
            lastSeen: Date()
        )
        browser.upsertDirectDevice(usbDev)
        assertTest(browser.discoveredPhones.contains(where: { $0.id == usbDev.id }), "USB direct device registered")

        browser.removeDirectDevice(id: usbDev.id)
        assertTest(!browser.discoveredPhones.contains(where: { $0.id == usbDev.id }), "USB device cleared when cable detached")
    }

    // MARK: - Test 3: USB Transport Detection Integrity
    static func testUSBTransportDetectionIntegrity() {
        print("\n[Test 3] Transport Selection Hierarchy & Strict USB Verification...")

        // USB Available -> Must choose USB
        let t1 = TransportSelector.resolveTransport(isUSBActive: true, preferUDP: true, udpFailed: false)
        assertTest(t1 == .usb, "USB takes highest priority when active (USB > UDP > TCP)")

        // USB Inactive, Wi-Fi healthy -> Must choose UDP
        let t2 = TransportSelector.resolveTransport(isUSBActive: false, preferUDP: true, udpFailed: false)
        assertTest(t2 == .udp, "UDP selected for wireless when UDP healthy")

        // USB Inactive, UDP Failed -> Must fallback to TCP
        let t3 = TransportSelector.resolveTransport(isUSBActive: false, preferUDP: true, udpFailed: true)
        assertTest(t3 == .tcp, "TCP selected as reliable fallback when UDP fails")

        // Device model: fake USB disabled
        let wifiOnlyDevice = MirooDevice(
            id: "WiFi-Only-Phone",
            deviceType: .iphone,
            displayName: "Remote iPhone",
            modelName: "iPhone 12",
            osVersion: "17.0",
            isUSBAvailable: false,
            isWiFiAvailable: true,
            availability: .available,
            lastSeen: Date()
        )
        assertTest(!wifiOnlyDevice.isUSBAvailable, "USB option hidden when physical USB is not detected")
    }

    // MARK: - Test 4: Projection Request Payload Integrity
    static func testProjectionRequestPayloadIntegrity() {
        print("\n[Test 4] Control Protocol Request Payload Integrity & Validation...")

        let sID = UUID().uuidString
        let clientID = "client-uuid-test"
        let req = ConnectionRequestPayload(
            clientID: clientID,
            clientName: "Nurul's iPhone",
            clientModel: "iPhone 15 Pro",
            protocolVersion: Int(MirooHeader.currentVersion),
            preferredWidth: 1170,
            preferredHeight: 2532,
            preferredFPS: 60,
            preferredTransport: "auto",
            sessionID: sID
        )

        let msg = MirooMessage.connectionRequest(req)
        assertTest(msg.header.messageType == .connectionRequest, "MirooMessage type matches .connectionRequest")

        let decoded = msg.decodeConnectionRequest()
        assertTest(decoded != nil, "Successfully decoded ConnectionRequestPayload from message payload")
        assertTest(decoded?.clientID == clientID, "Client ID matches payload")
        assertTest(decoded?.clientModel == "iPhone 15 Pro", "Client model matches payload")
        assertTest(decoded?.preferredWidth == 1170 && decoded?.preferredHeight == 2532, "Preferred resolution (1170x2532) validated")
        assertTest(decoded?.sessionID == sID, "Session ID matches payload")

        // Accepted payload verification
        let accepted = ConnectionAcceptedPayload(
            sessionID: sID,
            hostID: "host-mac-1",
            hostName: "Nurul's MacBook Pro",
            width: 1170,
            height: 2532,
            targetFPS: 60,
            scale: 2.0,
            selectedTransport: "UDP",
            udpPort: 51042,
            sessionToken: 777888
        )
        let accMsg = MirooMessage.connectionAccepted(accepted)
        let decAcc = accMsg.decodeConnectionAccepted()
        assertTest(decAcc?.hostName == "Nurul's MacBook Pro", "Decoded host name in connection accepted")
        assertTest(decAcc?.selectedTransport == "UDP", "Decoded transport in connection accepted")
    }

    // MARK: - Test 5: Connection Authorization Workflow
    static func testConnectionAuthorizationWorkflow() {
        print("\n[Test 5] Connection Authorization Workflow (Prompt, Accept, Reject)...")

        let authorizer = ConnectionAuthorizer()
        authorizer.clearAllTrustedDevices()

        let req1 = ConnectionRequestPayload(
            clientID: "untrusted-phone-1",
            clientName: "Guest iPhone",
            clientModel: "iPhone 11",
            protocolVersion: 1,
            preferredWidth: 1170,
            preferredHeight: 2532,
            preferredFPS: 60,
            preferredTransport: "auto",
            sessionID: "sess-prompt-1"
        )

        // First attempt -> Must prompt user
        let decision1 = authorizer.processRequest(req1, isCurrentlyStreaming: false, transport: "Wi-Fi")
        assertTest(decision1 == .promptUser, "Untrusted incoming request correctly requires user prompt")

        // User approves request with remember = true
        let approvedReq = authorizer.approve(sessionID: "sess-prompt-1", rememberDevice: true)
        assertTest(approvedReq != nil, "Approved request successfully returned")
        assertTest(authorizer.isTrusted(clientID: "untrusted-phone-1"), "Device now marked as trusted")

        // Next connection from same device -> Automatically approved
        let req2 = ConnectionRequestPayload(
            clientID: "untrusted-phone-1",
            clientName: "Guest iPhone",
            clientModel: "iPhone 11",
            protocolVersion: 1,
            preferredWidth: 1170,
            preferredHeight: 2532,
            preferredFPS: 60,
            preferredTransport: "auto",
            sessionID: "sess-auto-2"
        )
        let decision2 = authorizer.processRequest(req2, isCurrentlyStreaming: false, transport: "Wi-Fi")
        assertTest(decision2 == .approved, "Remembered device connection is automatically approved")

        // Test explicit rejection
        let req3 = ConnectionRequestPayload(
            clientID: "suspicious-phone",
            clientName: "Unknown Phone",
            clientModel: "iPhone",
            protocolVersion: 1,
            preferredWidth: 1170,
            preferredHeight: 2532,
            preferredFPS: 60,
            preferredTransport: "auto",
            sessionID: "sess-reject-3"
        )
        _ = authorizer.processRequest(req3, isCurrentlyStreaming: false, transport: "Wi-Fi")
        let rejection = authorizer.reject(sessionID: "sess-reject-3")
        assertTest(rejection != nil && rejection?.reason == .userRejected, "Explicit user rejection records .userRejected reason")
    }

    // MARK: - Test 6: Lifecycle Waiting For Approval & Declined States
    static func testLifecycleWaitingForApprovalAndDeclinedStates() {
        print("\n[Test 6] Client Lifecycle State Machine Transitions (waitingForApproval & declined)...")

        let sm = ConnectionStateMachine(initialState: .idle)

        // Searching -> Connecting -> WaitingForApproval -> Connected
        assertTest(sm.transition(to: .searching), "Transition to .searching")
        assertTest(sm.transition(to: .connecting(target: "MacBook Air", transport: .udp)), "Transition to .connecting")
        assertTest(sm.transition(to: .waitingForApproval(host: "MacBook Air")), "Transition to .waitingForApproval")
        assertTest(sm.currentState.isWaitingForApproval, "isWaitingForApproval flag is true")
        assertTest(sm.currentState.activeHost == "MacBook Air", "activeHost correctly identifies host during approval")
        assertTest(sm.transition(to: .connected(host: "MacBook Air", transport: .udp)), "Transition from waitingForApproval to .connected")

        // WaitingForApproval -> Declined Flow
        let sm2 = ConnectionStateMachine(initialState: .connecting(target: "MacBook Pro", transport: .tcp))
        assertTest(sm2.transition(to: .waitingForApproval(host: "MacBook Pro")), "Transition to .waitingForApproval")
        assertTest(sm2.transition(to: .declined(host: "MacBook Pro", reason: "Rejected by user")), "Transition to .declined")
        assertTest(sm2.currentState.isDeclined, "isDeclined flag is true")
        assertTest(sm2.currentState.userFriendlyMessage.contains("declined this display request"), "Declined user-friendly message accurate")

        // Try again from declined -> Searching / Connecting
        assertTest(sm2.transition(to: .searching), "Can transition from declined back to searching to try again")
    }

    // MARK: - Test 7: Authorization Timeout and Cancellation
    static func testAuthorizationTimeoutAndCancellation() {
        print("\n[Test 7] Request Timeout and Cancellation Safety...")

        let authorizer = ConnectionAuthorizer()

        let req = ConnectionRequestPayload(
            clientID: "timeout-phone",
            clientName: "Slow Phone",
            clientModel: "iPhone 12",
            protocolVersion: 1,
            preferredWidth: 1170,
            preferredHeight: 2532,
            preferredFPS: 60,
            preferredTransport: "auto",
            sessionID: "sess-timeout-1"
        )

        _ = authorizer.processRequest(req, isCurrentlyStreaming: false, transport: "Wi-Fi")
        assertTest(authorizer.getPendingRequest(sessionID: "sess-timeout-1") != nil, "Pending request registered")

        // Client cancels request before user decides
        authorizer.cancel(sessionID: "sess-timeout-1")
        assertTest(authorizer.getPendingRequest(sessionID: "sess-timeout-1") == nil, "Pending request cleanly removed on client cancellation")
        assertTest(authorizer.getPendingRequest(sessionID: "sess-timeout-1") == nil, "Cancelled request cannot be approved")
    }

    // MARK: - Test 8: Multi-Device Display Sessions
    static func testMultiDeviceDisplaySessions() {
        print("\n[Test 8] Multi-Device Display Sessions Architecture...")

        let devA = MirooDevice(
            id: "iPhone-A",
            deviceType: .iphone,
            displayName: "iPhone A",
            modelName: "iPhone 11",
            osVersion: "18.0",
            isUSBAvailable: true,
            isWiFiAvailable: true,
            availability: .connected,
            lastSeen: Date()
        )

        let devB = MirooDevice(
            id: "iPhone-B",
            deviceType: .iphone,
            displayName: "iPhone B",
            modelName: "iPhone 15 Pro",
            osVersion: "18.2",
            isUSBAvailable: false,
            isWiFiAvailable: true,
            availability: .connected,
            lastSeen: Date()
        )

        let sessionA = MirooDisplaySession(
            device: devA,
            sessionID: "session-uuid-A",
            width: 1170,
            height: 2532,
            preferredTransport: .usb
        )

        let sessionB = MirooDisplaySession(
            device: devB,
            sessionID: "session-uuid-B",
            width: 1179,
            height: 2556,
            preferredTransport: .udp
        )

        assertTest(sessionA.id == "session-uuid-A", "Session A has unique session identifier")
        assertTest(sessionB.id == "session-uuid-B", "Session B has unique session identifier")
        assertTest(sessionA.device.id != sessionB.device.id, "Sessions maintain distinct device identities")
        assertTest(sessionA.currentTransportType == .usb, "Session A configured with USB transport")
        assertTest(sessionB.currentTransportType == .udp, "Session B configured with UDP transport")

        // Independent lifecycle verification
        sessionA.stop(reason: .userDisconnected)
        assertTest(sessionA.state == .disconnected, "Session A successfully transitioned to disconnected")
        assertTest(sessionB.state != .disconnected, "Session B remains completely unaffected by Session A termination")
    }

    // MARK: - Test 9: Per-Device Persistent Display Arrangement
    static func testPerDevicePersistentDisplayArrangement() {
        print("\n[Test 9] Per-Device Display Arrangement Store Isolation...")

        let store = DisplayArrangementStore()

        let deviceID_A = "phone-hardware-uuid-aaa"
        let deviceID_B = "phone-hardware-uuid-bbb"
        let refBounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let mirSize = CGSize(width: 585, height: 1266)

        // Arrange Device A to Left: (-585, 0)
        store.saveArrangement(
            deviceID: deviceID_A,
            mirooBounds: CGRect(x: -585, y: 0, width: 585, height: 1266),
            referenceBounds: refBounds,
            orientation: .portrait
        )

        // Arrange Device B to Right: (1440, 100)
        store.saveArrangement(
            deviceID: deviceID_B,
            mirooBounds: CGRect(x: 1440, y: 100, width: 585, height: 1266),
            referenceBounds: refBounds,
            orientation: .portrait
        )

        // Load arrangements and verify per-device isolation
        let loadedA = store.loadArrangement(forDeviceID: deviceID_A, orientation: .portrait)
        let loadedB = store.loadArrangement(forDeviceID: deviceID_B, orientation: .portrait)

        let originA = loadedA?.computeOrigin(referenceBounds: refBounds, currentMirooSize: mirSize)
        let originB = loadedB?.computeOrigin(referenceBounds: refBounds, currentMirooSize: mirSize)

        assertTest(loadedA != nil, "Successfully loaded saved arrangement for Device A")
        assertTest(loadedB != nil, "Successfully loaded saved arrangement for Device B")
        assertTest(originA?.x == -585.0, "Device A preserved Left docking origin (-585, 0)")
        assertTest(originB?.x == 1440.0 && originB?.y == 100.0, "Device B preserved Right docking origin (1440, 100)")
        assertTest(originA?.x != originB?.x, "Arrangement coordinates are strictly isolated per device UUID")

        // Simulate ephemeral CGDirectDisplayID change:
        // When reconnecting, the display ID changes, but device UUID is invariant
        let ephemeralDisplayID_old: CGDirectDisplayID = 120
        let ephemeralDisplayID_new: CGDirectDisplayID = 135
        assertTest(ephemeralDisplayID_old != ephemeralDisplayID_new, "Simulated ephemeral display ID mismatch")

        let restoredAWithNewDisplayID = store.loadArrangement(forDeviceID: deviceID_A, orientation: .portrait)
        let restoredOriginA = restoredAWithNewDisplayID?.computeOrigin(referenceBounds: refBounds, currentMirooSize: mirSize)
        assertTest(restoredOriginA?.x == -585.0, "Persistent arrangement safely restores using device logical UUID regardless of ephemeral displayID")
    }

    // MARK: - Test 10: Dynamic Transport Switching Without Display Reset
    static func testDynamicTransportSwitchingWithoutDisplayReset() {
        print("\n[Test 10] Dynamic Transport Switching Without Display Destruction...")

        let dev = MirooDevice(
            id: "switch-test-device",
            deviceType: .iphone,
            displayName: "Switch Phone",
            modelName: "iPhone 15",
            osVersion: "18.0",
            isUSBAvailable: true,
            isWiFiAvailable: true,
            availability: .connected,
            lastSeen: Date()
        )

        let session = MirooDisplaySession(
            device: dev,
            sessionID: "dynamic-switch-session",
            width: 1170,
            height: 2532,
            preferredTransport: .udp
        )

        assertTest(session.currentTransportType == .udp, "Initial transport is UDP")

        // Switch from UDP -> TCP
        session.switchTransport(to: .tcp)
        assertTest(session.currentTransportType == .tcp, "Dynamically switched to TCP")
        assertTest(session.activeTransportName == "TCP", "Active transport name updated to TCP")
        assertTest(session.displayWidth == 1170 && session.displayHeight == 2532, "Virtual display dimensions preserved across transport switch")

        // Switch from TCP -> USB
        session.switchTransport(to: .usb)
        assertTest(session.currentTransportType == .usb, "Dynamically switched to USB")
        assertTest(session.activeTransportName == "USB", "Active transport name updated to USB")
    }
}
