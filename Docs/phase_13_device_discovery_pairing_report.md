# Miroo Phase 13: Production Device Discovery & Bidirectional Display Pairing Report

**Feature Release:** Phase 13 — Production Multi-Device Miroo System  
**Feature Branch:** `phase-13-device-discovery-pairing`  
**Base:** `origin/phase-13-device-discovery-pairing`  
**Date:** September 25, 2026  
**Status:** Complete, Verified, All Regression Suites Passing  

---

## 1. Executive Summary & Architectural Overview

Phase 13 elevates Miroo from a single-device, server-centric developer utility into a production-grade **multi-device secondary display ecosystem**. In this architecture:
1. **The Mac acts as the primary host and controller**, presenting a native macOS Dashboard application with Dock presence, primary window management, and minimal secondary menu-bar controls.
2. **Multi-device Bonjour discovery** operates continuously across both Wi-Fi (`_miroo._tcp`) and Apple USB (`usbmuxd`), providing real-time inventory of all available iPhones and Macs with accurate hardware metadata.
3. **Mac-Initiated Display Extension**: The Mac user can view all discovered iPhones, select one or multiple devices, and click `[ Extend Display ]` to establish concurrent independent display sessions.
4. **Phone-Initiated Projection Requests**: An iPhone user can discover nearby Macs and tap a Mac to transmit a structured `CONNECTION_REQUEST` control packet.
5. **Explicit Mac Approval Workflow**: When an incoming request arrives, the Mac displays a native non-disruptive approval prompt HUD (`MirooApprovalWindowController`). The Mac user must explicitly **Accept** or **Reject** the request (or opt to remember trusted devices).
6. **Isolated Display Sessions (`MirooDisplaySession`)**: Each secondary display operates as an autonomous session managing its own `VirtualDisplayManager`, `DisplayStreamCapturer`, `VideoEncoder`, `FrameQueue`, `MacInputController`, and transport socket.
7. **Per-Device Persistent Display Arrangement**: Arrangements are saved and restored using logical device UUIDs (`Miroo.DisplayArrangement.<deviceID>.<Orientation>`), ensuring arrangements survive reconnects and ephemeral `CGDirectDisplayID` reassignments without opening System Settings.
8. **Dynamic Video Transport Switching**: Transports (`USB`, `UDP`, `TCP`) can be switched dynamically on the fly from the Mac UI without destroying or recreating the virtual display.

```
                    ┌────────────────────────────┐
                    │      Miroo Mac Host        │
                    │   (Native Dashboard App)   │
                    └─────────────┬──────────────┘
                                  │
                  Bonjour Discovery / Pairing HUD
                  ┌───────────────┼───────────────┐
                  ↓               ↓               ↓
          ┌───────────────┐┌───────────────┐┌───────────────┐
          │   iPhone 11   ││ iPhone 15 Pro ││ iPhone 14 Pro │
          │ Miroo Session ││ Miroo Session ││ Miroo Session │
          │ (Virtual Disp)││ (Virtual Disp)││ (Virtual Disp)│
          │  Transport:   ││  Transport:   ││  Transport:   │
          │      USB      ││      UDP      ││      TCP      │
          └───────────────┘└───────────────┘└───────────────┘
```

---

## 2. Production macOS Application Architecture

Prior to Phase 13, Miroo ran primarily as a menu-bar accessory (`LSUIElement = true`). Phase 13 converts Miroo into a first-class macOS application while preserving background streaming and command-line compatibility:

### 2.1 Dock and Window Identity
- **Regular Activation Policy**: `NSApp.setActivationPolicy(.regular)` is set during initialization unless `--headless` is specified.
- **Application Bundle Identity**: `LSUIElement` removed from `Info.plist`. Miroo appears normally in the macOS Dock, Cmd-Tab application switcher, and Mission Control.
- **App Icon**: Dedicated production icon assets (`AppIcon.icns`, `AppIcon.png`) generated and installed into `MirooMac/Resources/` and packaged into `MirooMac.app/Contents/Resources/`.
- **Primary Dashboard Window (`MirooDashboardWindowController`)**: A 680×560pt native window with titlebar icon, close-to-hide behavior, and auto-centering. Re-opening via Dock click is handled via `applicationShouldHandleReopen`.

