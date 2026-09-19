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

**Phase 0** computes the approach band (`combat.ApproachBand`, unchanged from
round 247) and goes to 1.

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
`ActionDuration` as the remaining time (`+0x24`), carrying any overshoot
(`+0x28`) forward.

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

## The cooldown test the keep-up waits on

`SkillCooldowns::IsReady` (`0x64c1a0`; the block is `pc+0x1f40`): a row with a
`ReuseDelay` is refused inside a global window (`+0x50`/`+0x54`), inside the
action-duration window (`+0x58`/`+0x5c`) when the caller asked for it (gate
mask `0x80` -- phases 1 and 2 do, the keep-up wait does not) and the row is
active with a duration and no chain, then by its **cooldown group** -- the high
byte of `Overlap` (`+0x8f`), a shared map at `+0x2c` -- or, with no group, by
its own id (`+0x1c`).

## What srrevamp does with it (v0.1.406)

`server/internal/session/keepup.go`: after an accepted plain swing the server
repeats it every `ReuseDelay` of the base attack; a cast with
`AutoAttackType` 1 arms the same run after `CastingTime + ActionDuration`; any
new cast, a zone change, a disconnect, the player's death, the target's death
and a **move** end it. Two departures are stated in the code: the server cannot
walk the player back into reach, so a repeat that is out of reach ends the run
(the reach test is the engine's); and the retail client's explicit cancel on a
move click is stood in for by the position update, which srrevamp's client only
sends for a real move.
