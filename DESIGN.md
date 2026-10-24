# Fieldwork — product and interaction design

Working name. This is the target specification for an independently written, open-source drill editor. Competitive facts and sources are in `RESEARCH.md`; requirements here are design decisions, not claims that the app already exists.

## 1. Product promise

Design a complete show with precise, editable formations and movement. Hear the music and see the right count, every time. Keep your work in a documented file you control. Start with a professional native Mac editor; bring the same document and workflow to Windows.

The primary users are drill writers, directors and student designers. Their core loop is: build roster → define field → align music → create sets → draw and refine forms → evaluate movement → revise → export teaching materials. Music remains optional; a counts-only show must be fully editable.

## 2. Product scope and release order

| Milestone | Must actually work | Exit gate |
|---|---|---|
| M0 foundations | Domain model, timing conversions, portable core, document skeleton, Mac app opens; Windows core CI | Same deterministic fixtures on Mac and Windows; save schema documented |
| M1 first complete loop | Roster/field setup, selection/nudge/move, line/arc forms, set duplication, straight paths, WAV/MP3 waveform, anchor sync, save/reopen, undo/redo, coordinate PDF, guided sample | A user can build, play, close, reopen and print a short show without developer intervention |
| M2 capable Mac alpha | All core shape tools, exact assignment, custom paths, midsets, mixed meter, tempo changes, structural set/count editing, warnings, charts/dot books, CSV, `.dots` import | Realistic 350-performer show remains usable; no silent import loss |
| M3 native Windows beta | WinUI editor with matched tokens; native dialogs/audio/printing; feature parity matrix; `.dots` target-version export | Open the same native show on both systems; timing and geometry agree |
| M4 advanced design | Rewrite/cast changes, traditional transitions, production sheet, layered annotations, richer 3D preparation | Every advanced operation is previewable and reversible |
| M5 3D | Native 3D viewer, simple bodies/props, camera presets and video export | 2D/3D position agreement and long-playback audio tests |
| Later separate scope | Performer viewers, optional cloud sharing, live collaboration, automatic beat detection | Deliberate new specification; authoring remains available offline |

Full customization is the product destination. Do not compress the entire table into one fragile first build. Keep a real capability registry and make unreleased features visibly unavailable rather than clickable stubs.

## 3. Visual system

### Character

Quiet, precise, spacious. A dark blue-gray field, small crisp dots, restrained blue selection, pale floating controls and very little decoration inside the work area. Content has contrast and stability; glass gives the surrounding controls a sense of depth.

Use actual macOS system Liquid Glass in supported toolbars, compact transport controls and floating tool clusters. Group custom effects with `GlassEffectContainer` as appropriate. Avoid applying blur to the field, waveform, every inspector row or every dot. These surfaces need dependable contrast and efficient redraws. On older Macs use system materials or opaque surfaces with the same spacing and structure.

| Token | Light | Dark | Usage |
|---|---|---|---|
| Window | `#F5F6FA` | `#13151B` | Main shell |
| Surface | `#FFFFFF` | `#20232D` | Inspector/cards |
| Primary text | `#161820` | `#F1F3F8` | Content |
| Secondary text | `#626775` | `#ABB3C5` | Supporting labels |
| Accent | `#2868E8` | `#82A7FF` | Selection and primary actions |
| Field | `#DCE5EB` | `#192A36` | Default field style; a pale version of the navy in light |
| Grid | `#71848E` | `#5E727C` | Strength varies by hierarchy |
| Field surround | `#EEF1F5` | `#111C24` | Canvas around every field style but paper |
| Field ink | `#192A36` | `#192A36` | Labels, rings and paths on the light default field |
| Warning | `#A95F00` | `#FFC46A` | Icon + text + dashed path |
| Error | `#B92D41` | `#FF8E9A` | Invalid operation |

Spacing steps: 4, 8, 12, 16, 24, 32. Controls 28–32 pt in dense inspector areas and 36 pt for prominent actions. Small panel corners 10–12 pt; floating clusters 18–22 pt. One-pixel separators; a subtle edge highlight on glass. Do not add deep shadows to every nested component.

Mac text uses `.system` with semantic roles. Body 13 pt, small labels 11–12, section titles 13 semibold, window title 13, welcome title 30–36. Numeric coordinates, measures, counts and timecodes use monospaced digits. Windows uses Inter with its license or Segoe UI Variable; website uses installed system fonts. Match hierarchy/line height/spacing, not unlicensed font files. See source T4 in the research report.

## 4. Main editor layout

Reference window: 1440 × 960 pt; minimum usable 1024 × 720. The image in `website/assets/editor.svg` is the visual reference, not a literal Xcode layout constraint.