### 2.2 Dashboard UI (`MirooDashboardView.swift`)
The Dashboard interface provides:
- **Status & Wi-Fi Guidance Banner**: Advises users that connecting Mac and iPhone to the same Wi-Fi network ensures smooth wireless streaming, while noting USB functions independently.
- **Discovered iPhones List**: Displays human-readable device cards featuring:
  - Model name & OS version (e.g. `iPhone 15 Pro • iOS 18.2`)
  - Transport badges (`USB`, `Wi-Fi`, `Connected`)
  - Multi-selection checkboxes allowing one or multiple devices to be selected simultaneously
- **Action Toolbar**: Clear buttons for `Select All`, `Deselect All`, and the primary `[ Extend Display ]` button.
- **Active Displays Management Section**: Real-time cards for active sessions displaying:
  - Current resolution & orientation toggle
  - Transport selector pill (`Auto`, `USB`, `UDP`, `TCP`)
  - Live FPS and glass-to-render latency telemetry
  - Disconnect button

### 2.3 Headless & Secondary Controls
- **Headless Mode**: Running `MirooMac --headless` retains headless daemon compatibility for automated testing, servers, and CI environments without presenting UI windows.
- **Secondary Menu Bar**: Preserved as a minimal status utility with quick links to `Open Miroo Dashboard...`, session status, and `Quit Miroo`.

---

## 3. Multi-Device Bonjour Discovery & Transport Hierarchy

### 3.1 Advertising and Browsing (`MirooBrowser.swift`)
- Both Mac and iPhone advertise via `NWListener` using Bonjour service `_miroo._tcp`.
- Discovery endpoints publish standardized TXT records containing persistent UUIDs (`id`), device types (`type`), friendly names (`name`), model identifiers (`model`), OS versions (`os`), USB capability (`usb`), and availability (`state`).
- `MirooBrowser` monitors Bonjour services and maintains reactive collections:
  - `discoveredPhones: [MirooDevice]` (Mac consumption)
  - `discoveredMacs: [MirooDevice]` (iPhone consumption)

### 3.2 Transport Availability & Strict USB Verification
- Only devices with verified physical USB connections report `isUSBAvailable = true`.
- Fake or unverified USB transports are strictly prohibited.
- `TransportSelector` resolves transports according to the strict priority hierarchy:
  ```
  USB (Highest throughput, lowest latency, zero jitter)
   └── UDP (Low-latency wireless via bounded jitter buffer & MTU-safe slicing)
        └── TCP (Reliable fallback for lossy or congested Wi-Fi)
  ```

---

## 4. Phone-to-Mac Projection Requests & Native Mac Approval Workflow

### 4.1 Control Protocol Messages (`MirooProtocol.swift`)
Phase 13 establishes structured binary control framing for pairing:
- `CONNECTION_REQUEST` (wire type `17`):
  - `clientID`: Hardware-anchored persistent device UUID
  - `clientName`: Human-readable device name (e.g., "Nurul's iPhone")
  - `clientModel`: Device model (e.g., "iPhone 15 Pro")
  - `protocolVersion`: Current protocol version (`1`)
  - `preferredWidth`, `preferredHeight`, `preferredFPS`
  - `preferredTransport`: Transport hint ("auto", "usb", "udp", "tcp")
  - `sessionID`: Unique pairing session UUID
- `CONNECTION_ACCEPTED` (wire type `18`):
  - Returns allocated session parameters, display dimensions, negotiated transport, and UDP session token.
