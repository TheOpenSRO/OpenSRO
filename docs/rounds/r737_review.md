# Round 737 review: crowd scale lane C (players in the 3 x 3 blocks, retail spawns, encode once, coalesced writes)

This is an independent adversarial review of `911ecb69..67f8c27b`, in a detached worktree at `67f8c27b`. No code was
changed. The probes written for this review were kept out of the commit:

- `session/zz_review737_entryrace_test.go`;
- `session/zz_review737_10k_test.go`;
- `gateway/zz_review737_linger_test.go`.

The bodies of the two that carry findings are quoted where they are used.

Labels: MEASURED, READ, COMPUTED, INFERRED.

## Verdict: do not ship yet

Three things break play for real players on the public server, and one gate is now flaky:

- **F1:** any archer or crossbow user makes a whole block's players invisible.
- **F2:** with the monster AI on, which it is on the test server, other players' blows land on your own HP bar and can
  "kill" you.
- **F3:** a player who walks into view while you log in or change zone stays invisible, or frozen, until somebody
  crosses a block line.
- **F4:** `TestTheQueueLimitBoundsAGrowingQueueNotOneBatch` now fails intermittently.

All four have small, local fixes (below).

The retail layouts themselves hold up. Every field sampled matches both binaries except the ammunition plus byte
(F1).

## Gates

- `cd server && go build ./... && go test -count=1 -p 1 ./...`: **68 packages ok, exit 0** (MEASURED).
- **`-race`** on `session`, `world`, `gateway`, `pcspawn` and `npcspawn`:
  - `world`, `pcspawn` and `npcspawn`: ok.
  - `gateway`: **FAIL**, `TestTheQueueLimitBoundsAGrowingQueueNotOneBatch` (F4). The race detector reported no data race.
  - `session`: the default 10-minute timeout expired under `-race`. It is being re-run with `-timeout 90m`; the result is
    in the hand-back message, not in this file.
- The box (`RENDER_DIR=/opt/opensro-client-r737rev`, `GODOT_LOCK=/var/tmp/r737rev/lock`):
  - `remote_godot.sh check`: `checked 645 scripts and 9 scenes`, `ALL LOAD`.
  - `remote_godot.sh tests`: **`ran 245 suite(s), 0 failing`**.

## Findings, most severe first

### F1 BUG (HIGH): an equipped arrow or bolt shifts the spawn record by one byte, so every player in that block disappears

**Where.** `server/internal/session/pcrecord.go:160` writes a plus byte for every item in equip slots 0..8:
`pcspawn.Item{..., HasPlus: true}`. The comment at `:150-152`, and `docs/protocol/pc_spawn.md` row 8 and its note, say
every item there is TypeID 3/1. That is false.

**Ammunition is worn in slot 7.** `server/internal/equipment/rules.go:221-224` (`SlotFor`) puts TypeID 3/3/4 in
`SlotShield`, as the engine's resolver does. A bow user equips arrows to shoot.

