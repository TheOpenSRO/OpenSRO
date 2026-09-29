#!/usr/bin/env python3
"""Movement versus facing, from a client log written with
SRREVAMP_QA_FACING_LOG=1 (round 637; World3D._qa_facing_report).

  facing_measure.py <log> [player|monster]              per-leg report
  facing_measure.py <log> [player|monster] --runs [ms]  turn runs, skipping
                                                        the first `ms` of the log

Per leg: consecutive samples moving faster than 5 u/s. The steady part is the
leg after its first 0.4 s (a half turn takes a third of a second); its
|movement - facing| is reported, and when the facing first came within 2 deg.
--runs: the share of moving samples within 2 deg of their movement, and how
long each stretch off by more than 2 deg lasted (a turn in progress)."""
import math, re, sys

pat = re.compile(r"QA FACING (\w+) (\d+) ms=(\d+) pos=\(([-\d.]+),([-\d.]+)\) front=\(([-\d.]+),([-\d.]+)\)")

def load(path, kind):
    by = {}
    for line in open(path, errors="replace"):
        m = pat.search(line)
        if m and m.group(1) == kind:
            by.setdefault(int(m.group(2)), []).append(tuple(float(m.group(i)) for i in range(3, 8)))
    return by

def ang(x, z):
    return math.degrees(math.atan2(x, z))

def diff(a, b):
    return (a - b + 180.0) % 360.0 - 180.0

def moving(s, skip_before=-1.0):
    """(ms, vx, vz, fx, fz, previous ms) per moving sample; None marks a stop."""
    for a, b in zip(s, s[1:]):
        dt = (b[0] - a[0]) / 1000.0
        if dt <= 0 or a[0] < skip_before:
            continue
        vx, vz = (b[1] - a[1]) / dt, (b[2] - a[2]) / dt
        yield (b[0], vx, vz, b[3], b[4], a[0]) if math.hypot(vx, vz) > 5.0 else None

def legs_report(by, kind):
    for eid, s in by.items():
        legs, cur = [], []
        for r in moving(s):
            if r is not None:
                cur.append(r)
            elif cur:
                legs.append(cur); cur = []
        if cur:
            legs.append(cur)
        print("%s %d: %d samples, %d legs" % (kind, eid, len(s), len(legs)))
        for i, leg in enumerate(legs):
            t0 = leg[0][0]
            steady = [r for r in leg if r[0] - t0 >= 400] or leg[-1:]
            d = [abs(diff(ang(r[3], r[4]), ang(r[1], r[2]))) for r in steady]
            aligned = next((r[0] - t0 for r in leg if abs(diff(ang(r[3], r[4]), ang(r[1], r[2]))) < 2.0), None)
            print("  leg %d: %.2f s, %d samples; move %7.1f deg, face %7.1f deg, |move-face| mean %.2f max %.2f"
                  " (first sample %.1f, within 2 deg after %s ms)" % (
                i, (leg[-1][0] - t0) / 1000.0, len(leg),
                ang(sum(r[1] for r in steady), sum(r[2] for r in steady)),
                ang(sum(r[3] for r in steady), sum(r[4] for r in steady)),
                sum(d) / len(d), max(d), abs(diff(ang(leg[0][3], leg[0][4]), ang(leg[0][1], leg[0][2]))), aligned))

def runs_report(by, kind, skip_ms):
    first = min(v[0][0] for v in by.values()) if by else 0.0
    tot = ok = 0
    runs = []
    for s in by.values():
        start = None
        for r in moving(s, first + skip_ms):
            if r is None:
                start = None
                continue
            tot += 1
            if abs(diff(ang(r[3], r[4]), ang(r[1], r[2]))) < 2.0:
                ok += 1
                if start is not None:
                    runs.append(r[0] - start)
                start = None
            elif start is None:
                start = r[5]
    runs.sort()
    print("%s: %d bodies, %d moving samples, %.1f%% within 2 deg; %d off-runs, longest %s ms, median %s ms" % (
        kind, len(by), tot, 100.0 * ok / max(tot, 1), len(runs),
        runs[-1] if runs else 0, runs[len(runs) // 2] if runs else 0))

if __name__ == "__main__":
    kind = sys.argv[2] if len(sys.argv) > 2 else "player"
    by = load(sys.argv[1], kind)
    if "--runs" in sys.argv:
        i = sys.argv.index("--runs")
        runs_report(by, kind, float(sys.argv[i + 1]) if len(sys.argv) > i + 1 else 0.0)
    else:
        legs_report(by, kind)
