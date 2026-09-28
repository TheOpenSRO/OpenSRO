# Buffs, self-casts and Ghost Walk: the server (round 616)

What srrevamp's server does with a skill that needs no monster, where each rule came from, and
the wire contract rounds 617 (client cast), 618 (buff bar) and 619 (effects) build against.

Labels: **READ** from `SR_GameServer.exe` (dump `/var/tmp/decomp_server` on the RE box) at the
address given; **MEASURED** from the retail archives on the RE box; **INFERRED** with the
reasoning given; **OURS** a design choice; **OPEN** not established.

## The wire (srrevamp's own opcodes)

`0x00F5`..`0x00F9` were free when this round began: the highest session opcode in use was
`OpTeleportResult 0x00F4`, and no file under `server/` or `client/scripts/` defined any of them
(re-measured by grep; the only textual hits were unrelated struct offsets such as `+0xf8`).

All little-endian, in srrevamp's own encoders (`session/wire.go`: a string is u16 length + bytes).

| opcode | direction | payload | retail analogue |
|---|---|---|---|
| `OpUseSkill 0x0072` (extended) | C→S | `{name, i64 skillId, i64 targetMonsterId, u8 targetType, [targetType 2: f32 x, f32 y, f32 z]}` — targetType 0 none/self, 1 entity, 2 ground. **A request without the suffix decodes as targetType 1.** Any other targetType, or a ground point cut short, is a malformed request. | 0x7074 kind 4 |
| `OpAttackResult` (extended) | S→C, the requester | the existing payload, then a trailing `u8 targetType`: a skill reply echoes the request's 0, 1 or 2 (an old-format request: 1); a plain swing, a keep-up repeat, a duel blow and a monster-initiated result carry 1. A 42-byte result from an older server decodes as 1 | — |
| `OpBuffStart 0x00F5` | S→C, every session in the owner's zone | `{i64 ownerId, i64 skillId, u32 token, i64 durationMs, i64 remainingMs, u32 runSpeed, u8 ownerKind}` — 41 bytes; `ownerKind` 0 a character, 1 a monster (monster ids from `combat.Hub` and character ids from the database overlap; every buff is a character's today); a 40-byte payload decodes as a character; `durationMs`/`remainingMs` are −1 for a buff with no `dura`; `runSpeed` is the owner's new run speed when this buff wrote to it, else 0 (unchanged) | 0xB0BD |
| `OpBuffEnd 0x00F6` | S→C, the owner's zone | `{i64 ownerId, u8 count, count × u32 token, u32 runSpeed, u8 ownerKind}` — `ownerKind` as in `OpBuffStart`, optional to a decoder; `runSpeed` the owner's new run speed when an ended buff had written to it, else 0 | 0xB072 |
| `OpBuffCancel 0x00F7` | C→S | `{name, i64 skillId, u32 token}` — token 0 cancels the first record of that skill, as retail matches any record for a zero token. **No reply**: success is the `OpBuffEnd` broadcast; a refusal is silent, as retail's is | 0x7074 kind 5 |
| `OpSkillMove 0x00F8` | S→C, the caster's zone, the caster included | `{i64 characterId, i64 skillId, f32 x, f32 y, f32 z}` — where the ground cast put the caster | the 0xB070 result with a position (INFERRED) |
| `OpSelfID 0x00F9` | S→C, the entering session only | `{i64 characterId}` — the entering client's own character id, the id `OpBuffStart`/`OpBuffEnd` carry as `ownerId` and `OpSkillMove` as `characterId`. Sent once per `OpEnterWorld` (a reconnect included), after `OpEnterWorldResult` and the `OpEntityEntered` broadcasts, before the in-view buffs. Added to the contract during round 616 at the coordinator's request; `0x00F9` was free (the same grep) | not looked for (OURS) |

The token is a server-wide u32 counter that never yields 0 (OURS).

**Auto-attack and a self-cast (READ).** A cast of any kind still ends a running auto-attack
(`keepUp.Cancel`), a buff and Ghost Walk included: retail sends every cast as a 0x7074 kind-4
action, `Push` (`0x4ad630`) queues it behind a keep-up in phase 3, and the keep-up ends itself on
seeing the queue at depth 2 (`auto_command.md`). No self-buff hands the swings back: the kind-3,
Target_Required-0 class rows carry AutoAttackType 0 (987) or 2 (72), never 1 (MEASURED). A client keys icons and auras by
`(ownerId, token)`.

