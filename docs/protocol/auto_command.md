# The auto-command actor: one click, and the server fights

How a plain attack repeats itself, how a skill hands back to plain attacks,
and where the "default attack" of a weapon comes from. Read off
`SR_GameServer.exe` on 2026-09-19 (round 256), from the dump at
`/var/tmp/decomp_server` and objdump re-disassembly of the two ticks.

## The class

`CGCharAutoCommandActor` -- the binary's own RTTI name, vtable `0xaecd0c`,
constructor `0x4ac9f0`. Every character owns one; `CGObjChar::Update` calls its
`Update` (`0x4ad7a0`). It is a queue of **actions** and a table of **tick
handlers by action kind**:

| offset | field |
|---|---|
| `+0x4` | the action list (`std::list`, `0x4acab0` initialises it) |
| `+0xc` | queue depth |
| `+0x10` | the owning character |
| `+0x14` | last tick time -- `Update` runs at most every **30 ms** |
| `+0x18` | last command time (set by the 0x7074 handler) |
| `+0x1c` .. `+0x2c` | handler by kind: **[1] attack `0x4ad8e0`**, [2] pick up `0x4ae0c0`, [3] trace `0x4ae3d0`, **[4] use skill `0x4ae590`**, [5] `0x4ae520` |

An **action** record:

| offset | field |
|---|---|
| `+5` | kind (u8, 1..5 as above) |
| `+8` | the `CRefSkill` (kind 4) |
| `+0x10` | when the current phase began (`GetTickCount`) |
| `+0x14` | stop distance (the approach walks to here) |
| `+0x18` | reach |
| `+0x1c` | **phase**: 0 measure, 1 approach, 2 execute, 3 keep-up, 5 queued-not-started |
| `+0x20` / `+0x24` / `+0x28` / `+0x2c` | chain-skill bookkeeping (see the skill tick) |
| `+0x30` | the **context**: the request as the client sent it -- `+8` skill id, `+0xc` flags, `+0x10` target id, `+0x3c` the target list |

`Action_SetPhase` (`0x4ac9e0`) writes the phase and the phase start time.

## How an action arrives: the 0x7074 handler (`0x4acc40`)

Byte 1 is the command: 1 start, 2 cancel (`0x4ad320` clears the queue and stops
the walk). Byte 2 is the kind. Kind 4 carries a skill id, resolved through
`SkillBook::ResolveUsableSkillRef` (`0x59d600`: it must be a learned entry);
kind 5 resolves the row without the learned check. The context is built from
the rest of the message (`0x5aa0b0`, `0x5aa480`), a kind-4 action passes
`Skill_CheckUseConditions` with mask `0x37` unless the row sets `+0x284`, a
duplicate of the running attack/skill/pick-up is refused `0x4004`, and
`CGCharAutoCommandActor::Push` (`0x4ad630`) queues it. The reply is `0xB074`
(`0x4ad270`): result 1 started, 2 ended, 3 + a u16 error code.

`Push` is where "a new action ends the old one" lives: an empty queue takes the
action; a front TRACE is dropped for it; a front action in phase 5 or 1 is
cleared for it; a front action in phase **2 or 3 keeps running and the new one
queues behind it** -- and the keep-up ends itself when it sees depth 2. Phase 0
or 4 refuses (busy).

## The attack tick (`0x4ad8e0`, kind 1)

The one round 247 named `GObjPC::ActionTick_UseSkill`. It is the **plain
attack**; the correction is in `recovered_names.tsv`.

**Phase 0** computes the approach band (`combat.ApproachBand`, round 247; round
488 corrected its reach at exactly 10, where the one `if (10 < r)` skips both
the stop and the reach add) and goes to 1.

**Phase 1** -- `PrepareAction` (`0x4ad030`): for kind 1 the context's skill id
is **overwritten with the weapon's default attack**
(`SkillBook::DefaultAttackSkillID`, below) every pass, so a weapon swap between
swings takes effect on the next one; the target check `0x58cc70` follows. Then
`Skill_CheckUseConditions` mask `0x24` (weapon requirement + ammunition). Out
of reach: `GObjPC::MoveTowardObject(target, round(stop))`. In reach: face the
target, gate mask `0x81` (the cooldown, with the action-duration window), and
phase 2.