| Area | Starting size | Contents |
|---|---|---|
| Title/toolbar | 54 pt | Document name, undo/redo, tool controls, view mode, export |
| Navigator | 220 pt, resizable | Movements, sets with counts, roster sections, search/filter |
| Canvas | Flexible center | Field, dots, selection, forms, trajectories and annotations |
| Inspector | 260 pt, resizable | Context-sensitive values and operations |
| Timeline | 180 pt, resizable | Transport, rulers, waveform, timing lanes and set transitions |
| Status | 22 pt or integrated | Count, selection, coordinates, warnings and save status |

Use split-view collapse controls. At narrow widths only one side panel remains expanded; the timeline stays useful. Inspector never floats over the active form handle. Store layout preferences per user, not as required show content.

### Navigator

Movements contain named sets, each with thumbnail, arrival count, incoming duration and notes indicator. Show both set number and name. Separate start formation (“Preset, count 0”) from later arrivals. Reordering a movement or set opens a timing impact preview. Roster tab supports sections, tags, search and selection of all members. Lock and hide are distinct actions with visible states.

### Context-sensitive inspector

- Nothing selected: show field/show settings and current set metadata.
- Performer: number, section, exact x/y and field-relative coordinates, facing, label settings, incoming/outgoing movement and notes.
- Multiple performers: selection count, bounds, align/distribute, pivot transform, saved group and per-value mixed states.
- Form: segment handles/type, performer assignment/order, interval versus count distribution, locked endpoints, append/split/close.
- Transition: duration, path, waypoints, stepping policy, hold phases and warnings.
- Audio/anchor: musical position, audio timestamp, fit mode, pin state and resulting local tempo.

Batch edits show the affected performer and set ranges. No hidden propagation: default edit scope is selected set and selected performers. An explicit range selector enables multi-set edits.

## 5. Drill interaction model

### Precision editing

Click selects; Shift-click adds/removes; empty drag selects a box; an explicit Lasso tool avoids modifier conflicts. Space-drag pans while the field has editing focus. Scroll/pinch zooms toward the pointer; Fit Field and Fit Selection are menu actions. Escape cancels a drag/tool preview before clearing selection. Arrow keys nudge by configured step; modifiers use fine/coarse increments. Text entry receives its own keys first.

Dragging previews a transform; mouse-up commits one undoable command. Inspector supports exact coordinate entry and unit conversions. Axis lock, grid spacing and snap are visible toolbar states. Temporary snap bypass has a documented platform-specific modifier. Avoid assigning the same modifier simultaneously to selection addition and bypass during one gesture.

### Forms and assignment

Create forms before or after selecting performers. Forms include line, arc, ellipse/circle, rectangle/block, polygon, Bezier, freehand and composite segments. Users choose fixed interval, equal arc-length distribution or specified count. Forms preserve control geometry, membership and order. An explicit Detach action converts to independently editable dots.

Offer sequential, reverse, nearest-cost and custom pinned assignment. Draw proposed connecting lines before Apply; highlight crossovers and oversized travel. “Optimize” must describe its cost settings; it must not silently reorder drill identities or claim collision-free choreography. Editing one form across sets is explicit, not accidental linked mutation.

### Transitions and rewriting

An arrival set holds exact coordinates; a separate transition defines travel from the prior arrival. Users can inspect any intermediate count. Support straight movement first, then editable curved routes, midsets, holds, rotation, translation, follow-the-leader and interval-aware movement. Provide endpoint locks and continuity checks. Group transforms calculate actual performer trajectories rather than independently interpolating a rotation's endpoints.

Adding/removing performers from an existing show opens a rewrite preview: affected forms, identity mapping, redistributed intervals, unresolved positions and warnings. Provide preserve endpoints, preserve interval and redistribute options. Users confirm one transaction or cancel. Count insertion/deletion and set splitting use the same preview pattern.

### Analysis

Warnings display on paths and in a searchable issue list. Each issue has performer(s), count/time range, measured value, threshold and Jump To action. Distinguish large stride, actual discontinuity and close passing. Use icon/pattern/text as well as color. Warnings never assert real-world safety; drill spacing and stride checks are design aids.

## 6. Audio and musical timeline — core feature

Timeline lanes, from top to bottom: seconds ruler; measures/beats ruler; waveform; tempo/meter/rehearsal marks; sync anchors; set transitions/arrivals. The same vertical playhead crosses every lane. Select a musical ruler or seconds ruler to navigate without editing.

An arrival marker represents **arrival at a formation**. A bar before it represents the move into that formation. Label it “Set 4 arrival · m17 b1; move: 16 counts.” This avoids ambiguous “page start” language. Include a preference for conventional page labeling in print, without changing timing semantics.

### First alignment

