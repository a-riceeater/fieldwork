# Progress log

## 2026-10-19: Shorter, safer shape assignments in a fraction of the time

Three causes of long or odd marches and slow arrangement were traced in the code
and fixed:

- **One performer crossing the form.** Total straight-line distance ties between
  "everyone steps one dot" and "one performer runs to the far end", so the old
  matching could choose the latter. It now minimizes total *squared* travel. In a
  straight move from the previous set this also keeps every matched pair at least
  1/√2 of its start or end spacing apart, so most close passes never arise.
- **Matching the wrong move.** The cost used each performer's current position on
  the edited set, so retrying shapes on one set matched against the previous
  attempt rather than the actual march. It now uses the previous set's position
  and, when the next set is placed, the next set's position; the current position
  is used only when neither neighbor is placed.
- **Slow refinement.** Each proposed swap rescored every performer and every swap
  partner was tried, so the 500,000-unit budget was usually exhausted. Swaps now
  go only to nearby dots (12, widening to 48 in later sweeps) and to performers
  already in conflict, with a grid broad phase and sparse pair scores. A swap may
  not trade a close pass for a large stride. Sorting the selection by roster order
  also looked up performers linearly inside the comparator; it now ranks once.

Measurements on the Windows machine (Release, assignment only, 16-count moves):

| Case | Before | After |
|---|---|---|
| 48-dot block shifted diagonally, longest move | 8.24 m | 4.12 m (everyone shifts once) |
| 120 scattered → block | 0.47 s | 0.003 s |
| 350 scattered → circle | 0.16 s | 0.015 s |
| 350 scattered → block, both moves placed | 0.54 s, 1,326 close passes | 0.15 s, 900 |
| 100 through 150 stationary performers → arc | 0.49 s, 7 close passes | 0.07 s, 5 |

In Debug, the same 120 → block case fell from 4.03 s to 0.020 s and 350 → circle
from 1.25 s to 0.19 s. Cases that end with many unavoidable conflicts still run
to the work budget: 0.5–1.1 s in Debug (previously 3.4–4.5 s). These figures come
from a scratch benchmark that was not committed. They cover assignment only, not
end-to-end editor latency.

Validation: all portable suites passed (DrillTiming 20, DrillCore 64,
DrillDocument 28, DrillBridge 2). New regressions cover retrying a shape on a set
whose positions were reversed by an earlier attempt, the one-dot shift that
previously tied, and a far-off performer that must not stall the broad phase.
Tests that relied on the current position overriding the previous set were updated
to the new rule. The Mac app was not built or run; its arrangement
calls these same core functions.

## 2026-10-19: Keep collision-aware arrangement responsive

The previous collision optimizer executed on the Mac main actor and repeated
current-pair measurements for every proposed swap. Four sweeps alone did not
bound its cubic work or its per-arc sampling, so dense drill could block the UI.
The app was not running when investigated; this cause was traced in the code.

- Cache the current pair-risk matrix and per-performer totals, refreshing only
  changed rows after an accepted swap. Cache unselected-performer scores too.
- Limit collision refinement to 500,000 work units, charging broad-phase checks
  and reserving arc sampling/refinement work before each narrow-phase call.
  Stop on cancellation or budget exhaustion. Discard incompletely evaluated
  candidates and return the last fully scored assignment; an incomplete baseline
  leaves the proximity assignment intact. Normal close-pass warnings remain.
- Build drawn forms, quick shapes and Place All from an immutable show snapshot
  on a detached task. Show “Arranging performers…” and Cancel. Commit the result
  as one normal undo step on the main actor only if the document revision, set,
  selection and editability still match. Cancellation, edits, selection changes
  and set navigation discard obsolete results.

Validation: all portable suites passed (DrillTiming 20, DrillCore 61,
DrillDocument 28, DrillBridge 2). The Mac suite passed 25 tests with one opt-in
benchmark skipped; the three arrangement tests passed again after adding explicit
worker cancellation checks. Tests deliberately block background calculation to
verify main-actor responsiveness, one undo step, Cancel, obsolete-result rejection
and failure recovery. Nine collision regressions also passed in Release. The
350-performer assignment measured 0.361 s Release (previously 0.492 s) and 2.77 s
Debug (previously 4.1–4.5 s). An 80-performer curved case with an intentionally
small 5,000-unit budget returned its intact baseline in 0.36 ms Release / 2.0 ms
Debug. These measurements cover assignment, not end-to-end editor latency.
No manual UI session or user-document reproduction was run.