**Phase 2** serialises the context into a **0x7070 command** (`0x5aa630`:
skill id, flags, the target list, the position list) and posts it to the
character's own command source -- `CCmdSrcNet::PostCommand` (`0x40b720`), the
same queue the client's packets arrive through. The blow itself is resolved by
whoever consumes 0x7070, not here. Accepted -> **phase 3**. Refused (the
command queue is at its limit) -> the action ends.

**Phase 3 -- `[HANDLE_ATTACK-KeepUp]`.** In order:

1. the context's skill must still resolve (`ResolveUsableSkillRef`); if not,
   log `[HANDLE_ATTACK-KeepUp] Name:%s,SkilID:%d,DeafultID:%d` and end;
2. `Skill_CheckUseConditions` with mask **1** -- the cooldown test alone
   (`SkillCooldowns::IsReady`, `0x64c1a0`). While it refuses, return 1: **wait**.
   So the repeat cadence is exactly the base attack's `ReuseDelay`;
3. if the queue depth is 2 (another action arrived), end -- the next takes over;
4. the target must resolve (`0x485d90`) and be alive (IGObj slot 6);
5. recompute stop and reach (the same band as phase 0; the ranged-vs-flying
   override `0x4af3c0` applies when the target's slot 248 says so), clear
   context flag `0x10`, and go back to **phase 1**.

So: one click, and the server swings every `ReuseDelay`, walking back into reach
whenever it has to, until the target is dead or the player does something else.

## The skill tick (`0x4ae590`, kind 4)

**Phase 0**: no row -> `0x3003`; `0x49a1b0` -> `0x3030`; the row's id goes into
the context; gate mask `0x17`; `Basic_Activity` (`+0x65`) must be 2. A skill
with no target requirement (`+0x94` == 0) or a land target goes straight to
phase 2. Otherwise the band: with `reqc` bit 1 the stop is 0 and the reach is
the two radii; else the round-247 formula with the skill's `Range` (`+0x92`),
or when that is 0 the weapon's range **plus the skill's `+0x250` param**, the
`CBRA`/`WIRU` bonuses and the Myopia cut. Then phase 1.

**Phase 1**: prepare, `0x4ad230`, gate `0x91`; walk or face and phase 2.

**Phase 2**: prepare, gate `0x91`, the row (or the current chain link) is
resolved, the 0x7070 command is posted -> **phase 3**. Chain bookkeeping: a row
with a `ChainCode` (`+0x68`) becomes the current link (`+0x20`) with its
`ActionDuration` as the remaining time (`+0x24`), less what is left of
`+0x28`. The action's release (`FUN_004ac920`, and
`sAutoCommand::ReleaseAndClear` `0x4ac980`) seeds `+0x28 = 500` and zeroes
`+0x2c`. A link no longer than what is left has its wait zeroed and `+0x28`
drawn down by its duration. On the link where `+0x28` runs out, the remainder
is cut from that link's wait and added to `+0x2c`, and `+0x28` becomes 0.
Phase 3 adds `+0x2c` to the final link's wait when that link's `+0x90` is
non-zero and it is the only queued action. So a chain's final link waits up to
500 ms longer.

**Phase 3**: wait until `now - phaseStart > CastingTime + ActionDuration`
(`+0x74 + +0x78`; the server's `CastingTime` already includes
`PreparingTime`, `SkillGlobal::PostLoadSkillTable` adds it), plus `+0x2c` for
an auto-attack row when it is the only queued action. Then:

- a chain link: the context's row becomes the link's `ChainCode` row and the
  action re-enters **phase 2** -- the next hit of a multi-hit skill;
