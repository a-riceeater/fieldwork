# Fieldwork — implementation architecture

This is a proposed architecture, not an implemented or benchmarked system. Sources and platform decisions are documented in `RESEARCH.md`. Implement the useful Mac editor first, while proving the portable core on Windows from M0.

## 1. Chosen stack and boundaries

| Component | Implementation | Boundary |
|---|---|---|
| Mac application | SwiftUI scene, commands, split views and inspectors; AppKit `NSDocument` integration | Owns platform UI, file coordination, menus and window state |
| Mac field canvas | `NSView` drawing with Core Graphics, hosted through `NSViewRepresentable`; Metal backend only when profiling justifies it | Takes immutable scene snapshots; returns semantic editing intents |
| Mac music | AVFoundation (`AVAudioEngine`/player node and decoded PCM) | Native audio clock, seeking, rate and output handling |
| Portable domain | Swift Package Manager packages using cross-platform Swift/Foundation | No SwiftUI, AppKit, CoreGraphics, AVFoundation or RealityKit imports |
| Persistence | SQLite through a system-library/module wrapper with platform-specific SQLite linking; original SQL repositories | No Apple-only persistence framework |
| Windows application | C# WinUI 3/Windows App SDK, native drawing/composition, native media adapter | Matches design tokens and commands, not Apple APIs |
| Shared Windows core | Swift DLL with a versioned C ABI and opaque handles | No direct Swift object/collection/string ABI exposed to C# |
| Future Mac 3D | RealityKit adapter | Renders the shared evaluated scene; never owns drill state |
| Website | Plain HTML/CSS/JS and local SVG images | Standalone marketing/concept pages only |

Choose a released Xcode/Swift pair that supports the APIs and a matching supported Windows Swift compiler; record the exact pair in the repository. Initial deployment target: macOS 14+ with `#available(macOS 26, *)` for Liquid Glass. Baseline Windows GUI target: Windows 11; no requirement to imitate unsupported material effects on older systems. Feature detection is required even within supported versions.

Native Swift is the Mac implementation requirement. The Windows UI is deliberately C#, with Swift domain logic. If every Windows source file must also be Swift, that is a different constraint: run a limited Swift/WinRT or Swift-native GUI spike before committing, rather than pretending Apple's SwiftUI runs on Windows.

## 2. Repository and Xcode handling

Keep one repository with these roots:

| Path | Purpose |
|---|---|
| `apps/macos/` | App entry, platform adapters, assets, entitlements, `project.yml`, xcconfig files |
| `apps/windows/` | WinUI solution, view models, drawing/audio adapters, C# interop |
| `packages/DrillCore/` | IDs, field, roster, sets, paths, forms, commands and validation |
| `packages/DrillTiming/` | Musical events, tempo compiler, anchors and invertible time map |
| `packages/DrillDocument/` | Native container, SQL storage, migration and recovery |
| `packages/DrillInterop/` | OpenMarch and exchange adapters |
| `packages/DrillBridge/` | DLL product and C ABI exports |
| `spec/` | Native format, exchange schemas, compatibility profiles and golden fixtures |
| `design/` | Shared tokens, interaction notes, reference images |
| `website/` | Static public pages |
| `scripts/` | Bootstrap, test, packaging, signed release procedures |

Create the Xcode application project from a checked-in **XcodeGen `project.yml`**. It defines one small Mac app target, app tests, shared scheme and local Swift package dependencies. Treat that spec plus source and xcconfig files as authoritative; ignore generated `.xcodeproj`, DerivedData, `xcuserdata`, build products and personal signing overrides. Generate before opening Xcode and before CI. Pin the XcodeGen release in bootstrap documentation/tool configuration.

Do not edit generated project settings by hand and expect them to persist. Add files and targets to the spec or package manifests, regenerate, then build. Swift package logic remains testable without an app project. This keeps coding-agent edits away from routine `.pbxproj` merges.

If the repository already has a working Xcode project, **preserve it for the first working milestone**. Move logic into local packages first. Convert to XcodeGen once in a dedicated, reviewable change and compare targets, entitlements, resources, schemes and build settings. Never delete a functioning project to enforce a preferred structure prematurely. An explicitly user-required committed Xcode project overrides the generated-project recommendation; in that case keep changes small and use one source of build configuration.