**Retail writes and reads the plus only for 3/1** (READ, the RE subagent's pass on the box):

- The server's `CInstanceItem::vslot_010` `0x42e230` in mode 2 writes the u8 only for 3/1. A 3/3/4 item matches none of
  `FUN_0042fe10` / `0042fe50` / `0042fdc0`, so only its u32 goes out.
- The client reads the u8 only when `(w&2)==0 && (w&0x1c)==0xc && (w&0x60)==0x20`, i.e. 3/1 (`0x9de370..0x9de385`).

**OpenSRO's two sides disagree.** OpenSRO's own client follows retail: `client/scripts/net/user_spawn.gd:73-77`
`has_plus` is true for 3/1 only. So the server writes one byte the client does not read.

**What players see.**

- A 0x3015 for that player is dropped with a warning.
- A group (`read_group`, `user_spawn.gd:242-245`) fails as a whole: "record i of n". So **every player in that 320-unit
  block is invisible to every viewer** while one of them wears arrows.
- A retail client would misread the record the same way.

**No test covers it.** `user_spawn_test.gd` and `pcspawn`'s fixture have no ammunition.

**Fix.** Set `HasPlus` from the item table (TypeID1 == 3 && TypeID2 == 1) through the `spawnItemRefs` lookup
`jobStateOf` already uses. Keep "unknown item: true", which matches the client. Correct the comment and `pc_spawn.md`
row 8, and add an ammo-in-slot-7 case to the Go fixture and to `user_spawn_test.gd`.

### F2 REGRESSION (HIGH with the monster AI on, as the public server runs): a monster's blow on another player is drawn as a blow on you

**Where.** `client/scripts/world/monster_strikes.gd:181` (`is_own_unpaired`), called from `World3D.gd:19685`.

**The rule rests on a premise that is no longer true.** It decides "this blow is mine" by elimination: the target is
not in `_other_bodies`. Its premise (class comment, `:49-53`) is "the server tells this client of every other player in
its zone". Since this round, a client holds bodies only for its own block ±1.

**Who receives a strike push.** Strike pushes go to the watchers of the *monster's* cell ±1 (`monsterAI.deliver`,
`monsterai.go:2079`; `monsterWatchers`, `aoi.go:570`).

**How it goes wrong.** A viewer in block 3 watches a monster in block 4 that is hitting a player in block 5.

- The viewer gets the push.
- It holds no body for the target.
- It runs `_show_own_strike`: its HP bar takes the stranger's HP, and the struck clip plays on its own character.
- If the stranger died, it enters the dead state: input locked, Revive offered, while the server has it alive.

This is READ from both sides' code and was not run live. The arithmetic of the two windows makes it routine wherever
players fight near a block line, or with ranged attacks.

**Fix.** In `is_own_unpaired`, when `NetClient.own_character_id >= 0` (OpSelfID is sent at every entry since round
616), return `target_id == own_id`. Keep the elimination only as the fallback when no id has been told. Add a test with
a push for an undrawn id that is not one's own.

### F3 RACE (HIGH, MEASURED): a player who comes into view during your world entry or zone change is never spawned to you, or left as a frozen ghost

**Where.**

- `server/internal/session/world.go:1480`: `hub.Enter` files the arriver.
- `:1537`: `arrivePlayer`, which is the first place the arriver's `playerView` exists (`playerview.go:378`).
- In between: the heading store read, the result's encode and send, and `forgetNPCWindow`.

**What goes wrong.** A player Q who crosses into the arriver's window in that gap:

- runs `crossPlayer` → `spawnPlayerToOthers(Q, [arriver])`;
- finds no view, so it builds a throwaway one (`playerview.go:262-266`) and sends the 0x3015 **before
  OpEnterWorldResult**, recording it nowhere;
- the client discards it at the result (`net_client.gd` `_start_user_view` clears `_pending_spawns` and `user_roster`).

`arrivePlayer` then spawns only the `others` snapshot taken at `hub.Enter`, which lacks Q. From then on, every move,
motion and buff of Q's is dropped by `sendIfKnown`, while Q's own view holds the arriver. The hub has them in view of
each other, so nothing repairs it until one of them crosses a block line.

**Zone changes.** `warpTo` has the same gap between `hub.ChangeZone` (`world.go:1606`) and `arrivePlayer` (`:1657`):
`savePosition`, the result send, `departPlayer` and `endBerserk`. Here the crossing finds the mover's **old** view and
records Q in it, and `startPlayerView` then throws that view away.

- If that 0x3015 landed after the result, Q is drawn (`_arrival_entries`) but unknown to the server. Q is never moved
  or despawned: a frozen ghost until the next zone change.
- If it landed before the result, Q is invisible.

**The probe** (MEASURED, `TestReview737EntryRace`):