- otherwise, if the row's **`AutoAttackType` (`+0x90`, skilldata column 19) is
  1**, the context holds a target, that target resolves, is of type 1 (slot
  62), is alive (slot 6) and not in state 8 (slot 63), and this is the only
  queued action: **a new kind-1 ATTACK action is pushed in phase 5 carrying the
  same context**, this action drops its context and ends. `Update` starts the
  new one on its next tick (phase 5 -> 0) and the plain-attack loop above runs
  from there. Rows with `AutoAttackType` 0 -- the staff, wand and harp bolts,
  every buff -- simply end.

That hand-off is why, in the original, using a sword skill on a monster leaves
your character hitting it with plain swings afterwards.

## The default attack of a weapon

`SkillGlobal::PostLoadSkillTable` (`0x5893e0`, `SkillGlobal.cpp`) fills a
32-entry table `g_DefaultAttackSkillByTID4` (`0xc82638`, indexed by the
weapon's **TypeID4**) by comparing every row's `Basic_Code` against literal
names. The ids are the retail skilldata's rows with those names:

| TypeID4 | literal | id |
|---|---|---|
| 1 (bare hand) | `SKILL_PUNCH_01` | 1 |
| 2, 3 (CH sword, blade) | `SKILL_CH_SWORD_BASE_01` | 2 |
| 4, 5 (CH spear, glaive) | `SKILL_CH_SPEAR_BASE_01` | 40 |
| 6 (CH bow) | `SKILL_CH_BOW_BASE_01` | 70 |
| 7 (EU sword) | `SKILL_EU_SWORD_BASE_01` | 8419 |
| 8 (EU two-hander) | `SKILL_EU_TSWORD_BASE_01` | 8420 |
| 9 (EU axe) | `SKILL_EU_AXE_BASE_01` | 8421 |
| 10 (EU dark staff) | `SKILL_EU_WAND_WARLOCK_BASE_01` | 10625 |
| 11 (EU staff) | `SKILL_EU_STAFF_BASE_01` | 9944 |
| 12 (EU crossbow) | `SKILL_EU_CROSSBOW_BASE_01` | 9354 |
| 13 (EU dagger) | `SKILL_EU_DAGGER_BASE_01` | 9355 |
| 14 (EU harp) | `SKILL_EU_HARP_BASE_01` | 11162 |
| 15 (EU cleric rod) | `SKILL_EU_WAND_CLERIC_BASE_01` | 11526 |
| 16 (fortress weapon) | `SKILL_CH_FORTRESSWEAPON` / `SKILL_EU_FORTRESSWEAPON`, by a race byte | 21228 / 21229 |

`SkillBook::DefaultAttackSkillIDForWeaponTID` (`0x59e650`) reads it: a TID4 of
0 (no weapon) is treated as 1, the result must also be a learned entry, and a
transformed character answers with its transform's own attack. This is exactly
round 255's `combat.BaseAttackSkillFor`, which was derived from the rows'
`ReqCast_Weapon` bytes; it is now the engine's own table. The same pass also
does `CastingTime += PreparingTime`, parses each row's params, links chain
skills (`+0x5a4`/`+0x5a8`) and level neighbours within a group
(`+0x59c`/`+0x5a0`), and keeps the `MOB_AUTOMOB` row at `0xc82628`.

## The damage of a plain swing

A plain swing is not a skill-less blow. It is a cast of the default attack row
above (round 505):

- `GObjPC::PrepareAction` (`0x4ad030`) case 1 writes
  `*(ctx+8) = SkillBook::DefaultAttackSkillID()` on every pass of phase 1. A
  weapon swapped between swings therefore changes the next swing's row.
- The 0x7070 serializer (`GObjPC::FUN_005aa630`) appends `ctx+8` first, then
  the flags, the targets and the positions. The consumer resolves the blow from
  that row like any other cast.
- The row's `att` descriptor (`CRefSkill+0x230`) gates the blow
  (`damage_pipeline.md` stage 0) and scales it after mitigation by
  `descriptor[+4] / 100` (stage 6). Its `mc` is the hit count. `att` value[0]
  is the damage-type mask, so a staff's swing is magical.

Measured on the retail skilldata rows (`/var/tmp/allskills.txt` on the RE box,
read there and not committed; `/opt/sro-files/client/skills.csv` agrees on
every `att`/`mc` value):

| TypeID4 | row | `att` type/percent/min/max | hits (`mc`) | `getv MAAT` |
|---|---|---|---|---|
| 1 | `SKILL_PUNCH_01` (1) | 5 / 150 / 0 / 0 | 1 | no |
| 2, 3 | `SKILL_CH_SWORD_BASE_01` (2) | 5 / 60 / 0 / 0 | 2 | yes |
| 4, 5 | `SKILL_CH_SPEAR_BASE_01` (40) | 5 / 117 / 0 / 0 | 1 | yes |
| 6 | `SKILL_CH_BOW_BASE_01` (70) | 6 / 84 / 0 / 0 | 1 | yes |
| 7 | `SKILL_EU_SWORD_BASE_01` (8419) | 5 / 123 / 0 / 0 | 1 | no |
| 8 | `SKILL_EU_TSWORD_BASE_01` (8420) | 5 / 217 / 0 / 0 | 1 | no |
| 9 | `SKILL_EU_AXE_BASE_01` (8421) | 5 / 73 / 0 / 0 | 2 | no |
| 10 | `SKILL_EU_WAND_WARLOCK_BASE_01` (10625) | 10 / 153 / 0 / 0 | 1 | yes |
| 11 | `SKILL_EU_STAFF_BASE_01` (9944) | 10 / 180 / 0 / 0 | 1 | yes |
| 12 | `SKILL_EU_CROSSBOW_BASE_01` (9354) | 6 / 116 / 0 / 0 | 1 | no |
| 13 | `SKILL_EU_DAGGER_BASE_01` (9355) | 5 / 54 / 0 / 0 | 2 | no |
| 14 | `SKILL_EU_HARP_BASE_01` (11162) | 10 / 200 / 0 / 0 | 1 | no |
| 15 | `SKILL_EU_WAND_CLERIC_BASE_01` (11526) | 10 / 153 / 0 / 0 | 1 | yes |
| 16 | `SKILL_CH_/EU_FORTRESSWEAPON` (21228/21229) | 5 / 0 / 0 / 0 | 1 | no |

No base row carries flat damage. A CH sword swing is two hits of 60% (120% in
all), bare hands 150%, and a staff 180% of the magical roll. Of the ordinary
weapons only the CH bow (84%) swings weaker than a skill-less blow. The
fortress rows' percent of 0 is a floor blow (`refdata.Skill.FloorBlow`).

**The mastery term.** `Skill_GetRequiredMasteryLevel` (`0x59e770`) returns 0
unless the row's `+0x574` is non-zero. The only writer is the row's own
`getv MAAT` parameter (`SkillGlobal::RefSkill_ParseParams` `0x587630`, `+0x574
= DAT_00c826bc + 1`). So in the engine the CH swings and the EU staff and wand
swings are scaled at stage 1 by the caster's level in the row's mastery
(`ReqCommon_Mastery1`, e.g. 257 for the CH sword, 514 for the staff), and the
punch and the other EU swings are not. srrevamp does not export MAAT, so every plain swing takes
mastery 0 (see "What srrevamp does with it").

## The cooldown test the keep-up waits on

`SkillCooldowns::IsReady` (`0x64c1a0`; the block is `pc+0x1f40`): a row with a
`ReuseDelay` is refused inside a global window (`+0x50`/`+0x54`), inside the
action-duration window (`+0x58`/`+0x5c`) when the caller asked for it (gate
mask `0x80` -- phases 1 and 2 do, the keep-up wait does not) and the row is
active with a duration and no chain, then by its **cooldown group** -- the high
byte of `Overlap` (`+0x8f`), a shared map at `+0x2c` -- or, with no group, by
its own id (`+0x1c`). The arm, `FUN_0064c700`, files the new timer in the
per-id map and, for a non-zero `+0x8f`, in the group map too. The `+0x2c` map is
also the one `ItemCooldowns::IsReady` (`0x64c040`) reads for item cooltime
groups: skills and items share it (round 504).

## What srrevamp does with it (v0.1.406)

`server/internal/session/keepup.go`: after an accepted plain swing the server
repeats it every `ReuseDelay` of the base attack; a cast with
`AutoAttackType` 1 arms the same run after `PreparingTime + CastingTime +
ActionDuration`; any new cast, a zone change, a disconnect, the player's death,
the target's death and a **move** end it. Four departures are stated in the
code:

- The server cannot walk the player back into reach, so a repeat that is out
  of reach ends the run. The reach test itself is the engine's.
- The retail client's explicit cancel on a move click is stood in for by the
  position update, which srrevamp's client only sends for a real move.
- A row with a non-zero `ChainCode` does not hand off at all. srrevamp does
  not play the links, and the engine tests the LAST link's byte after the last
  link's duration. (Older text here called every such row a "chain head"; round
  507 counted them: of the 1,246 player rows with a non-zero `ChainCode`, 582
  are true heads that no other row names and 664 are intermediate links. A
  head's `AutoAttackType` always equals its final link's -- 463 type 1, 49
  type 2, 70 type 0 -- so this departure costs the hand-off on the 463 type-1
  true heads.)
