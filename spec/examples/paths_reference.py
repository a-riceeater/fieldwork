#!/usr/bin/env python3
"""Reference implementation of the converter side of Fieldwork paths.

This is the worked example for spec/converter-paths.md. It shows, in plain
Python with no dependencies, everything a converter needs to write
per-performer paths into a .fieldwork file:

  * evaluate a path with the exact math Fieldwork uses (spec §3),
  * fit holds, lines, arcs and mid-count corners to per-count samples (§4),
  * reduce the result to canonical form (§5),
  * check every count before writing (§6),
  * add schema 5 path_segment rows and the drill.paths.v1 capability to a
    .fieldwork container (§7).

Run it with no arguments to check it against the synthetic fixture:

    python spec/examples/paths_reference.py
    python spec/examples/paths_reference.py --fwtool <path to fwtool> --out paths-refit.fieldwork

The demo reads spec/fixtures/paths-evaluation.json, keeps only the whole
counts (what a .3du stores), fits paths to them, writes the result into a
copy of spec/fixtures/paths.fieldwork whose paths were removed, and compares
the fitted segments with the fixture's own. With --fwtool it also opens the
output in Fieldwork's core and checks every golden frame, including the
mid-count frame at 4.5.

Only synthetic data is used here. Never commit a real drill or its conversion.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import sqlite3
import struct
import subprocess
import sys
import tempfile
import zlib
from dataclasses import dataclass
from fractions import Fraction

# ---------------------------------------------------------------------------
# Segments (spec §2). Points are (x, y) tuples in meters; counts are Fractions.

@dataclass(frozen=True)
class Segment:
    kind: str                      # "hold", "line" or "arc"
    counts: Fraction               # duration in count pulses, > 0
    end: tuple | None = None       # None for a hold
    sweep: float | None = None     # degrees, arc only; + is clockwise from above

    def with_counts(self, counts):
        return Segment(self.kind, counts, self.end, self.sweep)

    def with_end(self, end):
        return self if self.kind == "hold" else Segment(self.kind, self.counts, end, self.sweep)


def hold(counts):
    return Segment("hold", Fraction(counts))


def line(counts, to):
    return Segment("line", Fraction(counts), to)


def arc(counts, to, sweep):
    return Segment("arc", Fraction(counts), to, sweep)


def sub(a, b): return (a[0] - b[0], a[1] - b[1])
def add(a, b): return (a[0] + b[0], a[1] + b[1])
def mul(a, k): return (a[0] * k, a[1] * k)
def dist(a, b): return math.hypot(a[0] - b[0], a[1] - b[1])
def cross(a, b): return a[0] * b[1] - a[1] * b[0]
def dot(a, b): return a[0] * b[0] + a[1] * b[1]
def norm(a): return math.hypot(a[0], a[1])

# ---------------------------------------------------------------------------
# Evaluation (spec §3). This matches ArcGeometry and ResolvedPath in
# packages/DrillCore/Sources/DrillCore/Path.swift.

def arc_geometry(p0, p1, sweep_degrees):
    """Center, radius and start angle of the arc from p0 to p1, or None when the chord is too short."""
    c = sub(p1, p0)
    length = norm(c)
    theta = math.radians(sweep_degrees)
    if length <= 1e-12 or theta == 0 or not math.isfinite(theta):
        return None
    mid = mul(add(p0, p1), 0.5)
    left = (-c[1] / length, c[0] / length)
    h = (length / 2) / math.tan(theta / 2)
    center = sub(mid, mul(left, h))
    return center, dist(p0, center), math.atan2(p0[1] - center[1], p0[0] - center[0]), theta


def segment_point(p0, seg, s):
    """Position at fraction s (0..1) of one segment that starts at p0."""
    if seg.kind == "hold":
        return p0
    if s >= 1:
        return seg.end
    if s <= 0:
        return p0
    if seg.kind == "line":
        return add(p0, mul(sub(seg.end, p0), s))
    geometry = arc_geometry(p0, seg.end, seg.sweep)
    if geometry is None:
        return add(p0, mul(sub(seg.end, p0), s))
    center, r, phi0, theta = geometry
    a = phi0 - theta * s
    return (center[0] + r * math.cos(a), center[1] + r * math.sin(a))


def path_point(start, segments, u):
    """Position u counts into the move. A boundary belongs to the later segment."""
    total = sum(seg.counts for seg in segments)
    u = min(max(u, 0.0), float(total))
    point, offset = start, Fraction(0)
    for i, seg in enumerate(segments):
        last = i == len(segments) - 1
        if u < float(offset + seg.counts) or last:
            return segment_point(point, seg, (u - float(offset)) / float(seg.counts))
        point = seg.end if seg.end is not None else point
        offset += seg.counts
    return point

# ---------------------------------------------------------------------------
# Canonical form (spec §5). A port of PerformerPath.canonical and merge.

POINT_TOLERANCE = 1e-9
ANGLE_TOLERANCE = 1e-9
MINIMUM_SAGITTA = 1e-6
MINIMUM_CHORD = 1e-6


def sagitta(chord, sweep_degrees):
    return (chord / 2) * math.tan(math.radians(sweep_degrees) / 4)


def merge(a, a_start, b):
    if a.kind == "hold" and b.kind == "hold":
        return hold(a.counts + b.counts)
    if a.kind == "line" and b.kind == "line":
        v1 = mul(sub(a.end, a_start), 1 / float(a.counts))
        v2 = mul(sub(b.end, a.end), 1 / float(b.counts))
        l1, l2 = norm(v1), norm(v2)
        if abs(l1 - l2) > POINT_TOLERANCE or l1 <= 0 or l2 <= 0:
            return None
        if abs(cross(v1, v2)) / (l1 * l2) > ANGLE_TOLERANCE or dot(v1, v2) <= 0:
            return None
        return line(a.counts + b.counts, b.end)
    if a.kind == "arc" and b.kind == "arc":
        g1, g2 = arc_geometry(a_start, a.end, a.sweep), arc_geometry(a.end, b.end, b.sweep)
        if g1 is None or g2 is None:
            return None
        w1, w2 = g1[3] / float(a.counts), g2[3] / float(b.counts)
        if (dist(g1[0], g2[0]) <= POINT_TOLERANCE and abs(g1[1] - g2[1]) <= POINT_TOLERANCE
                and abs(w1 - w2) <= ANGLE_TOLERANCE and abs(a.sweep + b.sweep) < 360):
            return arc(a.counts + b.counts, b.end, a.sweep + b.sweep)
    return None


def canonical(segments, start, end):
    """The canonical segment list, or None when the move needs no path rows."""
    out, starts, point = [], [], start
    for seg in segments:
        if seg.counts <= 0:
            continue
        if seg.kind == "arc":
            chord = dist(point, seg.end)
            if chord <= MINIMUM_CHORD or abs(sagitta(chord, seg.sweep)) < MINIMUM_SAGITTA:
                seg = line(seg.counts, seg.end)
        if seg.kind == "line" and dist(point, seg.end) <= POINT_TOLERANCE:
            seg = hold(seg.counts)
        merged = merge(out[-1], starts[-1], seg) if out else None
        if merged is not None:
            out[-1] = merged
        else:
            out.append(seg)
            starts.append(point)
        point = seg.end if seg.end is not None else point
    moving = [s for s in out if s.kind != "hold"]
    if not moving and dist(start, end) <= POINT_TOLERANCE:
        return None
    if len(out) == 1 and out[0].kind == "line" and out[0].end == end:
        return None
    return out

# ---------------------------------------------------------------------------
# Fitting per-count samples (spec §4).

FIT_TOLERANCE = 0.001      # 1 mm
MAX_DENOMINATOR = 960


def fits_hold(samples, i, j, start):
    return all(dist(samples[k], start) <= FIT_TOLERANCE for k in range(i + 1, j + 1))


def fits_line(samples, i, j, start):
    seg = line(j - i, samples[j])
    return all(dist(segment_point(start, seg, (k - i) / (j - i)), samples[k]) <= FIT_TOLERANCE for k in range(i + 1, j))


def circle_center(a, b, c):
    d = 2 * (a[0] * (b[1] - c[1]) + b[0] * (c[1] - a[1]) + c[0] * (a[1] - b[1]))
    if abs(d) < 1e-12:
        return None
    a2, b2, c2 = dot(a, a), dot(b, b), dot(c, c)
    return ((a2 * (b[1] - c[1]) + b2 * (c[1] - a[1]) + c2 * (a[1] - b[1])) / d,
            (a2 * (c[0] - b[0]) + b2 * (a[0] - c[0]) + c2 * (b[0] - a[0])) / d)


def fit_arc(samples, i, j, start):
    """An arc through the samples i..j at even angular speed, or None. The sweep comes from the samples."""
    if j - i < 2:
        return None
    center = circle_center(start, samples[(i + j) // 2], samples[j])
    if center is None:
        return None
    points = [start] + [samples[k] for k in range(i + 1, j + 1)]
    angles = [math.atan2(p[1] - center[1], p[0] - center[0]) for p in points]
    deltas = [math.remainder(b - a, 2 * math.pi) for a, b in zip(angles, angles[1:])]
    if not (all(d > 0 for d in deltas) or all(d < 0 for d in deltas)):
        return None
    sweep = -math.degrees(sum(deltas))          # clockwise is positive
    if not 0 < abs(sweep) < 360:
        return None
    seg = arc(j - i, samples[j], sweep)
    if all(dist(segment_point(start, seg, (k - i) / (j - i)), samples[k]) <= FIT_TOLERANCE for k in range(i + 1, j)):
        return seg
    return None


def longest_run(samples, i, start, kinds=("hold", "line", "arc")):
    """The longest hold, line or arc from sample i, as (segment, last sample index). Ties prefer hold, then line."""
    n = len(samples) - 1
    best = None
    if "hold" in kinds:
        j = i
        while j < n and fits_hold(samples, i, j + 1, start):
            j += 1
        if j > i:
            best = (hold(j - i), j)
    if "line" in kinds:
        j = i + 1
        while j < n and fits_line(samples, i, j + 1, start):
            j += 1
        if best is None or j > best[1]:
            best = (line(j - i, samples[j]), j)
    if "arc" in kinds:
        found, j = None, i + 2
        while j <= n:
            seg = fit_arc(samples, i, j, start)
            if seg is None:
                break
            found, j = (seg, j), j + 1
        if found and found[1] > best[1]:
            best = found
    return best


def velocity(seg, seg_start):
    return (0.0, 0.0) if seg.kind == "hold" else mul(sub(seg.end, seg_start), 1 / float(seg.counts))


def solve_corner(p, q, va, vb):
    """Time t1 (0 < t1 < 1) after p at which leg A (velocity va) turns into leg B (velocity vb, reaching q at t = 1)."""
    w = sub(q, p)
    sa, sb = norm(va), norm(vb)
    if sa == 0 and sb == 0:
        return None
    det = cross(va, vb)
    if sa == 0:                                   # hold, then a line that starts mid-count
        if abs(cross(w, vb)) / sb > FIT_TOLERANCE or dot(w, vb) <= 0:
            return None
        t1 = 1 - norm(w) / sb
    elif sb == 0:                                 # a line that arrives mid-count, then a hold
        if abs(cross(w, va)) / sa > FIT_TOLERANCE or dot(w, va) <= 0:
            return None
        t1 = norm(w) / sa
    elif abs(det) / (sa * sb) <= ANGLE_TOLERANCE:  # same direction, new pace
        if abs(cross(w, va)) / sa > FIT_TOLERANCE or dot(va, vb) <= 0 or abs(sa - sb) <= 1e-12:
            return None
        t1 = (norm(w) - sb) / (sa - sb)
    else:                                         # a true corner between two straight legs
        t1, t2 = cross(w, vb) / det, cross(va, w) / det
        if abs(t1 + t2 - 1) * max(sa, sb) > FIT_TOLERANCE:
            return None
    return t1 if 0 < t1 < 1 else None


def fit_move(samples, corners=True):
    """Segments for one performer's move from samples at counts 0, 1, …, n.

    samples[0] must be the placement at the previous set and samples[-1] the
    placement at the arrival set, with their exact doubles.
    """
    n = len(samples) - 1
    out, starts = [], []          # segments and the point each starts at
    fitted = []                   # True for runs, False for 1-count fallbacks
    point, i = samples[0], 0
    while i < n:
        seg, j = longest_run(samples, i, point)
        if corners and j == i + 1 and i + 1 < n:
            # A 1-count chord may hide a corner between two legs (hold or line).
            if out and fitted[-1] and out[-1].kind in ("hold", "line"):
                a, a_start = out[-1], starts[-1]
            elif not out:
                a, a_start = hold(0), point      # the move's start counts as a hold of no length
            else:
                a = None
            b = longest_run(samples, i + 1, samples[i + 1], kinds=("hold", "line")) if a is not None else None
            if b is not None and (b[0].kind == "hold" or b[1] - (i + 1) >= 2):
                b_seg, k = b
                va = velocity(a, a_start) if a.counts else (0.0, 0.0)
                t1 = solve_corner(point, samples[i + 1], va, velocity(b_seg, samples[i + 1]))
                if t1 is not None:
                    t1 = Fraction(t1).limit_denominator(MAX_DENOMINATOR)
                    if 0 < t1 < 1:
                        corner = add(point, mul(va, float(t1)))
                        a2 = hold(a.counts + t1) if a.kind == "hold" else line(a.counts + t1, corner)
                        b_counts = (k - i - 1) + (1 - t1)
                        b2 = hold(b_counts) if b_seg.kind == "hold" else line(b_counts, samples[k])
                        if out:
                            out[-1] = a2
                        else:
                            out.append(a2); starts.append(a_start); fitted.append(True)
                        out.append(b2); starts.append(corner); fitted.append(True)
                        point = corner if b2.kind == "hold" else b2.end
                        i = k
                        continue
        out.append(seg); starts.append(point); fitted.append(j > i + 1 or seg.kind == "hold")
        point = seg.end if seg.end is not None else point
        i = j
    # The path must end on the arrival placement's exact doubles (spec §6).
    last = max((k for k, s in enumerate(out) if s.kind != "hold"), default=None)
    if last is not None:
        out[last] = out[last].with_end(samples[-1])
    return out


def max_error(samples, segments):
    if segments is None:
        segments = [line(len(samples) - 1, samples[-1])]
    return max(dist(path_point(samples[0], segments, float(u)), p) for u, p in enumerate(samples))


def path_for_move(samples):
    """Canonical segments for one performer-move, or None when it moves straight (no rows).

    Refuses (raises) when no fit reproduces every count within 1 mm.
    """
    for corners in (True, False):
        segments = canonical(fit_move(samples, corners), samples[0], samples[-1])
        if max_error(samples, segments) <= FIT_TOLERANCE:
            return segments
    raise ValueError(f"no path reproduces these samples within {FIT_TOLERANCE * 1000:.0f} mm")

# ---------------------------------------------------------------------------
# Writing (spec §7).

PATH_SEGMENT_DDL = """CREATE TABLE path_segment (transition_id TEXT NOT NULL REFERENCES transition(id), performer_id TEXT NOT NULL REFERENCES performer(id),
    ordinal INTEGER NOT NULL, kind TEXT NOT NULL CHECK (kind IN ('hold','line','arc')),
    counts_num INTEGER NOT NULL, counts_den INTEGER NOT NULL, x1 REAL, y1 REAL, sweep REAL,
    PRIMARY KEY (transition_id, performer_id, ordinal))"""

PATHS_CAPABILITY = "drill.paths.v1"


def segment_rows(transition_id, performer_id, segments):
    for ordinal, seg in enumerate(segments):
        x1, y1 = seg.end if seg.end is not None else (None, None)
        yield (transition_id, performer_id, ordinal, seg.kind, seg.counts.numerator, seg.counts.denominator,
               x1, y1, seg.sweep if seg.kind == "arc" else None)


def write_paths(db, paths):
    """Adds path rows to a schema 4 or 5 database. paths maps (transition_id, performer_id) to segments.

    With no paths a schema 4 database stays schema 4.
    """
    if not paths:
        return
    if db.execute("PRAGMA user_version").fetchone()[0] < 5:
        db.execute(PATH_SEGMENT_DDL)
        db.execute("PRAGMA user_version = 5")
    # Rows go in arrival-set order, then roster order, then segment order.
    set_order = {t: k for t, k in db.execute(
        "SELECT t.id, s.ordinal FROM transition t JOIN arrival_set s ON s.id = t.to_set_id")}
    roster = {p: k for p, k in db.execute("SELECT id, ordinal FROM performer")}
    for t, p in sorted(paths, key=lambda key: (set_order[key[0]], roster[key[1]])):
        db.executemany("INSERT INTO path_segment VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)", segment_rows(t, p, paths[(t, p)]))
    db.commit()
    if db.execute("PRAGMA foreign_key_check").fetchall():
        raise ValueError("path rows reference a missing move or performer")


def read_container(path):
    """Members of a stored-only ZIP, in archive order, as (name, bytes)."""
    import zipfile
    with zipfile.ZipFile(path) as archive:
        return [(info.filename, archive.read(info)) for info in archive.infolist()]


def write_container(path, members):
    """A ZIP with Fieldwork's writer rules: stored, UTF-8 names, fixed 1980-01-01 timestamps, no extras."""
    body, central = bytearray(), bytearray()
    for name, data in members:
        encoded, crc, offset = name.encode("utf-8"), zlib.crc32(data) & 0xFFFFFFFF, len(body)
        body += struct.pack("<IHHHHHIIIHH", 0x04034B50, 20, 0x0800, 0, 0, 0x0021, crc, len(data), len(data), len(encoded), 0)
        body += encoded + data
        central += struct.pack("<IHHHHHHIIIHHHHHII", 0x02014B50, 20, 20, 0x0800, 0, 0, 0x0021, crc, len(data), len(data),
                               len(encoded), 0, 0, 0, 0, 0, offset)
        central += encoded
    end = struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, len(members), len(members), len(central), len(body), 0)
    with open(path, "wb") as f:
        f.write(bytes(body + central + end))


