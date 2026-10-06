# Round 749 review: C3, moving by destination

An independent, adversarial review of `81dc69e1` and `c02fe611` on `worktree-agent-abd933d835e4c7be3`,
based on dev `daeb1b0c`. Labels: READ, MEASURED, COMPUTED, INFERRED, REASONED (from the code, not run).
No code was changed; the probes below lived in a scratch worktree and were deleted.

## Verdict

**Do not ship to the public server as it stands.** The retail half is right: the wire layouts, the
gates that exist and the 3 x 3 rule match the decompiles, the Go and Godot gates are green, `-race`
is clean, and the live walk draws well. But the round sells its position bound as "the speed bound"
(`r749.md`, "That is the speed bound"; `destmove.go:58`), and it isn't one. **A client teleports
1,650 units in 8 ms** by streaming stop reports (F1, MEASURED). That isn't a regression, because
before this round every position was trusted. It is still a security claim the code doesn't
deliver, and it is about to go public. F2 (a free recall to the login spot) belongs to the same
bound. Fix F1 and F2 (small, local changes in `destmove.go`) and the rest can ship, with F3-F6
taken now or filed.

## Findings, most severe first

### F1. EXPLOIT: the stop and placement bound has no clock, so unlimited speed and teleport

- **Where**:
  - `server/internal/session/destmove.go:305-311` (`stopAdmits`), `:346-348`
    (`relocationAdmits`);
  - `server/internal/session/world.go:1780-1792` (`handleMove`'s `admit`).
- **Evidence (MEASURED)**, from probe tests on the dead-world fixture with `strictPositions`
  (the production bound, no `-trust-client-positions`):
  - **Idle creep:** 300 OpMove stop reports, each 5.5 further along x, with no 0x7021. In
    **8.2 ms** the server had Aria at **x = 1650.0**. A legitimate run covers 0.4 in that time.
    Each report is measured against where the *previous* report put her (`idleSlack` 6, standing).
  - **Placement creep:** 300 relocated OpMoves of 5.5 each moved her to z = 1650.0 the same way.
  - **Leg hop:** a 0x7021 to a far point, then at once a stop 54 along it. That passes, because
    `Travelled(0) + 50 x 1 s + 5 = 55`. Repeat the pair 15 times and she is at **x = 810 in
    under 0.3 s**. The one-second lead is granted afresh to every leg.
- **Consequences**: every position-gated check reads the hub's position:
  - attack reach;
  - pick-up reach (10);
  - NPC talk range;
  - trade's 320;
  - monster aggro and leash;
  - the saved position.

  A modified client goes anywhere at any speed, then acts from there. Walls don't matter either:
  the creep steps through them, and so does a plain 0x7021 leg that is never stopped (the
  departure the notes disclose).
- **Fix**: give the bound a clock and an anchor.
  - Keep, per character, the last point the server itself fixed (the end of a leg, a correction,
    a named landing) and the time it was fixed.
  - Measure a standing stop or placement from that anchor, not from the last report, and do not
    move the anchor on a report.
  - Better: keep a per-character distance budget of `speed x elapsed`, capped at about 1 s, that
    every admitted stop, placement and leg start draws from. The second's lead is then shared
    across legs instead of granted per leg.
  - Add the three probes above as tests with the trust off.

### F2. EXPLOIT: the world-entry point is a permanent free recall

- **Where**:
  - `destmove.go:373-385` (`noteArrivalLanding`: "no deadline");
  - `:398-414` (`landingAdmits`);
  - `world.go:1510` (called with the *restored saved position* under `-persist-position`).
- **Evidence (READ, and the round's own test)**: `TestRound749ARelocationOnlyThroughTheNamedPoints`
  takes a relocation to an arrival point from anywhere. The arrival set holds the world entry's
  position, which is where the character logged out, plus that zone's spawn spot, until the next
  zone change. So:
  1. log out at a farming spot or a dungeon mouth;
  2. log in and walk to town to sell and repair;
  3. send one relocated OpMove to the login point.

  That is a free, unlimited return scroll with no cast and no item.
- **Fix**:
  - Give the arrival points the GM point's deadline (`landingGrace`, 2 minutes covers the
    landing).
  - Take the zone's spawn spot only after an `/unstuck` the server saw.
  - Or consume a point once it is taken (one landing per arrival, as `noteWarpLanding` does).

### F3. DESYNC: a 0x7021 the server refuses is invisible to the client

- **Where**: `destmove.go:222-276` (every refusal `return nil`);
  `client/scripts/World3D.gd:16215-16221` (the own 0xB021 is ignored);
  `move_order_sync.gd:62-66` ("ended" sends nothing).
- **Evidence (REASONED)**:
  - The client marks the order as sent the moment it writes it (`sent_destination`) and never
    checks that its echo came back. The echo is "a receipt" that the code drops.
  - When the server refuses the move silently, the client walks alone. If it ends within
    `ARRIVE_SLACK` of the point, nothing is ever sent. The server, the observers, and every range
    check keep the character where it stood, until a later stop is refused and the player snaps
    back.
  - Refusals an honest client can hit:
    - the end of a sit or stand transition, which the client times from its own key press and
      the server from the request's arrival (a click that lands just as the client unlocks);
    - the 5.0 gate at its edge (F5);
    - a stun, freeze or root: those the client does not refuse.
  - Retail's client avoids this. Its own 0xB021 flag 1 snaps it to the source (`movement.md`,
    "The client treats its own 0xB021 like anyone else's"). This round drops that and doesn't
    list it among the departures.