- A zero-damage row does not hand off. Phase 3 tests only `+0x90 == 1`, the
  target and the queue depth, and never looks at damage. But srrevamp's cast
  handler (`useSkillHandler`, `session/skill.go`) returns early for a row with
  `NoCombatParam` or `ZeroDamage`, and that return comes before the hand-off.
  On the real rows this affects five player rows:
  `SKILL_EU_WARRIOR_DUALA_STUN_A_01..05` (ids 9245-9249), which are type 1
  with no chain and `ZeroDamage` 1. Retail hands off after them. srrevamp does
  not.

**Round 502: the hand-off did not fire until then.** `cmd/export-refdata`
wrote a literal `"0"` into both `AutoAttackType` and `Basic_ChainCode`, so every
real export carried 0 and `skillHandsOff` never saw a 1. The exporter now reads
column 19 and column 9 (the `CopyFixedColumns` offsets above). The wait is also
corrected: phase 3 waits `+0x74 + +0x78`, and `+0x74` has `PreparingTime`
(`+0x70`) added at load, but srrevamp's refdata keeps both columns raw, so the
server sums all three. The `+0x2c` term is the chain carry described under
phase 2. The release zeroes it, phase 0 zeroes it again, and only a chain
link's bookkeeping adds to it. A standalone row never reaches that bookkeeping,
so the term is 0 for every row srrevamp hands off.