1. Drag audio into the waveform area or choose Import Audio. Copy the media into the show by default; display filename, duration and decoding status.
2. Add meter and tempo: for example 4/4, quarter = 120. Specify the march count pulse separately if it differs from the notated beat.
3. Place the playhead at the first musical entrance, for example `00:12.400`.
4. Select measure 1 beat 1 and press **Align here**. This creates a visible pinned anchor.
5. Check a later downbeat. Add `m17 b1 → 00:44.600` and choose Fit Between Anchors when the recording drifts.
6. Create sets on musical positions. Playback and scrubbing now evaluate the drill using the fitted map.

### Everyday operations

Drag an anchor horizontally to a transient; type milliseconds; nudge with fine increments; undo. Snap is optional and never overrides an explicit timestamp. “Align selected set here” resolves its arrival musical position and creates the same kind of anchor; there is no separate competing page-clock system.

Tempo edits offer Preserve Audio Pins or Preserve Notated Tempo. Two fixed timestamps constrain elapsed time; when the requested BPM cannot satisfy both, explain the conflict and offer release a pin, fit the interval or cancel. Never silently alter music speed or relocate a pinned downbeat. Anchor deletion previews the timing change.

Support waveform zoom, vertical gain for display only, loop in/out, playback rate, count-in, metronome, previous/next set and current count. Resizing a set changes its musical duration; it does not destructively stretch the audio. Replacing audio asks whether to retain or reset the old anchors and flags every retained anchor for review.

Tap alignment records a recoverable draft. Users can retap one region, remove an accidental tap and resume. Pickup bars, 6/8 with dotted-quarter pulse, changing meters, fermatas and unmetered holds are explicit states. MusicXML import is later: preview repeats/unfolding and meter/tempo choices before applying.

## 7. Introduction and contextual teaching

Welcome screen: Create Show, Open Show, Try a 90-second Sample. No sign-in requirement. New Show setup has four short steps: field; ensemble; music optional; first sets. “Skip for now” always yields a valid editable show.

After setup, show a compact checklist and anchored coach marks with small pointer arrows. Teach by observed actions, not a series of Next buttons:

| Step | Anchored target | Task and completion event |
|---|---|---|
| 1 | Roster Add button | Add a section; complete after successful roster creation |
| 2 | Field selector | Choose a field or keep preset; complete after apply/explicit keep |
| 3 | Waveform import well | Import audio, or choose counts-only |
| 4 | Align Here action | Bind a downbeat to the playhead; complete after a valid anchor commits |
| 5 | Form toolbar | Select marchers and apply a line/arc |
| 6 | Add Set | Duplicate/create a set and move its formation |
| 7 | Transport | Play across a set boundary |
| 8 | Export | Generate a coordinate PDF preview |

Show one bubble at a time, maximum two short sentences. Bubble repositions when the target moves and falls back to an inspector card when a target is offscreen. Never obscure the dot/handle being manipulated. Keep Back, Skip, Close and Escape available; restore keyboard focus after dismissing. Persist tour progress locally per user and tour version, not in shared show content. Help → Getting Started reopens it. Support VoiceOver, reduced motion and reduced transparency. Sample tutorial edits do not touch existing documents.

## 8. Export and custom settings

Export dialog contains preview, range, section/performer selection, paper/margins/orientation, coordinate rounding, side naming, measure/count display, label density, notes and previous/next paths. Save named export presets. Explain errors before producing an empty file.

Customize field dimensions, hashes/checkpoints, units, step size, background calibration, section styles, performer overrides, labels, groups, shortcuts, snapping, timeline density, warning thresholds and print layout. Keep destructive changes reversible. Template presets never silently replace a show's existing field or roster.

## 9. Windows and later 3D

Windows matches the layout, control hierarchy, radii, spacing, type scale, tool logic and colors. Keep native window management, shortcuts, menus, file dialogs and accessibility. Do not draw fake macOS traffic-light buttons. Use the Windows compositor for supported material effects with opaque fallbacks. Shared token JSON is the source for both UI styles.

3D later uses the same show position evaluator. Initially provide top, stands, end zone and free orbit, selected-performer follow, simple section bodies and dimensioned props. Later add uniforms, equipment, facing/visual tracks and camera keyframes. Future 3D features must not force rewriting stored 2D drill or create a second timeline.

## 10. Website specification

`website/index.html`: product introduction, large editor image, editing/audio feature sections, honest platform/roadmap status and placeholder downloads/source. `website/workflow.html`: audio alignment, guided setup, format choice and release roadmap. No backend, mailing-list form, analytics, download pretence or invented testimonials.

Use a restrained Apple-like product page: generous typography, cool blue/lilac accents, translucent sticky navigation and large original product illustrations. Clearly mark every image as a concept. Built-in theme toggle and working page links are appropriate; placeholder actions explain availability. No claims that native builds or compatibility ship today. The HTML opens directly from disk and uses only local assets.