def rewrite_container(source, destination, scratch, edit, has_paths):
    """Copies the .fieldwork at source to destination after edit(db) changes its database.

    The manifest lists drill.paths.v1 in capabilities and requiredCapabilities
    exactly when has_paths, and every member's size and SHA-256 are recomputed.
    """
    members = dict(read_container(source))
    manifest = json.loads(members["manifest.json"])
    db_path = os.path.join(scratch, "show.sqlite")
    with open(db_path, "wb") as f:
        f.write(members["show.sqlite"])
    db = sqlite3.connect(db_path)
    edit(db)
    db.close()
    with open(db_path, "rb") as f:
        members["show.sqlite"] = f.read()
    os.remove(db_path)
    for key in ("capabilities", "requiredCapabilities"):
        manifest[key] = [c for c in manifest[key] if c != PATHS_CAPABILITY] + ([PATHS_CAPABILITY] if has_paths else [])
    for member in manifest["members"]:
        data = members[member["path"]]
        member["bytes"], member["sha256"] = len(data), hashlib.sha256(data).hexdigest()
    members["manifest.json"] = json.dumps(manifest, indent=2, sort_keys=True).encode("utf-8")
    order = ["manifest.json", "show.sqlite"] + [m["path"] for m in manifest["members"] if m["path"] != "show.sqlite"]
    write_container(destination, [(name, members[name]) for name in order])