Measured on the 33,632 real rows: column 19 is 1 on 28,702, 0 on 4,608 and 2
on 322. Of the 6,981 player rows (`Basic_Code` `SKILL_*`), 2,051 carry 1.
1,012 of those carry a non-zero column 9 (463 true heads and 549 intermediate
links; round 507) and 1,039 do not. Of the 1,039, 1,034 pass the hand-off test
and the damage gate: **571 standalone castable rows**, which now hand off when
cast, and **463 final links** (named by another row's column 9), which the
engine plays as the last step of a head's chain. Whether a player can cast a
final link by its own id was not read; srrevamp hands off after one if a cast
names it. The other five are the zero-damage stun rows
`SKILL_EU_WARRIOR_DUALA_STUN_A_01..05` (ids 9245-9249, `ZeroDamage` 1), which
the fourth departure above stops. 177 of the 1,034, all standalone, have a
non-zero `PreparingTime`, so their wait grows. The 322 type-2 rows (all
`SKILL_*`) do not hand off, because the test is `== 1`. It takes effect after a
re-export of the skill CSV.

**Round 504: the cooldown group is enforced.** The exporter writes `Overlap`'s
high byte (skilldata column 18 `>> 24`) as the skill CSV's column 45,
`CooldownGroup`. `useSkillHandler` now also refuses a cast with "skill on
cooldown" while the row's group timer runs, and arms the group with the row's
`ReuseDelay` when a cast is accepted. So Smash A and Smash D (both group 2)
share one timer. The group tracker is the item cooltime tracker itself
(`session/itemcooldown.go`), because the engine has one map at `+0x2c`. Two
kinds of row take no part in a group:

- a row with no `ReuseDelay`, which `IsReady` never holds. srrevamp does not
  arm the group for it, and on the real rows neither does the engine (round
  507, corrected): the arm `FUN_0064c700` is called by the action-kind
  handlers in the table at `.data 0xc63c7c`, and the kind-0 handler
  (`Skill_BuildUseContext_B` `0x586700`) calls it only when `ReuseDelay != 0`
  (`0x586c03`). The 195 grouped rows with no `ReuseDelay` are 192 kind-0 chain
  links and 3 kind-4 rows (`SKILL_CH_SWORD/SPEAR/BOW_BALANCE_A_01`), whose
  handler (`0x587260`) is not one of the arm's four call sites. The kind-1
  (`Skill_BuildUseContext_A` `0x5857b0`) and kind-3 (`SkillAction_Buff`
  `0x5830b0`) handlers call it unguarded, and there a grouped row would arm
  `PreparingTime + CastingTime + ActionDuration` when it is active with a
  duration (`+0x74` already holds `PreparingTime`), or, when its delay comes to
  0 and it carries no `cbuf` (`0x64c84e`-`0x64c85c`), file a delay-0 entry over
  the group's pointer (`0x64cc15`-`0x64cc25`), which releases the whole group.
  No real grouped row takes either path, and neither is modelled;
- a row at 300 000 ms or more, which the engine persists through
  `CTJ_CoolTimeKeeper`. It keeps only its own timer here (disclosed). The
  engine's persisted branch still files the entry in the group map
  (`0x64cae4`-`0x64cafb`) when it finds a keeper slot free; with none free
  (`0x64cb82`-`0x64cbd5`) it returns without filing (round 511). So there
  these rows share their group when a keeper slot is free, and here
  they do not: Water Harmony A-D (group 73, 300 000 ms each) and the Rogue's
  mask A/B (group 29, 600 000 ms) can each be cast inside another's timer.

The global and action windows (`+0x50`..`+0x5c`) are still not modelled. The
keep-up's own wait (`handOffDelay`) is unchanged: the base attacks are all
ungrouped. It takes effect after a re-export of the skill CSV.

**Round 505: a plain swing is its base attack skill.** Until then every plain
swing, the click's and the keep-up's alike, went to `performAttack` as a
skill-less blow: no percentage, one hit, physical. `session.plainSwingOf` now
reads the weapon-in-hand's base row (see "The damage of a plain swing") and
passes its `att` percentage and flat range, its `mc` hit count and its mask. The
click's swing reads it once. The keep-up reads it again on every repeat, as
`PrepareAction` re-resolves the row on every pass. The repeats after an
`AutoAttackType`-1 hand-off are the same swing. Three things are still
not the engine's:

- Mastery. Every plain swing passes mastery 0. The engine applies the caster's
  mastery to the rows that carry `getv MAAT` (the CH swings and the EU staff and
  wand swings), and srrevamp does not export that flag. See `docs/TODO.md`.
- The empty hand's roll. The punch's 150% scales `session.unarmedDamage`, a
  disclosed 5. What the engine rolls with no weapon (params 190/191 from the
  equipment aggregate) is not read.
- Defence. A magical swing (staff, wands, harp) is mitigated by the monster's
  one `Defense` value, as a magical skill already is. srrevamp models no
  separate magical defence for monsters.

A skill-less blow remains the fallback when there is no base row to read: a
store that cannot look skills up, or a weapon type the table does not list. A
base row with no percentage (an export predating the damage columns) adds
nothing, and a row whose mask names no damage half stays physical.

## srrevamp's cast and buff messages (round 617, the client half)

srrevamp does not speak 0x7074. The skills epic's shared contract (rounds
616-619; OURS, with the retail analogues named) extends `OpUseSkill` and adds
four messages. The client half is `client/scripts/net/skill.gd` (codec) and
`net_client.gd` (signals `buff_started`, `buff_ended`, `skill_moved`, and
`send_buff_cancel(skill_id, token)`), all little-endian:

