# Progress log

## 2026-10-19: Field-focused workspace and performer labels

- New windows start with a 190 pt sets panel, 260 pt inspector and 180 pt timeline;
  the field receives the remaining space. Dividers remain draggable and expose
  accessibility adjustment actions. Narrow windows retain at least 420 pt for the
  field and 360 pt of field-row height.
- Warnings use a disclosure control, start collapsed, and remember their expanded
  state per user. The status bar keeps the warning count visible.
- The tempo-fit choices use the full width below their own heading, rather than
  squeezing the heading and radio choices into adjacent columns.
- Field fitting follows the initial layout and later pane/window resizing until
  the user pans or zooms; Fit Field restores that behavior. This prevents a tiny
  first-open field without resetting a manually chosen view.
- Toolbar Labels and View → Always Show Performer Labels toggle a saved per-user
  preference. Labels remain 8 pt at every zoom with a subtle contrast outline.
  Their rendered bitmaps are cached so playback avoids repeated text shaping.
- Mac tests pass, including initial pane allocation, narrow-window limits,
  label persistence/rendering and the playback regressions. The 350 × 150 Paper
  benchmark with labels on reached 179 updates in three seconds (16.68 ms median,
  17.64 ms p95 live intervals).

## 2026-10-19: Native playback performance

Read all project design, architecture, research and format documents. Profiled the
running Mac editor and the supplied `drill1.fieldwork` (261 performers, 215 sets).
The main costs were editor-wide SwiftUI invalidation, timing-map recompilation
inside set rows, per-frame warning scans and timeline lane redraws.

- Isolated display updates from document state, retained native audio as the clock,
  and switched visible playback to a view-associated display link.
- Reused compiled timing maps, removed redundant frame lookups and warning scans,
  cached field backgrounds, and composited the timeline playhead separately.
- Reduced numeric readout layout to 10 Hz; pause refreshes immediately. Waveform
  peak construction now runs off the main actor with obsolete-load protection.
- The controlled no-audio Debug UI refresh benchmark improved from 70.10 ms median
  to 18.62 ms, including its deliberate 16.7 ms run-loop wait. The 350 × 150 fixture
  reached 180 display updates in three seconds; the real document with audio and
  Paper reached 178, with 16.72 ms median / 18.36 ms p95 update intervals.
- All portable suites pass: DrillTiming 20, DrillCore 28, DrillDocument 22,
  DrillBridge 2. The Mac suite passes 12 tests with the opt-in real-document profile.
- Verified an unsigned Release build and manually opened/played the supplied file
  with embedded audio. The source document was not edited or saved.

See [PERFORMANCE.md](PERFORMANCE.md) for methodology, reproduction commands,
measurement limits and remaining platform/long-duration verification.

## 2026-10-17: First verified macOS build

Environment: macOS 26.6.1 (25G76), arm64, Xcode 26.6 (17F113), Apple Swift 6.3.3. This is the verified Mac build baseline; older deployment targets and Intel remain unverified.

- Added the required `override` to the window controller's Select All responder action.
- Isolated the AppKit application delegate to the main actor so its Getting Started action can call the editor controller synchronously.
- Gave the app test target its own product name and bundle identifier in the authoritative XcodeGen spec. Shared xcconfig settings previously named both modules `Fieldwork`, producing duplicate module outputs when testing.
- Regenerated the project with the pinned XcodeGen 2.42.0 using `./scripts/bootstrap-macos.sh`.
- The requested unsigned Debug `xcodebuild ... build` command passes.
- `xcodebuild -project apps/macos/Fieldwork.xcodeproj -scheme Fieldwork -configuration Debug CODE_SIGNING_ALLOWED=NO test` passes: 3 app tests, 0 failures.
- `./scripts/test-portable.sh` passes on this Mac: DrillTiming 17, DrillCore 20, DrillDocument 16 and DrillBridge 2 tests, all with 0 failures.

The interactive acceptance flow, native audio playback/latency, MP3 decoding, accessibility, coach marks and canvas profiling remain unverified. The earlier entry below records the original Windows-only implementation status.

## 2026-10-17: M0 foundations and the portable half of M1