## 2026-10-19: Consider timed collisions during shape assignment

Shape creation now refines the proximity matching with up to four deterministic
pair-swap sweeps. The objective prioritizes fewer close-pass warnings, then less
clearance deficit, then shorter travel. It checks both adjacent moves, including
unselected moving and stationary performers, using the show's `minClearance`.
Candidate routes receive the same endpoint adjustment and canonicalization as
committed paths. The shared analyzer supplies exact straight/hold measurements
and sampled/refined arc measurements, so crossing at different counts is allowed.
No performer outside the selection is reassigned, and path timing and control
points remain authored. A zero clearance disables this refinement.

This is bounded local optimization, not a global or collision-free guarantee.
Fixed endpoint spacing cannot be repaired by assignment; remaining mid-move
close passes still use the normal analysis warnings. Initial presets with no adjacent move keep proximity behavior;
existing form-handle and explicit reverse-order edits retain their assignments.

Validation: all portable suites passed (DrillTiming 20, DrillCore 59,
DrillDocument 28, DrillBridge 2). The unsigned Debug Mac suite passed 22 tests
with one opt-in benchmark skipped. Seven new collision regressions cover
incoming/outgoing moves, an unselected stationary performer, staggered holds,
an unselected arc whose chord misses the collision, disabled clearance,
undo/redo and a 350-performer reversed formation. The large formation has no
remaining close-pass warnings after assignment. All seven collision regressions
also passed in Release; the 350-performer assignment command took 0.492 seconds
(about 4.1–4.5 seconds in Debug). No manual UI session was run.


## 2026-10-19: Assign shape dots by proximity

New drawn lines/arcs and quick lines, arcs, blocks and circles now assign members
by minimum total straight-line travel in meters using a deterministic Hungarian
matching. Section and roster order no longer determine destinations for placed
performers. An unresolved arrival uses the previous set's position when available;
performers without either position fill remaining dots in stable roster order.
Place Unplaced also matches across its section blocks when prior positions exist.
Existing form handle edits and explicit Reverse Order retain their assignments.
The Mac editor and C bridge use the same core assignment, and undo/redo preserves
the resulting membership and placements.

Validation: all portable suites passed (DrillTiming 20, DrillCore 50,
DrillDocument 28, DrillBridge 2); the final DrillCore run passed 52 tests including
six proximity regressions. The unsigned Debug macOS app test suite passed via
`xcodebuild ... test`. Tests cover all four quick shapes with reversed section
order, drawn line/arc membership, undo/redo, previous-set fallback, mixed placed
and unplaced members, deterministic ties, and a case where greedy nearest-dot
selection produces unnecessary travel. No manual UI session was run.


## 2026-10-19: Per-performer paths (P0 and P1 of `FIELDWORK_PATHS.md`)

Environment: Windows 11 Home (10.0.26200), Swift 6.4 (`swift-6.4-RELEASE`), .NET SDK. **No Mac was available**, so the macOS part was written but not compiled or run.

### Completed behavior

- **Model** (`DrillCore/Path.swift`): `PathSegment` (`hold`, `line`, `arc`) with exact `Rational` counts, `PerformerPath` on `Transition.paths`, arc geometry with tight bounds, split, scale, end moves and canonical form. `Transition` still decodes without `paths`, so older journals and fixtures replay. `transition.model` stays `straight`.
- **Evaluator:** follows a performer's path when there is one; `isMoving` is false during a hold; `z` and facing interpolate as before. `makeSplitMove`, playback and the bridge scenes use the same evaluator.
- **Validation:** the path invariants (placed ends, counts that add up exactly, finite points, arc sweep and chord, end on the arrival).
- **Commands:** new `setPaths`. Placement edits move the last leg's end (arcs keep their sweep), changing move counts scales segments exactly, splitting a move cuts each path at the count, deleting a set joins the two routes so its positions become waypoints, unresolved or inactive ends and removed performers drop paths, and new sets start straight. Builders: hold phases (start late, arrive early), insert, move and delete waypoints, curve a leg by sagitta with snap, even pace, straighten, per-segment info.
- **Analysis:** stride uses the fastest segment and reports its count range; close passes split at both performers' joints, are exact on straight pieces and sampled (8 per count, then refined) on arcs, and are marked as sampled; arc bulges outside the field are flagged.
- **Document:** schema 5 `path_segment`, migration 4 → 5, canonical deterministic rows, a reader that rejects unknown kinds, gaps, bad NULLs and non-integer durations, and `drill.paths.v1` in both capability lists when any path exists.
- **fwtool:** `info` reports path counts; `paths-fixture` writes the synthetic `spec/fixtures/paths.fieldwork` (golden output in `spec/fixtures/paths-evaluation.json`).
- **macOS (not compiled):** paths drawn for the selection or everyone (View › Show All Paths) with count ticks, hold markers and dashed warning paths; drag the path to add a waypoint, drag or double-click a waypoint ring, drag a leg's diamond to curve it; a path inspector with hold phases, Even Out Pace, Straighten and per-segment counts, length and `n to 5`.

