# Bjarbys skärminspelare

[![Support me on Patreon](https://img.shields.io/badge/Patreon-Support%20my%20work-FF424D?style=flat&logo=patreon&logoColor=white)](https://www.patreon.com/AndersBjarby)

<img src="App/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" width="128" alt="App icon">

A native macOS screen recorder for polished demos and tutorials. It records **data, not a
finished video**: the screen without the cursor, the microphone, system audio and camera
on separate tracks, and every mouse move and click as events. Zoom, cursor, background
and framing are added afterwards in the editor, and they stay editable.

The interface is in Swedish (*skärminspelare* means screen recorder), with an English
translation that follows the system language.

## What it does

**Recording**
- A whole display, a window or an app through the system picker, or an area you drag out.
- A 3-2-1 countdown, then a floating panel with time, level meters, pause, stop and
  discard. It warns about a silent microphone, a disk running full and tracks that stop.
- Global shortcuts: ⌃⌥⌘R start/stop, ⌃⌥⌘P pause, ⌃⌥⌘A record an area.
- The app's own windows never end up in the recording.
- Crash-safe: every track is its own file, written in 2-second fragments. A recording that
  is cut off is playable up to the last fragment and is recovered at the next launch.

**Editor**
- Zooms suggested from your clicks, with a spring-driven camera that keeps the cursor in
  a safe zone and looks ahead. Move them, resize them, delete them or add your own on the
  timeline.
- The cursor is drawn back on a smoothed path, at any size, with click rings, and hides
  when it stands still.
- Gradient, solid or blurred backgrounds, padding, rounded corners, shadow, and 16:9,
  9:16, 1:1 or 4:3 output.
- Split, delete and change the speed of parts of the recording, with undo.
- A camera bubble in any corner, round or rounded square.

**Export:** MP4 (H.264, 1080p), MP4 (HEVC, 4K), ProRes 422 and GIF.

## Measured, not assumed

- Picture and sound about 5 ms apart, measured against a flash-and-beep reference film
  played in QuickTime, after subtracting the latency the headphones report.
- Killed with `kill -9` after about 10 seconds, the files still played to 10.0 s.
- 1080p export runs at 2–3.5× real time on an Apple M5.

The numbers and how they were taken are in
[`docs/VERIFIERAD-STACK.md`](docs/VERIFIERAD-STACK.md) (in Swedish).

## Building

Requires macOS 26 or later on Apple Silicon, and Xcode 26.1 or later. No dependencies
outside Apple's frameworks.

```bash
./scripts/build.sh          # → dist/Bjarbys skärminspelare.app
./scripts/test.sh           # unit tests for RecorderKit
open Skarminspelare.xcodeproj
```

The project is signed with the author's Developer ID. For your own copy, pick your own
team under *Signing & Capabilities* in Xcode, or pass your identity and team ID to the
build script:

```bash
SKARMINSPELARE_SIGNERING="Apple Development" SKARMINSPELARE_TEAM=<your team id> ./scripts/build.sh
```

On first launch the app asks for **Screen Recording**, which is the only permission it
needs. Microphone and Camera are optional, as are **Accessibility** (lets zooms frame the
button you clicked rather than a box around the pointer) and **Input Monitoring**, which
records keyboard shortcuts: only keys pressed with ⌘, ⌃ or ⌥, never text. Showing those
shortcuts in the video is not built yet.

## How it is put together

- `RecorderKit/` holds all the logic as a local Swift package: `Capture` (ScreenCaptureKit,
  camera), `Writing` (one `AVAssetWriter` per track on a shared clock), `Telemetry` (mouse,
  clicks, cursor images), `Project`, `Motion` (springs, cursor and camera paths), `Render`
  (one Core Image compositor on Metal for both preview and export) and `Export`.
- `App/` is the SwiftUI and AppKit interface: menu bar, recording panel, area selector,
  library and editor.
- A recording is a `.bsrec` package: the raw tracks, an `events.jsonl` log and a
  `project.json` with every editing decision. See [`docs/FORMAT.md`](docs/FORMAT.md).

## Status

The first three phases of [`docs/FÄRDPLAN.md`](docs/FÄRDPLAN.md) are done: the recording
engine, the editor and export. Next on the roadmap are editing by transcript, automatic
masking of sensitive text, a "save the last minutes" buffer, and HDR and 120 fps.

Built and tested on macOS 26.1 on an Apple M5 only. Not yet tried with a real camera or
with a window that moves during recording. There is no notarized binary release yet.

`docs/utredningar/` holds the three research reports the app was planned from, unedited.
Their claims about other products have not been checked.

## License

[MIT](LICENSE)