Environment: Windows 11 Home (10.0.26200), Intel Core i5-10400 @ 2.90 GHz, 23.7 GB RAM, Swift 6.4 (`swift-6.4-RELEASE`), .NET SDK 10.0.401. **No Mac or Xcode was available.** No `xcodebuild`, macOS playback, notarization or Mac UI test was run, and none is claimed.

### Completed behavior

- **Timing core** (`DrillTiming`):
  - Measures with notation denominator, tempo unit, pulse unit and grouping; pickups; hold events with fixed elapsed time and no count advance.
  - Exact `Rational` cursors over stable event IDs.
  - Tempo is compiled into baseline event durations, including linear ramps integrated exactly.
  - Sample-frame anchors. One anchor sets the offset; consecutive anchors fit elastic durations by a common scale, and holds stay fixed.
  - Piecewise-linear forward map with binary-search inverse; pre-roll gives negative times.
  - Conflicts (duplicate pin, non-monotonic pins, implied tempo out of range, edits inside pinned intervals in Preserve Notated Tempo mode) return options and change nothing.
  - Locale-independent time parsing and formatting.
- **Drill core** (`DrillCore`):
  - Show model in meters with stable IDs; field presets and a checkpoint-based coordinate describer ("S1: 4.00 outside 35", "8.00 behind front hash").
  - Roster by section; performers are explicitly unresolved until placed.
  - Preset and arrival sets placed by count, with incoming transitions.
  - Retained line/arc forms with equal arc-length distribution and assignment order. Moving every member translates the form; moving some members detaches them.
  - Semantic, Codable commands. Each commits atomically after validating the whole show; batches are one undo unit.
  - Dirty tracking that returns to clean after undo back to the saved state; journal replay.
  - Straight-path evaluator driven by audio time → cursor → count → progress.
  - Analysis: stride per count (reported as N-to-5), zero-count jumps, analytic close passes with a grid broad phase, field bounds, missing positions.
  - Onboarding tour state machine (`FieldworkTour`); original sample show; 350-performer fixture generator.
- **Documents** (`DrillDocument`):
  - `.fieldwork` ZIP (original reader and writer; stored members, CRC-32, SHA-256 manifest, path/size/encryption/compression checks).
  - `show.sqlite` schema 1 through a vendored SQLite 3.46.1, built from memory with `sqlite3_serialize`/`deserialize`.
  - Migration framework that works on a copy; newer format or schema is refused untouched; unknown optional extensions are preserved; unknown required ones open read-only.
  - File save verifies the encoded bytes, writes and flushes a temporary file, and replaces atomically (`ReplaceFileW` on Windows, `link` + `rename` on POSIX), keeping `<name>.previous`.
  - Recovery journal (base snapshot + assets + JSONL commands; a torn final line is ignored).
- **Media and export**: original WAV decoder (8/16/24/32-bit integer, 32/64-bit float, extensible); min/max peak pyramid; original PDF writer and coordinate sheets plus set charts. I rendered the acceptance PDF to PNG with PyMuPDF in a scratch directory and checked it by eye.
- **Windows bridge**:
  - `FieldworkCore.dll` exports nine plain C symbols (checked with `llvm-objdump -p`): opaque handles, JSON in and out, one core-owned deallocator, status codes, per-session lock.
  - The C# P/Invoke smoke test passes.
- **Tools**: `fwtool demo | acceptance | profile | pdf | info | evaluate`.
- **macOS app source** (not compiled): XcodeGen `project.yml`, xcconfigs without a team, UTType/document declaration, NSDocument subclass, AppKit canvas, timeline, AVFoundation transport and decoder, SwiftUI shell, inspector, navigator, PDFKit preview, welcome and New Show flow, coach-mark overlay, recovery prompt, programmatic menus, and three app tests.

### Commands actually run (all on the Windows machine above)

