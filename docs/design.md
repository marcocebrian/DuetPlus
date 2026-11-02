# DuetPlus — Design (POC)

Play the same song on up to 10 phones (iOS + Android) with **≤ 5 ms** offset between any two phones (target ≤ 2 ms after calibration).
POC: no store and no ToS constraints, sideload only.

## 1. Topology

- 1 **master**: finds and pulls the audio (YouTube search or a local file), sends it to the others, owns the clock, and **plays the audio itself**, using the same engine as a slave with clock offset 0.
- Up to 10 **slaves**: download the track, sync their clock to the master's, and play at the scheduled time.
- Everyone on the same Wi-Fi, or on the master's hotspot (turned on by hand on iOS; Android can use LocalOnlyHotspot).
- No Bluetooth: it is not used for sync or data, and Bluetooth audio output is blocked or warned against (100–300 ms of latency that isn't reported reliably).

## 2. Audio source

Everything ends up as **Opus at 48 kHz**, the only format the slaves need to handle.

| Source | Master does |
|---|---|
| YouTube search | Search + resolve streams, pick **itag 251** (Opus in WebM, ~130–160 kbps VBR, the best free quality; 256k AAC needs Premium, and YT Music free uses the same streams). Demux WebM → Opus packets. **No re-encode.** |
| Local file | Decode with the platform decoder (AVAudioFile / MediaCodec) → PCM → libopus encode at 160 kbps → Opus packets. |

Extraction libraries sit behind the `SourceProvider` interface:
- Android: **NewPipeExtractor** (search + stream URLs, actively maintained).
- iOS: **YouTubeKit** (Swift). If iOS extraction proves unreliable, the POC requires an Android master.

## 3. Transport (Wi-Fi only)

| Channel | Protocol | Use |
|---|---|---|
| Discovery | Bonjour / NSD (`_duetplus._tcp`) + QR code (ip:port:sessionKey) | Joining |
| Control + data | 1 TCP connection per slave, length-prefixed binary messages | Track metadata, Opus chunks, schedule commands, stats |
| Clock | UDP, unicast | NTP-style ping/pong |

Unicast only, so there's no iOS multicast entitlement. For 10 slaves: a 4-minute track is ≈ 4 MB, so 40 MB total from the master, a few seconds on Wi-Fi.

**Progressive start:** the master forwards chunks while it is still downloading from YouTube. Playback is scheduled once **every** slave has reported ≥ 10 s buffered and decoded. Time to first sound should be ~2–4 s.

### Messages (control channel)
`HELLO(deviceModel, outputRoute, calibOffset)` · `TRACK(id, durationFrames, codecHeader)` · `CHUNK(trackId, seq, opusPackets[])` · `BUFFERED(trackId, framesReady)` · `PLAY(trackId, frame F, masterTime T)` · `PAUSE(masterTime T)` · `SEEK(frame F, masterTime T)` · `VOLUME(v)` · `STATS(errorUs, ratePpm, rttUs)`.

Every transport command is **scheduled in master time ~300–1000 ms ahead**. Nothing means "now".

## 4. Clock sync

- Monotonic clocks: `mach_absolute_time` (iOS), `CLOCK_MONOTONIC` (Android, the same base AAudio timestamps use).
- Slave sends `t1`, master replies with `t2, t3`, slave records `t4`. `rtt = (t4−t1)−(t3−t2)`, `offset = ((t2−t1)+(t3−t4))/2`.
- Rate: a 50-ping burst at 20 Hz on join, then 10 Hz. That also keeps the Wi-Fi radio out of power-save, which otherwise adds tens of ms of jitter.
- Filter: over a sliding 10 s window, keep the lowest-RTT 25% of samples, then **linear regression** → `offset + skew` (skew covers crystal drift of 10–50 ppm).
- Expected accuracy: 0.2–1 ms on decent Wi-Fi.
- Load on the master for 10 slaves: 100 small packets/s, negligible.

## 5. Playout engine (the core)

Each device decodes the **whole track to int16 PCM in RAM** (4 min ≈ 46 MB), decoding progressively as chunks arrive. That makes seeking sample-exact.

Output:
- Android: **Oboe** (AAudio, low-latency, exclusive where possible). Presentation time from `getTimestamp(CLOCK_MONOTONIC)` → (framePos, timeNs).
- iOS: **RemoteIO AudioUnit**. Presentation time = render `mHostTime` + `outputLatency` (+ IO buffer as needed; verified empirically in M1).

Control loop (every render callback):
```
expectedFrame = F + (masterNow(presentTime) − T) × 48000 + calibOffsetFrames
error = expectedFrame − actualFrameBeingPresented
|error| > 20 ms  → hard jump, with a 5 ms crossfade (no click)
otherwise        → PI controller → resample ratio, clamped to ±500 ppm (inaudible, < 1 cent)
```
Resampler: speexdsp (quality 5) on the playout path.

Joining mid-song works for free: download, compute the current frame from the schedule, start there.

## 6. Acoustic calibration (M5)

Some Android devices report the wrong latency. Calibration step:
1. Put the phones next to the master (< 10 cm, so acoustic travel time can be ignored).
2. Each slave plays a 20 ms log chirp (2–8 kHz) at a scheduled time, one slave after another.
3. The master's mic records; cross-correlation gives the arrival time; the residual becomes that device's `calibOffset`.
4. Stored per (device model, output route) and sent in `HELLO`.

## 7. Measurement (from M1)

- **Click-track mode**: 1 click/s on all devices.
- An external recorder (laptop mic) captures all the phones together; a script cross-correlates and reports the offset distribution.
- Each device also reports `STATS` → live table on the master (error µs, ppm, RTT).

POC acceptance: p95 offset ≤ 5 ms across 10 devices over 30 min.

## 8. Stack

```
┌─────────── shared C++ core (CMake) ───────────┐
│ clock sync · scheduler · playout/control loop │
│ protocol + POSIX sockets · libopus · speexdsp │
│ WebM demux (libwebm) · PCM store              │
└───────────────────────────────────────────────┘
   ▲ JNI                         ▲ ObjC++
Android: Kotlin + Compose        iOS: Swift + SwiftUI
  Oboe, NSD, NewPipeExtractor      AudioUnit, NWBrowser, YouTubeKit
  foreground service               audio background mode
```

## 9. Milestones

| # | Goal | Pass |
|---|---|---|
| M1 | Clock sync + click track, 2 phones of the same OS, C++ core + one native shell | ≤ 5 ms measured externally |
| M2 | Cross-platform (iOS ⇄ Android), drift correction, 30 min run | ≤ 5 ms p95, no hard jumps after lock |
| M3 | Local file → Opus → distribute → play, 10 devices, pause/seek, mid-song join | as above |
| M4 | YouTube search + itag 251 extraction on the master, progressive start | first sound ≤ 4 s |
| M5 | Acoustic calibration | ≤ 2 ms p95 |
| M6 | Queue, volume, UX polish | — |

## Risks

- YouTube extraction breaks (signature/PO-token changes) → pin library versions, keep the local-file path as fallback.
- iOS output-latency reporting is inaccurate on some routes → M5 calibration.
- Wi-Fi power-save jitter → constant 10 Hz ping + min-RTT filter.
- Memory for long tracks → fall back to a streaming decode window if > 15 min.