- `CONNECTION_REJECTED` (wire type `19`):
  - Contains standardized rejection reason codes (`userRejected`, `busy`, `versionMismatch`, `unsupportedCapabilities`, `timeout`) and explanatory message.
- `CONNECTION_CANCELLED` (wire type `20`):
  - Issued when client aborts pending connection request before host decides.

### 4.2 Mac Approval HUD Prompt (`MirooApprovalWindowController.swift`)
When a phone requests connection:
1. `ConnectionAuthorizer` inspects the request.
2. If the client is known and trusted (`autoAcceptTrustedDevices == true`), it is immediately approved.
3. Otherwise, `MirooApprovalWindowController` presents an on-screen HUD prompt:
   - Header: "Miroo Display Request"
   - Body: "`[Device Name]` wants to connect as a secondary display."
   - Badges: Transport type (Wi-Fi or USB) and requested resolution.
   - Option: "Remember this device" checkbox.
   - Actions: `[ Decline ]` and `[ Accept ]` buttons.
4. **Timeout Safety**: If the Mac user does not respond within 30 seconds, the request times out safely and the client is notified.
5. **No Blind Auto-Acceptance**: Untrusted incoming requests never spawn a display without explicit user approval.

### 4.3 Phone Lifecycle State Machine
`ConnectionLifecycleState` handles the pairing workflow:
```
.idle ──► .searching ──► .connecting ──► .waitingForApproval ──► .connected
                                               │
                                               └──► .declined (with retry)
```
- In `.waitingForApproval`, the iPhone UI displays a progress spinner: "Waiting for approval from `[Mac Name]`..." with a "Cancel Request" button.
- In `.declined`, the iPhone displays a banner: "`[Mac Name]` declined this display request" with a "Retry" button.

---

## 5. Multi-Device Display Session Architecture (`MirooDisplaySession.swift`)

Rather than maintaining a single global display or capturer, Miroo encapsulates each physical display in an isolated `MirooDisplaySession`:

```swift
public final class MirooDisplaySession: Identifiable, @unchecked Sendable {
    public let id: String
    public let device: MirooDevice
    public private(set) var displayManager: VirtualDisplayManager?
    public private(set) var capturer: DisplayStreamCapturer?
    public private(set) var encoder: VideoEncoder?
    public private(set) var videoTransport: VideoTransport?
    public private(set) var inputController: MacInputController?
    public private(set) var currentTransportType: VideoTransportType
    public private(set) var state: DisplaySessionState
    ...
}
```

### Key Session Invariants:
1. **Independent Virtual Displays**: Each session creates its own virtual display via CoreGraphics private SPI with custom dimensions and refresh rates matching the target phone.
2. **Dedicated Pipelines**: Each session runs its own ScreenCaptureKit stream, VideoToolbox hardware H.264 encoder, and input event controller.
3. **Session Teardown Isolation**: Terminating or disconnecting Session A does not interrupt, drop frames, or destabilize Session B.

---

## 6. Per-Device Persistent Display Arrangement

Display arrangement persistence in `DisplayArrangementStore.swift` is keyed per-device and per-orientation:
```
Miroo.DisplayArrangement.<deviceID>.<Orientation>
```
- `computeOrigin(referenceBounds:currentMirooSize:)` recalculates exact virtual desktop placement relative to the Mac's primary display.
- **Hardware-Invariant Keying**: Even when CoreGraphics assigns a different ephemeral `CGDirectDisplayID` upon reconnection, the persistent arrangement matches on the invariant device UUID and restores the exact desktop placement seamlessly.
- Separate arrangements are stored for `.portrait` and `.landscape` orientations for each individual iPhone.

---

## 7. Dynamic Transport Switching Without Display Destruction