Use `Base.xcconfig`, `Debug.xcconfig`, `Release.xcconfig` plus an ignored `Local.xcconfig`. Commit bundle ID/UTType templates with a clearly replaceable namespace. Do not commit a personal Development Team, certificates, private keys or local provisioning profiles. Allow unsigned local CI builds. Pin resolved dependencies; keep public source builds possible without signing secrets.

Representative commands after implementation:

```sh
swift test --package-path packages/DrillTiming
swift test --package-path packages/DrillCore
xcodegen generate --spec apps/macos/project.yml
xcodebuild -project apps/macos/Fieldwork.xcodeproj -scheme Fieldwork -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Do not report these as passing until they run on a Mac with the chosen toolchain.

## 3. Portable model

Use strongly typed UUID identifiers, `Double` coordinates, integer/rational musical offsets and immutable snapshots. Persist **meters** as canonical world units; steps, yards, inches and pixels are views or import conversions. Origin: field center, +x to audience's right while looking from front stands, +y toward the back sideline, +z upward. Field-relative coordinate naming is configurable and must never be inferred from raw left/right strings.

| Entity | Essential fields |
|---|---|
| Show | ID, title, movements, format version, creation metadata |
| Movement | ID, ordered timing events, set IDs, media selection |
| Field | dimensions, origin, checkpoints/hashes, display side labels, step size, calibrated background transform |
| Performer | stable ID, drill label, section/tag IDs, optional private roster fields, active interval, appearance |
| ArrivalSet | ID, movement, timeline cursor, label, subset flag, notes |
| PerformerPosition | performer ID + set ID, world x/y/z, facing, appearance overrides |
| Transition | source/destination set IDs, movement model, per-performer paths, count-pulse policy |
| Path | line/Bezier/composite geometry, waypoint cursors, hold/move segments, optional group transform |
| Form | control geometry + assignment order + spacing constraints; set-specific instance |
| Annotation | set/range, geometry, text, layer/style |
| MediaAsset | asset ID, hash, relative embedded path, sample rate/frame count, media metadata |
| AudioAnchor | timeline cursor, audio asset ID, source sample frame, lock and fit policy |
| SceneAppearance | section defaults, performer overrides, future equipment/body/prop references |

An arrival set is an exact formation at a cursor. Incoming movement is a separate interval. Preset is count 0; move 16 arrives after 16 count pulses. Display counts and labels can be customized without altering identity or time. Optional subsets and midsets are distinct: a subset is a named arrival boundary; a midset can constrain a single trajectory without becoming a full ensemble set.

Give every active performer a defined position at every arrival, or an explicit unresolved/inactive state. Do not invent `(0,0)` for missing data. Endpoint continuity and active intervals are model invariants. Facing is explicit and may differ from travel direction. Store z/facing now with defaults; add richer 3D assets later through versioned schemas.

## 4. Commands, editing and state

The document session is the sole mutable model owner. On Mac, an actor serializes document commands and persistence; the main actor owns view state only. On Windows, the bridge delegates to the same core command processor through a serialized session boundary.

Gesture preview → semantic command → validation → atomic transaction → revision number + inverse command/change set → immutable scene snapshot. Persist only on commit, not every pointer move. One drag equals one undo unit; multiple inspector fields may form a named transaction. Escape drops preview. Undo must restore geometry, assignments, timing and dependent objects together.

Selection, hover, panel widths, visible range and tour progress are local view state. Do not serialize them as required drill semantics. A scene snapshot contains typed geometry, style keys and draw ordering; hit testing returns performer/form/path IDs. Both canvases share world transforms and evaluator tests, but platform drawing is separate.

Edits that affect references (delete beat/set, rewrite roster, replace field, shorten movement) produce an impact plan. The UI shows reattachment, deletion and unresolved outcomes; user applies one transaction or cancels. Never cascade-delete drill because a tempo group was removed.

## 5. Timing engine

### Musical representation

Separate notation, march count pulses and recorded time. A meter is `(numerator, denominator, grouping)`; tempo specifies its beat unit. A 6/8 bar at dotted-quarter = 80 lasts 1.5 seconds; whether it contains 2 or 6 marching counts is explicit. Time signature numerator alone cannot answer that.

Store ordered **performance events** with stable IDs: notated beat/subdivision events plus explicit timed hold events. Each musical event has a rational notated duration and baseline duration; notated positions are indexed to measure/beat/subdivision. A cursor is `(eventID, rationalFraction)`; at boundaries use a canonical next-event cursor. A hold can have elapsed time with no advancing notation or march count. This avoids two anchors at the same ambiguous notated tick during a fermata. Set arrivals in a hold use explicit cursors, and the UI labels the hold offset.

Tempo-group operations compile into event baseline durations transactionally. Constant tempo uses `seconds = 60 × beatUnits / BPM`. A ramp has an explicit policy (initially linear BPM over musical position), integrated consistently; record compiler/version semantics. Per-event duration overrides are supported. Do not store an independently editable second tempo truth and silently reconcile it with durations.

Pickup measure numbering, repeated music unfolding, pulse grouping and measure numbers are mappings over the performance event order. Stable IDs survive renumbering. Deleting referenced events requires an impact plan. MusicXML repeats must be deliberately unfolded or rejected with an explanation.

### Anchors and fitting

For the first version one selected audio asset supplies the playback reference per movement. Anchors bind cursors to exact source sample frames; timestamps shown in milliseconds are an input/output view. Store each asset's sample rate and sample coordinate; output-device resampling does not alter persisted anchors. Audio offset is just the first anchor in another UI form.

With one anchor, use baseline durations before and after it. With two or more, require strictly increasing cursors **and** source frames. For each constrained interval, integrate baseline event/sub-event durations to weights `w_i`. Fit unlocked event durations by a common positive scale so they sum to the constrained audio duration. For fixed hold durations, subtract fixed time first and scale only elastic durations. Reject an interval with nonpositive remaining time, no elastic duration or an out-of-range implied tempo.

Inside an interval, cumulative fitted duration gives a continuous, strictly increasing piecewise map `F(cursor) → audioTime`. Its inverse is found by binary search over cumulative boundaries and interpolation within the event. All rendering, set navigation, loops, export and click scheduling use this map. Beyond pinned intervals use baseline durations from the nearest anchor. Negative mapped audio time means pre-roll/silence, not a negative seek into the file.

Example: 4/4, quarter = 120, 16 bars means 64 quarter beats. Pin m1 b1 to 12.400 s. Unfitted m17 b1 is 44.400 s. Pin it instead to 44.600 s: elapsed 32.200 s, scale 1.00625, mean quarter tempo approximately 119.255 BPM. Geometry and set musical positions are unchanged. Report the fitted result to the user.

Preserve Audio Pins mode refits elastic durations. Preserve Notated Tempo mode requires moving/releasing conflicting pins explicitly. Never silently satisfy contradictory constraints. Moving a set to another musical cursor and creating an anchor for its current cursor are separate commands with separate undo descriptions.

### Playback

Audio sample/host time is the master clock. After scheduling playback/seek, query the native engine's presented/scheduled audio position and map through `F⁻¹`. A display timer only asks what to draw; it never increments the authoritative count. Account for output latency in the transport adapter, with an optional user calibration offset stored separately from authored sync.

On Mac use a native AVFoundation PCM pipeline, source seeking, rate control and scheduled metronome. On Windows use a native audio adapter (Media Foundation decoding plus an audio render clock; validate the final API/library in the Windows spike). Never use UI timers as media clocks. Define pause, seek, loop boundaries, device changes, underruns, end-of-file and no-audio playback explicitly. No-audio mode uses a monotonic host clock through the same timing map.

Initial guaranteed import targets: WAV and MP3 on each supported platform. Add AIFF/M4A where tested. OGG needs an explicitly selected, license-audited decoder on both platforms; do not promise it just because OpenMarch supports it. Decode waveform peaks in the background, cache multi-resolution min/max pairs and render only visible samples. Rate changes do not rewrite the map or source anchors.

## 6. Native document format

**`.fieldwork` is a ZIP container on both operating systems**, not a macOS-only directory package. Register a UTType/document extension and Windows file association. The published format specifies these members:

| Member | Contents |
|---|---|
| `manifest.json` | format identifier, major/minor, writer/min-reader versions, show ID, capabilities, asset hashes |
| `show.sqlite` | schema version, roster, field, event order, sets/positions, forms, paths, anchors, notes |
| `assets/<hash>.<ext>` | embedded audio, calibrated backgrounds and later licensed assets |
| `preview.png` | Optional regenerated preview |
| `extensions/<namespace>/...` | Optional future/third-party opaque extensions |

A working directory contains an extracted database and SQLite journal while open. Use SQLite transactions and foreign keys. Do not mutate a ZIP on every drag. Serialize app file operations with NSDocument save coordination; never let both NSDocument and a parallel custom writer race to replace the same document. On Windows use an equivalent single session writer.

Save creates a consistent database snapshot with SQLite backup API into staging, includes assets, validates manifest/hashes, writes a sibling temporary archive, flushes and atomically replaces the target where supported. Keep the prior good version/recovery journal. Never copy an active WAL database without its committed state. Recovery replays only complete versioned commands after the last snapshot. Two writers opening one document get conflict handling, not simultaneous write access.

Migrate a copy and keep the original before upgrading. A higher unsupported major version opens read-only or is refused without changing bytes. Unknown optional extensions are preserved on rewrite; required unknown capabilities block editing. Strip private roster names from public exports unless requested. Media paths are relative; optional linked media requires relinking and does not make a portable package complete by magic.

Publish a machine-readable schema and original golden examples. ZIP readers reject path traversal, excessive expanded size, malformed manifests and untrusted SQL execution. SQL imports read data through prepared queries into our model; they never execute embedded undo SQL.

## 7. Interoperability contracts

### OpenMarch `.dots`

Importer opens a copy read-only, recognizes SQLite signature and known schema/migration profiles, reads relevant tables, then emits native entities plus diagnostics. It must never run OpenMarch migrations on the user's original file. Maintain a coverage matrix keyed by real release + commit + migration journal fingerprint.

Convert field pixels using the actual profile's field scale, origin and orientation. Map beat IDs/order/durations and measure start IDs to event cursors. Verify whether an OpenMarch page's attached beat represents a displayed formation or the next movement boundary in that version; fixtures, not names, decide. Convert shape SVG path commands/control points and marcher order. Map path ownership, partial path ranges, midsets, rotations, appearance inheritance and embedded audio only when their semantics are verified. Preserve unmapped data as a provenance attachment where appropriate, without claiming editability.

Export constructs a **new** database conforming to a pinned known target, including required metadata/defaults and referential integrity. Do not copy the source's undo SQL or inject custom tables. Flatten unsupported anchor/tempo data into target beat durations where representable; bake form positions or sample paths only with an explicit approximation tolerance. Complex 3D visual tracks and hold semantics may be unrepresentable. The loss report lists omitted/approximated fields, timing/position tolerances and affected performers/sets. User sees it before export.

Ship import before export. A compatibility badge requires reopening output in the actual target OpenMarch release and checking geometry, timing and assets, not merely reading our own output. Unknown schema versions receive an actionable unsupported message; experimental best-effort parsing is explicitly labeled.

### Other formats

Native JSON exchange is documented and versioned, using canonical units and stable IDs. CSV roster and coordinates have a wizard for units, field origin and label mapping. PDF coordinate extraction, Pyware/UDB import/export and 3DUDB conversion are not promised by this architecture. Implement only from supported/documented interfaces and verified samples; do not infer them from extensions. `.fielddots` import is a later small adapter with a missing-background warning.

## 8. Geometry, animation and analysis

Use analytic line/arc operations, cubic Bezier paths and adaptive arc-length lookup tables. Equal spacing means equal distance along a path, not equal Bezier parameter. Separate assignment optimization from trajectory generation. Hungarian/min-cost assignment can minimize travel with section/order penalties, but pinning and collision inspection remain necessary; a minimum-distance assignment does not prove marchability.

Store transition evaluators for linear travel, waypoint path travel, group transforms and later traditional maneuvers. Parameterize movement in count pulse progress, with optional hold/travel phases. Frame evaluation uses audio time → cursor → count phase → transition progress → world scene. Direction/facing and step stride are separate outputs.

Stride analysis uses traveled path distance per count and each performer's pulse/hold policy, not just endpoint straight-line distance. Straight-line pair collision distance can be minimized analytically over a common interval; curved paths use broad-phase spatial bins/swept bounds plus adaptive refinement and an explicit error bound. Mark sampled/approximate results as such. Check field bounds and missing positions. Warn rather than automatically warp formations.

Targets for profiling, not existing benchmark claims: 350 performers × 150 arrivals, smooth interactive pan/drag at 60 Hz on a reference Apple-silicon machine; useful fallback at 30 Hz for heavier scenes; bounded memory during long playback. Record actual device, display scale and scene complexity. Cache field layers, spatial indices and path lengths; render dense dots in one drawing surface instead of hundreds of SwiftUI layout nodes.

## 9. Native Windows bridge

Prove this at M0 with create show → move performer → encode/decode → evaluate positions → return errors on a clean Windows machine. Export a narrow C-callable surface with a documented ABI version. Confirm stable export mechanisms for the pinned Swift compiler; isolate any underscored compiler attributes if necessary.

Suggested API families: `fw_abi_version`, `fw_session_create/destroy`, `fw_dispatch_command`, `fw_get_snapshot`, `fw_evaluate_scene`, `fw_buffer_free`. Opaque handles and fixed-width primitives only. Exchange structured commands/snapshots as UTF-8 JSON initially; use contiguous typed scene buffers for per-frame evaluation after profiling. Every returned buffer carries length and has exactly one core-owned deallocator. C# copies/pins buffers for defined call lifetimes and never frees Swift memory itself.

All functions return explicit status/errors; Swift exceptions do not cross FFI. Document thread confinement, cancellation and callback ownership. Avoid cross-runtime callbacks in the initial bridge. Package the Swift runtime and dependent DLLs as required by the chosen toolchain, validate architecture matching and run an installed clean-machine test. Keep UI accessibility and window behavior native to WinUI. A bridge failure must not corrupt the document.

## 10. 3D without rebuilding the app

The scene evaluator produces performer transforms, facing, appearance keys, props and field dimensions for any cursor. The 2D renderer uses x/y; the later 3D renderer uses x/y/z with an explicit adapter coordinate transform. RealityKit on Mac and an independently selected native renderer on Windows consume the same snapshot contract.

Begin with instanced/simple bodies and simple dimensioned props, not a complex uniform catalogue. Camera tracks are separate from drill movement and reference the common timeline. PDF and video export use deterministic evaluation, not recorded UI frame timing. Test identical world positions at set boundaries and intermediate counts. Evaluate licensing and asset ownership before distributing model libraries.

## 11. Onboarding implementation

Versioned tour state machine listens to command-success events. Each step declares prerequisites, target semantic accessibility ID, completion predicate and fallback instruction. Anchors resolve through view preferences/geometry; arrows are rendered in an overlay. A target moving offscreen collapses the coach mark into an instructional card. No hard-coded screen coordinates or timing-based auto-advance.

Tour progress is per-user local settings. Sample show has its own untitled session. Keyboard focus, Escape, skip/back, reduced motion/transparency and screen reader descriptions are acceptance criteria. Help can reset the tour without resetting user preferences or documents.

## 12. Tests, CI and distribution

Essential tests: format round trips and failed-save recovery; migrations with original retained; inverse timing map; 6/8 pulse distinctions; pickups/holds; anchor conflicts and locale-independent numbers; set boundary evaluation; undo/redo for compound commands; `.dots` real fixtures and target app verification. UI smoke: create roster → draw line → create/move set → import audio → anchor → play → save/reopen → export preview. Include a 350-performer fixture and a large-show performance harness.

Run portable Swift tests on Mac and Windows on every change. Mac CI generates project and performs unsigned build/UI smoke. Windows CI compiles the core DLL and interop smoke early, then the GUI/installer when present. Use pinned toolchains and dependency lockfiles. Capture failures without personal show/music data in telemetry; crash reports should be opt-in or locally exportable.

Open-source distribution: publish repository license, contribution guide, issue templates, security contact, build instructions, file-format specification and a truthful feature matrix. Recommend GPL-3.0-or-later for original app code, but audit reused components and compatible obligations before merging them. Ship exact corresponding source/build scripts alongside releases. Start with GitHub release artifacts; no account or server is required for editing.

Mac release: build chosen architectures, sign with Developer ID, enable required hardened-runtime settings, notarize and staple, then create a DMG/ZIP. Signing credentials stay in protected release CI. A contributor can build locally without distributor credentials. Do not claim Intel support unless the chosen toolchain/API/deployment matrix is tested. Windows: signed installer/MSIX or appropriate package, runtime dependencies and clean-machine smoke. Later updater uses signed metadata/artifacts and rollback; do not build an unsigned arbitrary-code updater. App Store distribution is a separate decision, not a reason to block direct open-source releases.

Release gates are reproducible document/audio/export behavior, not a checklist of UI buttons. This planning package contains no native executable, real codec integration, compatibility converter or signing configuration yet.
