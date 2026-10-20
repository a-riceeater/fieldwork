# Converter contract: per-performer paths

This is the contract for any converter that writes `.fieldwork` files with per-performer paths. It was written first for the `.3du` converter. It replaces §8 of the original paths brief and describes what Fieldwork implements today. Where this document and the code in `packages/DrillCore` or `packages/DrillDocument` disagree, the code wins, and both should be fixed.

Covers: container format **1.0**, database schema **5**, capability **`drill.paths.v1`**.

The field-by-field file reference is [`docs/fieldwork-file-schema.md`](../docs/fieldwork-file-schema.md) (§6.6 `path_segment`, §7 invariants). The normative summary is [`fieldwork-format.md`](fieldwork-format.md). The worked example is [`examples/paths_reference.py`](examples/paths_reference.py), a dependency-free Python reference for everything below. It is checked against the synthetic fixture [`fixtures/paths.fieldwork`](fixtures/paths.fieldwork).

---

## 1. What changes for a converter

| | Before (schema 4) | Now (schema 5) |
|---|---|---|
| Curved or staggered moves | Exact only through derived subsets (`60~1`, `60~2`, …) at every count where someone turns or changes speed | One `path_segment` row per hold, leg or arc. The designer's sets are written as they are. |
| Sets written | Designer sets plus derived subsets | Designer sets only. `is_subset = 1` is kept for subsets the designer actually wrote. |
| `transition.model` | `straight` | Still `straight`. It is the model for performers **without** a path. |
| Schema | 4 | 5 when at least one path exists, otherwise 4 |
| Manifest | `drill.core.v1`, `timing.anchors.v1` (+ `media.audio.v1`) | Adds `drill.paths.v1` to **both** `capabilities` and `requiredCapabilities` when at least one path exists |
| `--preserve-curves`, `curves_flattened` | Used and reported for Fieldwork | Not used or reported for Fieldwork. OpenMarch targets keep the subsets, because OpenMarch 0.1.7 ignores its midsets. |
| Text notes, props | | Unchanged |

---

## 2. The data

A **path** is the route one performer takes during one move. A move goes from set *A*, the previous set in the same movement, to set *B*. A path is an ordered list of segments:

| Kind | Meaning | `x1`, `y1` | `sweep` |
|---|---|---|---|
| `hold` | Stand still (mark time) at the current point | NULL | NULL |
| `line` | Straight leg at constant speed to (`x1`, `y1`) | end point, meters | NULL |
| `arc` | Circular arc at constant angular speed to (`x1`, `y1`) | end point, meters | signed degrees, 0 < \|sweep\| < 360 |

- **Durations** (`counts_num / counts_den`) are exact rationals in **count pulses**, each greater than 0. Corners can fall between counts, so durations need not be whole. They must add up **exactly** to the move's length, `pulse(B) − pulse(A)`.
- The path's **start is implicit.** It is the performer's placement at *A*. Each segment starts where the previous one ends, and a hold ends where it starts.
- The path's **end** is the end of the last `line` or `arc`. It must be the performer's placement at *B*. Write that placement's exact doubles: the reader allows 1e-6 m.
- **Sweep sign:** positive is **clockwise seen from above**, which bulges to the **left** of start→end. That is the same side as a positive `form.bulge`. With +x toward the audience's right and +y toward the back sideline, clockwise means the angle around the center *decreases*.
- **Units:** meters from field center (+x audience right, +y back sideline). No easing: within a segment, speed is constant, and a speed change starts a new segment.
- A performer with **no rows** in a move travels straight from *A* to *B* at constant speed, exactly as in schema 4.
- Only performers that are `placed` at both *A* and *B* can have a path.

---

## 3. Evaluation

This is the math Fieldwork plays back with (`ResolvedPath` and `ArcGeometry` in `Path.swift`, and `path_point` in the reference). A converter needs it for its own check before writing (§6).

For a performer at count `u` into the move, with `u` clamped to `[0, pulse(B) − pulse(A)]`:

1. Walk the segments, adding durations, to the one that contains `u`. **A boundary belongs to the later segment.**
2. Let `s = (u − segmentStart) / segmentCounts`, and let `P0` be the segment's start and `P1` its end.
   - `hold`: `P0`.
   - `line`: `P0 + (P1 − P0)·s`.
   - `arc` with sweep θ in radians:
     ```
     c = P1 − P0,  L = |c|,  M = (P0 + P1)/2,  n = (−c.y, c.x)/L      // left normal
     h = (L/2) / tan(θ/2)
     C = M − n·h,  r = |P0 − C|,  φ0 = atan2(P0.y − C.y, P0.x − C.x)
     P(s) = C + r·(cos(φ0 − θ·s), sin(φ0 − θ·s))
     ```
     and exactly `P1` at `s = 1`.
3. `z` and facing interpolate over the whole move, as for straight travel. The performer counts as moving unless the current segment is a hold.

**Vectors** (meters, counts, exact to 1e-6). The reference script checks the first five.

| # | From | Segments | Expect |
|---|---|---|---|
| 1 | (0, 0) | hold 4, line 4 → (4, 0) | u=2 (0,0); u=4 (0,0); u=6 (2,0); u=8 (4,0) |
| 2 | (0, 10) | arc 4 → (10, 0), sweep +90 | center (0,0); u=1 (3.826834, 9.238795); u=2 (7.071068, 7.071068); length 15.707963 |
| 3 | (10, 0) | arc 4 → (0, 10), sweep −90 | center (0,0); u=2 (7.071068, 7.071068) |
| 4 | (10, 0) | arc 3 → (0, 10), sweep +270 | u=1 (0, −10); u=2 (−10, 0); u=3 (0, 10) |
| 5 | (0, 0) | line 9/2 → (4.5, 0), line 7/2 → (4.5, 3.5) | u=4 (4, 0); u=5 (4.5, 0.5); u=8 (4.5, 3.5) |

---

## 4. Fitting per-count samples

The input for one performer-move is the performer's position at every whole count of the move, `samples[0…n]`, where `n = pulse(B) − pulse(A)`. Set `samples[0]` and `samples[n]` to the placements at *A* and *B*, using exactly the doubles you write to `placement`.

Only the result is normative: it must pass §5 and §6. The algorithm below is the one the converter's analysis was based on and the one the reference implements (`fit_move`). The tolerance is **1 mm**.

1. **Greedy runs.** From the current sample `i`, and from the current point (the end of the last segment written), take the longest run `i…j` that is one of these:
   - a **hold**: every sample is within 1 mm of the current point;
   - a **line**: every sample `k` is within 1 mm of `current + (samples[j] − current)·(k − i)/(j − i)`;
   - an **arc** (needs `j − i ≥ 2`): take the circle through the current point, `samples[(i + j) / 2]` and `samples[j]`. Every angular step between consecutive samples has the same sign, the total turn is the sweep (0 < \|sweep\| < 360, positive clockwise), and every sample is within 1 mm of the §3 arc from the current point to `samples[j]` with that sweep.

   If two kinds tie, prefer hold, then line, then arc. **Arc ends are the sample points, and the sweep comes from the samples.** A least-squares circle is also fine, as long as §6 still passes.
2. **Mid-count corners.** If the longest run from `i` is a single count, that count may hide a corner. Let leg A be the segment just written (a hold or a line that came from a real run, or a hold of no length at the start of the move), with velocity `va`. Let leg B be the longest hold or line run from `i + 1`, with velocity `vb`. A line B must last at least 2 counts. Let `p` be the current point, `q = samples[i + 1]` and `w = q − p`. Solve for the time `t1` (0 < t1 < 1) after `p` at which A turns into B:

   | Case | `t1` | Accept when |
   |---|---|---|
   | line → line, turning | `t1 = cross(w, vb) / cross(va, vb)`, `t2 = cross(va, w) / cross(va, vb)` | `\|t1 + t2 − 1\| · max(\|va\|, \|vb\|) ≤ 1 mm` |
   | line → line, same direction, new pace | `t1 = (\|w\| − \|vb\|) / (\|va\| − \|vb\|)` | `w` lies on A's line within 1 mm |
   | hold → line (start mid-count) | `t1 = 1 − \|w\| / \|vb\|` | `w` lies along `vb` within 1 mm |
   | line → hold (arrive mid-count) | `t1 = \|w\| / \|va\|` | `w` lies along `va` within 1 mm |

   Rationalize `t1` to the nearest fraction with a denominator of **at most 960** (`Fraction(t1).limit_denominator(960)`), and use `t2 = 1 − t1` exactly, so the durations still add up exactly. The corner is `p + va·t1`. Leg A grows by `t1` and ends at the corner. Leg B starts at the corner and lasts `(k − i − 1) + t2` counts, where `k` is B's last sample.