1. Bram in the world, then teleported 5000 units away.
2. Aria logs in at the spawn.
3. `enterWorldBeforeResultHook` relocates Bram back through `hub.Relocate` + `afterRelocate`, exactly as `handleMove`
   does.

Result:

```
Aria's frame 0: 0x0024      (Bram's move, before her result)
Aria's frame 1: 0x3015      (Bram's spawn, before her result -- the client drops it)
Aria's frame 2: 0x0021      (OpEnterWorldResult)
hub: in view; Aria's view holds Bram=false; Bram's view holds Aria=true
```

In a town with players walking at 20 moves a second this is a per-login probability, not a corner case: the gap holds a
store read and a send.

**Fix.**

- In `arrivePlayer`, after `startPlayerView`, take the window from the hub now (`hub.ViewOfCharacter`) under the new
  view's lock, rather than the `Enter` / `ChangeZone` snapshot.
- In `warpTo`, `forgetPlayerView` at the hub change, so the gap has no view.
- Make a session that is in the hub with no view hear **no** player spawns and despawns in production. The "no view
  hears everything" rule exists for the unit tests and the benchmark, which can give themselves views, as the crowd
  harness already does.

**The tests could not catch this.** `deadWorldFixture.read` now steps over every spawn and despawn opcode
(`readPastSpawns`, `playerspawn737_helpers_test.go:163`), so the revive, recall, teleport and zone tests no longer fail
on a missing or duplicate spawn.

### F4 REGRESSION (gate): the queue-limit test flakes since the one-write drain

**Where.** `server/internal/gateway/sendqueue662r_test.go:82`, `TestTheQueueLimitBoundsAGrowingQueueNotOneBatch`.

**Measured:**

| | flake rate |
|---|---|
| base `911ecb69`, `-race -count=20` | 0 / 20 |
| head, `-race -count=20` | **14 / 20** fail |
| head, `-count=50` | **2 / 50** fail |

**Why.** The 98 KB batch is now one `Write`, which returns only after the reader has drained enough of it. So the test's
next `Send` races the writer's `inFlight = len(buf)` (`gateway.go:485`): `pending + size > limit` (`:390`) stalls the
session.

**Production.** This is the same accounting as before, a whole drain counting until its write returns. The new thing is
that a single write now spans the client's read, so the test's assumption broke. The full-suite gate passed once by luck.

**Fix.**

- **The test:** wait for `inFlight == 0` (or `flush`) before the follow-up Send.
- **Or the writer:** write a big drain in bounded slices (for example 64 KB) and decrement `inFlight` as each lands.
  That also gives the queue limit a truer picture of a slow client.

### F5 REGRESSION (MEDIUM): players sitting at a zone-change or teleport destination are drawn standing

**Where.** `net_client.gd` `_user_spawned` (`:1084-1090`) emits `entity_entered` and then a SIT `state_changed`.

**What goes wrong.**

1. During a zone change's load (`_arrival_pending`), `World3D._on_entity_entered` (`:15602-15606`) only files the
   snapshot.
2. The SIT reaches `_on_state_changed` with no body and is classified "unknown" and dropped.
3. `_replace_others_for_arrival` then lays out with `result.seated == []`.

The world entry is fine, because it appends to `res.seated`. Outside a load, a sitter coming into view now plays the
sit-down clip instead of appearing seated (cosmetic).

**Fix.** While World3D's arrival is pending, keep the motion with `_arrival_entries` and apply it in
`_replace_others_for_arrival`. Or have NetClient append to the pending result's `seated`.

### F6 REGRESSION (MEDIUM): "X entered the zone." / "X left the zone." on every block crossing

**Where.** `World3D.gd:15605`, `:15610`, `:15813`, via `_log_system`, which writes to the system log and the chat.

**What changed.** Before, these lines fired on zone entry and exit only. Now every 0x3015, every member of a group spawn
and every 0x3016 logs one. Walking through a busy town, or arriving in one, floods the chat. At the crowd target it also
costs a RichTextLabel append per player. So do the per-spawn `print`s in `net_client.gd` and `_note_other_pluses`.