| opcode | direction | payload | retail analogue |
|---|---|---|---|
| `OpUseSkill 0x0072` | C->S | `{name, i64 skillId, i64 targetMonsterId, u8 targetType (0 none/self, 1 entity, 2 ground), [2: f32 x, f32 y, f32 z]}` -- the type byte and point are a strict suffix, so a request without them reads as 1 | 0x7074 kind 4 |
| `OpAttackResult` (existing) | S->C | trailing `u8 targetType` after `i64 monsterId`: the echo of the request's 0/1/2; a keep-up repeat sends 1 | -- |
| `OpBuffStart 0x00F5` | S->C | `{i64 ownerId, i64 skillId, u32 token, i64 durationMs (-1 none), i64 remainingMs, u32 runSpeed (0 unchanged), u8 ownerKind (0 character, 1 monster)}` | 0xB0BD |
| `OpBuffEnd 0x00F6` | S->C | `{i64 ownerId, u8 count, count x u32 token, u32 runSpeed, u8 ownerKind}` | 0xB072 |
| `OpBuffCancel 0x00F7` | C->S | `{name, i64 skillId, u32 token}` | 0x7074 kind 5 (sender 0x81c5b0) |
| `OpSkillMove 0x00F8` | S->C | `{i64 characterId, i64 skillId, f32 x, f32 y, f32 z}` (28 bytes), OpMove's coordinates | 0xB070 with a position (inferred) |
| `OpSelfId 0x00F9` | S->C, on world entry | `{i64 characterId}` -- this client's own id (`NetClient.self_id_received`, `own_character_id`) | the character-data packet's own id |

