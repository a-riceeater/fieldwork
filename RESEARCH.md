# Research and product decisions

Checked October 17, 2026, Pacific time. Primary sources only. Labels distinguish documented behavior, source observations, and recommendations. This is a substantial feature and workflow audit, not a hands-on certification of every application feature or a claim to have tested their binaries.

## 1. What matters in the competing products

Pyware sets the professional scope: sophisticated rewriting, movement design, analysis, production output and realistic presentation. OpenMarch supplies a more approachable open-source baseline and unusually useful documentation about musical timing and file evolution. A new native app should combine an approachable editing workflow with a strong document and timing model; a polished field of draggable dots alone will not replace either product.

Pyware now also markets **3DX**. Treat 3D v11 material as the established feature reference and 3DX pages as the newer product direction. The 3DX beta notes are evidence of development, not proof every listed item is stable in all shipping editions. Do not use decades-old Java manuals to infer current codec support or pricing. [P1–P5]

OpenMarch explicitly marks its Master Feature List as very outdated. Detailed guides and source are stronger evidence than that list. Its field guide documents indoor floors even though the older list says indoor is coming. Documentation also names Node 22 while the repository README names Node 24: a concrete example of why implementation should pin a release/commit and inspect its actual schema. [O1, O2, O6, O11]

## 2. Feature audit

“Not verified” means the reviewed material did not establish a production-ready feature. It does not mean the feature cannot exist in a newer build.

| Domain | Pyware evidence | OpenMarch evidence | Fieldwork requirement |
|---|---|---|---|
| Field and venue | Custom grids; indoor editions and Real View venues [P1,P3] | Rectangular custom fields, football/indoor templates, checkpoints, image backgrounds, side descriptions, field labels [O6] | Editable dimensions, hashes, units, step calibration, side conventions, labels, backgrounds and reusable field presets |
| Roster | Cast import/export and rewrite tools [P1] | Batch marchers; section/number/name/notes; appearances and tags also visible in schema [O1,O11,O12] | Stable performer IDs, roster CSV, sections, tags, symbol/color/label overrides, active ranges, missing performers |
| Selection and precision | Fast Edit supports direct manipulation [P1] | Rectangle/lasso, axis lock, rounding, alignment, spacing, rotate/scale [O3] | Predictable select/transform handles, exact inspector values, saved selections, nudge and configurable snap |
| Forms | Professional form creation [P1] | Line and multi-segment curve shapes, move/close segments, grouping and ungrouping [O3] | Editable lines/arcs/ellipses/blocks/Bezier/freehand/composite forms, ordering, spacing and locked endpoints |
| Assignment | Matching is a core drill workflow [P2,P4] | Distribution/order represented in shape membership [O3,O12] | Explicit assignment order, reverse order, pin pairs, proximity assignment with preview and crossover warnings |
| Sets and counts | Count Track and production planning [P1] | Pages/subsets; pages aligned to beat references [O4,O12] | Set boundary semantics, subsets, holds, count insert/delete/split, movement organization and dependency preview |
| Paths and transitions | Float/path adjustment [P1] | Paths and midsets appear in schema; documented path display [O1,O12] | Straight/custom paths, mid-transition waypoints, group transforms, hold/travel phases and shared evaluator |
| Rewriting | Splice/cast change and transition reuse [P1,P5] | Copy adjacent positions; repair/version workflows documented [O3,O9,O10] | Change performer count without losing identities; preview affected pages and continuity, copy/reuse movement |
| Music | Tempo/time-based and set-based sync [P1]; visual adjustment and automatic sync marketed in 3DX [P2] | Audio offset, beat durations, tempo groups, per-beat adjustment, experimental MusicXML/tapping [O4,O5] | Exact anchors plus tempo/measure editing, recoverable tap sessions, pickup and mixed meter support |
| Analysis | Stride/collision/continuity work appears in current beta notes [P4] | Configurable step distance warnings, styled paths [O8] | Warnings for stride, clearance, bounds, missing data and continuity, with count and performer references |
| Print/export | Production and coordinate outputs [P1] | Performer coordinates and individual/overview PDF charts [O7] | Print preview, PDF charts, dot books, coordinate sheets, roster CSV, documented exchange JSON |
| 3D/presentation | Real View, video capture and appearance tools [P1,P2] | Production 3D viewer not verified in reviewed guides | Later 3D camera/venue/appearance tools built over the same scene and motion data |
| Delivery/collaboration | Portal/UDB/mobile ecosystem [P1,P6] | On the Move guides are in current docs navigation [O2] | Offline authoring first; later separate performer viewer and optional sharing architecture |
| Recovery | Autosave/undo features [P1] | Persisted history, migration backups, non-destructive database repair [O9–O12] | Transactional edits, recovery journal, portable snapshots, migrations and corruption handling |

### The OpenMarch lessons worth keeping

