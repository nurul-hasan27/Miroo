# Miroo architecture

Goal: an iPhone behaves like a Sidecar display for the Mac — extend the desktop, touch works, and it stays
responsive on ordinary Wi-Fi, including bad Wi-Fi.

## Why the previous version was replaced

| Problem found in v1 | Effect | v2 |
|---|---|---|
| Virtual display 2532×1170 on a phone whose panel is 1792×828 (and later the safe-area region of it) | 2× the pixels to encode, send and decode (encode 9.0 ms vs 5.2 ms at p50, measured) | Stream exactly the phone's full panel (full bleed, notch included), re-fit on rotation |
| H.264 keyframe every 3 s, recovery only by "send a keyframe" | periodic bursts of 5–10× frame size, visible stutter | infinite GOP; losses repaired with parity first, keyframe only as a rare fallback |
| No pacing: a whole frame dumped on the socket at once | AP buffer spikes, burst loss | token-bucket pacer on its own thread |
| No FEC, no selective repair | any lost packet = lost frame | Reed-Solomon per frame + on-demand extra parity |
| TCP for control **and** touch, TCP fallback for video | multi-hundred-ms freezes under loss | UDP for everything real-time; TCP only for setup |
| Whole networking layer duplicated byte-for-byte in Mac and phone targets | every fix made twice | one Swift package compiled into both |
| Unauthenticated, unencrypted stream | anyone on the Wi-Fi sees/can inject | pairing with confirmation code + AEAD on every packet |
| Tests used in-memory fake connections | 100 % green, but nothing worked on hardware | tests run the real encoder/decoder/UDP stack; every claim below was also run on a real iPhone 11 |

## Data path

```
Mac                                                                    iPhone
CGVirtualDisplay (stable serial per phone → macOS remembers placement)
 └ ScreenCaptureKit, NV12, queueDepth 3, newest frame wins
    └ LinkEncoder: VideoToolbox HEVC, EnableLowLatencyRateControl, no B-frames, infinite GOP
       └ FrameEnvelope (codec, recovery flag, timestamps, parameter sets) + AVCC bitstream
          └ Packetizer: k data packets (≤1360 B) + m Reed-Solomon parity packets
             └ Pacer → ChaCha20-Poly1305 → UDP (traffic class: interactive video)
                                       ════ Wi-Fi ════►  FrameAssembler (any k of k+m completes a frame)
                                                            └ FrameSequencer (in-order, loss detection, recovery)
                                                               └ LinkDecoder (VideoToolbox, async, real-time)
                                                                  └ AVSampleBufferDisplayLayer (DisplayImmediately)
          ◄════ feedback every ~8 ms: loss, queue delay, repair requests, display timestamps
          ◄════ touch/scroll events, each datagram repeats the last 8 events
```

### Wire format (little-endian, 24-byte header)

`magic | version<<4 | kind | flags | packetSeq | frameId | frameLen | index | k | m | sendTimeUs`.
Kinds: data, parity, feedback, input, hello, probe. With encryption on, bytes 0–19 of the header are
authenticated (AAD), the body is encrypted, a 16-byte tag is appended. The send timestamp (bytes 20–23) is
patched at the instant a packet leaves the pacer and is deliberately not authenticated.

## The ideas that matter

1. **Right-sized pixels.** The picture is the whole panel (1792×828 / 828×1792 on an iPhone 11), edge to edge. Fewer pixels = less encode, less air time, less decode.
   **Resolution choices.** The virtual display publishes six HiDPI "looks like" steps in the phone's aspect ratio
   (long side = 67.5 %, 75 %, 80 %, 85 %, 92 %, 100 % of the panel; 1210×558 … 1792×828 for an iPhone 11). The framebuffer is 2× the step and is captured
   down to the panel, so text stays sharp. They show up in System Settings › Displays and as a slider in Miroo's menu (kept in sync both ways, kept across rotation).
   macOS refuses to offer HiDPI modes below ~1210×558 points (probed: the physical size declared by the display does not change that), so the
   biggest-text choice is 1210×558; a phone-sized 896×414 mode would be flagged "unusable" and System Settings would then list only 800×600.
2. **Reed-Solomon over GF(256), systematic Cauchy matrix** with coefficients independent of the parity count
   (`x_p = p`, `y_j = 255-j`). Any `k` of `k+m` packets rebuild a frame, *and* the sender can mint further parity rows
   for a frame on demand ("incremental redundancy") — the receiver just says "frame 1042 still needs 3 packets".
3. **Repair before recovery.** A frame that stalls gets a repair request; the sender keeps the last 24 frames and answers
   with fresh parity at the front of the pacer queue. A recovery keyframe is only requested if repair fails, or if many
   frames are missing outright (then one keyframe is cheaper than re-sending them all). Repairs for frames older than a
   recovery point are ignored forever so late packets cannot restart a repair loop.
4. **Outage clock.** Wi-Fi regularly stalls for 50–150 ms, taking repair requests with it. Loss-detection timers run on a
   clock that slows to 1/20 speed after 60 ms of silence, so repairs get their full time budget once the link returns.