3. **Fallback.** Anything else becomes a 1-count `line` to the next sample. A smooth curve that is neither a line nor a circle therefore becomes a chain of 1-count lines.
4. **Exact end.** Set the end of the last `line` or `arc` to the placement at *B*, using its exact doubles. This matters when the move ends in a hold.
5. **Canonicalize** (§5). A route that is one straight line, or that never moves, gets **no rows**.

Samples sit on whole counts, so this procedure expects every set to arrive on a whole count. That is true of `.3du` drill.

---

## 5. Canonical form

Fieldwork's writer stores only canonical paths, so the same show always encodes to the same bytes. The reader accepts non-canonical rows if they pass the invariants, but the next save in Fieldwork rewrites them. Write canonical rows so that converted files are stable. `canonical` in the reference is a line-for-line port of `PerformerPath.canonical`.

Walk the segments in order, ignoring any with no counts, and apply these rules:

- An arc whose chord is ≤ 1e-6 m, or whose sagitta `(L/2)·tan(θ/4)` is below 1e-6 m, becomes a line.
- A line shorter than 1e-9 m becomes a hold.
- Merge two adjacent holds.
- Merge two adjacent lines whose velocities match: equal speed within 1e-9 m per count and the same direction within 1e-9 rad.
- Merge two adjacent arcs on the same circle (center and radius within 1e-9 m) at the same angular speed (within 1e-9 rad per count), if the merged sweep stays below 360°. A full loop stays two arcs.

Finally, write **no rows** if the result has no line or arc and the start equals the end, or if it is a single line ending exactly at the placement at *B*.

---

## 6. Check before writing

Before writing anything, the converter evaluates every whole count of every path-bearing move with the §3 math. If any count is more than **1 mm** from the source position, the converter **refuses its own output**. The reference fits again with corners turned off, then raises (`path_for_move`).

It must also satisfy the invariants Fieldwork enforces on read. A file that breaks one is reported as damaged ("the show data is inconsistent"), and Fieldwork does not repair it.

| Invariant | Fieldwork's message when it fails |
|---|---|
| The transition exists and is not the preset's; the performer exists | "A path references a missing move." / "…references a missing performer." |
| The performer is `placed` at both *A* and *B* | "… is not placed at both ends of the move." |
| At least one segment; ordinals 0…n−1 with no gaps | "A path's segments are not numbered 0, 1, 2, …." |
| `counts_num`, `counts_den` are SQLite INTEGERs and both > 0 | "A path segment has no duration." |
| The durations add up exactly to `pulse(B) − pulse(A)` | "… lasts X counts, but the move has Y." |
| `hold`: `x1`, `y1`, `sweep` NULL. `line`: point set, `sweep` NULL. `arc`: point and sweep set | "A hold segment has a point or sweep." / "A line segment needs…" / "An arc segment needs…" |
| Points and sweeps are finite; 0 < \|sweep\| < 360; arc chord > 1e-6 m | "Path points must be finite numbers." / "…an arc that does not turn between 0 and 360 degrees." / "…an arc without a chord." |
| The path ends within 1e-6 m of the placement at *B* | "… does not end at the set's position." |
| `kind` is `hold`, `line` or `arc` | "Unknown path segment kind X." (It is never read as straight.) |

---

## 7. Writing the file