Order on a cast (revised in the review): the broadcasts go first -- `OpBuffEnd` for a record the
recast rule ended, then `OpBuffStart`; or `OpSkillMove` -- and then the `OpAttackResult`
answering `OpUseSkill`, so a buff or move that cannot be done after the costs were taken (the
session left the world in between) hands the HP and MP back and answers `"the skill could not be
used"` instead (the re-use timer stays armed; disclosed). OURS.

**Consistency (review).** Every book operation and the packets it sends run under a per-owner
lock (`session.buffLock`), and each packet's `runSpeed` is the speed that one operation left,
computed under the book's own lock (`buff.Speed`): the owner's speed when the operation changed
it, else 0. A recast's `OpBuffEnd` and `OpBuffStart` carry the same value, so neither can undo
the other. A cast holds the owner's lock from the recast check to the start, so a check that
passes cannot be overturned after the costs.

**Identity (review).** A cast or a cancel must name the character this session has in the world;
otherwise it is refused (`"not in world"`) before anything is spent -- the costs and the buff or
move land on one character.

**Coordinates (review).** A ground point, or an `OpMove`, with a NaN or an infinity in it is
refused (the cast, before any cost) or dropped (the move).

**Entering view** (OURS; whether retail re-sends is OPEN): after `OpEnterWorldResult` and after a
zone change, the arriving session is sent an `OpBuffStart` for every active buff of everyone in
its zone, its own included, and everyone already there is sent the arriving character's. A record
that writes the run speed carries its owner's current speed; the others carry 0. A logout sends
nothing extra: `OpEntityLeft` takes the owner's buffs with it.

## The data: skill CSV columns 47..61

`cmd/export-refdata -mode skills` appends, a strict suffix (an older CSV loads every one as 0 --
an instant action, no buff, no ground move, no marker):

| col | name | source |
|---|---|---|
| 47 | ActionKind | the first raw Param word, `CRefSkill+0x168` (skilldata column 68) |
| 48 | TargetRequired | `+0x94`, column 22 |
| 49 | TargetLand | `+0x96`, column 24 |
| 50-52 | TargetSelf / Ally / Party | `+0x98`/`+0x99`/`+0x9a`, columns 26-28 |
| 53 | DuraMs | `dura` value[0] (`+0x280`) |
| 54-57 | Cbuf / Nbuf / Bbuf / Lnks | the runs `cbuf` `+0x358`, `nbuf` `+0x35c`, `bbuf` `+0x360`, `lnks` `+0x370` present |
| 58-59 | Tele0 / Tele1 | `tele` value[0], value[1] (`+0x2ec`) |
| 60 | BuffParams | every run whose code publishes a ParamKeeper param (`skillparam.Contributions`), `code:v0,v1;...` |
| 61 | Lks2 | the `lks2` marker (`+0x374`) present -- added in the review, for the recast rule; 160 retail rows, all kind 3 |

The Param block is walked (`skillparam.Walk`), never scanned.

**MEASURED on the retail Media.pk2 (33,698 exported rows, the index order of `skilldata.txt`):**

- `SKILL_CH_LIGHTNING_GYEONGGONG_A_01` (id 113): kind 3, TR 0, dura 355462, `hste:20`.
- `SKILL_CH_LIGHTNING_GYEONGGONG_B_01` (id 114): kind 0, TR 1, Land 1, tele 500, 100.
- `SKILL_CH_WATER_HEAL_A_01` (id 149): TR 1, Self/Ally/Party 1.
- `SKILL_CH_COLD_GIGONGTA_A_01` (id 90): kind 3, dura 15000.
- Census: kind 0 21,727 / 1 8,840 / 3 2,348 / 4 783; `dura` on 2,198 rows (2,195 of them kind 3);
  153 kind-3 rows carry no `dura` (toggles and summons); `cbuf` 473, `nbuf` 285, `bbuf` 226,
  `lnks` 308; `tele` on 19 rows, every one kind 0 with TR 1 and Land 1 (the Ghost Walks); Land
  on 26. Publishing runs: `dru` 651, `defp` 314, `tant` 293, `ru` 138, `hr` 129, `onff` 116, `odar`
  91, `reat` 70, `hpi` 69, `apau` 64, `hste` 60, `hide` 48, ... `hst3` 29, `hst2` 11.

