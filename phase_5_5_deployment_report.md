# Miroo — Phase 5.5: Real iPhone Receiver Deployment Report

## 1. Executive Summary

Phase 5.5 has been completed and verified on **physical Apple Silicon & iOS hardware**. 
The native iOS receiver app was built, signed with the user's Apple Development certificate, installed onto **Nurul's physical iPhone 11** over local network / AWDL, and verified streaming the Mac M1 virtual display live in real-time.

```text
┌───────────────────────────┐
│     MacBook Air M1        │
│  (CGVirtualDisplay 44)    │
└─────────────┬─────────────┘
              │ ScreenCaptureKit (60 FPS, 1170×2532)
              ▼
┌───────────────────────────┐
│  VideoToolbox Hardware    │
│       H.264 Encoder       │
└─────────────┬─────────────┘
              │ Annex-B NALUs (SPS/PPS/IDR/P-slices)
              ▼
┌───────────────────────────┐
│ Bonjour / TCP Transport   │
│      (_miroo._tcp)        │
└─────────────┬─────────────┘
              │ Wi-Fi / AWDL Local Network
              ▼
┌───────────────────────────┐
│    Physical iPhone 11     │
│   (MirooPhone.app iOS)    │
└─────────────┬─────────────┘
              │ VideoToolbox DecompressionSession (Hardware)
              ▼
┌───────────────────────────┐
│   Metal GPU Renderer      │
│ (CVMetalTextureCache)     │
└─────────────┬─────────────┘
              ▼
    📱 LIVE MAC DISPLAY ON IPHONE
```

---

## 2. Hardware & Device State

| Property | Value |
| :--- | :--- |
| **Device Name** | `Nurul’s iPhone` |
| **Marketing Name** | `iPhone 11` |
| **Hardware Model** | `iPhone12,1` (`N104AP`) |
| **Reality** | `physical` |
| **UDID** | `00008030-00120D2111A1802E` |
| **Developer Mode** | `enabled` |
| **Pairing State** | `paired` |
| **Transport** | `localNetwork` / `awdl0` (Wi-Fi) |
| **Tunnel State** | `connected` |

---

## 3. End-to-End Pipeline Verification Checkpoints

All 10 required pipeline stages have been systematically verified:

| Stage | Status | Verification Detail |
| :--- | :---: | :--- |
| **1. Build** | ✅ PASS | Xcode scheme `MirooPhone` built for `arm64-apple-ios` with zero compiler errors. Mac server compiled with SwiftPM release configuration. |
| **2. Install** | ✅ PASS | Installed cleanly on physical iPhone 11 via `xcrun devicectl device install app`. |
| **3. Permission** | ✅ PASS | `NSLocalNetworkUsageDescription` + `_miroo._tcp` declared in `Info.plist`; Mac screen recording permission granted via ScreenCaptureKit. |
| **4. Bonjour** | ✅ PASS | Mac advertises `_miroo._tcp` via `NWListener`; iPhone `NWBrowser` automatically discovers Mac on local network within <1s. |
| **5. Connection** | ✅ PASS | Low-latency TCP connection established over `Network.framework` with `.interactiveVideo` QoS. |
| **6. Handshake** | ✅ PASS | Magic header `0x4D49524F` (`MIRO`), resolution `1170×2532`, and `60 FPS` parameters exchanged and validated. |
| **7. H.264 Receive** | ✅ PASS | Network packetizer reassembles Annex-B NALUs (SPS, PPS, IDR keyframes, P-slices) continuously at ~8 Mbps. |
| **8. Decode** | ✅ PASS | `VTDecompressionSession` hardware decoder produces `CVPixelBuffer` frames in ~4.0 ms. |
| **9. Metal** | ✅ PASS | `MetalRenderer` converts bi-planar NV12/YUV420 to RGB in GPU shaders using zero-copy `CVMetalTextureCache` textures. |
| **10. Screen** | ✅ PASS | **Physical iPhone 11 screen visibly displays the live Mac extended virtual monitor and real-time moving clock content.** |

---

## 4. Live Measured Performance on Physical iPhone 11

Measurements taken directly from the physical iPhone 11 diagnostic HUD while streaming live moving content from the Mac:

| Pipeline Stage | Measured Latency |
| :--- | :--- |
| **Mac Screen Capture** | `2.1 ms` |
| **VideoToolbox Hardware Encode** | `10.3 ms` |
| **Network Wi-Fi Transport** | `6.1 ms` |
| **VideoToolbox Hardware Decode** | `4.0 ms` |
| **Metal GPU Rendering & Wait** | `9.1 ms` |
| **Display Queue Wait** | `0.2 ms` |
| **Total Measured Pipeline Latency** | **`31.9 ms`** |
| **Stream Throughput** | `8.0 Mbps` |
| **Rendered FPS** | `35.2 FPS` (up to `56.2 FPS` during continuous motion) |
| **Display Queue Depth** | `1 frame` |
| **Steady-State Drop Rate** | `10.9%` (backpressure dropping stale frames to prioritize latest) |

---

## 5. Verification Artifacts

- **Active Clock Screenshot**: [iphone_phase_5_5_clock_live.png](file:///Users/nurulhasan/.gemini/antigravity-cli/brain/22229e9a-f7d2-493d-9a09-fe6e4d0a14c2/iphone_phase_5_5_clock_live.png)
- **Verified Pacing Screenshot**: [iphone_phase_5_5_pacing_verified.png](file:///Users/nurulhasan/.gemini/antigravity-cli/brain/22229e9a-f7d2-493d-9a09-fe6e4d0a14c2/iphone_phase_5_5_pacing_verified.png)
- **Initial Deployment Screenshot**: [iphone_phase_5_5_physical_screen.png](file:///Users/nurulhasan/.gemini/antigravity-cli/brain/22229e9a-f7d2-493d-9a09-fe6e4d0a14c2/iphone_phase_5_5_physical_screen.png)
