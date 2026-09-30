# How long the build-and-review loop takes, and what changed it

Every change to how rounds are built, tested and reviewed is measured here, before and after, on
the same code. Estimates are labelled as estimates. The baseline is the batch of rounds 641-647,
released as v0.1.462.

## The baseline: rounds 641-647 (2026-09-29 15:48 to 2026-09-30 00:22)

8 h 34 min from the request to the release. From the session's own timestamps:

| Step on the path the release waited for | Took |
|---|---|
| Round 645 built | 55 min |
| Its review, then an extra pass on the reeds' cost that could not cut it | ~2 h 10 min |
| Merging (a merge broke the build and was fixed) | 22 min |
| Final review, which found +3.3 ms a frame at the Jangan spawn | 61 min |
| Round 647, written only to cut that cost | 2 h 19 min |
| A second full review, because round 647 was new code | 1 h 21 min |
| Go-ahead, CI, the release build | 21 min |

Across all 16 agents (1,401 agent-minutes): 283 min in wait loops on render-box jobs, ~270 min
running Godot, tests and ssh on the box, 274 min of model steps (2,762 steps, median 3 s). One
agent was lost to a rejected permission check (about 20 min).

The late performance finding cost about 3.5 of the 8.5 hours: round 645's own review measured
only the Dunhuang reeds at 320x180.

## Changes, measured

| Change | Before | After | How it was checked |
|---|---|---|---|
| Full client test suite (`remote_godot.sh tests`), 8 suites at a time in one ssh (`run_suites.sh`) | 251 s | **59 s** (4.3x) | Same tree, back to back: 167 suites, 0 failing both ways. A deliberate FAIL suite and a hanging suite are both reported, exit 1. |
| Performance check per world round (`perf_gate.sh`) | none; round 645's +3.3 ms surfaced 3.5 h late | **~6 min** (`--sites jangan`), ~15 min all views | Proof: 8658370 vs c306c51 reports `frame SLOWER (+3.0)`, exit 1. Same build against itself: 12 of 12 numbers SAME, exit 0. |
| A hung suite holding a lane's lock (`SUITE_TIMEOUT`) | 13 min until killed by hand | fails after 600 s (default) | A script-less boot ended at 21 s with a 20 s limit, nothing left running. |

## What the render box is short of (measured 2026-09-30)

`amdgpu_top` (installed on the box; `gpu_sample` logs it once a second) and `vmstat 1`, one Jangan
render against six at once:

| | One render | Six at once |
|---|---|---|
| CPU busy (10 cores) | 33 % | 89 % (run queue 12, peak 26) |
| GPU busy | 17 % | 37 %, never 90 % |
| Frame | 12.4 ms | 36-37 ms |
| RAM | 1.6 GB | 9.8 GB; 11 GB free, no swap |

The CPU is the shared resource: one render uses about 3.3 cores. The container's CPU is not
capped (`cpu.max` unlimited, never throttled). Parallel lanes still finish more work than serial
ones (six renders: 148 s at once against ~372 s one after another). More cores would help
parallel lanes almost directly; a faster GPU would not.

## Still to measure

- World entry: the gate logs 14.0 s at the Jangan spawn, 10.5 s at the reeds, 15.5 s on the
  crossing, with a single 3-5 s frame each. Every boot on the box pays it, and so does a player.
- The next batch's total against the baseline above, with the same breakdown.
