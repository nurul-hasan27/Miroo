# Miroo

Use your iPhone as an extra display for your Mac — wirelessly, like Sidecar does for an iPad.
Drag windows onto the phone, touch it to click, drag and scroll. Built for low latency over ordinary Wi-Fi.

```
Mac                                                        iPhone
CGVirtualDisplay (phone-native pixels)                      UDP ► FrameAssembler (Reed-Solomon FEC + repair)
 └ ScreenCaptureKit (NV12, newest-frame-wins)                 └ in-order gate + recovery
    └ VideoToolbox HEVC, low-latency rate control                 └ VideoToolbox decode (≈2–3 ms)
       └ packetizer + FEC + pacer + ChaCha20-Poly1305               └ AVSampleBufferDisplayLayer (show immediately)
          └ UDP ═══════════ Wi-Fi / peer-to-peer ═══════════►        touch / scroll ◄══ UDP (redundant, encrypted)
 TCP control channel: pairing handshake, setup, rotation, teardown (encrypted after the handshake)
```

## Use it

1. Build and install (needs Xcode, your Apple developer team in `Scripts/create_phone_project.py` if you are not `6NNWP5NQ7Z`):

   ```bash
   Scripts/package_mac_app.sh                      # → build/Miroo.app (menu-bar app, signed with your Apple Development identity)
   python3 Scripts/create_phone_project.py         # → Miroo.xcodeproj
   xcodebuild -project Miroo.xcodeproj -scheme Miroo -configuration Release \
     -destination 'generic/platform=iOS' -allowProvisioningUpdates -derivedDataPath build/ios build
   xcrun devicectl device install app --device <UDID> build/ios/Build/Products/Release-iphoneos/Miroo.app
   ```
2. Open **Miroo** on the iPhone and keep it in the foreground. Open `build/Miroo.app` on the Mac (menu-bar icon).
3. First time: in the Mac menu choose **Extend Display** next to your iPhone. A 4-digit code appears on both screens; tap **Allow** on the iPhone only if they match. After that the Mac connects by itself whenever the phone app is open.
4. macOS will ask for **Screen Recording** (to capture the extra display) and **Accessibility** (so touches can move the cursor). Both are listed in the menu with an *Allow…* button.

The picture fills the **whole phone screen** (notch included). Choose the resolution with the slider in the Miroo menu (*Larger text … More room*) or in **System Settings › Displays**; both stay in sync.

Gestures on the phone: one finger = mouse (tap = click, drag = drag) · two-finger drag = scroll (with momentum) · two-finger tap = right-click · three fingers = show/hide the stats overlay.

Tip for the best result: use a **5 GHz** network. If your iPhone *is* the hotspot, turn **Maximize Compatibility off** (Settings → Personal Hotspot); the default 2.4 GHz channel is crowded and stalls for 50–150 ms several times a second.

## Repository layout

| Path | What |
|---|---|
| `Sources/MirooCore` | Wire format, Reed-Solomon FEC, frame assembler, sequencer, pacer, rate control, input protocol (no platform dependencies) |
| `Sources/MirooMedia` | VideoToolbox encoder/decoder, display-layer renderer |
| `Sources/MirooNet` | UDP/TCP channels (Network.framework), Bonjour, pairing + encryption (CryptoKit, Keychain) |
| `Sources/MirooSession` | `LinkStreamer` (Mac) and `LinkReceiver` (phone): the two ends of the video link |
| `Sources/MirooHost` | Virtual display, ScreenCaptureKit capture, input injection, `HostSession` |
| `Sources/MirooApp` | The Mac menu-bar app (SwiftUI) |
| `PhoneApp` | The iPhone app (SwiftUI), built by `Miroo.xcodeproj` against this package |
| `Sources/miroo-host`, `miroo-selftest`, `MirooTestKit` | CLI host for hardware tests; self-test rig with an emulated bad-Wi-Fi proxy |
| `Scripts` | `package_mac_app.sh`, `create_phone_project.py`, `run_checks.sh` |
| `Docs/ARCHITECTURE.md` | Design, decisions, measurements, limits |
| `Docs/archive-v1` | The previous implementation's reports (and your uncommitted v1 edits as a patch) |

## Verify

```bash
Scripts/run_checks.sh     # unit tests + the real stack against emulated bad Wi-Fi (about 3–4 minutes)
```