def save_with_paths(source, destination, paths, scratch):
    """Copies the .fieldwork at source to destination with the given path rows added."""
    rewrite_container(source, destination, scratch, lambda db: write_paths(db, paths), bool(paths))


def strip_paths(source, destination, scratch):
    def edit(db):
        db.execute("DELETE FROM path_segment")
        db.commit()
        db.execute("VACUUM")
    rewrite_container(source, destination, scratch, edit, False)

# ---------------------------------------------------------------------------
# Self-check: the evaluator vectors from the brief, then the fixture round trip.

def check_vectors():
    def near(a, b): return dist(a, b) <= 1e-6
    v = [hold(4), line(4, (4, 0))]
    assert all(near(path_point((0, 0), v, u), p) for u, p in [(2, (0, 0)), (4, (0, 0)), (6, (2, 0)), (8, (4, 0))])
    v = [arc(4, (10, 0), 90)]
    assert near(arc_geometry((0, 10), (10, 0), 90)[0], (0, 0))
    assert near(path_point((0, 10), v, 1), (3.826834, 9.238795)) and near(path_point((0, 10), v, 2), (7.071068, 7.071068))
    assert near(path_point((10, 0), [arc(4, (0, 10), -90)], 2), (7.071068, 7.071068))
    v = [arc(3, (0, 10), 270)]
    assert all(near(path_point((10, 0), v, u), p) for u, p in [(1, (0, -10)), (2, (-10, 0)), (3, (0, 10))])
    v = [line(Fraction(9, 2), (4.5, 0)), line(Fraction(7, 2), (4.5, 3.5))]
    assert all(near(path_point((0, 0), v, u), p) for u, p in [(4, (4, 0)), (5, (4.5, 0.5)), (8, (4.5, 3.5))])
    print("evaluator vectors 1-5: ok")