**srrevamp-01**: the VM's `skills` table is imported from this CSV. Re-run `export-refdata -mode
skills` with the new binary, then the new `import-refdata` (its store adds the fifteen columns
before it writes the rows), then restart the server. Until then every skill loads kind 0 and no
buff starts. `deploy/README.md` has the steps and a check query.

## What a cast does

`session.useSkillHandler`, after the existing gates (known, weapon, cooldown):

1. **A caster buff** — `ActionKind == 3` and either `TargetRequired == 0` or one of
   Self/Ally/Party set:
   - refused `"The selected item cannot be used together or the skill is already in use."`
     (0x300c `UIIT_SKILL_USE_FAIL_OVERLAP`'s text, MEASURED in `textuisystem.txt`) when the recast
     rule below refuses, **before anything is spent** — the gate precedes EngageSkill;
   - no reach test, no blow: SkillAction_Buff (`0x5830b0`) resolves none when it engages. An
     imbue's `att` acts on the caster's later blows — **OPEN, not modelled**;
   - costs, cooldown and the group timer as before; then the record starts and the zone hears it.
   - Target_Required 0: the targets are the caster (INFERRED, spec §2.2: no `efr`).
     Target_Required 1 with a friendly group: whom retail picks with nothing friendly selected is
     **OPEN**; srrevamp puts it on the caster.
   - Target_Required 1 with only hostile groups (Water Cancel, the Warlock DOTs — a debuff on the
     target): **not modelled**, the path is unchanged.
2. **A targetType 0 cast** that is neither a caster buff nor a ground cast applies to the caster
   and **ignores the monster field** (the reply's `MonsterID` is 0):
   - retail's skill tick clears the action context's target vector for a Target_Required 0 row
     (`0x4ae6f0`, `auto_command.md`), and the targets then come from the row's `efr` collector
     around the caster (READ, `skill_params.md`); srrevamp builds no collector (OPEN), so such a
     row resolves **no blow**: the 23 class rows of that shape carrying `att` are
     `SKILL_EU_BARD_BATTLAA_EXPLOSION_A/B` (`efr` kind 1, radius 80, five targets, 35 % falloff —
     MEASURED). Its costs are paid, and a self-heal row heals as before;
   - a Target_Required 1 row with no friendly group needs a hostile target and is **refused**
     (`"select a target first"`, OURS text) before anything is spent; a friendly one lands on the
     caster, as the buffs do;
   - an **imbue** (kind 3 with `att`, e.g. Ice River Force) is a caster buff whatever targetType it
     is sent with: SkillAction_Buff resolves no blow when it engages, and its `att` acts on the
     caster's later blows (OPEN, not modelled).
3. **A ground cast** — the row carries `tele`:
   - it needs targetType 2 and `TargetLand`; anything else is refused (`groundRefusal`, OURS text).
     READ: FUN_005862e0 returns 0 when the context's position list is empty and the builder aborts;
   - a seated character in the sit/stand transition is refused, as a move is;
   - after the costs the caster moves (below).

### The recast rule (READ; corrected in the review)

`Skill_CheckUseConditions` (`0x58d8f0`) row 16 (`0x58e2fd`), under mask bit 2:

- a row with **no `lnks`** (`+0x370 == 0`) and **Target_Required 0** calls
  `FUN_0059d870(book, skill, caster)`; a 0 answer is `0x300c`;
- a row **with `lnks`** instead calls `FUN_0059dc80(0)` -- only when it also carries `efr`
  (`+0x294`) -- which walks the self-cast records carrying an attached object (`ctx+0x68`) and
  compares `lnks` values, skill ids, `lks2` and the attached object's id (answers `0x300c`,
  `0x3029`, `0x3037`). srrevamp keeps no attached objects, so **an `lnks` row gets no overlap check
  (OPEN)**;
- a Target_Required 1 row without `lnks` gets **no check at all** at this gate, and srrevamp gives it
  none: a recast adds a second record rather than ending the first (the review withdrew round 616's
  OURS extension of the rule to these rows). Whether retail limits them elsewhere is OPEN.

`FUN_0059d870`, for an action-kind-3 skill (not a kind-1 `msch`), walks the book's active records
and, for each whose skill is kind 3 (`+0x168 == 3`) without `cbuf` (`+0x358 == 0`), in order:

- if both skills carry `dttp` (`+0x424`) with the same value[0]: the same caster may stack; a
  record the owner cast on itself is passed over; otherwise a lower value[1] is refused and a
  higher one ends the old record -- **not modelled (OPEN)**: srrevamp does not export `dttp`, and
  for its 36 retail rows (`SKILL_CH_FIRE_DESCRY_*`) applies the GroupID branch instead;
- a field at `+0x290` (no code maps to it) opens another branch -- **not modelled (OPEN)**;
- the GroupID branch, **modelled**: the new row carries no `lks2` (`+0x374`), the active record is
  not an `lnks` record its owner cast on itself (`old+0x370 == 0 || ctx+0x20 != 1`), the new GroupID
  (`+0x8`) is non-zero and equal to the active one's. Then `new.Basic_Level (+0x64) <
  old.Basic_Level` refuses; otherwise the old record's `+0x10` is cleared -- it ends on the next
  book update -- and the cast proceeds. The first matching record decides.

Falling off the list, the function tests the row's Action_Overlap bytes (`+0x8c`) and `ovl2`
(`+0x37c`) against the character's state bits and its running action (`FUN_0059db10`) -- **not
modelled (OPEN)**.

srrevamp: `buff.Books.CheckOverlap` / `Start` (`overlapLocked`). A Grass Walk recast refreshes it.
That the old record leaves before the new one engages, and that `OpBuffEnd` precedes
`OpBuffStart`, is **INFERRED** (retail clears the old record's flag at the gate and its book update
ends it; the relative order of that and the new record's engage was not read). The book is walked
in insertion order, INFERRED to be retail's list order.

### The run speed (READ, and one MEASURED base)

- `ApplySkillParamsToChar` (`0x594ac0`), the speed holder `pc+0xc24` (`param_1[0x309]`):
  - `hste` (`+0x2b8`): **if the holder is empty** it writes value[0] into params 23 and 24 at slot 2
    keyed by the record; either way the record becomes the holder;
  - `hst2` (`+0x2bc`), on a row without `hste` (implemented in the review): the holder's own 23/24
    contributions are removed (`Param_RefreshContributions` `0x4b3570` -> `FUN_004b31a0` ->
    `FUN_004b2e00`, which erases the entry keyed by the holder), value[0] is written into 23 and 24
    at slot 2, and the record becomes the holder only if there was none;
  - `hst3` (`+0x2c0`), on a row with neither: value[0] into 23 and 24 at slot 2, no holder.
- `SkillAction_BuffEnd` (`0x5829d0`): an `hste` row's end runs `book[0x7d] = 0` -- the book is
  `pc+0xa30` (int index `0x28c`), so that is `pc+0xc24`: the holder empties. An `hst2` row's end
  empties the holder when the record IS the holder, and otherwise writes the holder's `hste`
  value[0] back into 23 and 24 (a holder without `hste` is retail's `"HST2 Changed param skill
  error"` log line, and nothing is written).