**Fix.** Drop the log for view changes (retail prints nothing for them), or keep it for real zone arrivals only.

### F7 REGRESSION (LOW-MEDIUM): other players' abnormal states vanish after any view change

**Where.** `World3D._on_entity_left` (`:15788`) erases `_abnormal_states`.

**What changed.** Player statuses are still broadcast zone-wide (`status.go:793`), but are never replayed with a spawn:
`buffStateFrames` (`playerview.go:490`) covers buffs only. A stunned or poisoned player who walks out of view and back
shows no state until the next change. Before this round, a body was never despawned within a zone.

**Fix.** Append the character's `ObjectStatus` to the spawn's `after` frames.

### F8 PERF (MEDIUM, INFERRED for SQL): store reads under a viewer's lock block other players' read loops

**Where.**

- `spawnPlayersTo` (`playerview.go:195-237`) holds the viewer's view lock while `playerRecord` makes two store reads per
  spawned player: `bodyOf` → `chars.GetByID`, and `equippedItems`.
- In production both stores are Postgres. A town arrival or a crossing into a crowd is hundreds of queries under one
  lock.
- Every other player's goroutine that sends to that viewer (`sendIfKnown`, a move's fan-out) blocks behind it, so one
  arrival stalls the read loops of the movers around it.

**Why the bench hides it.** The crowd bench uses memory stores. Measured at 10k in-memory: a town arrival takes
**67 ms** of `enterOwned` under that lock.

**Fix.**

- Build the records before taking the lock: read the hub and stores, then lock, re-check `Sees` and `held`, and send.
- Add the per-character look cache r737 lists as OPEN, invalidated by the equipment broadcast.

### F9 PERF / MINOR (MEASURED): the 2 ms linger adds 2.1 ms to every isolated reply

`gateway.go:466-471` sleeps `SendCoalesce` whenever the writer wakes to under 4 KB. Every attack result, click reply
and handshake step is under 4 KB. Measured queue-to-write latency (`TestReview737LingerLatency`):

| | p50 | p99 |
|---|---|---|
| linger 0 | 1.3 µs | 16 µs |
| linger 2 ms | **2.118 ms** | 2.131 ms |

That is small against a WAN round trip. But it is paid on every request/response, and (F11) it batches nothing at
realistic per-client rates. Shutdown, close and stall during the sleep were checked by reading the code and are handled:
`closing` is re-read, and `stalled` drops the queue.

**Fix.**

- Linger only when the previous write was within the last few ms (a stream is running).
- Or flush on a server tick (F11).
- Or let request replies bypass the linger.

### F10 MINOR (pre-existing semantics, now claimed handled): a reconnect's late leave despawns the live character

**Where.** `WorldDisconnectHandler` → `departPlayer(left, remaining)` (`world.go` disconnect, `playerview.go:387`).

**What goes wrong.** A reconnect whose old session leaves after the new one entered has the old session's leave send
0x3016 for the character id, which is live on the new session. Observers drop the body, and their known sets drop it
too, so the live character stays invisible until a crossing.

The old OpEntityLeft did the same. But r737's note says the arrival's `again` 0x3015 handles the race, and it only
handles the opposite order.

**Fix.** In `departPlayer`, skip the despawn when `hub.EntityByCharacterID(gone.CharacterID)` is in the world on another
session.

### F11 PERF: zone-wide paths and one global mutex left on the hot paths

- `bumpPlayerState` takes one process-wide mutex on **every** move (`playerview.go:412`, `:474`). Use a per-character
  atomic in the hub entity, or a `sync.Map` of `*atomic.Uint64`.
- Buff and status paths still iterate the whole zone (and every 0x3015 still looks up a `sync.Map` per entity), which
  under `-single-frame` is the whole world:
  - `skill.go:1400` `startCasterBuffLocked(hub.EntitiesInZone(...))`;
  - `buffs.go:616`;
  - `status.go:664`, `:793`.

  The result is correct but O(world). Switch them to `zoneOf` / `ViewOfCharacter`.