**Schema.** If no performer has a path, write schema 4 as before. Otherwise write schema 5, which is schema 4 plus this table. Create it exactly as written; it is also in the schema doc, §6.2.

```sql
CREATE TABLE path_segment (transition_id TEXT NOT NULL REFERENCES transition(id), performer_id TEXT NOT NULL REFERENCES performer(id),
    ordinal INTEGER NOT NULL, kind TEXT NOT NULL CHECK (kind IN ('hold','line','arc')),
    counts_num INTEGER NOT NULL, counts_den INTEGER NOT NULL, x1 REAL, y1 REAL, sweep REAL,
    PRIMARY KEY (transition_id, performer_id, ordinal));
PRAGMA user_version = 5;
```

**Rows.**

- Write one row per segment. `transition_id` is the move into *B*, `ordinal` is 0-based within `(transition, performer)`, and `kind` is lowercase.
- Bind `counts_num` and `counts_den` as **integers**, never REAL, in lowest terms with a positive denominator. Both must fit in 64 bits.
- Bind `x1`, `y1` and `sweep` as REAL, or NULL as §2 says.
- Insert rows ordered by arrival-set ordinal, then performer ordinal, then segment ordinal. This is the order Fieldwork writes, though the reader sorts by `(transition_id, performer_id, ordinal)` itself.
- Leave `transition.model` as `straight`.
- Run `PRAGMA foreign_key_check`. It must return nothing.

**Manifest.** When at least one path exists, append `drill.paths.v1` to both lists. Then recompute the size and SHA-256 of `show.sqlite`:

```diff
   "capabilities" : [
     "drill.core.v1",
-    "timing.anchors.v1"
+    "timing.anchors.v1",
+    "drill.paths.v1"
   ],
   …
   "requiredCapabilities" : [
-    "drill.core.v1"
+    "drill.core.v1",
+    "drill.paths.v1"
   ],
```

If `media.audio.v1` is present, it stays between `timing.anchors.v1` and `drill.paths.v1`. A reader that does not know `drill.paths.v1` opens the show **read-only**, so it never saves the show with its routes flattened. A reader that only knows schema 4 refuses the file ("schema 5 is newer than this version supports") without changing it.

**Container.** Nothing changes: members are stored uncompressed, names are UTF-8 (flag `0x0800`), timestamps are fixed at 1980-01-01 00:00, and there are no extra fields. The order is `manifest.json`, then `show.sqlite`, then assets. `write_container` in the reference is a complete writer in about fifteen lines.

---

## 8. Worked example

`fixtures/paths.fieldwork` is an original synthetic show with 4 trumpets (T1–T4) and 3 sets at counts 0, 8 and 14. Its whole-count positions are in `fixtures/paths-evaluation.json`. The reference script treats those positions as the source drill, fits them, and recovers the fixture's own rows:

| Move | Performer | Rows (`kind counts → x1, y1, sweep`) | What the samples show |
|---|---|---|---|
| 1 → 2 | T1 | `hold 2`, `line 6 → (−2, −4)` | Still for counts 0–2, then even steps: a delayed start |
| | T2 | `arc 8 → (10, 0), +90` | A quarter circle around (0, 0), clockwise |
| | T3 | `line 9/2 → (4.5, 0)`, `line 7/2 → (4.5, 3.5)` | A corner between counts 4 and 5 (below) |
| | T4 | `arc 6 → (0, 10), +270`, `hold 2` | Three quarters of a circle, then arriving 2 counts early |
| 2 → 3 | T1 | `arc 6 → (−2, 2), −180` | A counter-clockwise half circle |
| | T2 | *(no rows)* | Stands still |
| | T3 | `hold 1/2`, `line 11/2 → (8, 3.5)` | Starts half a count late (below) |
| | T4 | *(no rows)* | A straight line |

That is 6 paths and 10 rows. **T3, move 1 → 2.** The samples are (0,0), (1,0), (2,0), (3,0), (4,0), then (4.5,0.5), (4.5,1.5), (4.5,2.5), (4.5,3.5).