def check_fitting():
    """Cases the fixture does not cover: what each shape fits to, and that every count is within 1 mm."""
    def samples_of(start, segments):
        n = int(sum(s.counts for s in segments))
        return [path_point(start, segments, float(u)) for u in range(n + 1)]

    def kinds(segments):
        return None if segments is None else [s.kind for s in segments]

    corner = Fraction(4603, 1000)
    cases = [
        ("corner 4.603 counts in", samples_of((0, 0), [line(corner, (4.603, 0)), line(8 - corner, (4.603, 3.397))]), ["line", "line"]),
        ("new pace mid-leg", samples_of((0, 0), [line(Fraction(5, 2), (2.5, 0)), line(Fraction(7, 2), (4.25, 0))]), ["line", "line"]),
        ("arrives early mid-count", samples_of((0, 0), [line(Fraction(11, 2), (5.5, 0)), hold(Fraction(5, 2))]), ["line", "hold"]),
        ("straight", samples_of((0, 0), [line(8, (6, 2))]), None),
        ("standing still", [(3.0, 1.0)] * 9, None),
        ("smooth curve", [(u * 0.75, 0.04 * u * u * u) for u in range(9)], "lines"),
        ("noisy arc", [(p[0] + 0.0003 * (-1) ** k, p[1]) for k, p in enumerate(samples_of((0, 10), [arc(8, (10, 0), 90)]))], ["arc"]),
    ]
    for name, samples, want in cases:
        got = path_for_move(samples)
        error = max_error(samples, got)
        ok = error <= FIT_TOLERANCE and (kinds(got) == want if want != "lines" else set(kinds(got)) == {"line"})
        detail = "straight, no rows" if got is None else ", ".join(f"{s.kind} {s.counts}" for s in got)
        print(f"  {name}: {detail} (worst count {error * 1000:.3f} mm){'' if ok else '  <-- unexpected'}")
        assert ok, name
    print("fitting cases: ok")