| Command | Result |
|---|---|
| `swift test` in `packages/DrillTiming` | 17 tests, 0 failures |
| `swift test` in `packages/DrillCore` | 20 tests, 0 failures |
| `swift test` in `packages/DrillDocument` | 16 tests, 0 failures, including the 32-performer acceptance test and the golden fixture |
| `swift test` in `packages/DrillBridge` | 2 tests, 0 failures |
| `scripts/test-portable.ps1` | All of the above, then release `FieldworkCore.dll`, then `dotnet run` of BridgeSmoke: **21/21 interop checks PASS**, exit 0 |
| `llvm-objdump -p FieldworkCore.dll` | Exports `fw_abi_version`, `fw_buffer_free`, `fw_dispatch_command`, `fw_encode_document`, `fw_evaluate_scene`, `fw_get_snapshot`, `fw_session_create`, `fw_session_destroy`, `fw_session_open`. Imports: swiftCore, Foundation, FoundationEssentials, VCRUNTIME140 and the UCRT. |
| `fwtool acceptance out/acceptance` | 32 performers; line + arc; 16-count set; undo/redo; WAV import; pins m1 b1 = 00:02.000 and m5 b1 = 00:10.050 (scale 1.00625); evaluation across the set boundary; save and reopen gave an identical model; 34-page PDF |
| `fwtool demo examples/first-light.fieldwork` | 18 performers, 4 sets, 32 s click track at 11,025 Hz aligned at m1 b1 = 00:01.500 (891 KB) |
| `fwtool profile 350 150` (release build) | See the profile below |

Acceptance run output (abridged):

```
5. Imported audio; pinned m1 b1 = 00:02.000 and m5 b1 = 00:10.050 (scale 1.00625, mean 119.254 BPM)
   t=00:08.050 count 12.02 set index 0 T1 y=3.436 m
   t=00:09.550 count 15.01 set index 0 T1 y=4.288 m
   t=00:10.050 count 16.00 set index 1 T1 y=4.572 m
6. Saved and reopened Acceptance.fieldwork: identical model, set 2 arrival 00:10.050
```

### Profile: 350 performers × 150 sets (release build, the Windows machine above)

These are measurements of the portable core only, not of a Mac UI, and they are not comparable to the 60 Hz Apple-silicon target.

| Operation | Time |
|---|---|
| Build fixture | 14.7 ms |
| Evaluator setup | 0.8 ms |
| Evaluate one frame (350 positions) | 37.3 µs average over 2000 frames |
| Audio time → count lookup | 0.12 µs average |
| Full analysis (stride, bounds, close passes, 149 moves) | 61.2 ms |
| Encode document (11 MB) | 596.6 ms |
| Decode document | 394.0 ms (identical after round trip) |
| Commit a 50-performer drag (validate + undo snapshot) | 3.20 ms average |

### Known limitations and honest gaps

- **The Mac app has never been compiled or run.** Expect compile fixes on the first Mac build. The AVFoundation playback clock, MP3 decoding, latency handling, Liquid Glass rendering, VoiceOver behavior and coach-mark anchoring are all unverified.
- Coach marks anchored to toolbar items (the form tools and Export) probably fall back to the instruction card, because toolbar items sit outside the SwiftUI preference tree. This needs checking on a Mac.
- On macOS, document commands run on the main actor instead of a dedicated actor (the architecture asks for an actor). The commands measured above take milliseconds; revisit this if profiling on a Mac shows hitches.
- The working database is materialized at save time from the in-memory model. A live SQLite working copy is not used; the recovery journal covers crashes instead.
- Meter and pulse can only be reconfigured before sets or pins exist. Later structural timing edits need the M2 impact-preview flow.
- The bridge returns JSON scenes. The typed per-frame buffer is deferred until WinUI profiling. The clean-machine deployment of Swift runtime DLLs is untested.
- MP3 is decoded only through AVFoundation, which is untested. The core can detect MP3 but not decode it.
- The CI workflow has not been observed running on GitHub.

### Next explicit milestone

1. **Finish M1 on a Mac:**
   - Run `scripts/bootstrap-macos.sh`, fix compile errors and pin the Xcode version.
   - Run the app tests and the UI acceptance flow (create a 32-performer show, line and arc, 16-count set, undo/redo, import WAV and MP3, two anchors, play across a set boundary, save, quit, reopen, export PDF).
   - Measure playback latency and profile the canvas with 350 performers.
2. **M2:**
   - Composite Bézier and other forms, with exact arc-length spacing.
   - Pinned, custom and proximity assignment with previews.
   - Custom paths and midsets.
   - Meter changes and holds after sets exist, structural count edits with impact previews.
   - Printable charts and dot books; roster and coordinate CSV.
   - `.dots` import against a pinned OpenMarch release with real fixtures and a loss report.