- The longest run from count 0 is a line to count 4. From count 4, only a 1-count chord fits, so the fitter looks for a corner.
- Leg A has `va = (1, 0)`, leg B (counts 5–8) has `vb = (0, 1)`, and `w = (0.5, 0.5)`.
- `cross(va, vb) = 1`, so `t1 = cross(w, vb) = 0.5` and `t2 = cross(va, w) = 0.5`. Their sum is 1, so the corner is accepted at (4.5, 0).
- A becomes `line 4 + 1/2 = 9/2`, and B becomes `line 3 + 1/2 = 7/2`.

**T3, move 2 → 3.** The samples are 0.63636… m apart, except that the first gap is half that, 0.31818… m.

- No run of more than one count starts at count 0, so the move's start acts as a hold of no length.
- B runs from count 1 to count 6 with a speed of 0.63636… m per count.
- `t1 = 1 − 0.31818 / 0.63636 = 1/2`, which gives `hold 1/2`, `line 11/2`.

The rows as stored (IDs shortened):

```
transition  performer  ord kind counts_num counts_den  x1    y1    sweep
82D56A7C…   C10E7796…  0   hold  2         1          NULL  NULL  NULL
82D56A7C…   C10E7796…  1   line  6         1          -2.0  -4.0  NULL
82D56A7C…   6037A3A1…  0   arc   8         1          10.0   0.0  90.0
82D56A7C…   5BD7A4EA…  0   line  9         2           4.5   0.0  NULL
82D56A7C…   5BD7A4EA…  1   line  7         2           4.5   3.5  NULL
82D56A7C…   21549D99…  0   arc   6         1           0.0  10.0  270.0
82D56A7C…   21549D99…  1   hold  2         1          NULL  NULL  NULL
F04472E5…   C10E7796…  0   arc   6         1          -2.0   2.0  -180.0
F04472E5…   5BD7A4EA…  0   hold  1         2          NULL  NULL  NULL
F04472E5…   5BD7A4EA…  1   line  11        2           8.0   3.5  NULL
```

The reference also fits synthetic cases the fixture does not cover:

| Case | Result |
|---|---|
| A corner 4.603 counts in | `line 3374/733`, `line 2490/733`; worst count 0.002 mm |
| A new pace partway along one line | `line 5/2`, `line 7/2` |
| Arriving early, mid-count | `line 11/2`, `hold 5/2` |
| A smooth curve | Eight 1-count lines |
| An arc with ±0.3 mm noise | One `arc 8`; worst count 0.6 mm |
| Straight, or standing still | No rows |

---

## 9. Checking a conversion

From `packages/DrillBridge`, `swift run -c release fwtool …` builds and runs the tool. The built binary is under `.build/` (on Windows, `.build/out/Products/Release-windows-x86_64/fwtool.exe`).

```sh
# The reference against the fixture: vectors, fitting cases, round trip, then Fieldwork's own evaluator
python spec/examples/paths_reference.py --fwtool <path to fwtool> --out /tmp/paths-refit.fieldwork

# Any converted file
swift run -c release fwtool info converted.fieldwork              # sets, counts, and "paths: N performer paths with M segments in K of L moves"
swift run -c release fwtool evaluate converted.fieldwork 0 1 2 3 …  # JSON positions per count, rounded to 1 µm
```

Expected output of the reference run: `0 differ from the fixture`, `fwtool info` reporting `6 performer paths with 10 segments in 2 of 2 moves`, and a worst difference from the golden output of 0.0010 mm (both sides are rounded to 1 µm). The script exits 0.

**Acceptance on real drill.** The converter's owner runs this privately:

- `fwtool info` lists the designer's sets and **no** `~n` subsets.
- `fwtool evaluate` at every whole count matches the source positions within 1 mm.

Real drills and their conversions must never enter this repository or the converter's.

---

## 10. Not supported

Fieldwork does not support these yet. A converter must not write them:

- other segment kinds, such as `cubic`;
- easing or acceleration within a segment;
- facing along the path;
- named maneuvers (counter-march, flanks and to-the-rear import as plain segments);
- 3D paths;
- OpenMarch midset export.
