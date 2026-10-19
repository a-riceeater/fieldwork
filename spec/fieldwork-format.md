# `.fieldwork` document format, version 1.0

Status: implemented by `packages/DrillDocument` (reader and writer) and covered by its tests. The namespace `org.fieldwork` is provisional and defined in one place (`FormatIdentity`) so the product can be renamed.

## Container

A `.fieldwork` file is a ZIP archive with the same layout on every operating system.

| Rule | Requirement |
|---|---|
| Compression | Version 1 writers store every member uncompressed (method 0). Readers reject other methods with an explicit message. |
| Integrity | Every member has a correct CRC-32. Every member except `manifest.json` is listed in the manifest with its SHA-256 and byte count. Unlisted, missing or mismatched members are treated as damage. |
| Paths | Relative, `/`-separated, UTF-8. No leading `/`, no `\`, `:`, NUL, empty, `.` or `..` components. At most 512 bytes. |
| Limits | At most 10,000 members and 2 GiB expanded. ZIP64, multi-disk and encrypted archives are not supported. |
| Order | `manifest.json` is written first. Writers produce identical bytes for identical content (fixed timestamps, sorted extension members). |

| Member | Contents |
|---|---|
| `manifest.json` | Format identity, versions, capabilities, member hashes |
| `show.sqlite` | The show database (schema below) |
| `assets/<sha256>.<ext>` | Embedded media, named by the SHA-256 of its bytes. Version 1 uses this for audio (`wav`, `mp3`). |
| `extensions/<namespace>/…` | Optional third-party or future data, preserved byte-for-byte on rewrite |

`preview.png` is reserved and not yet written.

## Manifest

```json
{
  "format": "org.fieldwork.show",
  "formatVersion": { "major": 1, "minor": 0 },
  "minReaderVersion": { "major": 1, "minor": 0 },
  "writer": "Fieldwork 0.1.0",
  "showID": "8F0C…",
  "capabilities": ["drill.core.v1", "timing.anchors.v1", "media.audio.v1"],
  "requiredCapabilities": ["drill.core.v1"],
  "members": [{ "path": "show.sqlite", "sha256": "…", "bytes": 98304 }],
  "extensions": [{ "namespace": "com.example.notes", "required": false }]
}
```

Reader behavior:

- A higher `formatVersion.major` or `minReaderVersion.major` is refused with a message, and the file is not changed.
- An unknown required capability, or an extension marked `required`, opens the show read-only.
- Writers add `drill.paths.v1` to both `capabilities` and `requiredCapabilities` when any performer has a path, so a reader without paths never saves the show with its routes flattened.
- Unknown optional extensions are kept and written back unchanged.

## Show database (`show.sqlite`, schema 5)

The database is SQLite 3 with foreign keys enabled. `PRAGMA user_version` holds the schema version. Older schemas are migrated on an in-memory copy (schema 1 → 2 adds `show.counting_mode` defaulting to `measures` and empty `arrival_set.rehearsal_mark` and `measure_marker`; schema 2 → 3 adds a NULL `performer.symbol`; schema 3 → 4 adds an empty `field_note` table; schema 4 → 5 adds an empty `path_segment` table, so every performer moves straight). A newer schema is refused without changing bytes. Readers use prepared queries only and never execute SQL stored in a document.

Canonical units: positions in **meters** from field center (+x toward the audience's right, +y toward the back sideline, +z up). Facing is in **degrees**: 0 faces the front sideline and values increase clockwise when seen from above. Durations are in **seconds**. Audio positions are **sample frames** of the referenced asset. Note values and cursor fractions are exact rationals, stored as `*_num`/`*_den` integer pairs with a positive denominator. IDs are uppercase UUID strings and stay stable across edits.

| Table | Meaning |
|---|---|
| `meta(key, value)` | `writer`, `units` = `meters` |
| `show(id, title, max_stride, min_clearance, counting_mode)` | One row. Analysis thresholds are in meters. `counting_mode` is `measures` (set positions shown as measures and beats) or `counts` (sets are pages of counts; measure numbers are author markers). |
| `field(singleton=1, name, preset, length, width, step_size, side_labels JSON, front_label, back_label)` | Field size in meters |
| `field_checkpoint(ordinal, axis 'x'\|'y', position, label, prominence)` | Yard lines, sidelines, hashes and custom lines |
| `media_asset(id, sha256, extension, original_filename, byte_count, sample_rate, frame_count, channel_count)` | Archive path is `assets/<sha256>.<extension>` |
| `section(id, ordinal, name, prefix, symbol, color_index)` | `symbol` is `circle`, `cross`, `square`, `triangle`, `diamond` or `slash`. `color_index` points into the shared palette in `design/tokens.json` |
| `performer(id, ordinal, label UNIQUE, section_id, name NULL, notes, symbol NULL)` | `name` is private roster data. `symbol` overrides the section's symbol for this performer; NULL follows the section. |
| `movement(id, ordinal, name, audio_asset_id NULL, fit_mode)` | `fit_mode` is `preserveAudioPins` or `preserveNotatedTempo` |
| `measure(id, movement_id, ordinal, number, meter_numerator, meter_denominator, grouping NULL, tempo_unit_*, pulse_unit_*, pickup_* NULL)` | `number` is a display label (a pickup is 0). `grouping` looks like `3+2`. |
| `timing_event(id, movement_id, ordinal, kind 'beat'\|'hold', measure_id, beat_index, notated_*, baseline_seconds > 0)` | The ordered performance events. Tempo is compiled into `baseline_seconds` and is not stored separately. |
| `audio_anchor(id, movement_id, event_id, fraction_*, asset_id, sample_frame, sample_rate, locked)` | Pins a cursor to an exact source sample |
| `arrival_set(id, movement_id, ordinal, label, event_id, fraction_*, is_subset, notes, rehearsal_mark, measure_marker)` | An exact formation at a cursor. The first set in a movement is the preset. `rehearsal_mark` (such as `A` or `CC`) and `measure_marker` (free text such as `222-223`) are display annotations, empty when unused; they never move the set. |
| `transition(id, to_set_id UNIQUE, model)` | The move into a set. Version 1 has one model: `straight`, which applies to every performer without a path. It stays `straight` when paths exist. |
| `path_segment(transition_id, performer_id, ordinal, kind 'hold'\|'line'\|'arc', counts_num, counts_den, x1 NULL, y1 NULL, sweep NULL)` | One performer's route through one move, in order. Durations are exact rationals in count pulses (> 0) and add up exactly to the move's length. `x1`, `y1` is the end point of a `line` or `arc` (NULL for a `hold`). `sweep` is an arc's signed turn in degrees, 0 < \|sweep\| < 360, positive clockwise seen from above (bulging left of start→end); NULL otherwise. The start is the performer's placement at the previous set, and the last leg ends exactly at the placement at `to_set_id`. Unknown kinds are damage, never read as straight. |
| `placement(set_id, performer_id, state, x, y, z, facing)` | `state` is `placed`, `unresolved` or `inactive`. Coordinates are NULL unless the state is `placed`. |
| `form(id, set_id, ordinal, kind 'line'\|'arc', x0, y0, x1, y1, bulge)` | Retained form geometry. `bulge` is the signed sagitta in meters. |
| `form_member(form_id, ordinal, performer_id)` | Assignment order along the form |
| `field_note(id, set_id, ordinal, x, y, text)` | A text box shown on the field at one set. `x`, `y` is the box's top-left corner in meters. Notes are reminders for the author and never affect drill. |

### Path semantics

- A performer is evaluated `u` counts into a move by walking the segments to the one containing `u` (a boundary belongs to the later segment). Holds stand still; lines and arcs move at constant speed, so speed changes only between segments. There is no easing.
- An arc with sweep θ from `P0` to `P1` has its center at `M − n·(L/2)/tan(θ/2)`, where `M` is the chord's midpoint, `L` its length and `n` its left normal. It turns from `P0` by `−θ·s` around that center and lands exactly on `P1`.
- `z` and facing interpolate over the whole move. A performer is not moving during a hold.
- Writers store only canonical paths: no rows for a single straight line or for standing still, no zero-length lines, no adjacent holds, no mergeable adjacent lines or arcs, and no arc with a sagitta under 1e-6 m. Rows are inserted by arrival-set, performer and segment order.

### Timeline semantics

- A **cursor** is `(event_id, fraction)` with `0 ≤ fraction ≤ 1`. At a boundary, the canonical form is the next event at fraction 0.
- **March counts** run from 0 at the start of the movement. Inside a measure, counts start at the cumulative `grouping` offsets, or at multiples of the pulse unit. Hold events add elapsed time without advancing counts.
- **Fitting:** with one anchor, baseline durations run before and after it. Between consecutive anchors, beat durations are multiplied by one common scale so the interval matches the audio time, and hold durations stay fixed. Anchors must increase strictly in both cursor and sample frame. The scale must stay within [1/3, 3].
- Mapped audio time can be negative. That means pre-roll before the file starts.

## Recovery journal (not part of the document)

Applications keep a per-session directory with these files:

- `base.fieldwork`: a snapshot taken at open, at creation and after every save.
- `assets/`: audio imported since that snapshot.
- `journal.jsonl`: one `{"v":1,"event":CommitEvent}` per committed change.

Recovery replays complete lines only. A torn final line is ignored and reported. The user's document file is never modified by recovery.
