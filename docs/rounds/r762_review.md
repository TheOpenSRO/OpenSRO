# Round 762 review: a crowd appears together, and leaves without a freeze

Reviewer: an independent adversarial pass over `6809681f` (base dev `886f0473`), in a detached
worktree. I read the code rather than re-measuring it. I made one short confirming boot on the box
(`/opt/opensro-client-r762rev`, the 20-body lineup, described in F1).

Labels: **READ** (our code at `6809681f`), **MEASURED** (the box, this review), **INFERRED**.

## Verdict

**Do not ship as is.** The arrival and departure work holds up: the budget, the held page, the GPU
fade-out and the departure queue are sound. The server change is byte-compatible. But three
player-visible regressions ride along:

- **F1:** other players are never dressed in the background, at any crowd size or machine speed.
- **F2:** buff auras that were active when a player arrived are never drawn.
- **F3:** after a zone change during a held page, every later crowd arrival waits 20 s, for the
  rest of the session.

All three are small fixes (below). F4 and F5 should be fixed or recorded with the user.

Gates (box, `RENDER_DIR=/opt/opensro-client-r762rev`, `GODOT_LOCK=/var/tmp/r762rev/lock`):

- `remote_godot.sh check`: **checked 700 scripts and 9 scenes, ALL LOAD**.
- `remote_godot.sh tests`: **ran 268 suite(s), 0 failing**.
- Server: `go build ./...` and `go vet ./internal/session/` were clean.
- `go test -count=1 ./internal/session/ ./internal/npcspawn/ ./internal/pcspawn/`: **ok** (session 181 s).

## Findings, most severe first

### F1 (High): the background dressing never runs, so no other player shows weapon particles

**Where:** `World3D._dress_room` (`client/scripts/World3D.gd:17330-17338`).

**Why it never runs (READ).** The room is `_frame_p95_usec - _frame_last_usec`. A dressing needs at
least `_dress_avg_usec`, which starts at 9 ms, rises at once to the longest dressing seen, and only
falls after something is dressed. The rule is relative: it asks the last frame to be shorter than
the scene's own p95 by a whole dressing. A steady scene almost never has that spread:

- with vsync on (the player's default; nothing in `project.godot` turns it off), every frame is
  about 16.7 ms, so the room is about 0;
- without vsync, a light scene's p95 less its last frame is a fraction of a millisecond.

A faster machine does not help, contrary to r762.md section 8 ("Faster machines dress them as room
allows").

**Measured on the box.** `crowd_run.sh ... 20 base,base OPENSRO_QA_LINEUP_BUFFS=1`, overlap 0:

- the page was revealed together after 911 ms;
- then over 292,226 frames (about 600 s, mean frame 2.0 ms) `to_dress` stayed at 20, and none of
  the 20 bodies was dressed;
- the probe never left its arrival step (F11), so the run was stopped by hand.

**What a player loses.** Every arrival is a ghost first (`_ghosts_on` and `CrowdGpu.enabled`
default on). A ghost is now dressed only when something forces it: a hit, a cast, sitting, berserk,
being chosen as a Detail shadow caster, or a buff that starts after it arrived. Against a dressed
body, that ghost lacks:

- **EquipFx particles** (glowing equipment's particle effects; 64 nearest weapons within 800):
  missing on every other player at every distance, the one standing next to you included. Retail
  draws them within LOD 0.9, about 720 units (round 761, `FUN_00c43780`). On dev, the background
  dressing reached the whole crowd in seconds to minutes.
- **Auras of the buffs it arrived with:** see F2.
- **Nothing else visible:** the glow is drawn on the GPU, the pixels match (round 756's parity), a
  Detail caster is dressed when it is chosen, and one-shot animations dress the body.

The round's notes scope this as "the box's ghost crowds ... the weapons' particles of the 64
nearest". It is every ghost on every machine.

**Cheapest fix.** Either of these:

- Judge the room against an absolute frame, not the p95. For example: room = max(aim, 16.7 ms)
  less the last frame's work, not its wall time, so a vsync wait counts as room. Then dress
  nearest-first within EquipFx's reach (720), and only ghosts whose kind has particle files
  (`KindPrep.efps` non-empty), at a guaranteed rate of one every `DRESS_EVERY` frames. The cost is
  bounded: at most one 3-34 ms dressing every 30 frames, near bodies only.
- Better, and as round 756's notes proposed: give ghosts EquipFx holders placed from the recipe's
  item bone and the GPU clip frame (`CrowdGpu.item_frame`'s equivalent for a ghost), as round 747
  did for far dressed bodies. No dressing is needed then.

### F2 (High): auras of buffs active at arrival are never drawn

**Where:** `World3D._fx_owner_body` (`World3D.gd:23219`), `_promote_ghost`, `BuildQueue.promote`
(`other_crowd.gd:309`) and the held branch of `_ghost_other` (`World3D.gd:17617`,
`_other_builds.drop`).

**How it happens (READ; the probe cannot see auras, so this is not measured).**

1. The server sends each arriving player's buffs right after the group frames (round 737).
2. A buff start on a body still waiting to be dressed calls `_promote_ghost`. That is a no-op
   unless the id is pending in the dressing queue.
3. But a held ghost is dropped from that queue (`:17617`), and a body that is not a ghost yet is not
   in `_ghost_ids`.
4. At the reveal, activation re-queues the body as background work (`:17771`), which F1 never runs.
5. So `_fx_resync_owner` never runs for it.

Every player in a group spawn shows none of the auras it arrived with, until a hit or cast dresses
it. A buff that starts later still promotes it and works.

**Fix:**

- At activation, `promote` every id that has entries in `_target_buff_book`.
- Make `promote` remember an id that is not pending, so it is urgent when it is queued.

### F3 (High): a zone change during a held page delays every later crowd arrival by 20 s

**Where:** `_replace_others_for_arrival` (`World3D.gd:6180`).

**What is left stale (READ).** The function clears the ghost queue, `_ghost_ids` and the bodies.
It leaves `_page_wait`, `_hold_slot`, `_hold_ids`, `_activate_ids` and `_ghost_queued_ms` as they
were. Nothing removes the stale ids from `_page_wait` afterwards: only `_ghost_other`,
`_dress_other` and `_on_entity_left_now` erase entries, and those bodies are gone.

**What follows.** `_hold_step` reveals a page only when `_page_wait.is_empty()`, or after
`HOLD_MAX_MSEC`. So after one teleport, gate or return scroll during a hold (a cold page holds
5-15 s), every later group spawn in the session:

- stays invisible and unclickable for 20 s, while those players can act on you;
- keeps `_crowd_transition()` true for those 20 s: no budget learning, no dressing.

A stale `_activate_ids` entry whose id re-arrives can also switch on a held body's plate and click
body before its page shows.

**Fix:**

- Reset all of the hold state in `_replace_others_for_arrival`, and close or reveal the old slot.
- Defensively, drop `_page_wait` ids with no live holder when a page is revealed by deadline.

### F4 (Medium): departures starve behind arrivals

**Where:** `_process` runs `_pump_other_builds()` (`World3D.gd:16311`) and only then
`_depart_step()` (`:16313`). Within `_pump_other_builds`, the ghosts take
`cap_usec = FrameBudget.left()`.

**How it starves (READ; INFERRED for a live crossing).**

- `_on_entity_left` queues a departure whenever `left() <= 0` (`:18682`).
- `_depart_step`'s budget is then clamped to 0, so it does one departure a frame (`:21712`).
- A block crossing sends lost and gained blocks in one batch (`playerview.go:624-626`). In a dense
  area, the departed players then stay for the whole arrival, up to one leaving a frame. They stay
  drawn, with plates, clickable and on the minimap, and frozen, because no movement comes for them.
- The round measured the walk-in and the walk-out separately, never both at once.

**Fix:**

- Run `_depart_step` before the ghost pump, or give departures a floor (for example 1 ms). A
  departure is about 37 µs (`left_ms` 150 ms over 4,000).

**The remaining departure questions:**

- **Click, target, party, minimap:** a departure waiting in the queue is fully live until it is
  taken, normally under about 1 s. Once it is taken, its click body is off at once (layer 0), its
  target is dropped, its minimap entry and plate go, and the fade runs on the GPU. The party lists
  are the server's, so they are unaffected.
- **Re-arrival while the departure is queued:** handled. `_spawn_or_update_other` takes the queued
  departure first, and the old holder is freed by its own key.
- **Zone change:** `_depart_flush` is correct, apart from F3's hold state.

### F5 (Medium): no other packet is handled while a group is read

**Where:** `NetClient._process` (`net_client.gd:469`) and `_group_step` (`:1293`).

**What happens (READ, with the round's own numbers).** Nothing after a group is dispatched until
every record is read, at `group_step_usec` (half of what is left, at least 300 µs) a frame. Live,
1,469 records took 99-126 frames (0.76-1.0 s); a 4,000-player window would take two to three times
as long. Meanwhile the player's own HP/MP updates, combat results, chat, and other players' and
monsters' movement all wait.

**Fix, either of these:**

- Read the records into the roster in chunks as now, but keep dispatching opcodes that do not name
  a uid still unread.
- Raise the read's floor (for example 2 ms). The record decode is 84 ms per 4,000; the costly part
  is the arrival work, which already has its own queues.

### F6 (Medium-Low): pages can stay held for up to 20 s while groups keep arriving

**Where:** `_arrival_hold_slot` (`World3D.gd:17708`).

**What happens (INFERRED).** Every group arriving while a page is held joins that page. The reveal
waits until `_page_wait` is empty. While running through a dense area, crossings every few seconds
can keep refilling it, so the page is shown only at the 20 s `HOLD_MAX_MSEC`. Held players can
fight but cannot be seen or clicked.

**Fix:** open a new page for groups arriving more than a few seconds after the current one opened.

### F7 (Low): finished fade-outs stay in the fade instances until freed, and the free queue blocks on its head

**What happens (READ).**

- Faded-out bodies stay in their groups' fade instances (vertex work, alpha 0) until
  `_depart_step` frees them. It frees at least one a frame, so nothing starves and memory stays
  bounded under ordinary churn.
- The free queue breaks at its first entry not yet due (`_depart_step`). An AppearFade model
  (`free_hook`, due now: a monster's corpse) can wait behind a player's entry due 1.5 s later.
  Meanwhile it is drawn at its last fade alpha, a few 255ths.

### F8 (Low): the body texture is first made for 4,096 bodies

**Where:** `first_slot_cap` (`crowd_gpu.gd:261`).

**Size (READ, COMPUTED).** The texture is RGBA32F: 4,096 slots x 5 texels x 16 B = **320 KB of
VRAM**, which is nothing.

**The cost.** `_upload` (`:1334`) sends the whole texture whenever any far body changed: 320 KB
copied three times (pack, Image, GPU), even for a single far body (on dev, 20 KB at 256 slots).
Probably 0.1-0.3 ms a frame; not measured, and the perf gate's views have no crowd. Above 4,096
bodies the cap doubles to 8,192 (640 KB): one new texture bound to every twin, a one-off hitch.

**Compatibility.** No half-float issue. The fade now rides in the body texture's fifth texel as a
full float, not in `INSTANCE_CUSTOM.w`, which GLES3 keeps as a half float. The largest value is
about 4e6, under 2^24, with the epoch at 60 s. This closes round 760's OPEN 9 for far fades.

**Optional:** grow to 4,096 only when a group page opens.

### F9 (Low): a material with no fade twin draws held and departed bodies opaque

**Where:** `crowd_gpu.gd:1484`.

**What happens (READ).** For such a material, `crowd_fades` is set to false on the twin, which its
groups share. Its parts of a held body then show before the reveal, and a departed body's parts
stay opaque until the holder is freed, about 1.5 s or later. Such materials are rare.

### F10 (Low): `EXTRAS_DUE_META` is written and never read

**Where:** `World3D.gd:17960`.

**What happens (READ).** A held ghost dressed during its hold skips `_replace_plate_and_click` and
the `CharacterLight` meta reset. Its plate and click body keep the ghost's estimated height.
Cosmetic.

### F11 (Low, QA): the probe never ends its arrival step at 96 bodies or fewer

**Where:** `qa_crowd_probe.gd:308`.

**What happens.** The offline arrival ends when the dressing queue is `settled`, which needs the
`DRESS_NEAREST` cut, so more than 96 bodies. MEASURED: n = 20 was still in its arrival step after
600 s. A `crowd_run.sh` at the README's 20 or 200 never finishes at 20.

## The server change (check 4)

**Byte-compatible:**

- `spawnPlayersTo` and `despawnPlayersFrom` build the same frames with
  `npcspawn.GroupFrames` / `DespawnGroup` and the same 4,052-byte chunks.
- Only the order changed: the records within a group, and the despawn ids, are sorted by
  `uint32(CharacterID)`, and the receiver's cell's group is moved last.
- Retail's client handles each record on its own (READ in r762.md section 2.2), so any order reads.

**Against retail (`0x534340`).** The receiver's own block goes last on a full insert. A crossing's
gained cells cannot include the receiver's own cell, so `ownCellLast` leaves a crossing's order
alone. That matches round 737's crossings, and the session suite passes.

**Coverage.** `TestOwnBlockGoesLast` and `TestGroupRecordsByUniqueID` test the two pure helpers
only. No test drives `spawnPlayersTo` or `despawnPlayersFrom` and decodes the order of the frames
they send. One test with two cells would pin it.

**Client side.** With fifo ghosts, the nearest players (the own block) are read and made last. A
page revealed by deadline (F6, or the cold 20 s) leaves those out first.

## Check 3 (the budget): what can starve

| Work | Least a frame | Starves? |
|---|---|---|
| Background dressing | 0 | **Always (F1)** |
| Departures | 1 | Behind arrivals (F4) |
| Frees after the fade | 1 | No; FIFO head-of-line only (F7) |
| Ghosts | 1 | No |
| Activation | 1 | No |
| NetClient group read | at least 300 µs | No, but blocks every other packet (F5) |
| Plate chunks | one a frame, `REBUILD_WAIT` 20 frames at most | No |
| Bounds (128 groups a frame) | restarts on each growth | A crowd that grows the box faster than every 16 frames (about 2,000 groups) leaves the later groups on old bounds; snapped to 64 units with a 16-unit margin, unlikely (INFERRED) |

Memory under churn stays bounded: frees run at least one a frame, against a few departures a
second in a live crowd. Faded-out bodies hold their slots and holders until freed (F7).

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