Users can switch the active transport (`Auto`, `USB`, `UDP`, `TCP`) on any active session:
```swift
session.switchTransport(to: .tcp)
```
1. `MirooDisplaySession` transmits a `SET_TRANSPORT` control packet to the connected phone.
2. The current video transport socket is stopped and recycled.
3. The new video transport socket is initialized.
4. An immediate IDR keyframe (`requestKeyframe()`) is requested from the hardware encoder to instantly prime the receiver's video decoder.
5. **The virtual display and ScreenCaptureKit stream remain running uninterrupted**, eliminating display flicker, window jumping, or desktop reconfiguration during transport transitions.

---

## 8. Verification and Quality Assurance

### 8.1 Automated Test Suites
The complete Miroo test suite was executed and verified:

| Test Target | Category | Tests / Assertions | Status |
|---|---|---|---|
| `Phase13Tests` | Multi-Device Discovery, Pairing HUD, Sessions, Dynamic Transport | 10 tests / 60 assertions | **PASSED (100%)** |
| `DeviceDiscoveryConnectionTests` | Bonjour TXT, Authorization, Control Wire Protocol | 20 tests / 83 assertions | **PASSED (100%)** |
| `DisplayArrangementTests` | Persistent Arrangement, Ephemeral ID Invariance, Clamping | 17 tests / 37 assertions | **PASSED (100%)** |
| `Phase12Tests` | Responsive UI, Safe-Area Clearance, Dynamic Island | 10 tests / 29 assertions | **PASSED (100%)** |
| `EdgeToEdgeTests` | Edge-to-Edge Metal Rendering & Viewport Geometry | 10 tests / 10 assertions | **PASSED (100%)** |
| `Phase11Tests` | Release Candidate Reliability, Gesture Routing, Backpressure | 12 tests / 12 assertions | **PASSED (100%)** |
| `Phase10Tests` | Production Lifecycle, Reconnection, State Transitions | 15 tests / 15 assertions | **PASSED (100%)** |
| `Phase9Tests` | Adaptive Bitrate, Queue Depth, Congestion Recovery | 12 tests / 12 assertions | **PASSED (100%)** |
| `Phase8BTests` | Native USB Transport, usbmuxd Framing, Priority Hierarchy | 14 tests / 14 assertions | **PASSED (100%)** |
| `Phase8ATests` | UDP Slicing, Jitter Buffer, Frame Reassembly | 18 tests / 18 assertions | **PASSED (100%)** |
| `Phase7Tests` | Timestamp Propagation, 8-Stage Glass-to-Glass Telemetry | 8 tests / 8 assertions | **PASSED (100%)** |
| `Phase6BTests` | Two-Finger Trackpad Scrolling & Right-Click Gestures | 5 tests / 18 assertions | **PASSED (100%)** |
| `Phase6ATests` | Touch Normalization, Viewport Clamping, CGEvent Injection | 5 tests / 26 assertions | **PASSED (100%)** |
| **Cumulative Total** | **Entire Miroo Regression Verification Suite** | **156 tests / 342+ assertions** | **ALL PASSED** |

### 8.2 Application Packaging & Platform Build Verification
- **macOS Release Build**: `./Scripts/build_mac_app.sh` compiled release binaries, structured `MirooMac.app`, verified `AppIcon.icns`, applied code signing, and generated `Miroo.dmg`.
- **iOS Xcode Build**: `xcodebuild -project MirooPhone.xcodeproj -scheme MirooPhone -destination 'generic/platform=iOS'` completed with `** BUILD SUCCEEDED **`.
- **Compiler Warnings**: Clean build with zero warnings across all modules.

---

## 9. Conclusion

Phase 13 successfully transforms Miroo into a multi-device secondary display application:
- Seamless multi-device Bonjour discovery across USB and Wi-Fi.
- Mac-directed device selection and multi-display extension.
- Phone-to-Mac pairing requests with explicit native approval HUD.
- Multi-device isolated session architecture (`MirooDisplaySession`).
- Per-device persistent display arrangements surviving reconnects.
- Dynamic transport switching without display recreation.
- Zero regressions across all 12 prior phases.