def set_pulses(db):
    """Count at each arrival set, for timelines of plain beats (no grouping, pickups or holds), which the demo uses."""
    measures = {m: Fraction(pn, pd) for m, pn, pd, g, pk in db.execute(
        "SELECT id, pulse_unit_num, pulse_unit_den, grouping, pickup_num FROM measure") if g is None and pk is None}
    start, pulse = {}, Fraction(0)
    for event, kind, measure, nn, nd in db.execute(
            "SELECT id, kind, measure_id, notated_num, notated_den FROM timing_event ORDER BY ordinal"):
        if kind != "beat" or measure not in measures:
            raise ValueError("the demo only handles plain beats")
        start[event] = (pulse, Fraction(nn, nd) / measures[measure])
        pulse += start[event][1]
    return {s: start[e][0] + Fraction(fn, fd) * start[e][1]
            for s, e, fn, fd in db.execute("SELECT id, event_id, fraction_num, fraction_den FROM arrival_set")}


def demo(fixture, golden_path, out, fwtool):
    with open(golden_path, encoding="utf-8") as f:
        golden = json.load(f)
    # The "source drill": every performer's position at every whole count.
    source = {frame["pulse"]: {p["id"]: (p["x"], p["y"]) for p in frame["performers"]}
              for frame in golden["frames"] if float(frame["pulse"]).is_integer()}

    scratch = tempfile.mkdtemp(prefix="paths-reference-")
    members = dict(read_container(fixture))
    db_path = os.path.join(scratch, "fixture.sqlite")
    with open(db_path, "wb") as f:
        f.write(members["show.sqlite"])
    db = sqlite3.connect(db_path)
    expected = {}
    for t, p, kind, n, d, x1, y1, sweep in db.execute(
            "SELECT transition_id, performer_id, kind, counts_num, counts_den, x1, y1, sweep FROM path_segment ORDER BY transition_id, performer_id, ordinal"):
        expected.setdefault((t, p), []).append(Segment(kind, Fraction(n, d), None if x1 is None else (x1, y1), sweep))
    pulses = set_pulses(db)
    sets = list(db.execute("SELECT id FROM arrival_set ORDER BY ordinal"))
    placements = {(s, p): (x, y) for s, p, x, y in db.execute("SELECT set_id, performer_id, x, y FROM placement WHERE state = 'placed'")}
    performers = [p for (p,) in db.execute("SELECT id FROM performer ORDER BY ordinal")]
    moves = list(db.execute("SELECT t.id, t.to_set_id FROM transition t JOIN arrival_set s ON s.id = t.to_set_id ORDER BY s.ordinal"))
    previous = {b: a for (a,), (b,) in zip(sets, sets[1:])}
    db.close()

    # The fixture with its paths removed stands in for the converter's straight-only output.
    straight = os.path.join(scratch, "straight.fieldwork")
    strip_paths(fixture, straight, scratch)

    paths, failures = {}, 0
    for t, b in moves:
        a = previous[b]
        start, end = int(pulses[a]), int(pulses[b])
        for p in performers:
            if (a, p) not in placements or (b, p) not in placements:
                continue                                  # unplaced at either end: no path
            # The golden samples are rounded to 1 µm, so fitted sweeps differ from the fixture by about 1e-5°.
            samples = [source[u][p] for u in range(start, end + 1)]
            samples[0], samples[-1] = placements[(a, p)], placements[(b, p)]
            segments = path_for_move(samples)
            if segments is not None:
                paths[(t, p)] = segments
            want = expected.get((t, p))
            same = (segments is None and want is None) or (
                segments is not None and want is not None and len(segments) == len(want) and all(
                    s.kind == w.kind and s.counts == w.counts and (s.end is None or dist(s.end, w.end) <= 1e-5)
                    and (s.sweep is None or abs(s.sweep - w.sweep) <= 1e-4) for s, w in zip(segments, want)))
            failures += not same
            label = "straight" if segments is None else ", ".join(
                f"{s.kind} {s.counts}" + ("" if s.sweep is None else f" sweep {s.sweep:+.6g}") for s in segments)
            print(f"  move into set {sets.index((b,)) + 1}, performer {performers.index(p) + 1}: {label}{'' if same else '  <-- differs from the fixture'}")
    rows = sum(len(s) for s in paths.values())
    save_with_paths(straight, out, paths, scratch)
    print(f"fit {len(paths)} paths with {rows} segment rows; {failures} differ from the fixture; wrote {out}")

    if fwtool:
        fwtool = os.path.abspath(fwtool)
        print(subprocess.run([fwtool, "info", out], capture_output=True, text=True, check=True).stdout.rstrip())
        counts = [str(frame["pulse"]) for frame in golden["frames"]]
        result = json.loads(subprocess.run([fwtool, "evaluate", out, *counts], capture_output=True, text=True, check=True).stdout)
        worst = max(dist((p["x"], p["y"]), (g["x"], g["y"]))
                    for frame, gold in zip(result["frames"], golden["frames"])
                    for p, g in zip(frame["performers"], gold["performers"]))
        print(f"fwtool evaluate at {len(counts)} counts: worst difference from the golden output {worst * 1000:.4f} mm")
        # Both sides are rounded to 1 µm; a converter's own check is 1 mm against its source.
        failures += worst > 1e-5
    return failures


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--fixture", default=os.path.join(root, "fixtures", "paths.fieldwork"))
    parser.add_argument("--golden", default=os.path.join(root, "fixtures", "paths-evaluation.json"))
    parser.add_argument("--out", default=os.path.join(tempfile.gettempdir(), "paths-refit.fieldwork"))
    parser.add_argument("--fwtool", help="path to fwtool, to open and evaluate the output in Fieldwork's core")
    args = parser.parse_args()
    check_vectors()
    check_fitting()
    sys.exit(1 if demo(args.fixture, args.golden, args.out, args.fwtool) else 0)


if __name__ == "__main__":
    main()