### F12 MINOR (docs and labels)

- `pc_spawn.md` row 8 and its note: the "every item is 3/1" rule is wrong (F1).
- `pc_spawn.md:101`: 0x3015 also carries a u32 (`obj+0x154`) after the spawn type **when the type is 5 or 6**
  (`0x533fe1..0x534009`, READ). It is harmless at OpenSRO's 4, but not recorded.
- `pc_spawn.md:106` says "OpenSRO's client does not read" the spawn type. `user_spawn.gd:222` reads it, and only does
  not use it.
- `pcspawn.Record.JobState`'s zero value is 0, not `JobStateNone` (4). A record built without setting it drops the guild
  block while the client reads one. The only builder sets it today.
- **Party:** party members outside the 3 x 3 can no longer be clicked, healed from the party board, or show buffs and
  portrait, because those go through `_other_bodies` (`World3D.gd:22243-22266`). This is retail's behaviour, but a
  change players will notice.
  - The party invite range (600, `reachTarget`) is wider than the window guarantees. Retail's window is 320-640
    depending on where you stand in your block.
  - The minimap marks and party HP still work: they are server-pushed (`RunPartyUpdates`).

## Item by item

### 1. Retail layouts (READ, the RE subagent on the box)

- **The guild block's condition:** CONFIRMED. The server's `0x4e5d3b` compares slot 71 GetJobState (`chardata+0xf`)
  with 4. The derivation matches on both sides:
  - the server's `0x4e124e`: 4 by default, else slot 8's 3/1/7/1..3 TypeID4;
  - the client's `0x9db8b0` on visual slot 8.

  The guild name (row 29) is read unconditionally (`0x9ddf36`). The block's order and widths match `pcspawn.go:138-148`
  and `user_spawn.gd:168-173`.
- **The storage size:** CONFIRMED. The server writes the count only when the capacity is non-zero
  (`CGPCInventoryOP::FUN_004ba720`). The client always reads it (`0x9de325..0x9de33c`).
- **The item list with pluses:** CONFIRMED for 3/1. **WRONG for ammunition** (F1).
- **The avatar list:** CONFIRMED. Avatar items 3/1/13 and 3/1/14 also carry a plus. OpenSRO sends 0 of them.
- **The framing:** CONFIRMED.
  - **4,052 bytes:** `FUN_00430a20` cuts at `[msg+0x104c] - [msg+0x103e] - 0x20`. `FUN_00471500` sets the header to 6 in
    a 0x1000 buffer, and `AllocMsgForPeer` → `FUN_00937800` writes the `0x2209 {u32, u16}` envelope. That the
    AgentServer strips the envelope stays INFERRED.
  - **Split points:** the cut is at byte offsets, not record boundaries. The client concatenates every 0x3019
    (`0x8ac170` → `0x833380`, uncapped 4 KB pages) and parses at 0x3018 (`0x8ac3d0` → `0x8a6d20`).
  - **One group per block:** the slot-2 loop (`0x534340`) calls `0x533e70` per block, filled by `FUN_00533910` from that
    block's three lists.
  - **The `0x8abfa0` assert:** "FindObjList(wSvr) == NULL", NetProcessInObject.cpp, on a second 0x3017 before the
    0x3018.
  - **OpenSRO:** both its NPC groups (`npcworld.go` `frames`) and its player groups go out in one batch each, so groups
    never interleave in the queue.
  - **Kind 2:** u32 ids. **Count:** u16.
- **Mixed groups are valid retail.** `0x8a6d20` dispatches every record on its RefObjID (`FUN_009c1fa0`). OpenSRO's
  separate NPC and player groups are the disclosed departure, and are legal.

### 2. Regressions (the consumer audit)