### Commands actually run

| Command | Result |
|---|---|
| `scripts/test-portable.ps1` | DrillTiming 20, DrillCore 46 (18 new path tests), DrillDocument 28 (6 new), DrillBridge 2; release `FieldworkCore.dll`; C# interop smoke test passes; exit 0 |
| `fwtool paths-fixture spec/fixtures/paths.fieldwork` then `fwtool info` | 6 paths with 10 segments in 2 of 2 moves |
| `fwtool profile 350 150` (release, no paths) | Evaluate frame 35.2 µs, full analysis 58–60 ms, 50-dot drag commit 3.02 ms, round trip identical |

### Not done

- **The Mac UI code has not been compiled.** Expect compile fixes on the first Mac build.
- P2 generators (follow-the-leader, block rotation) and a `cubic` segment kind.
- "Keep holds fixed" when stretching a move; it scales every segment today.
- The converter acceptance run on a real drill belongs to the converter's owner and was not run here.

## 2026-10-19: Start move readouts at count one

Move readouts now use one-based marching counts rather than elapsed counts from
zero. The displayed count is capped at the move duration, so a one-count move
shows “1 count” throughout, including with Whole Counts Only enabled. Timing and
performer interpolation are unchanged. Verified with `git diff --check`; no builds
or computer control run.

## 2026-10-19: Show counts within the current move

Canvas, transport and status readouts now show elapsed counts from the previous
set and the source/destination labels (for example, “7 counts · Set 22 → 23”).
At an arrival, before the preset and after the final set, they show the set label.
The whole-count preference applies consistently across these readouts. Cached
set pulses supply the offset without evaluating performers or rebuilding timing.
Read all project Markdown documentation. Verified the diff with `git diff --check`;
no builds, app tests or computer control run, per the requested lightweight workflow.

## 2026-10-19: Keep front labels tight to performer dots

Front labels now use cached glyph images cropped to their visible ink, removing
the invisible font line padding that made the gap appear larger on small dots.
The visible text edge stays one screen point from the dot edge at every zoom.
Original offset placement retains its previous image and position. Cropping runs
only when populating the label cache, avoiding additional per-frame work.
The Mac suite passes: 19 tests, one opt-in benchmark skipped, zero failures.


## 2026-10-19: Center performer labels toward the front sideline

Labels now default to horizontal centering in front of each dot (toward the
audience, below the dot in Fieldwork). View → Performer Label Position → Offset
(Original) restores the previous diagonal placement. This per-user choice persists
without modifying the show; fixed label sizing and bitmap caching are unchanged.
Regression checks cover front-side centering, rendering after switching both ways,
and persistence of the original placement. The Mac suite passes: 18 tests, one
opt-in benchmark skipped, zero failures.

## 2026-10-19: Keep zoomed field content inside the canvas

Enabled native view clipping, saved and clipped the Core Graphics drawing context
at the canvas bounds, and clipped the SwiftUI canvas host. Zoomed dots, labels,
notes and gesture previews can no longer draw over neighboring UI. A bitmap
regression renders an edge-crossing performer into a larger surface and verifies
that outside pixels stay untouched and the caller's clip is restored. The Mac
suite passes: 17 tests, one opt-in benchmark skipped, zero failures.

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
- All 16 Mac tests pass, including initial pane allocation, narrow-window limits,
  initial field fit, manual zoom preservation, label persistence/rendering and the
  playback regressions. The real file with audio and labels on reached 179 updates
  in three seconds (16.67 ms median / 18.18 ms p95 intervals). The 350 × 150 Paper
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