- MEASURED: `SKILL_EU_ROG_DAGGERA_SPEED_A_01` (id 9834, group 628) is kind 3, dura 15000, `hst2`
  48. Over Grass Walk A lv1 it runs the character at `50 × 1.48 = 74` (Grass Walk's 20 removed),
  and at its end Grass Walk's 60 comes back (tested).
- Slot 2 reduces as the product of `(1 + e/100)` (`GParamKeeper FUN_004b2e60`, the `== 2` arm).
- So Grass Walk A lv1 (`hste` 20) gives run speed `50 × 1.20 = 60`. The base 50 is **MEASURED**:
  all 52 player rows of `characterdata` (`CHAR_CH_MAN_*` .. `CHAR_EU_WOMAN_*`) carry walk 16, run
  50 (column 47) — `session.PlayerRunSpeed`.
- A second `hste` buff of another group while the first holds writes nothing (it stacks no speed);
  when an `hste` record ends the holder empties even if a later one is still active — both READ,
  both modelled.
- On the wire the speed is rounded to the nearest unit (OURS; the engine keeps a float).

The server still does not police movement speed (movement is client-authoritative); `runSpeed` is
what the client should move by.

**Other publishing codes — OPEN.** srrevamp computes damage, defence and HP/MP without a
ParamKeeper, so nothing there has a slot to take a buff's contribution. The next ones to wire,
with what is already READ in `0x594ac0`: `defr` (params 5/6 slot 1 = value[0]/value[1]), `defp`
(5/6 slot 0 = value[0]/[1] plus the context's `+0x34`/`+0x38`, capped by value[2] percent of the
current param), `apau`/`apru` (13-16 slot 0 / slot 1), `hpi`/`mpi` (MaxHP/MaxMP), `er`/`terd`/`thrd`
(parry/hit, which the engine itself never reads -- stats.go), `irgc` (regen). None is recorded in
the book today.

### Expiry (READ), cancel (READ), death and logout

- **Expiry**: SkillAction_Buff sub-state 2 ends the record when `GetTickCount() - record+8 >
  dura[0] + ctx+0x24` — strictly greater; `skillparam.BuffEndsAt` is the end, and the record is still
  running AT it. The extension `ctx+0x24` is 0 here. Its setter is READ in `SkillAction_Buff`
  (`0x5830b0`): when the row carries `RPBU` (`+0x508`) or `STDU` (`+0x518`), the extension grows
  by the `+4` word of the entry `FUN_005a0330` finds for that code; otherwise, with `DTDR`
  (`+0x52c`), it is `round(dura[0] × entry+4 / 100)`. `FUN_005a0330` is a lookup in the book's map
  at `+0x244` keyed by the code; what files entries there was not read (the `P`-named passives
  `SKILL_EU_ROG_STEALTHP_TIME_*` and `SKILL_EU_WARLOCK_MINDP_MAINTAIN_*` carry the codes too, which
  suggests passive skills -- INFERRED only). Rows naming a code
  (MEASURED, a literal scan): `DTDR` 142 kind-3 / 4 kind-4, `RPBU` 10 / 6, `STDU` 9 / 9. srrevamp
  keeps no passive records, so the extension stays 0 -- **OPEN, not modelled**.
  `session.RunBuffTicker` polls every 100 ms (OURS, as regen's poll is; retail's book update runs
  per server frame, period OPEN); the test itself is exact to the millisecond.
- **Toggles and summons** (kind 3 without `dura`: `onff` drains MP every onff[0] ms and ends when MP
  runs short; `summ` ends at summ[0]): **OPEN, not modelled** — such a buff runs until cancelled,
  a death or a logout.
- **Cancel**: `0x4ae520` → `FUN_0059ef90` finds the record of that skill id in sub-state 1 or 2,
  matching the token unless it is 0; `FUN_0059eff0(0)` returns **without ending it** when the skill
  carries `nbuf` (`+0x35c`) and the record's `ctx+0x20 != 1`. SkillAction_Buff writes `ctx+0x20`
  = 1 after `RegisterSkillInBook` when the target object is the caster (`puVar8 == param_2`) and 2
  on the records it builds for a target that is not (`local_cc != param_2`) — READ stores; that
  1 means "cast on oneself" is INFERRED from them. So **an `nbuf` buff someone else cast cannot be
  cancelled; your own can.**
  (The retail client refuses every `nbuf` row without `lnks` before sending — spec §3.2; that is the
  buff bar's rule, round 618.)
- **Death**: srrevamp ends every buff (`markDead` → OpBuffEnd). **OURS**: `GObjPC_OnDeath`
  (`0x4e6980`) clears no book, and `CGObjChar::SetLifeState` (`0x4a9c80`) on state 2 calls slot 4
  of an unidentified member at `+0x188`; the retail death rule was not traced.
- **Logout**: the book is dropped on disconnect -- unless the character is still in the world on
  another session (a reconnect before the old session's disconnect was seen): the stale
  session's leaving then leaves the live one's book alone (review). `CGObjChar::vslot_214` (`0x4a72e0`), a teardown,
  calls `FUN_0059c820(pc+0xa30)` on the book (READ); that it runs on logout is INFERRED. Retail
  restores some buffs at the next login (a record with `ctx+0xc` bits 4 and 8 ends on a saved
  remaining time, skill_params.md) — **OPEN, not modelled**.
- **Zone change**: the book is kept (OURS; retail's teleport rule not read).
- **Category ends**: `FUN_005a16c0(book, mask)` ends every self-cast record whose skill's `skc`
  (`+0x490`) byte at `+4` intersects the mask, or `FUN_005a1840` says so (callers pass 1 from
  `0x4b0ea0`, 2 from `0x4d2200` and `0x59b480`, 4 from the berserk handler `0x515b30`) — which
  events those are is **OPEN**, not modelled.

## Ghost Walk (READ, one piece not modelled)

`FUN_005862e0`, reached from `Skill_BuildUseContext_A/B` when `tele`/`tel2`/`tel3` is set:

- the requested point comes from the context's position list; the maximum distance is `tele`
  value[1] (the field's word at `+4`) — 100 for Ghost Walk B lv1, 110 for lv2, 215 for D lv1;
- the offset from the caster is measured in **all three components** (`x² + y² + z²`); within the
  maximum the point is the destination, beyond it the destination is `caster + unit(offset) × D`;
- then a navmesh test (`DAT_00cc387c` vtable `+0x30`; bit `0x10000000` refuses the cast).

srrevamp: `session.ghostWalkDestination` is the clamp; `moveBySkill` stores the point through
`world.Hub.Move`, saves the position the way `handleMove` does (`savePositionEvery`), stands a
seated caster (`motions.moved`), cancels the keep-up, and sends `OpSkillMove` to the zone.

**The navmesh test is NOT modelled**: srrevamp's server has no navmesh and no reachability check
for movement — `handleMove` stores whatever the client sends. The client stands the player on its
own walkable graph at the landing point, as it does for every move. `tele` value[0] (500 on every
Ghost Walk row) is not read there — **OPEN** (a delay or a duration in ms, perhaps).