The four trailing fields (targetType echo, both ownerKinds, and OpSelfId itself) were added by
round 617's review. Each is a suffix or a new message: a client reads them when present and
falls back when absent.

What the client sends, by the skill's own columns (the skill tick's phase-0
rule above, READ; `SelfCast.plan`):

- **Target_Required 0** (Grass Walk, the imbues, the shields, a self-heal):
  targetType 0 at once, from where the player stands, whether or not a monster
  is selected. The monster field carries the selection when there is one --
  OURS, so a server that predates the byte still reach-gates a damaging
  Target_Required 0 row against it as before; a server that reads the byte
  ignores it for type 0.
- **Target_Required 1 + TargetType_Land 1** (the 19 Ghost Walk rows):
  ground-pick mode; the left click's point on the ground (the click-to-move
  ray) goes out as targetType 2. Right click or Escape cancels. The cursor is
  OURS (the system cross); retail's ground-cast cursor and decal are OPEN.
- **Every other row**: targetType 1 at the selection, after the walk into
  reach, as before; refused with nothing selected. The retail fallback for a
  Target_Required 1 heal with nothing selected is OPEN.

The reply to a type-0 or type-2 cast is still an `OpAttackResult`. Its
echoed targetType says which request it answers; a type-0/2 reply that
reports no damage, no kill and no death is not drawn as a blow on the
selected monster. From a server without the echo the client falls back to
the in-flight request queue, which a keep-up repeat or a swing dropped inside
its re-use delay can put out of step -- so an unechoed reply is swallowed only
when it carries no damage, no kill, no death and no error (`SelfCast.is_self_reply`).

`OpSkillMove` snaps the character to the point (the move's duration is OPEN:
`tele` value[0] = 500 is unread by the server's clamp). `runSpeed` from a
buff start or end becomes the player's `_move_speed` -- the characterdata
Speed2 units the client already moves by; 0 leaves it. A buff whose ownerKind
is 1 (a monster) is never this player's. This player's id is OpSelfId's; the
sit state (`SitState.own_id`) is checked against it and takes it. Before any
OpSelfId (an older server) the sit answer's id is used, and failing that the
id is learned from the first start or move answering one of the client's own
casts within 10 s (OURS; `SelfCast`).
