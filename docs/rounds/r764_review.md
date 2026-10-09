# Round 764 review (independent, adversarial)

Branch `r764`: `3b4069a1` (server), `1a09e915` (client), `b0381a13` (native and notes), on dev
`438035a9`. Reviewed by reading the diff and the code it touches, with re-runs on the render box
(`RENDER_DIR=/opt/opensro-client-r764rev`, `GODOT_LOCK=/var/tmp/r764rev/lock`, owned by
`ghidra`). Labels follow r764.md: **READ**, **MEASURED**, **INFERRED**.

## Verdict

**Do not ship it as it stands. Ship after F2 and F4, which are small, and after a decision on F3.**
The page join (#3A) and the server landing (#3B) are sound. The batch draws correctly under
Forward+ and under GL Compatibility. #1 and #2 are reasonable.

Two things still need work:

- **F2 is a new visible bug.** Every arrival draws far more hosts than the budget allows for about
  half a second, and then most of those effects disappear.
- **#4 is fixed only in part (F1).** The effects no longer change with the camera angle, but in the
  swarm 95.7 % of the hosts within 720 units still draw no seal effects. The user has to be told
  this plainly, because their report ("I don't see all the seal effects at once") still holds in a
  crowd.

## Findings, most severe first

### F1 (HIGH, user-facing): #4 is only partly fixed

Where: `equip_fx_batch.gd:62` (`HOST_BUDGET := 500`), `equip_fx.gd:939` and `equip_fx.gd:1059-1066`.

**What is drawn (MEASURED, the round's own `V764b.log` on the box).** In the 4,000 swarm, 11,601
ghost hosts are within 720 units in some direction (`fx_in_view=11601`), and 503 are drawn
(`fx_batch_hosts`). So **11,098 hosts within 720, 95.7 %, draw no effect.**

**What the budget counts.** The budget counts hosts, not characters. At about 2.9 hosts a ghost,
500 hosts is about 170 characters. The cut is the nearest to the camera in every direction, so
about half of those characters stand behind the camera. Against v0.1.516's 64 hosts, all of them
in view, the gain on screen is about 4x, not the 8x that r764.md section 2.3 states (INFERRED).

**Retail (READ, the client dump `/var/tmp/decomp_client`).**

- `FUN_00c43780` returns `mod+0x3c >= *(owner+8)+0x7c`.
- The owner's `+0x7c` is the LOD factor, set through `CCompChar::FUN_00c25620` (clamped to
  `[0,1]`).
- `GlobalDataManager::FUN_009c4aa0` computes that factor as `vtable+0x44() / _DAT_00d83080`, which
  is 800. It forces the factor to 0 in three cases:
  - when getter `0x17` (an option) returns 0;
  - when the object is exactly the runtime class at `0xef1b44`. That class is registered next to
    `ICPlayer::FUN_009d6700` in character creation, so it is INFERRED to be the own `CICPlayer`;
  - when the object is a `CICMonster` of rarity (`+0x7ac`) 3 or 8.
- So another player's effects stop at 0.9 x 800 = 720 units, and **retail has no count limit**:
  every character within 720 has its effects, which would be all 11,601 hosts here.
- The per-object rescale (`cfg+0x134 x s + cfg+0x138`) stays OPEN.
- `docs/protocol/crowd_scale.md:118` says the opposite ("every other player's weapon particles draw
  at every distance (factor 0)"), as does r736.md. That line should be corrected to the reading
  above.

**Dressed bodies still flicker.** Their hosts keep the old holder path: the 64 nearest, in the
frustum, chosen again every cycle. Since #1, a body is dressed only when it is promoted: a buff at
arrival, an aura, sitting, a hit or a cast. In a real town many players are buffed or sitting, so
their seal effects still come and go with the camera angle (READ, `equip_fx.gd`: the holder branch
is unchanged for hosts with no `anchor`).

**Why the budget exists, and how to remove it.** The +3 ms of GPU for all 11,600 hosts is mostly
repeated work: every particle vertex recomputes its host's frame, about 20 `texelFetch`, a
Gram-Schmidt step, a determinant and a `pow` (`HEAD`, `equip_fx_batch.gd:525-578`). Compute each
host's frame once a frame instead, in a small pass or natively into a texture, and let the particle
read 3 texels. Then re-measure without the budget, or with a much larger one. Also send dressed
bodies' ghost-style hosts through the batch, or choose their holders the same way regardless of
view.

### F2 (MEDIUM-HIGH, new bug, MEASURED): every arrival draws several times the budget, then drops it

Where: `equip_fx.gd:939`: `var sel := gd <= MAX_DISTANCE and gd <= _batch_cut`.

**The cause.** The cut comes from the previous scan cycle. While a page is held, its hosts are
skipped (their origin is INF), so the cycle before a reveal sees fewer than 500 hosts and leaves
`_batch_cut = INF`. The first cycle after the reveal then selects every host within 720 as it scans
them. `_place_pending` keeps to the budget (`_selected < host_budget`); the scan does not.

**Measured.** I added one print in `_finish_cycle` to my box copy only, and ran `crowd_run.sh` with
4,000 bodies and the steps `base,leave,base,back,base`:

```
back reveal (t=45990 ms): selected=500 table_hosts=500
t=46149: d=3276 cut=234.2 selected=3276 table_hosts=2223   <- 4.4x the budget drawn
t=46291: selected=501 table_hosts=928
t=46434: selected=501 table_hosts=501
cold arrival: table_hosts 500 -> 1574 -> 756 -> 501
```

**Effect.** For about 0.3-0.5 s after each reveal, seal effects appear on far bodies and then
disappear: a pop at the moment the crowd shows. The extra GPU work and the large host-table uploads
also land in the reveal window. In the 11,601-host swarm a cycle is 58 frames, so the overshoot can
reach about 11,000 hosts (INFERRED). This is probably part of the box's 5-15 % slower reveals (F9).
The round's tests set the budget only after the hosts are steady, so they miss it.

**Fix.** Either cap the scan's selection at `_selected < host_budget` while the cut is INF, or put
the held hosts' real distances (CrowdGpu has the body position) into `_batch_d`, so that the cut
exists before the reveal.

### F3 (MEDIUM): the zone-change spot is an unvalidated teleport

Where: `server/internal/session/world.go:1145-1160` and `:1685`.

**Retail compatibility is fine.** `OpChangeZone` is `0x0026`, which is OURS (`world.go:31`, "our
own protocol"), so no retail client or server ever sends or reads it. The client's resend after
"malformed request" is safe:

- an older server refuses trailing bytes (`decodeStrings`, `wire.go:60`);
- the resend carries no spot and clears `_zone_spot_retry`, so it cannot loop;
- `world_test.gd` covers it.

There is one small edge: any result clears `_zone_spot_retry`, so a spotted request sent while
another request is in flight is not retried.

**The hole.** The spot is accepted anywhere in `[0,1920)²` of the zone's centre region:

- `req.Zone` may be any `rx/ry` label (`worldmap.FrameFor` -> `ParseRegionLabel`);
- nothing checks that the spot is walkable;
- there is no GM gate, no cooldown and no combat check (only death is refused);
- under `-single-frame` a request for the current zone is never refused, so it can be repeated.

Before this round the same request was already a free warp, but only to a region's middle. Now it
lands on any point, which bypasses `hub.Claim`'s distance bound entirely: a modified client can step
inside walls, into closed areas, or next to a target. The fallback to Jangan's square is correct for
Jangan only. Every other zone has no `LandingSpot` row and lands at its middle as before; I checked
that `TestRound764ChangeZoneLanding` covers Donwhang.

**Fix, cheapest first.**

- Accept only spots the server knows: the `LandingSpot` rows plus the developer panel's town spots.
- Or accept a spot only from a GM session.
- At the least, disclose it as a dev-only hole before any public server runs this build.

### F4 (MEDIUM-LOW): a host keeps drawing after its slot is freed or reused

Where: `equip_fx_batch.gd:141-151` and `:246-256`; `crowd_gpu.gd:504-508`.

**The cause.** `remove()` only marks the batch dirty, and the tables are rebuilt one frame in six.
`CrowdGpu.remove` sets the freed slot's fade texel to 0, and the shader reads 0 as "no fade", which
means drawn. During those frames:

- a removed ghost's effect stays at the body's last transform. That covers a dressing swap, or a
  departure without a fade;
- or it is drawn on a new body that took the slot. `_free_slots` hands slots out last in, first
  out. The new body is drawn with the old layout's bone index and pose rows, so the effect is
  misplaced.

A held page is protected (`t4.y >= 3.5e6`); a single unheld arrival is not. A slot that changes
under a live host is found only when that host is next selected, within one cycle.

**Effect.** At most about 100 ms, cosmetic.

**Fix.** Write a negative sentinel into the freed slot's fade texel. `fxb_off` already tests
`t4.y < 0`, and no part instance names a freed slot. Or rebuild at once on a removal.

### F5 (MEDIUM-LOW): the #2 budget treats main-thread work as idle

Where: `other_crowd.gd:68-71` and `:157-184`.

**The cause.** `FrameMark.wait_usec` is the time from the last `_process` callback (priority
+1e6) to the next frame's first callback. That gap includes the render-thread sync and vsync, which
are real idle time. It also includes SceneTree's deferred-call flush and delete-queue flush, input,
and the physics `flush_queries`, which are main-thread work. During a departure, freeing the
holders lands in that flush.

The budget is `aim - (own - wait)`, with no margin and up to 12 ms. So:

- on a frame with a large flush, the frame overshoots its aim by the size of the flush;
- at a 60 Hz vsync the aim is about 16.7 ms, the budget fills it, and any flush misses a vsync
  (INFERRED).

It cannot starve: the floor of 1.5 ms is unchanged. A slower CPU spikes by at most one body's cost
past the budget, as before.

**Evidence.** The round's A/B (`OPENSRO_QA_BUDGET_WORK=0`) reports reveal seconds only. Its "over
p95" share in `cross` rose from 2.9 % to 3.5-4.2 % against v0.1.516, which the round puts down to a
lower p95.

**Fix.** Leave a margin, for example 0.85 x the aim, or measure only the render sync. Report the
over-p95 share and the worst frame for the rule's own A/B.

### F6 (LOW-MEDIUM): `EquipFxBatch` is never cleared, so it leaks across world re-entries

Where: `equip_fx_batch.gd:175`. `clear()` has no caller (grep). `_layouts` (`:113`) keeps the
CrowdGpu `Layout`s of a world that has left, along with their bone texture arrays. The batches'
materials keep the old `crowd_bodies` texture. `step()` returns early when `crowd == null`, so
nothing rebinds.

A relog builds a new CrowdGpu. Its layouts are appended after the old ones, so they form new layout
groups and new batches, and the old ones are hidden but never freed. GPU memory therefore grows with
every world entry.

**Fix.** Call `clear()` and reset `_layouts` when `ghost_gpu` changes, or from World3D's
`_exit_tree`.

### F7 (LOW): the transparent sort is fixed at the world origin

Where: `equip_fx_batch.gd:52` and `:471`. `BATCH_AABB` is centred on (0, 0, 0), so Godot sorts
every batch draw as an object at the frame's origin. That is Jangan's middle, or, under
`-single-frame`, a point 28,800-170,880 units from the far towns. Effects drawn with `blend_mix`
are then ordered wrongly against other transparent objects. The effects that add are unaffected.
This is the same as r764.md OPEN 5.

**Fix.** Each frame, move a custom AABB or the MMI's transform to the camera or to the hosts'
centroid. It costs one `instance_set_custom_aabb` per draw.

### F8 (LOW): #3A joins a page from its first group, not from the previous group

Where: `World3D.gd:17842`. A page takes the groups received within 3 s of its first group. That is
enough on a LAN: one window is one `SendFrames`, and the socket is drained every frame
(`_read_during_group` -> `_drain`).

A window whose delivery spreads past 3 s still splits into two pages, for example about 1 MB over
an uplink slower than 3 Mbit/s (INFERRED). A gap rule would hold on such a link and still split
batches sent seconds apart: join when `rx - previous_group_rx <= PAGE_JOIN_MSEC`.

The other cases the question raised are covered:

- the held group ends are counted, and reset with `_held_packets` everywhere (`net_client.gd:514`,
  `:659`, `:750`);
- the clock is monotonic (`Time.get_ticks_msec`);
- a reconnect builds a new `PacketReader`, so the stamps start over;
- a zone change is a barrier, and `_reset_pages` clears the pages;
- no page can wait for ever: the 20 s deadline is still counted from `opened_ms`, the read time.

One minor point: `_held_groups` also counts a held despawn 0x3018, which can delay a reveal by a
frame or two.

### F9 (LOW): the regressions are partly avoidable

**EquipFx main thread, 1.69 -> 2.19 ms (MEASURED, `Q516.log` against `V764b.log`, `base` split):**

| | v0.1.516 | r764 |
|---|---|---|
| `fx_batch` | – | 0.41 |
| `fx_masters` | 0.70 (36 stepped a frame) | 0.91 (50) |
| `fx_effects` | 0.71 | 0.07 (no dressed bodies' world simulations: #1) |
| the rest of `fx_driver` (the scan and the cycle) | 0.28 | 0.80 |

**What can be avoided:**

- `step()` polls every kind, every batch and four layout textures every frame. Making it run only
  on a master step, a host change or a CrowdGpu version bump would save most of the 0.41 ms.
- A master whose kind has no holder still uploads its own MultiMesh at each step, through
  `apply_draws` or `_update_draws`. Skip that upload.
- Do not place hosts or rebuild tables for ghosts whose page is held, since the shader draws nothing
  for them.
- Fix F2: its overshoot falls in the reveal window.
- The extra 0.52 ms in the scan and cycle is not attributed by the round's split. It needs a timer
  before it can be cut.

**The reveal slowdown.** On a frame the main thread sets, every millisecond EquipFx adds comes out
of the crowd budget (`aim - own`), so the reveal slows in proportion. The user's "only faster" rule
is not met on the box. I count it as LOW only because the user's frame is set by the GPU, where
F5's rule applies.

### F10 (LOW): the particle texture can grow past the texture size limit

Where: `equip_fx_batch.gd:413-414`. `width = max(1 + widest*5, width*2)` has no upper bound. Above
3,276 particles on one draw node, the width passes 16,384 and the texture is not created. That is
not reached today: 3,083 particles are alive across all masters. Clamp it, or use more rows per
node.

## The questions asked, answered

- **Compatibility (MEASURED, GL Compatibility on Mesa radeonsi, OpenGL 4.6 core, 1,000 ghosts,
  `crowd_run.sh` with `--rendering-method gl_compatibility --rendering-driver opengl3`).** It
  compiles and draws, with 0 `SCRIPT ERROR` and no shader errors. `fxab` measures the batch against
  the holders, the noise floor and no effects:

  | render thread | d(A,B) batch vs holders | d(A,A2) noise | d(A,C) none |
  |---|---|---|---|
  | `safe` | 4,286 px | 18,863 px | 21,656 px |
  | separate | 11,381 px | 21,249 px | 27,037 px |

  The batch draws the holders' pixels; the native library was present.
  - One separate-thread boot crashed at world load, before any crowd: `FATAL: Index p_index = 0 is
    out of bounds`, then signal 4. The base `438035a9` crashed the same way in the same setup
    (MEASURED), so this is **already there, not this round's**, and it needs its own ticket.
  - The fallback without the library is the round's own `NO_NATIVE` run: 270 suites, 0 failing. An
    older library without `draw_rows` / `draw_buffer` gets empty buffers: the counts are drawn but
    every vertex collapses, so nothing is visible and nothing is wrong on screen (READ).
- **Shader placement.** It composes the same frame as `EquipFx.place`:
  - `fxb_bone` and the ghost's own frame and row arithmetic match `crowd_gpu_vertex.gdshaderinc`
    line for line (READ);
  - `cpu_hold` matches the holder to 3.9e-6 (the round's test);
  - `fxab` matches on pixels, under Forward+ (the round) and under Compatibility (here).
  - A Volume variant's bone factor is not applied, but the holders' `ghost_item_frame` does not
    apply it either (READ), so the two agree.
- **#1, no idle dressing.** I found nothing a dressed body shows that a ghost loses:
  - a ghost carries its name plate, click body, circle shadow, clip sounds, glow rows and
    particles;
  - Detail's shadow casters (`CharacterBlobs.on_cast` -> `_crowd_wake_node` -> `_dress_ghost_now`),
    effects, berserk, auras, hits, casts and sitting still dress a body;
  - the 16 nearest bodies are no longer posed on the CPU, which rounds 747 and 756's parity probes
    cover.

  Two differences remain (READ):
  - a ghost's particles show at full strength at the reveal while its body fades in over 2 s, and
    vanish when its fade-out starts. Retail's glow is gated on full alpha; its particles are OPEN;
  - the dressed body's holder path keeps its camera dependence (F1).

  Near range is not visibly worse (INFERRED from the parity probes; I did not measure it again).
- **#2.** It cannot starve, and it cannot spike more than one body's cost past the budget. It can
  overshoot the aim by the main-thread work hidden in `wait` (F5).

## Gates re-run

- `go test -count=1 ./internal/session/ ./internal/worldmap/`: **ok** (session 178 s);
  `go vet ./internal/session/`: clean.
- `remote_godot.sh check`: **checked 707 scripts and 9 scenes, ALL LOAD**.
- `crowd_ghost_test`, `packet_reader_test`, `net_group_hold_test`, `world_test`, `other_crowd_test`
  and `efp_native_test`: **ALL PASS** each.
- The Compatibility boots and the F2 probe are described above. The probe's print was only in the
  box copy, which was synced back from the worktree afterwards.
- `PERF_LANE=r764rev perf_gate.sh --base 438035a9 --head b0381a13 --sites jangan --frames 40000`:
  **exit 0, every number SAME**.

  | | base | head |
  |---|---|---|
  | frame (ms) | 0.75 | 0.74 |
  | entry (ms) | 8,436 | 8,291 |
  | freeze (ms) | 2,676 | 2,644 |
  | hitches | 5 | 5 |

  The first attempt, without `--frames`, logged a base run with no numbers. The gate's views have
  no crowd, so they cannot see F2, F5 or F9.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
