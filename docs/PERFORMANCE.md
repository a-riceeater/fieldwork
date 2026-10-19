# Playback performance

## Contract

Smooth native playback is a primary product requirement. The reference workload is
350 performers × 150 sets at 60 display updates per second. Measure the complete
editor, including waveform, navigator and inspector, rather than inferring UI
performance from the portable evaluator benchmark. Audio remains the master clock.

## October 19, 2026 investigation

Machine: Apple M3, macOS 26.6.1, Xcode 26.6, arm64, 2× backing scale. The UI harness
opens a 1440 × 960 point editor window. The supplied `drill1.fieldwork` contains
261 performers and 215 sets; analysis produces 5,480 warnings. The input is read
only and is not checked into this repository.

A five-second `sample` of the original running Debug app found repeated timing-map
compilation underneath `NavigatorView` → `Show.moveCounts`, full SwiftUI editor
invalidation, and warning filtering in every canvas snapshot. The native scene
evaluator was not the main bottleneck.

Changes:

- Give playback frames their own publisher. Native canvas and timeline coordinators
  subscribe directly; the navigator, inspector and toolbar update on document/view
  changes. Numeric time/count readouts refresh at 10 Hz and immediately on pause.
- Supply the session's compiled timing map when constructing incoming move counts.
- Preserve roster order when mapping evaluated performers to canvas dots and use
  the section lookup already available for symbols. Skip warning filtering when
  there are no paths to draw.
- Cache one field-background bitmap at the viewport's backing resolution. Changes
  to field, style, zoom, pan, bounds or backing scale replace it.
- Use the canvas's display link, which follows the view's display, instead of an
  unsynchronized timer that enqueues a main-actor task for each tick. A headless
  client retains a timer fallback. Neither clock advances authored musical time.
- Composite the timeline playhead as a separate layer. Waveform and marker lanes
  redraw for content, viewport and size changes, rather than every clock tick.
- Decode audio and build the waveform peak pyramid away from the main actor;
  discard obsolete audio-load results before publishing them.

The controlled baseline with embedded audio disabled measured **70.10 ms median,
76.25 ms p95, 87.43 ms maximum** per synthetic UI refresh iteration. Each iteration
sets a playhead value, services the main run loop for at least 1/60 second, and
forces pending window drawing. These figures include the deliberate wait and are
not standalone rendering costs or GPU-presented FPS.

Final Debug measurements:

| Workload | Synthetic refresh median / p95 | Live updates in 3 s | Live interval median / p95 |
|---|---|---|---|
| `drill1`, audio disabled, Dark | 18.62 / 25.58 ms | 178 | 16.79 / 21.42 ms |
| `drill1`, embedded audio, Grass | 18.42 / 27.30 ms | 180 | 16.69 / 17.69 ms |
| `drill1`, embedded audio, Paper, labels on (new workspace) | 18.26 / 25.58 ms | 179 | 16.67 / 18.18 ms |
| `drill1`, embedded audio, Paper | 18.51 / 24.67 ms | 178 | 16.72 / 18.36 ms |
| Generated 350 performers × 150 sets, Grass | 18.36 / 24.11 ms | 180 | 16.67 / 16.72 ms |

The comparable no-audio synthetic refresh median fell from 70.10 to 18.62 ms
(73% lower). The refresh figures include the deliberate wait; live intervals
measure the separate normal-playback phase.

## Reproducing measurements

After `./scripts/bootstrap-macos.sh`, run the opt-in app test:

```sh
TEST_RUNNER_FIELDWORK_PROFILE_DOCUMENT="$HOME/Downloads/drill1.fieldwork" \
xcodebuild -project apps/macos/Fieldwork.xcodeproj -scheme Fieldwork \
  -configuration Debug CODE_SIGNING_ALLOWED=NO \
  -only-testing:FieldworkTests/PlaybackPerformanceTests test
```

Add `TEST_RUNNER_FIELDWORK_PROFILE_AUDIO=1` to decode the embedded audio, wait for
waveform peaks, and play through AVFoundation. Use
`TEST_RUNNER_FIELDWORK_PROFILE_STYLE=paper` or `grass` to check those backgrounds.
Add `TEST_RUNNER_FIELDWORK_PROFILE_LABELS=1` to include the always-visible label
overlay. Labels use cached bitmaps at the display's backing resolution, avoiding
per-frame text shaping. The 350 × 150 Paper run with labels enabled reached 179
updates in three seconds (16.68 ms median / 17.64 ms p95 intervals).
Use `TEST_RUNNER_FIELDWORK_PROFILE_DOCUMENT=synthetic` for the original generated
350 × 150 workload. Test preferences are isolated from the user's field settings.

`PLAYBACK PROFILE` reports the 120 synthetic refresh iterations described above.
`LIVE CLOCK` reports display update count and median/p95 intervals over three
seconds of normal playback, beginning at 45 seconds. It measures callbacks reaching
the native surfaces, not GPU presentation or acoustic latency. Run measurements
without another playing editor or an active build competing for resources.

The regular app suite verifies that a 350-performer scene reaches both native
surfaces without document-wide notifications, that pausing refreshes the editing
UI/readouts, that field cache changes render correctly, and that moving the
playhead does not invalidate the waveform lanes. Portable tests continue to verify
timing, scene interpolation, command undo and document round trips.

Use Release builds for normal performance evaluation. Debug retains `-Onone` for
useful debugging; the fixes must also keep that build responsive. No comparative
OpenMarch benchmark, GPU frame capture, Intel performance result or long-duration
acoustic synchronization claim is implied by these measurements.