The drill-writing guide has a coherent workflow: select performers, create a form, refine alignment, and reuse it on later pages. Keep this directness while expanding precision editing. Shapes must remain editable as shapes; distributing dots and discarding the curve is insufficient. [O3]

The field guide's custom geometry, checkpoints, naming and coordinate descriptions are essential, especially for indoor work. `.fielddots` is documented as JSON and does not include its background image. An import adapter must handle that missing-image case explicitly. [O6]

The audio guide supports MP3/WAV/OGG and a positive or negative offset. The tempo guide goes further: tempo groups, gradual changes, individual beat duration edits, rehearsal marks and experimental MusicXML/tap workflows. Its documented limitations include awkward structural edits and page dependencies. These are useful constraints to improve, not interfaces to reproduce unchanged. [O4,O5]

The tempo documentation contains a formula typo: seconds per beat is **60/BPM**, not BPM/60. The examples themselves use the correct results. Preserve time signature denominators and explicit pulse units in Fieldwork; do not make all counts implicitly quarter notes. [O4]

The export guide covers coordinate rounding, section grouping, compact sheets, personalized charts and previous/next positions. Treat print output as an authoring requirement, not a late cosmetic add-on. [O7]

### Pyware capabilities that expand the long-term target

Beyond the table, established Pyware material highlights form/transition editing, saved history and snapshots, production notes, labels and annotations, reusable movement, and sophisticated presentation. New 3DX material emphasizes choosing a form before or after performers, visual audio adjustment, set navigation, and capture. [P1,P2]

The current beta page is especially useful for acceptance criteria: locale-independent saving, large-show selection performance, multi-monitor routing, continuity versus oversized strides, and lessons that advance when users perform actions. These are product-quality lessons, not just feature names. [P4]

Traditional/military drill deserves a later dedicated feature area: step-offs/drop-offs, counter marches, sweeping gates and custom routes. It is more than linear interpolation with different labels. [P3]

## 3. `.dots` decision

**Use an independent native format and provide versioned `.dots` interoperability.**

OpenMarch `.dots` is an application project database, not an industry-wide interchange standard. The repository schema uses SQLite tables for beats, measures, pages, marcher-page coordinates, path data, shapes, audio and history. It stores marcher-page x/y as pixels. Its actual field scale and origin must be interpreted; multiplying everything by a guessed step constant will produce wrong imports. [O11,O12]

The current inspected schema also contains midsets and appearance data that the basic feature list does not explain. Source presence alone does not certify a finished UI. The adapter needs fixtures and explicit conversion coverage. [O12]

OpenMarch warns that migrated files are almost never backward compatible and creates migration backups. This makes `.dots` a poor sole contract for another app with independent releases. Writing extra tables into someone else's live `.dots` file would make guarantees about migrations, undo and repair that you do not control. [O9,O10]

| Choice | Benefit | Cost | Decision |
|---|---|---|---|
| Adopt `.dots` as sole native format | Potentially easier initial OpenMarch exchange | Independent migrations, richer anchors and 3D may diverge; no Pyware compatibility gained | Reject |
| Fork OpenMarch and retain its document model | Fast route to extending existing drill logic | Its web UI does not meet the native Swift requirement; source licensing applies | Only reconsider if native UI ceases to be a priority |
| Own documented format plus adapters | Own evolution, robust timing, honest loss reports | Must build and maintain conversion tests | Adopt |

OpenMarch's repository README/root license identifies AGPL-3.0, while the desktop subdirectory also contains a GPLv3 license and there is an internal-use document limited to OpenMarch. This is a component-by-component audit issue, not permission to select whichever license is convenient. Write original app code; do not paste or translate upstream implementation and relabel it as independently authored. Format compatibility and code reuse are distinct choices. [O11–O14]

No reviewed source establishes `.dots` support in Pyware/UDB. Pyware lists its own formats and viewer/export ecosystem. Do not advertise `.3dudb`, `.3dz`, `.3dj` or portal compatibility until a supported integration and authorized real samples are tested. Start with PDF, CSV, a published exchange format and `.dots` conversion. [P1,P6]

## 4. Platform decision

**Build the macOS editor first.** Its defining requirement is native Swift and system Liquid Glass. Starting on Windows would optimize a separate UI stack before proving the defining experience. Build the shared Swift package on Windows immediately so the second UI does not trigger a domain rewrite.

| Approach | Fit | Recommendation |
|---|---|---|
| SwiftUI/AppKit Mac + WinUI 3 Windows + shared Swift core | True native Mac, strong Windows accessibility and OS integration; two frontends | Best fit |
| Swift-only Windows GUI frameworks | Single language possible; substantial framework/integration risk for a large pro editor | Re-evaluate via small spike only if all-Swift Windows is mandatory |
| Qt/native cross-platform C++ | Strong portability but weak fit to Swift-first goals | Alternative if priorities change |
| Electron/Tauri/WebView | UI reuse but conflicts with requested native editor | Reject for app shell |