- **Second form**: a correction (0xB023 to the mover) that crosses a 0x7021 already in flight.
  1. The client snaps to P and clears its order (`_apply_own_correction`).
  2. The server takes the in-flight order from P and runs that leg.
  3. The client stands at P while the server and the window walk the player to the old click,
     and nothing reconciles them.
- **Fix**: any one of these.
  - On a refusal other than the 5.0 gate, answer the mover alone with 0xB023 (OURS). Its client
    then snaps back at once instead of drifting.
  - Have the client hold its order as unconfirmed until its echo arrives, and send a stop from
    where it stands if none comes within about 1 s.
  - For the crossing correction: after `_apply_own_correction`, send a stop at P, which is on
    the in-flight leg at along 0 and so admitted.

### F4. DEPARTURE: READ gates OpenSRO has the state for, still not applied

- **Where**: `destmove.go:222-264`.
- **Evidence (READ)**, from `GObjPC::FUN_004b0ea0` (re-read this review) and `movement.md`'s list:
  - **stun, freeze, sleep or root** (abnormal bits `0xc1 | 0x4000`, `test al,0xc1` at `0x4b0fa6`).
    OpenSRO holds players' states (`status.go` `pcs`; `statuseffect.Holder.CanMove`, whose own
    comment cites this handler), but the handler only consults a monster's. A stunned or frozen
    player walks.
  - **an accepted trade** (interaction state 2). OpenSRO has it (`trade.go`).

  Retail also stops a mover when a state lands (vslot `0x570`, sending 0xB023), and OpenSRO's
  server leg runs on through a stun. The notes say the handler applies "the READ gates OpenSRO has
  the state for". These two exist, so that sentence is wrong.