- **Pluses at spawn, and round 735's glow:** fine. The record carries `EffectivePlus`, and `to_snapshot` →
  `_note_other_pluses`; 0x3038/0x3039 still agree on slot keys. `visual_slot` 0..8 matches `equipment.Slot` 0..8 one to
  one. Lost: accessories 9..12 (never drawn) and items the client table lacks.
- **Names, berserk, buffs, casts, motion and equipment broadcasts:** fine. Berserk comes back through `body_modes` and
  `_berserk_resync`; buffs follow the spawn.
- **Sitting:** broken at a zone change (F5).
- **Abnormal states:** broken (F7).
- **Guild, stall and PvP:** never in the old snapshot, so not a regression.
- **Party:** see F12.
- **PvP and targeting:** server checks are by name or by hub position and range, so unaffected. The client needs the
  body to click a target, which is now the 3 x 3.
- **Monster blows on others:** F2.
- **Teleport and zone change:** every position changer goes through `afterRelocate` (`handleMove`, `moveBySkill`) or
  `arrivePlayer`. That covers `warpTo` for teleport, recall and the revive at the point. The races are F3, F5 and F10.
- **Reconnect and logout:** the disconnect path calls `forgetPlayerView`, and no path leaves the world without a
  disconnect. See F10.
- **GM:** `/tp` and `/goto` ride the client's relocated OpMove or OpChangeZone, so they are covered. **There is no GM
  invisibility in the codebase**, so nothing new is exposed.
- **Tests weakened rather than migrated:**
  - the gender-of-others and which-slot assertions;
  - `readPastSpawns` in the shared fixture (F3).

### 3. Concurrency

**Lock order.** The order is: view lock → hub RLock, motion `mu`, berserk `mu`, buff books `mu`, the stores, and the
session `outMu`.

- No path takes a view lock while holding the hub lock or one of those.
- The berserk `Turn` and `buffLock` are held *around* sends that take view locks, but nothing under a view lock takes
  `Turn` or `buffLock`.
- No two view locks are ever nested.

So no deadlock was found (READ). `SendFrames` never blocks: a full queue stalls and closes the session instead.

**Races.**

- **F3**, measured.
- **A narrow staleness:** a buff operation computes its recipients before its book change, so a viewer that gained the
  owner between the two and spawned it from the old book misses that one buff (READ).
- **The race detector:** no data race reported in `world` or `gateway`. The `session` run is in the hand-back message.

**Leaks.**

- **Known-set entries:** none found on the crossing, leave and zone paths. Each removal goes through the viewer's lock
  against the hub's truth.
- **`playerViews` and `playerStateVersions`:** cleared on disconnect, which is the only way out of the world.

### 4. The writer linger

- **Latency:** F9.
- **A backed-up queue:** no linger past 4 KB, and the stall handling is unchanged.
- **Close during the sleep:** handled.
- **Throughput:** at realistic per-client rates it does not batch (see the 10k section).

### 5. NPCs and monsters

- **NPC spawning:** server code unchanged; groups are still one batch each.
- **The client:** NPC groups now go through `UserSpawnNet.read_group`, which reads non-player RefObjIDs with the NPC
  reader. `user_spawn_test.gd` covers a mixed group.
- **Small ordering hole:** while player records wait for the item table, NPC 0x3015 singles skip `_pending_spawns` while
  NPC 0x3016s and groups queue behind it. A despawn followed by a respawn of one NPC during loading could end with that
  NPC missing (LOW).
- **Monsters:** unchanged, but see F2.

### 6. Version skew: a v0.1.501 client on this server

COMPUTED: the base's `npc_spawn.gd` reader was ported line for line and run over this round's fixture bytes.

**It does not crash, and it shows no other players.**