5. **Rate control without clock sync.** Congestion = a *standing* queue (minimum relative one-way delay over 100 ms) or
   frames FEC could not repair. Plain random loss is not congestion (it only raises parity). Bitrate slow-starts from
   5 Mbps; pacing rate probes upward only while the pacer is the bottleneck. Repeated recoveries shrink bitrate.
6. **Newest frame wins** in capture, encoder input, pacer queue and decoder input; nothing buffers more than a frame.
7. **Encrypted and authenticated end to end.** First pairing: X25519 key agreement, both screens show a 4-digit code
   derived from the shared secret and both ephemeral keys (a man-in-the-middle ends up with different codes); the user
   approves on the phone; a 256-bit pairing key goes in each device's Keychain. Later connections prove possession
   of that key (HMAC over the whole handshake) without any prompt. Session keys come from HKDF over the ECDH secret, the
   pairing key and both ephemeral keys; one key per direction for UDP and for the control channel.
   A phone that was paired cannot be silently re-paired or impersonated: a mismatch is an error.
8. **Fast connect.** The hardware encoder, the UDP flow, the virtual display and the phone's decoder are prepared in parallel;
   the encoder is warmed up at app launch (the first low-latency hardware session in a process costs 0.4–0.8 s);
   after an unexpected disconnect the virtual display stays for 60 s, so windows stay put and reconnecting is fast.

## Measurements (iPhone 11, MacBook Air M1, iPhone Personal Hotspot on a crowded 2.4 GHz channel)

| What | Result |
|---|---|
| iPhone 11 HEVC decode | 2.0–3.0 ms per frame |
| Mac encode (real UI content, 1598×784) | 3–8 ms |
| Capture → phone decoder output (`glass`) | 7–17 ms typical (excludes display scan-out, ≤16.7 ms) |
| RTT on that link | 8–12 ms |
| Raw packet loss on that link | 1–1.5 %, in bursts of 8+ packets; arrival gaps up to 360 ms |
| After FEC + repair, 60 fps test animation, 40 s | **0 lost frames**, 57–60 fps |
| Real animated-wallpaper content (25 fps, up to 5 Mbps), 200 s | 92 abandoned frames (~1 per 2 s) with 1.2 % raw loss, 45 stall bursts of 8+ packets, gaps up to 143 ms; a frame whose packets all fall inside a 100 ms outage cannot be shown by any scheme. (Before the outage clock: ~4 per second.) |
| First frame, cold connect | 0.8–1.3 s (display creation ≈0.5 s, capture ≈0.2–0.3 s, handshake 0.1 s) |
| First frame, reconnect within the 60 s grace period | **0.46 s** |
| Mac app while streaming | ≈11–15 % of one core, 35–45 MB |

Emulated bad Wi-Fi (`Scripts/run_checks.sh`: real encoder, FEC, pacing, encryption, UDP and decoder, busy 1792×828 content,
worst gap between displayed frames after the first 1.5 s):

| Scenario | Frames shown | Worst freeze |
|---|---|---|
| clean link | 99 % | 79 ms |
| 3 % random loss + 3 ms jitter | 98 % | 114 ms |
| 60 ms total outage every 1.5 s | 94 % | 137 ms |
| bursty loss (3-packet bursts) | 89 % | 305 ms |
| 120 ms total outage every second | 84 % | 222 ms (an outage per second caps any scheme at ~88 %) |

Bug found by the freeze metric: a 285 KB recovery frame needs 210 packets and one Reed-Solomon block holds 255, so its parity
had collapsed to 4 packets and it almost never survived 3 % loss (freezes up to 947 ms). Big frames now use full-size packets and
the parity that fits; a frame that cannot be protected at all makes the sender cut the bitrate and restart from a new recovery frame.

## Things tried and rejected (with evidence)

* **Long-term-reference recovery** (VideoToolbox `EnableLTR`). It works — a lost frame recovered with a 393-byte
  frame instead of a 3 KB keyframe in the loopback test — but on a real link it cost ~10× the bitrate for static content
  (4.8 vs 0.5 Mbps) and VideoToolbox's low-latency encoder dropped every other frame while acknowledgements (60–90 ms
  over Wi-Fi) were outstanding. The code path remains (`LinkEncoder.Config.useLTR`) but is off.
* **Fast keepalive to defeat Wi-Fi power-save** (6 ms probes). Loss rose from 0.1 % to 1.5 %: on a crowded channel
  loss follows *packet rate* (air-time contention), not bytes. Keepalive is 50 ms; packets are 1360 B; tiny frames skip
  parity while the link is clean.
* **Timer jitter as the cause of encoder frame drops.** Not the cause (tested in isolation); the cause was LTR.

## Known limits

* Wireless only. v1 had a USB transport; v2 does not (usbmuxd offers TCP only, which would need a different transport).
* No audio. One phone at a time (a second Mac is turned away while a healthy stream is active).
* End-to-end "touch to photon" latency was not measured (needs a camera); the numbers above stop at the phone's decoder.
* The virtual display uses private CoreGraphics API (as BetterDisplay / DeskPad do) — not Mac App Store distributable.
* HEVC is used when the phone supports it; the H.264 path is covered by loopback tests but was not run on the phone.
* The Mac app is signed with a development identity; distributing it needs Developer ID signing + notarization.