Swift is officially available on Windows, but installing Swift does not provide Apple's SwiftUI/AppKit/AVFoundation. Use Foundation-only core code and native platform adapters. A C ABI between Swift and C# is a deliberate integration surface requiring a Windows proof of concept, not a claim that SwiftUI ports automatically. [T1]

Liquid Glass is Apple's system material. Use actual controls/effects on supported Macs. On Windows, recreate visual tokens with WinUI templates/composition and appropriate Mica/Acrylic surfaces. On the website, CSS blur is a visual approximation. They cannot be pixel-identical system renderers. [T2,T3]

Use system San Francisco through the macOS system font API. For Windows use Inter if bundled with its SIL OFL notice, or Segoe UI Variable. Web: system font stack, with optional licensed Inter. Apple's downloadable font license restricts redistribution and non-Apple usage; do not ship SF font files as Windows/web assets. Match type scale, spacing, weight and hierarchy instead. [T4,T5]

## 5. Source register

All links below are primary documentation, official product material, or source repositories. Reviewed online October 17, 2026; pages and `main` can change.

### OpenMarch

- O1 — [Master Feature List](https://openmarch.com/about/features/), explicitly outdated.
- O2 — [Documentation index](https://openmarch.com/guides/) and [Getting Started](https://openmarch.com/guides/getting-started/).
- O3 — [Writing Drill](https://openmarch.com/guides/writing-drill/).
- O4 — [Setting Tempo](https://openmarch.com/guides/music/tempo/).
- O5 — [Importing Audio](https://openmarch.com/guides/music/audio/).
- O6 — [Editing the Field](https://openmarch.com/guides/editing-the-grid/).
- O7 — [Exporting Charts](https://openmarch.com/guides/exporting/).
- O8 — [Step Size Warnings](https://openmarch.com/guides/step-size-warnings/).
- O9 — [Reverting to a Previous Version](https://openmarch.com/guides/reverting/).
- O10 — [Repairing Your Database](https://openmarch.com/guides/repairing-database/).
- O11 — [Repository/README](https://github.com/OpenMarch/OpenMarch), [Codebase](https://openmarch.com/developers/codebase/), [Desktop App](https://openmarch.com/developers/desktop-app/).
- O12 — [SQLite schema source](https://github.com/OpenMarch/OpenMarch/blob/main/apps/desktop/electron/database/migrations/schema.ts), [migration journal](https://github.com/OpenMarch/OpenMarch/blob/main/apps/desktop/electron/database/migrations/meta/_journal.json). Source fetched and inspected directly at repository commit `4bc4eeb3e403f7bfffe98f0163be94bf62e8050e`, committed October 13, 2026; this is a source snapshot, not a verified release profile.
- O13 — [Root license](https://github.com/OpenMarch/OpenMarch/blob/main/LICENSE), [desktop license](https://github.com/OpenMarch/OpenMarch/blob/main/apps/desktop/LICENSE).
- O14 — [Internal use license](https://github.com/OpenMarch/OpenMarch/blob/main/LICENSE-internal.md), limited to OpenMarch itself.

### Pyware

- P1 — [Pyware 3D features](https://www.pyware.com/3d/).
- P2 — [Pyware 3DX](https://www.pyware.com/3dx/).
- P3 — [Traditional tools description](https://www.pyware.com/Traditionaldetails.html), historical feature reference, not current pricing.
- P4 — [3DX beta release notes](https://www.pyware.com/3dxbeta/), reviewed build dated October 12, 2026; beta evidence only.
- P5 — [Top time-saving v11 features](https://www.pyware.com/top-time-saving-features-of-version-11/).
- P6 — [Viewer app](https://www.pyware.com/viewer-app/) and [UDB relationship](https://www.pyware.com/rehearsal-remastered/).

### Platform and tooling

- T1 — [Official Swift on Windows installation](https://www.swift.org/install/windows/).
- T2 — [Applying Liquid Glass](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views) and [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass). Apple documentation pages can require JavaScript.
- T3 — [Windows Mica/Acrylic documentation](https://learn.microsoft.com/en-us/windows/apps/develop/ui/system-backdrops).
- T4 — [Apple fonts and downloadable font license](https://developer.apple.com/fonts/).
- T5 — [Inter font source and license](https://github.com/rsms/inter).
- T6 — [XcodeGen](https://github.com/yonaskolb/XcodeGen), declarative project generation.
- T7 — [RealityKit](https://developer.apple.com/documentation/realitykit), proposed later Mac 3D integration.

## 6. Remaining verification before shipping compatibility

Pin an actual OpenMarch release and its commit, migration journal and field implementation; assemble original sample shows exercising every entity. Test exports in that exact binary. Verify origin, y-axis direction, field pixel scale, page start/end interpretation, path ownership and all default appearance inheritance. Check new versions deliberately rather than claiming every `.dots` file works. Measure real audio seek/decoder offsets on Mac and Windows. Prove the Swift/C ABI deployment on a clean Windows machine. These are implementation gates; this research does not substitute for them.
