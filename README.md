# Fieldwork

An open-source, native marching drill editor. You define performers and fields, draw editable forms, align sets to your music, play back moves and print coordinate sheets. Shows are documented `.fieldwork` files that you own.

“Fieldwork” is a provisional name. The product namespace lives in `FormatIdentity` (`packages/DrillDocument`), `apps/macos/Config/Base.xcconfig` and `Info.plist`.

> **Status: early alpha, not released.** The portable core has been built and tested on Windows and macOS. The macOS app now builds unsigned with Xcode 26.6; the full interactive acceptance flow remains unverified. See [Capabilities](#capabilities) and [docs/PROGRESS.md](docs/PROGRESS.md).

## Repository layout

| Path | Contents |
|---|---|
| `packages/DrillTiming` | Musical timeline, march-count pulses, audio anchors and the invertible fitted time map |
| `packages/DrillCore` | Show model (meters), field presets, roster, sets, forms, semantic commands with atomic undo, scene evaluation, analysis, onboarding tour state |
| `packages/DrillDocument` | `.fieldwork` container (ZIP + manifest + SQLite), atomic file save, recovery journal (`DrillDocument`); WAV decoding and waveform peaks (`DrillMedia`); coordinate PDF (`DrillExport`); vendored SQLite |
| `packages/DrillBridge` | `FieldworkCore` DLL with a versioned C ABI (`include/fieldwork_core.h`) and the `fwtool` CLI |
| `apps/macos` | SwiftUI/AppKit/AVFoundation Mac app (XcodeGen spec, sources, tests). **Unsigned Debug build verified.** |
| `apps/windows/BridgeSmoke` | C# console app that drives the core through the C ABI |
| `spec/` | Format specification and golden fixtures |
| `examples/` | Original demo show (`first-light.fieldwork`, with a generated click track) |
| `design/tokens.json` | Shared design tokens for the Mac and Windows frontends |
| `fieldwork-home.html`, `fieldwork-workflow.html` | Static concept pages, unchanged |

Planning documents: [DESIGN.md](DESIGN.md), [ARCHITECTURE.md](ARCHITECTURE.md), [RESEARCH.md](RESEARCH.md), [AGENT_PROMPT.md](AGENT_PROMPT.md).

## Toolchains

| Platform | Toolchain | Verified |
|---|---|---|
| Windows 11 x64 | Swift 6.4 (`swift-6.4-RELEASE`, x86_64-unknown-windows-msvc), .NET SDK 10.0.401 | Yes: portable tests, DLL, C# smoke test, `fwtool` |
| macOS 14+ | Xcode 26.6 (17F113), Apple Swift 6.3.3, XcodeGen 2.42.0 | Unsigned Debug build and 3 app tests on macOS 26.6.1 arm64; macOS 14 runtime not yet tested. |

## Build and test

Portable core (macOS, Linux or Windows):

```sh
./scripts/test-portable.sh            # swift test for every package
```

Windows, including the C ABI proof:

```powershell
./scripts/test-portable.ps1           # tests + FieldworkCore.dll + C# interop smoke test
```

Command-line tool:

```sh
cd packages/DrillBridge
swift run -c release fwtool demo out/demo.fieldwork        # demo show with aligned audio
swift run -c release fwtool acceptance out/acceptance      # headless acceptance flow + PDF
swift run -c release fwtool profile 350 150                # performance harness
swift run -c release fwtool info examples/first-light.fieldwork
swift run -c release fwtool pdf in.fieldwork out.pdf
```

macOS app (unsigned Debug build verified with Xcode 26.6):

```sh
./scripts/bootstrap-macos.sh          # downloads pinned XcodeGen, generates the project
xcodebuild -project apps/macos/Fieldwork.xcodeproj -scheme Fieldwork -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

No signing identity is committed. Personal settings go in `apps/macos/Config/Local.xcconfig`, which git ignores (see the `.template`).

## Capabilities

**Built and tested (portable core, Windows):**

- Timing:
  - Measures with meter, grouping, tempo unit and pulse unit (6/8 counted in 2 or 6; 5/8 as 3+2).
  - Pickups, fermata-style holds and linear tempo ramps.
  - Exact rational cursors with stable event IDs.
- Audio sync:
  - Sample-exact anchors.
  - One anchor sets the offset; more anchors refit the time between them.
  - Inverse time lookup and pre-roll.
  - Conflicts produce options (replace, release, fit or cancel) instead of silent changes.
  - Example from the prompt: m17 b1 moves from 44.400 to 44.600 s (scale 1.00625, about 119.255 BPM) while set coordinates and musical positions stay the same.
- Drill editing:
  - Roster by section with stable labels; new performers are explicitly unresolved, never placed at (0,0).
  - Field presets (high school, college and pro football, indoor floor) and custom dimensions.
  - Sets placed by counts; later sets shift, and the timeline extends inside the same transaction.
  - Line and arc forms keep their geometry and order, with equal arc-length spacing.
  - Reverse assignment order, detach, exact coordinates and nudge.
  - Undo/redo per command, including compound commands.
- Playback and analysis:
  - Straight-path scene evaluation driven by audio time.
  - Warnings for stride, zero-count jumps, close passes, field bounds and missing positions.
- Documents:
  - `.fieldwork` save and reopen preserves every M1 feature.
  - Verified writes and atomic replace that keeps the previous version.
  - Refuses newer formats, preserves unknown extensions, migrates on a copy.
  - Recovery journal replays only complete entries.
- Media and output:
  - WAV decoding (PCM integer and float, extensible format) and multi-resolution waveform peaks.
  - Coordinate PDF with per-performer sheets and set charts; rendered and checked visually.
- Windows interop: C ABI DLL driven from C# (create → edit → encode → reopen → evaluate → errors).
- Onboarding: the tour state machine advances only on observed actions; Back, Skip, Close and restart work.

**Compiled (macOS app; interactive behavior still unverified):**

- NSDocument document type with a single save path.
- AppKit field canvas: select, Shift-select, box select, drag with one commit, Space-drag pan, zoom, nudge, snap with Option bypass, axis lock, line and arc tools, form handles.
- Timeline with seconds and measure rulers, cached waveform, set and anchor lanes, scrubbing and anchor drag.
- AVFoundation playback with the audio clock as master; WAV and MP3 decoding through AVFoundation.
- Align Here and Align Set Here.
- Meter and tempo controls; inspector; warnings list.
- PDF preview through PDFKit.
- Welcome window, four-step New Show flow, sample show and anchored coach marks.
- Crash-recovery prompt.
- Liquid Glass on macOS 26 floating controls, with material or opaque fallbacks.

**Not implemented yet:**

- Shapes and paths:
  - Composite Bézier, ellipse, block and freehand forms.
  - Proximity or pinned assignment.
  - Custom paths, midsets and group transforms.
- Timing editing:
  - Meter changes after sets exist.
  - Count insert/delete with impact previews.
  - Metronome, count-in, loops and tap alignment.
  - MusicXML import.
- Exports: printable dot books and charts beyond the coordinate PDF; roster and coordinate CSV.
- `.dots` import and export.
- MP3 decoding outside macOS.
- The WinUI 3 app.
- 3D (deliberately later).

## License

Apache License 2.0. See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