- **The result lists** arrive empty, and OpEntityEntered is no longer sent.
- **A 0x3015 for an equipped player** reads "successfully" as an NPC record:
  - its uid is the scale byte (e.g. 0x22), its region 0x026d, and its position denormals;
  - the old `decode_single_spawn` has no trailing-length check.

  Such phantom records are filed in `_npc_records` and never placed (no model for a Figure's RefObjID, and an unloaded
  region). A naked player's record fails on its "buffs" byte instead.
- **Player groups** fail the old `finish()` and are dropped, with one warning each.
- **Moves for unknown ids** are ignored (`_on_entity_moved`, base `World3D.gd:15751`).

The client auto-updates, so this lasts one launch.

## 10,000 players (the added scope)

### Setup

`zz_review737_10k_test.go` is `runCrowd` at N = 10,000:

- the same real `gateway.Server` on loopback, the child-process readers, real `handleMove` and `enterOwned`, and memory
  stores;
- with r736's O(N^2) window-rule count taken out of the timed loop;
- with a `wide` layout added (100 x 100 blocks, about 1 player per block);
- with per-session memory measured.

One move per player per second (OURS, as r736/r737). The workstation is a 16-thread 5950X container, and the child
readers share it.

### Results

All MEASURED:

| layout | in view (avg) | drive | ns / move | server CPU ms per sim-s | wall s per sim-s | per client | total out |
|---|---|---|---|---|---|---|---|
| wide (100 x 100 blocks) | 9 | serial | 13,021 | 995 | 0.13 | 8.8 moves/s | 2.4 MB/s |
| wide | 9 | parallel | 17,164 | 1,143 | 0.17 | | |
| field (10 x 10) | 781 | serial | 934,012 | **70,838** | **9.3** | 777 moves/s | 212 MB/s |
| field | 781 | parallel | 579,265 | 51,407 | 5.8 | | |
| town (3 x 3) | 6,033 | serial, 1 s | 9,167,611 | **690,952** | **91.7** | 5,996 moves/s | 1.6 GB/s |

**The arrival** (`enterOwned`, memory stores):

| layout | `enterOwned` | arriver got | 0x3015s sent to the present | leave |
|---|---|---|---|---|
| wide | 0.19 ms | 26 frames / 2.2 KB (13 in view) | 13 | 0.05 ms |
| field | 5.4-6.5 ms | 57 frames / 131 KB (896 in view) | 896 | 1.4 ms |
| town | **67 ms** | 387 frames / 1.46 MB (10,000 in view) | 10,000 | 20 ms |

**The hub's write lock per move** (`hub.Relocate`, serial, realistic layouts, `BenchmarkReview737HubRelocate`):

| N | wide | field | town |
|---|---|---|---|
| 1,000 | 0.58 µs | 1.95 µs | 7.5 µs |
| 10,000 | 1.36 µs (113 B) | **11.5 µs (10 KB)** | **83.6 µs (77 KB)** |

**Memory per session:**

- The idle gateway session (server side): 5-6 KB heap + 10 KB stack, 2 goroutines. At 10k that is about 160 MB.
- The hub entry + known set: wide 1.2 KB, field **23.9 KB**, town **164.5 KB**. At 10k in a town that is **1.6 GB**;
  the known set is a `map[int64]struct{}` per viewer.
- Not counted: the writer's kept buffer (`writerKeepCap` 64 KB per session, after a large drain). Up to 640 MB at 10k.

**The profile** (field, 10k):

- 56% of CPU in `syscall.Syscall6` (`write`) under `writeLoop`, 73% cumulative.
- The scheduler's park/unpark is most of the rest.
- In wide, 45% of CPU is the write syscall.

### What dominates

- **One write syscall per delivered frame.** The 2 ms linger merges only what arrives within 2 ms. So it batches
  nothing below about 500 frames a second per client, which is every realistic layout in real time. It caps a client at
  about 470 writes a second, not fewer.
  - **Wide:** 88k deliveries a second already cost a whole core at 1 move a second (about 11 µs each).
  - **Walking at the client's real 20 Hz** makes that about 20 cores (INFERRED, linear).