- **Fix**: refuse on `!pcs[id].CanMove()` and in an accepted trade. Halt a running leg when a
  stopping state lands on a player (`haltForSit` already does the window's half).

### F5. DESYNC (minor): the client's 5.0 rule and the server's disagree at the edge

- **Where**: `move_order_sync.gd:60` against `world/mover.go:248`.
- **Evidence (REASONED)**:
  - The client sends when the *untruncated* target is `>= 5.0` from the truncated point it sent.
    The server refuses when the *truncated* new point is `<= 5.0` from its own (READ: the
    `(a<b) != (a==b)` idiom at `0x48c35f`, x and z only).
  - A re-aim measured at 5.3 can arrive as 4.6. The server refuses, and the client believes the
    leg moved (F3's silence).
  - A click within 5 of the walk's point is walked by the client and not sent. It ends up to
    5 + 2.39 + 1.42 = 8.8 from the server's point, while the standing bound is `idleSlack` 6.
    Its stop is then corrected: a 6-9 unit snap.
- **Fix**:
  - On the client, compare truncated points and send at `> 5.0 + 1.5`.
  - On the server, make `idleSlack` at least 9, or measure an arrived leg's stop against the leg
    (`Along` still works on an arrived leg).

### F6. DESYNC (minor): a click just beyond a wall puts the body behind the wall for everyone else

- **Where**: `move_order_sync.gd:62-66` ("ended" when within `ARRIVE_SLACK` 3.0 of the sent
  point).
- **Evidence (MEASURED, live, two clients, the production bound)**, Jangan's dragon pedestal:
  - In run `wall1`, A walked south from (42, 120) to (42, -60). The walk was blocked at
    **z = 6.562** (`NAV: the walk is blocked at local 1002.00, 953.44`). A reported the stop. B
    heard 0xB023 at exactly (42.000, 6.562) and snapped from 0.94 short of it. No correction.
    That case is right.
  - In run `wall2`, A clicked (42, 4.6), about 2 past that face. The 0x7021 went out truncated to
    (42, 5.0). A's walk ended by its stop distance at **(42, 6.665)** (`left=2.065`), *before* the
    wall. Nothing was sent, since the end lay within 3.0.
  - **The server and B kept A at (42.000, 5.000), on the far side of the face at 6.562.** B's last
    sample is `MOVE body 2 ... pos=(42.000,5.000)`, held until the run ended 40 s later.
  - The general case: any click that lands within about 3 units beyond a wall (fence, door frame,
    pedestal, building) leaves the server's position, and every observer's drawing, up to 3 units
    inside or behind it. A blocked end within 3.0 does the same.
  - Retail's server steps its own mover with collision and would stop it at the face.
- **Fix**: before reporting "ended", probe the nav graph along the segment from the client's
  position to the sent point (`step_tracked` with no slide). If it is blocked, send the stop. Also
  report every blocked end, whatever its distance.
- **Seen in passing (not this round's)**: A's first leg, from (42, -60) to (42, 120), walked
  *through* the pedestal northward, while the same pedestal blocks southward at 6.562. That is an
  asymmetric outline in the client's nav step. The server agreed with the client, so it caused no
  desync, but the world lane should look at it.

### F7. PERF: the mover pass holds the hub's write lock for 21% of the time in a 10,000 field

- **Where**: `world/mover.go:313-334`, `:206-231`.
- **Evidence (MEASURED)**, with a probe of `AdvanceMovers` alone, every player walking at 50, 40
  passes:

  | players | blocks | mean lock per pass | worst | share of wall time | crossings per pass |
  |---|---|---|---|---|---|
  | 1,000 | 10 x 10 | 0.73 ms | 1.16 ms | 0.3 % | 48 |
  | 10,000 | 10 x 10 | **53.4 ms** | **78.1 ms** | **21.3 %** | 491 |
  | 10,000 | 100 x 100 | 2.70 ms | 4.61 ms | 1.1 % | 494 |

  Every hub reader (the monster AI, every handler's `EntityBySession`) waits behind it. For each
  crossing, the pass builds `Gained`, `Lost` *and* a full `Watchers` list under the lock.
  `afterRelocate(..., nil)` never reads `Watchers`. It also takes the buff books' mutex once per
  mover per pass.
- **Fix**:
  - Skip `Watchers` in the pass.
  - Collect the crossings under the lock, then build `Gained` and `Lost` under `RLock` (or from
    the stored cells after the swap).
  - Read speeds before taking the lock.

  Not blocking at today's populations: 1,000 costs 0.3 %.

### F8. PERF / EXPLOIT (pre-existing): no rate limit on 0x7021

- **Where**: `destmove.go:222`.
- **Evidence**:
  - Retail has none (READ).
  - The 5.0 gate only refuses near-identical points. Alternating two far points is accepted
    every time, and each acceptance is a hub write plus one 0xB021 to every player in the window.
  - At round 749's own bench figure for a 1,000 town (606 us of server CPU per move, serial), a
    client sending 2,000 a second costs about 1.2 cores and puts about 2 million packets a second
    on other players' sockets (COMPUTED).
  - OpMove had the same amplification before. The honest client sends at most one 0x7021 per
    click, or per 5 units of a re-aim.
- **Fix**: a per-session token bucket (for example 10 a second, burst 20) that drops the excess.

### F9. WRONG-LABEL

- `r749.md:79` and `destmove.go:58`: "That is the speed bound". It is not (F1).
- `r749.md:76`, `:131` and `move_order_sync.gd:31` say the standing bound is 8. The code's
  `idleSlack` is **6** (`destmove.go:91`).
- `buffs.go:498`: "The server does not police movement speed ... no speed or distance check
  exists". This is now stale.

### F10. MINOR

- **Version skew, an older client** (REASONED):
  - Its stream is accepted only while each 20 Hz step stays within 6. One frame hitch of about
    120 ms or more makes a step that is refused. The correction is a 0xB023 the old client
    cannot read, and every later step is measured from the stuck point. So **after one hitch the
    old client is frozen on the server for the rest of the session**.
  - Its record reader also errors on a walking player's record ("a destination in a player
    record") and drops that spawn.
  - Both last one launch (auto-update), but say so in the skew section.
- **A lag spike over about 1 s**: the 0x7021 and the following stop arrive together. The stop
  lies more than 55 ahead of a leg that just started, so it is corrected: a rubber-band of the
  spike's length.
- **A heading run has no end on the server**. A client that dies, or a stale session of a
  reconnect, keeps a body running across the map until the session closes. It spawns and
  despawns for everyone it passes, and saves a position off the world.
- **Height**: stops and placements take any Y, and the leg interpolates Y in a straight line.
  Trade, NPC talk and the party board use 3-D distance. The harm is mostly to the player
  themself, but a saved Y can be anywhere.
- **Coverage**:
  - The whole `session` suite runs with `-trust-client-positions` on (`main_test.go`). Trade,
    pick-up, combat and party never meet the production bound.
  - Only `destmove749_test.go`'s few tests do, and none of them stresses it (F1's probes would
    have failed).

## The checks that held

### 1. Retail layouts and gates

The decompiles were re-read on the box this review.

- **0x7021 forms**: `proto.DecodeMovement` takes:
  - the field destination as three signed i16;
  - a dungeon as three i32;
  - the heading form as `00 | command | u16`.

  The client's `encode_destination` truncates as `ftol` does. Correct.
- **3 x 3**: `CGObjMoverByDest::FUN_0048c2d0` compares each region byte to the mover's current
  region within plus or minus 1. `regionsAdjacent` matches.
- **5.0**: `CGObjMoverByDest::vslot_004` at `0x48c35f`:
  - `fild`s the stored destination's x, z (`+4`, `+0xc`) against the new one's;
  - compares with `0xb45b28` using `<=`;
  - applies only while slot `0x4c0` (moving) answers.

  `StartMove` matches. One difference: retail compares raw region-local ints *ignoring the region
  word*, where OpenSRO compares world points. That only differs across a region line, so it is
  immaterial.
- **0xB021**: per the handler, the layout is uid, the movement, flag, then source region,
  x * 10 u16, y f32, z * 10 u16. The handler sends it through `FUN_00484d90` (the 3 x 3, the mover
  included) and sets WALK/RUN. `encodeMoveEcho` matches.
- **The handler also calls `FUN_005a16c0(+0x28c, 1, 0)`** (the move-ended buffs; disclosed as
  OPEN) and `FUN_004e0c60` (chardata `+0x13`).
- **0xB023** (`0x4a9430` disassembled):
  - It is sent only when slot `0x4c0` (moving) answers and `send` is not 0. A PC with slot
    `0x540` set (riding) sends none.
  - It writes `push 0xb023`, the uid (4 bytes, obj `+8`), then `FUN_00487c80`: 2 bytes of region
    (obj `+0x84`) and 0xe bytes, which are x, y, z f32 from `+0x88` and the u16 angle at `+0xc`.
  - The angle is computed from the facing vector (`+0x24`, `+0x2c`), not from the caller's
    argument.
  - It then sets WALK (2) or RUN (3) to STAND.

  `encodeMoveStop` (20 bytes) matches. The facing is `e.Heading`.

### 2. Box items.csv versus prod

- **Box (MEASURED)**: `/opt/sro-files/client/items.csv` has **52 columns**. Range is CSV field 60
  (`refdata/csv.go:331`). The box's server therefore reads every weapon's Range as 0, which
  explains the live run's "too far" at 19 against a reach of 21 + 2.
- **Prod** reads items from PostgreSQL (`items.attack_range`, `refdata/sqlstore.go:78`), imported
  from the export. `deploy/README.md` required items re-exports at 72 columns (round 632) and
  73 columns (round 728), both past field 60. So prod has Range *if those steps were run*
  (INFERRED; prod was not touched).
- **Check on opensro-01**: `SELECT count(*) FROM items WHERE attack_range > 0;` must answer more
  than 0.
- Not a movement fault: the stop put the server exactly where the client stood.

### 3. The local walk against the server's leg

The client does not path-find. A click walk is a straight no-slide step on the nav graph, at
exactly `_move_speed` horizontally (`_move_on_nav_graph`), ending at the first wall. So the
"walk around a building" case is a series of straight legs, each ending in a stop report on its
own leg (lateral 0.2 or less). It agrees with the server's straight line.

The cases where they part are F3, F5 and F6, plus off-graph `move_and_slide`, which can slide
for one tick.

### 4. Others' walking

- `OtherWalk` steps at the told run speed:
  - the record's param 24;
  - every buff packet's runSpeed (GM `/speed` included, through `sendSpeed`'s OpBuffEnd to the
    zone).
- It cuts at the point and resolves height under the monsters' budget.
- It takes the source only past 32.
- The observer's body walks into a wall for about one transit before the 0xB023 (disclosed).

### 5. The local player

- Attack, cast, sit and pick-up all `_flush_position` first.
- Death halts the leg (`markDead -> haltForSit`).
- A zone change and a revive go through `ChangeZone`, which drops the leg (`removeLocked`
  deletes `moving`).
- A skill move (`Relocate -> StopAt`) ends the leg.
- A reconnect makes a fresh entity.
- No rubber-band was seen in the live runs.

### 6. Regressions

- **Party**: position and HP are sampled from the hub (`party.go:556`, `partyPosition`), and so
  follow the leg. Nothing read the removed OpEntityMoved.
- **The minimap**: draws bodies.
- **Monsters**: read `EntitiesInZone` and `ViewOfCharacter`, which are leg positions.
- **PvP**: reach is measured from the hub.
- **The crossing deliveries** re-check `hub.Sees` under the viewer lock (`playerview.go:401`). So
  the pass goroutine and the session goroutine refiling one mover cannot leave a ghost spawn.

### 7. Concurrency

The pass takes the hub lock, then the buff books' lock. The buff package never calls back into
the hub, so there is no inversion.

## Gates (this review, on `c02fe611`)

- **Live, two clients**:
  - **Setup**: this commit's server built to `/var/tmp/r749rev/srv`, in memory, with no
    `-trust-client-positions`. The client was `/opt/opensro-client-r749rev`, run with round 749's
    own `run_live.sh` harness under the shared lock while the box was quiet. Both runs were
    `exit 0`, with no `SCRIPT ERROR` and no `MOVE correction` in either log.
  - **wall1**: a wall stop was taken and relayed exactly (F6, first case).
  - **wall2**: the body was held behind the wall (F6).
  - **Attack after a walk**: round 749's own `live3` shows it landing from the reported stop.
    This review did not repeat it: the town has no monsters within reach of the harness's spawn.

- `cd server && go build ./... && go vet ./...`: **exit 0**.
- `go test -count=1 -p 1 ./...`: **69 packages ok, 0 failing**, exit 0.
- `go test -count=1 -race ./internal/world/ ./internal/gateway/`: **ok**.
- `go test -count=1 -race -timeout 90m ./internal/session/`: **ok in 999.9 s**, no data race.
- Box (`RENDER_DIR=/opt/opensro-client-r749rev`, own lock):
  - `remote_godot.sh check`: **ALL LOAD, 667 scripts, 9 scenes**;
  - `remote_godot.sh tests`: **ran 255 suite(s), 0 failing**.
- Probes (scratch worktree, deleted): `TestReview749IdleCreep`, `RelocateCreep`, `LegHop`,
  `HeadingRunsForever`, and `world`'s `TestReview749PassLockHold` (F1, F7, F10).

## Fix verification (honest play)

A second verifier checked the fixes `2fc6770b..1d06b4ab` for the opposite failure: **honest players
the new bound refuses or snaps back**. Labels as above. Code is unchanged; the scenarios are tests
in `server/internal/session/destmove749v_test.go` (separate commit), all run **without**
`-trust-client-positions`. Each models the client as `World3D` + `MoveOrderSync` behave at
`1d06b4ab`:

- it walks a click at once;
- it reports a stop when the walk ends short, when a sky run ends, and when no echo has come
  within 1.5 s;
- it answers **every** own 0xB023 the same way (`_apply_own_correction`, READ, `World3D.gd`
  16365-16382): it snaps to the correction's (x, z), takes the terrain's height there
  (`_terrain_hit_height`, the terrain-only ray), and **sends a stop from it**.

The `TestR749vFP*` tests log the false positive and fail only under `OPENSRO_R749V_FP=1`, so the
suite stays green until the fixes land. Once they do, drop the gate.

### Verdict

**Ship after FP1 (with FP2 and FP3, one fix), FP4 and FP5.** Each is a few lines. FP6 should come
before a public test too; the minor items can be filed.

The latency handling itself is sound. The cause of every serious false positive is the
**claim height bound** (`claimHeight` 100) checked against heights the server only guesses:

- a leg's straight line;
- a sky run's start height;
- an arrival's `spawnPos.Y` 0, while the client stands bodies in a frame shifted by its grid anchor.

Combined with the client's unconditional answer to a correction, one refused claim becomes **an
endless correction loop at the round trip**:

- the player is pinned;
- the mover and every watcher get a 0xB023 per round trip (MEASURED: 25 of 25 corrections
  answered in a row in each of FP1-FP3; the cap was the test's. LIVE at Hotan: 6,758
  corrections in 112.6 s, 60 a second).

### False positives found

**FP1 (SEVERE). After a teleport or zone change to Hotan, Samarkand or Donwhang, production's
`-full-map` pins the player.**

- **The server's height.** Production runs `-full-map=true`, which forces `-single-frame` (READ,
  the prod override, line 45). The server lands every arrival at `spawnPos.Y` = 0
  (`arrival`, `teleportArrival`).
- **The client's height.** The client stands the body on its ground, at the raw `.m` height less
  its grid anchor: block 0, vertex 8 of the frame region
  (`MapmTerrainBuilder.near_row_middle_height`, `_frame_anchor_height`). Under `-single-frame`
  that frame is Jangan's for every town, with an anchor of -2.5.
- **The client tells the server nothing.** A teleport arrival calls `_move_sync.placed()` only
  (`_land_teleport_arrival`); a zone change only lifts Y. So no placement reaches the named
  point.
- **MEASURED** (the user's `Map.pk2`, all 124 field teleport points of `teleportdata.csv`; the
  sampler agrees with the rows' own retail Y at the field gates, which checks the axes). The client's ground
  against the server's 0, single frame:

  | Arrival | Client's ground vs the server's 0 |
  |---|---|
  | Hotan landing | **+246.3** |
  | Samarkand landing | **+182.5** |
  | Donwhang landing | -104.1 |
  | GATE_KT (Hotan) | +234.6 |
  | GATE_CA (Samarkand) | +182.5 |
  | GATE_WC (Donwhang) | -104.3 |
  | All 124 field teleport points | **53 more than 100 off** |

  In each town's own frame (`-single-frame` off), 45 of the 124 are more than 100 off, among them
  the Jangan ferries (-336, -255).
- **What the player gets** (`TestR749vFP1ArrivalHeightLoop`, a real `/goto hotan` zone change on a
  `-single-frame` fixture):
  1. A click 40 east is **not echoed**. The destination bound refuses
     |246 - 0| > 100 + 40, so every click within 146 of the landing is silently dropped.
  2. The client's no-echo stop is corrected.
  3. Each of **25 of 25** honest answers to a correction is corrected again.
- **Control:** the same spot claimed at the server's height 0 is taken, so the cause is the height
  bound.
- **The loop does not end on its own.** A click more than 146 away is taken, but the correction
  already in flight cancels it, and the stop from the leg's start is refused on height again. A
  relog restores the saved height 0 and loops again.
- **Return points:** a designated return point in those towns (revive option 1) lands the same way.
- **LIVE, confirmed** (`/var/tmp/r749v/run_fp.sh`, client C):
  - **Setup:** this branch's server (`-single-frame`, in memory, no trust) and client
    (`/opt/opensro-client-r749v`), headless at real time under the shared lock. Bram (GM) ran
    `/goto hotan`.
  - **The height:** the client stood him at **246.31**. The server had 0.00, as computed above.
  - **The first click** (40 east, tick 3600): no echo; `MOVE unconfirmed` after 1,500 ms.
  - **The loop:** a stop, then `MOVE correction: the server has this player at (-63360.00, 0.00,
    9600.00), the client at (-63321.73, 246.31, 9600.00)`, and then **6,758 corrections** in
    112.6 s (ms 77,340 -> 189,986). That is one per client physics tick, **60 a second**, to the
    end of the run.
  - **The second click** (40 south, tick 4500) was sent and cancelled by the next correction in
    the same tick.
  - No `SCRIPT ERROR`.

**FP2 (SEVERE, same loop). A sky run keeps its start height** (`Mover.At` heading branch:
`Y: m.Src.Y`).

- **MEASURED** on real terrain, the share of straight runs whose end lies more than 100 from the
  start height:

  | Run | Within 4 regions of Jangan | All 4,360 regions with relief |
  |---|---|---|
  | 300 units | 12 % | 29 % |
  | 1,000 units | 30 % | 49 % |
  | 100 units | -- | 12 % |

  Hotan's own centre region, run +x from local (60, 960) to (360, 960): 117.8 -> 243.6.
- `TestR749vFP2SkyRunHeight`: a 6 s run rising 125.8 has its end **corrected**, and 25 of 25
  answers are corrected again.
- The same happens at `HeadingRunLimit`: its 0xB023 reaches the mover, which answers it.

**FP3 (SEVERE, same loop). A destination leg's height is the straight line between its ends.**

- **MEASURED**, Jangan's fields: 99/168, leg (1500, 120) -> (1800, 120). The ends are at 45.1 and
  -23.7; the middle is at 146.3, **135.6 above the line**.
- **MEASURED**, share of honest mid-leg stops more than 100 off the line:

  | Leg | All regions with relief | Around Jangan |
  |---|---|---|
  | 200 units | 1.1 % | 0.7 % |
  | 400 units | 5.6 % | 2.0 % |

- `TestR749vFP3LegMiddleHeight`: a wall or approach stop there is **corrected**, then 25 of 25
  again.
- A stun mid-leg (`haltForState` sends 0xB023 to the mover) on such a spot loops the same way. On
  flat ground it ends after one exchange (`TestR749vHonestStunHaltEnds`, passes).

**Fix for FP1-FP3, three independent pieces. Any one of the first two ends the loop.**

- **(a) Client:** `_apply_own_correction` answers with a stop only when a 0x7021 may be in flight,
  that is, when it sent one since the last echo or placement. Never answer the same server point
  twice.
- **(b) Server:** do not refuse a claim on height while the reference height is a guess.
  - Either measure the height against the last height the **client** gave (a destination, a taken
    claim), with `claimHeight` plus the ground distance from that point, as the 0x7021 check
    already does;
  - or keep only an absolute sanity range (MEASURED: raw heights reach 4,056 at
    GATE_RC_MOUNTAIN_GATE).
  - The 0x7021 destination check needs the same rule.
- **(c) Client:** a teleport or zone-change arrival sends its placement (relocated, with its ground
  height). The arrival's named point takes it once, so `Trusted.Y` becomes the client's ground.

**FP4 (MODERATE). An uplink stall of about 1.2 s or more while walking snaps the player back.**

- The client stops a walk with no echo at `ECHO_TIMEOUT_MS` 1.5 s, 75 units at the base speed.
- The click and that stop then reach the server together (TCP keeps the order), so the leg has
  travelled about 0.
- The bound takes `claimSlack` 9 plus the allowance, at most 1 s of run (50), which is 59.

`TestR749vFP4LagSpikes` (a warmed-up character that stood 2 s; MEASURED, the lead is the client's
distance ahead of the server's leg):

| Case | Lead | Result |
|---|---|---|
| Steady 150 ms | 0.0 | taken |
| Jitter (300 ms click, 50 ms stop) | 12.5 | taken |
| 1.0 s spike | 45.0 | taken |
| 1.2 s spike | 55.0 | taken |
| 1.6 s spike | 75.0 | **corrected** |
| 3 s spike | 75.0 | **corrected** |

- Under a steady latency the server's leg starts exactly where the client turned, so redirects
  cost nothing (COMPUTED, and `TestR749vHonestChaseUnderJitter` passes).
- **LIVE, confirmed** (`/var/tmp/r749v/run_lag.sh`, run `live2`):
  - **Setup:** the same server (own frame), with Aria's link through a scratch proxy. The proxy
    holds the uplink 1.6 s from every second 0x7021, so the click and everything behind it reach
    the server together. Downlink is immediate; the base delay is 50 ms. Clicks alternate
    between (42, -60) and (342, -60), 8 s apart.
  - **Both held clicks** went `MOVE unconfirmed` at 1,500 ms, about 76 units into the walk:
    stopped at 264.51 from 340.3, and at 119.49 from 43.7.
  - **Both were corrected:** `the server has this player at (342.00, ...) the client at (264.51,
    ...)` and `(42.00, ...)` / `(119.49, ...)`. The player snapped back 77.5 units each time.
  - **The answering stop** was taken each time (flat ground, no loop).
  - The on-time clicks were clean. No `SCRIPT ERROR`.
- **Fix:** make `AllowanceSeconds` at least the echo timeout plus a margin (2.0 takes 109), or
  lower `ECHO_TIMEOUT_MS` to 1.0 s. Either way the bound stays a speed bound.

**FP5 (MODERATE). The first walk after a world entry or zone change banks nothing, however long
the player stood.**

- `Hub.Enter` leaves `allowSpeed` 0. `ChangeZone` copies the old one, which is 0 if the player
  never moved.
- `StartMove` brings the allowance up to date (`settleLocked` -> `accrueLocked`) **before** it
  sets `allowSpeed` (READ, `mover.go` 268-285). So the standing time is credited at speed 0.
- `Claim` sets `allowSpeed` before it accrues, so a claim is not affected.
- `TestR749vFP5FirstWalkAfterEntryBanksNothing`: after 10 s standing, a 0.5 s spike on the first
  walk (20 ahead) is **corrected**.
- **Fix:** in `StartMove`, `if e.allowSpeed == 0 { e.allowSpeed = o.Speed }` before
  `settleLocked`, as `Claim` already does.

**FP6 (MODERATE, the question asked). `/unstuck` after the 2-minute grace is corrected back into
the spot the player was stuck in** (`TestR749vFP6UnstuckAfterGrace`).

- The hint shown at every login says "Stuck in a wall or building? Type /unstuck". The server has
  no navmesh, so a client wedged by its own walk has no way out but a teleport, a GM, or a relog.
- **Not acceptable for a public test without a server-side path.** Either a server `/unstuck`
  that names the zone's landing (or LandingSpot), taken once per few minutes, or reword the hint.
- A town-centre recall on a cooldown is benign. F2's concern was the *logout spot* as a free
  recall, which this would not restore.

**Minor (file):**

- **The client does not gate its own clicks** on states it knows: a stun from OpObjectStatus, or
  an established trade.
  - The server refuses such a click silently, as retail does, but OpenSRO's client walks it for
    1.5 s and reports. A click more than 59 away snaps back.
  - Aside on the exploit side: `handleMove` (claims) checks neither `characterCanMove` nor the
    trade, so a stunned or trading client can still move up to 9 plus its allowance by stop
    reports (REASONED).
- **A correction grounds by the terrain-only ray.** A correction on a bridge or a building's upper
  floor drops the body onto the terrain beneath. If that is more than 100 down, FP1's loop
  follows. Not measured.
- **A downlink-only delay over 1.5 s** stops the walk at 1.5 s. The stop is taken, but the player
  must click again.
- **`MoveOrderSync.arrived()` leaves `pending_ms` set**, so a late echo after a short walk sends
  one extra stop at the destination. It is harmless.

### Honest scenarios that held

| Scenario | Evidence |
|---|---|
| Steady latency, jitter, spikes up to about 1.2 s | `TestR749vFP4LagSpikes` (above) |
| A chase with four re-aims under 100-400 ms jittered uplink | `TestR749vHonestChaseUnderJitter`: the approach stop is taken |
| The click bucket | `TestR749vHonestBucketChase`: 23 a second for 10 s loses none; a 4 s stall of 15 re-aims a second (60) delivered at once loses none. A stall longer than 4 s at the fastest roster monster would drop the newest re-aims; the client then stops (minor) |
| A speed buff mid-walk, re-based 250 ms late, heard 100 ms late | `TestR749vHonestSpeedBuffMidWalk`: taken (3.75 ahead) |
| A stun halt on flat ground | `TestR749vHonestStunHaltEnds`: one exchange |
| Ghost Walk with a click in flight | `TestR749vHonestGhostWalkWithClickInFlight`: taken |
| A long walk across a region line | `TestR749vHonestRegionCrossing`: taken, refiled |
| The sit/stand transition | REASONED: the client's lock starts when its answer arrives, so it ends no earlier than the server's CHANGEMOTION; a click cannot reach the server inside it (`SitState.answer`, `motion.go`) |
| Walk/run toggle, mounts or COS, knockback | Do not exist: no code in client or server; a held mouse button sends nothing more (`World3D.gd` 775) |
| Death and resurrection | Moves are dropped while dead. Revive at the Jangan return point lands within 52 of the server's height (MEASURED: client -51.9 at the landing). A return point in Hotan or Samarkand is FP1 |
| The frozen lake (round 744) | REASONED: the ice's collision quads are on the terrain layer (`World3D.gd` 3873), so a click, a correction's grounding and the leg's destination heights all read the ice (802 in the single frame), not the lakebed. No height disagreement arises there unless FP2 or FP3's geometry does |
| A reconnect mid-walk | A fresh entity: Trusted is the saved spot, named once. Its first walk is FP5 |

### Gates (this verification, on `1d06b4ab` + the test commit)

- `go vet ./internal/session/`: clean.
- `go test -count=1 -run TestR749v ./internal/session/`: **ok**. With `OPENSRO_R749V_FP=1`, the
  six FP tests fail as recorded above (MEASURED).
- **Terrain measurements:** scratch Go tools over `/opt/sro-files/client/Map.pk2` on the box
  (built from this tree's `mapm` and `pk2` readers, not committed):
  - the deviation census of random legs and runs;
  - the client height at the 124 field teleport points;
  - concrete examples.
- **Live runs:** the shared lock was taken when no other Godot ran. Godot ran only on the box.
  `live` and `live2` are kept under `/var/tmp/r749v/`. The first run's client A spawned at
  (0, -1380) without a `/tp` and was walled in (no measurement), so A was rerun with `/tp 42 -60`
  as `live2`.
