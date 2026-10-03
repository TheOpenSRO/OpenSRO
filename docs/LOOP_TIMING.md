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
| perf gate: a base revision measured once, its client copy shared | 216 s a gate (2 runs a side, Jangan) | **170 s**; 4 boots instead of 6 at the default 3 runs | Two gates back to back on 56e8e24: the second reported "reusing the shared base copy" and "cached run(s) ... using them"; the fresh check was 11.22 ms against a cached median of 11.23. |
| A hung suite holding a lane's lock (`SUITE_TIMEOUT`) | 13 min until killed by hand | fails after 600 s (default) | A script-less boot ended at 21 s with a 20 s limit, nothing left running. |

## The second batch: rounds 648-652 (2026-09-30 06:14 to 08:17)

**2 h 03 min from the request to the release (v0.1.463), against the baseline's 8 h 34 min, for the
same number of rounds (five).** The loop ran on the new render box (28 cores, docs/RENDER_BOX.md)
with every change above.

| | Baseline (641-647) | Rounds 648-652 |
|---|---|---|
| Request to release | 8 h 34 min | **2 h 03 min** |
| Agent time, all agents | 1,401 min | **473 min** |
| Agents waiting in foreground loops on box jobs | 283 min | **28 min** |
| A builder's round, start to reviewed | 66-187 min | 67-82 min |
| One review | 19-81 min | 7-20 min |
| Rounds added late to fix something the reviews missed | 1 (round 647, ~3.5 h) | **0** |

What still cost time, measured:
- The perf-gate queue: four builders reached the gate together and queued for ~25 min, all
  re-measuring the same base. One of them (a server/UI round) should not have run it at all; the
  brief now says so. Caching a base revision's numbers per view is the next change (below).
- Go tests share one local Postgres; two builders saw internal/session fail under contention and
  pass alone.
- The final review waited for round 648's own review to finish before its last gate runs.

## The third batch: the monster world, rounds 653-666 (2026-09-30 08:16 to 2026-10-01 00:24)

**16 h 08 min from the request to the tag (v0.1.464), 16 h 27 min to opensro-01 running it.**
That covers fourteen rounds, which include two the final review added (665, the die-revive
loop it found live; 666, the deploy guide and its LOWs), plus an infra round (658, restoring the
user's shard DB). The rounds were far larger than batches one and two, so wall time per round
is not comparable with them. The measures below are.

| | Rounds 648-652 | Rounds 653-666 |
|---|---|---|
| Request to release | 2 h 03 min | 16 h 08 min |
| Agents | -- | 36 |
| Agent time, all agents | 473 min | 3,208 min |
| Agents waiting in foreground loops on jobs | 28 min | 240 min (7.5 %), in four agents |
| Go build and test in agents | -- | 193 min |
| Rounds added late, by the final review | 0 | 2 (665, 666) |

The cost of this batch, measured or seen:
- **The dev VM has 1 core and 2 GB** (`nproc`, `free`; measured 2026-10-01). It ran every lane's
  Go build and test. The session package took 100-190 s, and 245-560 s under -race, where a
  whole-package -race run hit Go's 10-minute timeout. Lanes queued on the one test Postgres
  (`testdb.Lock`). The disk (31 GB) filled twice from the shared Go cache, stopping Postgres and
  failing SQL tests falsely.
- **Every round needed one to three review cycles.** Each review found real defects: a server
  crash (665), a death loop (final review), invented minions (661), and mutants surviving (666).
  The cycles cost the most hours, and every one of them was worth it.
- **Foreground wait loops came back** in four agents, despite the brief. They cost 240 min.

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