- **The fan-out is N x in-view.** Field at 10k is 7.8M frames a second, and the server cannot keep real time even at 1
  move a second (9.3 s per second). Town is inherently 60M frames a second.
- **The single hub lock.** In field at 20 Hz, 11.5 µs x 200k moves a second is 2.3 s of lock-held time per second, so
  saturated.

### What 10k comfortably would take

1. **C3, move by destination.** Retail sends one 0xB021 per click, not 20 positions a second: about 20x fewer events.
   This is the single biggest lever.
2. **Batch on a tick, not a 2 ms linger.** Flush each session's queue every 25-50 ms (OURS; the AgentServer's own
   batching is OPEN) and skip the linger for request replies (F9). At 20 Hz walking that is about 20 writes a second per
   client instead of one per frame.
3. **Take work out of the hub's write lock.**
   - Compute `Watchers`, `Gained` and `Lost` under a read lock after the write, or keep per-block locks or a sharded hub.
   - Make `bumpPlayerState` per entity (F11).
4. **Shrink the known set.** Track known *blocks* plus per-block exceptions, not every entity. A town viewer then holds 9
   entries, not 6,000.
5. **Cap density.** Even retail's 3 x 3 rule is O(n^2) in one spot. A per-viewer cap (nearest K players, OURS, not READ)
   is the only way a 10k crowd in one town stays playable.
6. **Move store reads out of the view lock, and cache the look** (F8). With Postgres the arrival is otherwise thousands
   of queries.

## Would r737 block a later split across game-server processes?

**No hard block.** The block map, the known sets and the encode-once frames all map naturally onto a per-region shard.
A cross-process crossing can be retail's remove-and-insert, which `warpTo` already models as `departPlayer` plus
`arrivePlayer`.

What hard-wires one process as the only source of truth:

1. **Recipients are local `*gateway.Session` pointers.** `world.Entity.Session`, `MoveResult.Watchers`,
   `playerViews` keyed by the local session id, and every `SendFrames` call all assume an observer is a TCP connection
   in this process.
   - **Shape of a split:** a viewer near a shard edge watches entities owned by another process, so delivery must go
     through a recipient interface (local session | remote shard link).
   - **Cost:** cheapest to introduce now. Every r737 send already funnels through `sendIfKnown` / `sendAboutPlayer` /
     `afterRelocate`.
2. **The known-set correctness argument needs one linearizable hub.** "Check `hub.Sees` under the viewer's lock, and
   every change of truth delivers after it changes" holds only because `Sees` is a synchronous read of one in-memory map.
   - **Shape of a split:** across a boundary the neighbour's state is a replica. Edge visibility needs ghost entities and
     a rule for which shard decides `Sees` for a pair.
   - **Cost:** the more code relies on this synchronous re-check, the more expensive the change.
3. **Process-global singletons.** `playerViews`, `playerStateVersions`, `buffBooks`, `motions`, `spawnItemRefs`, the
   NPC window and the monster AI runtime.
   - **Shape of a split:** fine for one shard per process. They rule out several shards in one process (handy for
     tests).
   - **Cost:** moderate to undo later.
4. **Uid spaces are process-local counters** (pre-existing). Monsters use `combat.Hub.nextID`, ground items
   `grounditem.nextID`, NPCs `UIDBase + index`. Players use the character id's low 32 bits, which is fine with a shared
   database.
   - **Shape of a split:** a client seeing across a boundary sees two processes' id spaces, so each shard needs a
     disjoint uid range.
5. **Directory lookups go through the local hub** (pre-existing). `FindByName` (whisper), `EntityByCharacterID` (party
   position, friends) and `AllEntities` (unique notices) assume everyone online is in this hub.
   - **Shape of a split:** they need a directory service.
   - **Cost:** r737's O(1) maps are the right interface shape for one.

The encode-once `gateway.Frame` helps a split: while no session uses per-session security, its bytes are
forwardable as they are.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
