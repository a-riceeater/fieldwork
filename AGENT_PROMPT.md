# Implementation prompt — native Fieldwork drill editor

You are implementing a real open-source marching drill authoring app. Work in the provided repository. Read its instructions, inspect existing targets and preserve working code. Read the accompanying `DESIGN.md`, `ARCHITECTURE.md` and `RESEARCH.md` fully before choosing implementations. “Fieldwork” is a provisional name; keep naming easy to replace.

## Goal and constraints

Build the macOS app first in native Swift. Use SwiftUI for shell/inspectors/commands, AppKit for precise field interactions and document integration, and AVFoundation for audio. No Electron, Tauri, WKWebView or HTML editor shell. Use actual system Liquid Glass on supported macOS versions, with material/opaque fallbacks. Keep the field and waveform clear, stable and fast.

Windows will use a separate native WinUI 3 frontend and the same portable Swift core through a narrow C ABI. Do not attempt to import Apple's SwiftUI/AppKit into Windows. Compile/test the portable core on Windows from the first milestone, and prove the C ABI before treating that path as solved. Match layout, color, typography hierarchy and tokens; preserve native window controls/accessibility. Use licensed Inter or Segoe on Windows and system fonts on Mac. Do not redistribute Apple fonts or SF Symbols to other platforms.

The app must eventually support the full feature inventory in the design file: field customization, roster, forms, performer assignment, set/count editing, precise transitions/paths, music alignment, analysis, rewriting and teaching exports. Follow its milestones; implement an end-to-end useful editor before advanced maneuvers, 3D or cloud work. No fake functionality or unlabeled placeholders in the native alpha.

## First deliverable: M0 + M1 working loop

1. Inspect the existing Xcode setup. Preserve a working project initially. Put portable logic into Swift packages without Apple-only imports. For a new project, use checked-in XcodeGen `project.yml` and a small app target; pin tools and ignore generated project/user/build state. Do not commit personal signing credentials/team overrides.
2. Define stable performer, field, arrival-set, transition and musical-event IDs. Store canonical geometry in meters. Distinguish the initial preset from incoming moves and arrival formations. Give each performer a valid position or explicit unresolved state.
3. Implement semantic commands with atomic undo/redo. Preview pointer drags; commit one command on mouse-up. Support select/add selection, box selection, pan/zoom, nudge, exact coordinates and visible snap/axis lock.
4. Implement roster creation by section, field presets/custom dimensions, initial formation, line/arc creation with retained geometry/assignment, set creation/duplication, movement editing and straight-path playback.
5. Implement the documented `.fieldwork` ZIP document using a manifest, SQLite and embedded assets. Save consistently through one NSDocument-coordinated path with atomic replacement/recovery. Save/reopen must preserve every M1 feature. Never use `.dots` as the native document or modify an imported source file in place.
6. Import WAV/MP3 via tested native decoding. Show a zoomable cached waveform, seconds and musical rulers, meter/tempo controls, play/pause/seek, set markers and exact sync anchors. Audio is the clock; UI timers are display only.
7. Implement the timing core described in the architecture. Preserve notation denominator, pulse unit and stable event cursors. Provide “Align measure/beat here” and “Align selected set arrival here.” One anchor gives offset; later anchors can refit local timing. Contradictions produce options, not silent changes. An arrival at m17 b1 in 4/4 quarter=120 should map from 44.400 to 44.600 seconds when the second pin is changed, without changing set coordinates or musical positions.
8. Add basic stride/missing-data feedback and a real coordinate PDF preview/export. Provide meaningful file/save errors and a clear dirty/recovered state.
9. Implement welcome, New Show flow, optional music and an editable tutorial sample. Anchored arrow coach marks advance on successful user actions. Back/Skip/Escape/Help replay work; focus and accessibility remain usable. No hard-coded screen coordinates or forced sign-in.
10. Provide a small original demo show, build/run instructions, actual passing-test output and an honest capability list. Keep 3D explicitly later.

## Next milestones

After the loop works, implement composite Bezier forms, exact arc-length spacing, pinned/custom/proximity assignment, custom pathways/midsets, meter changes/holds, structural timing edits with impact previews, printable charts/dot books, roster/coordinate CSV, and richer analysis. Use the release order and acceptance gates in `DESIGN.md`.

Build `.dots` import as a separate adapter using a pinned real OpenMarch release/schema. Read a copy; do not run imported history SQL. Verify field pixel scaling/origin, page semantics, paths, shapes, audio and inheritance with original fixtures. Report loss. Export later creates a new target-version `.dots` database and must be opened in that actual OpenMarch release. Unknown profiles are explicitly unsupported. Do not claim Pyware/UDB/3DUDB compatibility based on file extensions.

For 3D later, add a native renderer consuming the same evaluated scene and timing map; keep x/y/z/facing and appearance keys ready now. Do not create a separate animation engine that disagrees with 2D. Start with simple bodies/props/cameras before uniforms or detailed visuals.

## Engineering rules

- Make reversible edits within the requested scope; keep existing architecture where it already satisfies requirements.
- Domain/timing/persistence do not depend on view frameworks. Selection and tour state do not become required show data.
- Validate compound operations and document changes in one transaction. Count/beat deletion must not silently delete drill.
- Preserve audio source samples and authored anchors. No destructive audio padding/trimming needed for alignment.
- Treat GPL/AGPL upstream licenses per file/component. Write original code; do not copy or translate source and relicense it. Keep third-party notices accurate.
- Keep native UI functional and accessible, including reduced transparency/motion. Warnings use text/patterns as well as color.
- Run meaningful tests for timing inverses/conflicts, geometry, compound undo, save/recovery/migration and import conversions. Avoid test quantity as a substitute for behavior.
- If running on Linux or Windows without Xcode, continue portable work and clearly state Mac builds were not run. Never invent a successful xcodebuild, notarization, native playback test or compatibility round trip.
- Website work is separate static HTML/CSS/JS with local assets. Keep two concept pages and honest platform placeholders; no backend or invented release downloads.

## Acceptance demonstration

Create a 32-performer show; choose a football field; create a line and an arc; add a 16-count arrival and move performers; undo/redo; import audio; align the first downbeat and a later measure to exact timestamps; scrub and play across a set boundary; save, quit, reopen and verify positions/timing; export a readable coordinate PDF. Repeat core fixture evaluations on Windows. Then profile a 350-performer fixture and record actual results.

Work until the current milestone is complete or a genuine platform/tool limitation blocks it. Keep a concise progress log of completed behavior, commands actually run and remaining limitations. Finish by reporting what works, what was tested and the next explicit milestone. A beautiful screen with unimplemented commands is not completion.
