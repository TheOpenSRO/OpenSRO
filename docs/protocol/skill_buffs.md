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
| `OpUseSkill 0x0072` (extended) | C→S | `{name, i64 skillId, i64 targetMonsterId, u8 targetType, [targetType 2: f32 x, f32 y, f32 z]}` — targetType 0 none/self, 1 entity (a monster), 2 ground, **3 a character (round 622): the id field names a character**, no point follows. **A request without the suffix decodes as targetType 1.** Any other targetType, or a ground point cut short, is a malformed request (a server before round 622 answers a type-3 request so). | 0x7074 kind 4 |
| `OpAttackResult` (extended) | S→C, the requester | the existing payload, then a trailing `u8 targetType`: a skill reply echoes the request's 0, 1 or 2 (an old-format request: 1); a plain swing, a keep-up repeat, a duel blow and a monster-initiated result carry 1. A 42-byte result from an older server decodes as 1 | — |
| `OpBuffStart 0x00F5` | S→C, every session in the owner's zone | `{i64 ownerId, i64 skillId, u32 token, i64 durationMs, i64 remainingMs, u32 runSpeed, u8 ownerKind}` — 41 bytes; `ownerKind` 0 a character, 1 a monster (monster ids from `combat.Hub` and character ids from the database overlap; every buff is a character's today); a 40-byte payload decodes as a character; `durationMs`/`remainingMs` are −1 for a buff with no `dura`; `runSpeed` is the owner's new run speed when this buff wrote to it, else 0 (unchanged) | 0xB0BD |
| `OpBuffEnd 0x00F6` | S→C, the owner's zone | `{i64 ownerId, u8 count, count × u32 token, u32 runSpeed, u8 ownerKind}` — `ownerKind` as in `OpBuffStart`, optional to a decoder; `runSpeed` the owner's new run speed when an ended buff had written to it, else 0 | 0xB072 |
| `OpBuffCancel 0x00F7` | C→S | `{name, i64 skillId, u32 token}` — token 0 cancels the first record of that skill, as retail matches any record for a zero token. **No reply**: success is the `OpBuffEnd` broadcast; a refusal is silent, as retail's is | 0x7074 kind 5 |
| `OpSkillMove 0x00F8` | S→C, the caster's zone, the caster included | `{i64 characterId, i64 skillId, f32 x, f32 y, f32 z}` — where the ground cast put the caster | the 0xB070 result with a position (INFERRED) |
| `OpSkillCast 0x00FA` (round 622) | S→C, the caster's zone **except the caster** | `{i64 casterId, u8 casterKind (0 character, 1 monster), i64 skillId, u32 castId, u8 phase (0 start, 1 act), u8 targetType (0 none, 1 monster, 2 ground, 3 character), i64 targetId, f32 x, f32 y, f32 z}` — 43 bytes; see "The cast broadcast" below | 0xB070 result 1 (start) / 0xB071 kind 1 (act) |
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
| 62-63 | TargetHealHP / TargetHealMP | round 622: what one cast restores to **each character it names** (`skillparam.TargetHealAmounts`, heal.md): a Target_Required 1, action kind 0 row with one flat `heal` and none of `efr`/`nmh`/`mwhh`/`mwmh`/getv `HLRU`/`resu`/a combat parameter, v1 = 0 for HP and v3 = 0 for MP. MEASURED on the box's export (33,698 rows): 27 rows, `SKILL_CH_WATER_HEAL_A/B/C_01..09`; Heal A lv1 (id 149) 369 HP, 0 MP |
| 64-76 | ActionOverlap, Ovl2, HasDttp, Dttp0, Dttp1, Efr2, Offensive, Msch1, Hide, SkcEnd, BasicGroup, Activity, Dtt | round 636, the recast rule's: Action_Overlap `+0x8c` AND `0xffffff`, `ovl2` value[0] `+0x37c`, `dttp` `+0x424`, an `efr` of kind 2 (`+0x290`), `FUN_00589d20`, `msch` value[0] == 1, `hide` `+0x428`, `skc` value[1] & 0xff, Basic_Group (column 5, `+0x44`), Basic_Activity (column 8, `+0x65`), `dtt` `+0x420` (`cmd/export-refdata` `stackColumns`). An older export loads them zero: no state bytes |

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
     Target_Required 1 with a friendly group: **the character the cast names** (round 622,
     "Friendly targets" below); nothing named is refused, as the retail client refuses it.
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
     (`"select a target first"`, OURS text) before anything is spent; a friendly one is refused
     too since round 622 (`"The target is not selected."`, "Friendly targets" below) -- until then
     it landed on the caster;
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
- a row **with `lnks`** instead calls `FUN_0059dc80(0)` -- only when it also carries an `efr` of
  kind 3 (`+0x294`, round 636: the field `efr` value[0] == 3 files) -- which walks the self-cast records carrying an attached object (`ctx+0x68`) and
  compares `lnks` values, skill ids, `lks2` and the attached object's id (answers `0x300c`,
  `0x3029`, `0x3037`; below). An `lnks` row without `efr` kind 3 gets no check at all
  (0x58e308 -> 0x58e32d). srrevamp: `buff.linkLocked` (the review of round 636);
- a Target_Required 1 row gets no check at this gate, **but the target test runs the same
  function on each target's book** (READ in round 622's review): `FUN_0058cc70`, for each target,
  calls `FUN_0059d870(target+0xa30, skill, caster)` (0x58d2ca..0x58d2d3) and refuses `0x300c` on a 0
  answer -- `lnks` rows included, after their `FUN_0059dc80` on the caster's book (0x58d294). The
  one skip (0x58d2ac..0x58d2c8): the target is the caster and the caster's running action
  (`+0xc08` -> `+0x18` -> `+8`) is this same skill; srrevamp keeps no running action, so it never
  skips. srrevamp applies `FUN_0059d870` on the target's book (`buff.Books.CheckOverlap` /
  `Start` for the owner the cast names) -- since round 636 the whole of it, below. Until the review a Target_Required 1 recast added a second record.

`FUN_0059d870(book, skill, caster)` -- **READ in full in round 636** (asm 0x59d870..0x59db06; the
Ghidra C of it is garbled, read the asm). `*book` is the book's owner (`FUN_005a16c0` uses
`*book + 0x1ec` as the owner's ParamKeeper).

1. **The list.** When the new row is action kind 3 (`+0x168`) and not `msch` value[0] == 1
   (`+0x4a4`), it walks the book's list (`book+0x268`, head `+0x26c`; node `+8` -> record, record
   `+0x18` -> ctx, ctx `+8` -> the record's skill row) and passes over every record whose skill is
   not kind 3 or carries `cbuf` (`+0x358`). For each other record, the first branch that applies:
   - **`dttp`** (`+0x424`) on both rows with the same value[0] (0x59d915..0x59d92d): when the caster
     is the owner (`cmp [book],caster`, 0x59d937) the answer is 1 at once -- nothing ends, no bit
     test; otherwise a record its owner cast on itself (ctx `+0x20 == 1`) is passed over
     (`FUN_005a3160` advances), a lower value[1] (unsigned `jb`, 0x59da6f) answers 0, and an equal or
     higher one clears that record's end flag (`+0x10`) and answers 1.
   - **`efr` kind 2** (`+0x290`; skill_params.md: `efr` files itself at `0x28c`/`0x290`/`0x294` by
     value[0] -- round 616 wrote "no code maps to it", which was wrong) on the new row with
     `FUN_00589d20` answering 0 for it (see below): the record ends -- together with the record of
     its skill that `FUN_0059ef90` finds on the object ctx `+0x6c` names, both end flags cleared,
     answer 1 -- when it has the same Basic_Group string (`+0x44`, `FUN_00425210`), a Basic_Level not
     above the new one (`+0x64`), `efr` kind 2 itself, `FUN_00589d20` 0, and a ctx `+0x6c`;
     otherwise it is passed over. **The GroupID branch is never tried for such a row.** ctx `+0x6c`
     is built by SkillAction_Buff for an `efr` kind-2 row without `dtt` (`+0x420`): `+0x10` = the
     caster's id (`param_2[2]`) -- READ; srrevamp gives it to the caster's own record only
     (INFERRED: the other branches that build target records do not write it).
   - **GroupID**: the new row carries no `lks2` (`+0x374`), the record is not an `lnks` record its
     owner cast on itself (`old+0x370 == 0 || ctx+0x20 != 1`), the new GroupID (`+0x8`) is not 0 and
     equals the record's -> `new.Basic_Level < old.Basic_Level` (unsigned byte) answers 0; otherwise
     the record's end flag is cleared and the answer is 1.
2. **The bit test** (0x59dad2..0x59db06), reached by falling off the list or for any other row: 0
   when `FUN_0059db10(ovl2 value[0])` (`+0x37c`) or `FUN_0059db10(Action_Overlap)` (`+0x8c`) answers
   1.

`FUN_0059db10(mask)` (EDI the book): for each of mask's **three low bytes** (shifts 0, 8, 16 -- the
high byte is the cooldown group, round 504) that is not 0, `0x1d` or `0x23`, 1 when that byte's bit
is set in the book's **state bit set** at `book+0x1b0` (`pc+0xbe0`; four 64-bit words, the byte
`>> 6` picks the word) or the byte appears among the Action_Overlap / `ovl2` bytes of the book's
running action (`book+0x1d8`, a buff between its cast and its engage).

**The bit set** is written only by `SkillBook::SetGroupBits(mask, clear)` (`0x59dc00`): each non-zero
low byte's bit set, or cleared (not counted: a clear clears it whoever set it). Its callers (all
nine, READ; round 636 listed seven and missed the last two):
- SkillAction_Buff sub-state 1 (the engage, 0x5842ce/0x5842ea): for every record but an `lnks` one
  cast on oneself it first runs `FUN_0059db10(Action_Overlap)` and **does not engage** on a 1
  (`return 2`); then it sets `local_d0` -- Action_Overlap; 0 for an `lnks` record cast on oneself;
  for a record on another character (ctx `+0x20 == 2`) `ovl2` value[0] when the row has one, else 0
  when it has `dttp` -- and `ovl2` value[0];
- SkillAction_BuffEnd (0x582c8c, 0x583093): clears `local_18` -- Action_Overlap; 0 for a record with
  the `lnks` link struct (ctx `+0x68`, which SkillAction_Buff builds for every `lnks` row) that is
  not on another character; `ovl2` value[0] for a record on another character whose row has it --
  and `ovl2` value[0];
- 0x584d5a, 0x585128, 0x58533f: the `ovl2` / pulse paths inside SkillAction_Buff (not needed here);
- `CTJ_SkillKeeper` slot 12, `FUN_00650e70` (0x651178, 0x651194): a buff restore (not modelled:
  srrevamp restores no buffs, OPEN with the login restore below).

**SkillAction_Buff's sub-state 0 (READ in round 636's review, 0x583ffb..0x584044).** After the
casting time, for a row with no `efr` of kind 3 (`+0x294`, the trap branch) that is not an `efr`
kind-1 row (`+0x28c`) with a Basic_Activity other than 1 (the collector branch), it tests the
**caster's** book (EDI = `param_2 + 0xa30`, the acting character -- also for a cast on another
character): `FUN_0059db10(ovl2 value[0])`, then `FUN_0059db10(Action_Overlap)`. A hit ends the
action with `FUN_0059ae10(2, 0, id, 0)` -- 0xB071 kind 2 with error 0 -- **before the costs**: the
spend (vslot `0x308`) runs only on the other path. The retail client's kind-2 handler
(`FUN_00a56680` -> `FUN_00a50a00`) ends the cast deco and shows no text. The collector branch
instead spends first (vslot `0x308`), sends 0xB071 kind 1 and runs `FUN_0059d870` on each target;
the record then meets the engage's test (sub-state 1, above) and, on a hit, simply does not start.
srrevamp: `buff.Books.CheckEngage`, after the category end and before the costs; a hit answers the
cast with `session.silentRefusal`, a marker the client ends the cast on without logging (OURS, since
srrevamp's reply has no "error 0"); a collector row's engage refusal (`buff.RefusedEngage`) keeps
the costs and answers the success, as retail does. MEASURED: the 18 `dttp` rows with a state byte
(`SKILL_CH_FIRE_DETECT_*` byte 0x2f, `SKILL_CH_FIRE_DESCRY_*` 0x2e) carry `efr` kind 1 with
Activity 2 -- the collector branch: a second cast while one runs passes the gate (the `dttp` owner
shortcut), is charged, and starts nothing.

**What the bytes are (MEASURED, round 636, over the 33,698 exported rows).** Only action-kind-3 rows
carry a state byte (1,835 rows). Each byte names a family: 1 every imbue (`*_GIGONGTA_*`, 20
Basic_Groups), 2 the Cold Protections (`SKILL_CH_COLD_GANGGI_*`) and the Cleric physical blessing,
3 the **Fire Protections** (`SKILL_CH_FIRE_GANGGI_A..E`) and the Cleric magical blessing, 6 the
**speed buffs** (`SKILL_CH_LIGHTNING_GYEONGGONG_A`, `_C`, `_E` -- Grass Walk - Flow, - Speed and the
E row -- the speed potions and scrolls), 11 the walls (`*_BINGBYEOK_*`, `*_HWABYEOK_*`), 16 Fire
Shield, 83 Cold Shield, and so on; `0x1d` (29) and `0x23` (35) are the Bard songs and dances, which
the bit test never tests (the category end uses them, below). Ghost Walk's Action_Overlap is
989855744 = `0x3b000000`: only the high byte, no state byte.

**The two reported cases, READ.** Fire Protection's records carry `cbuf`, so the list passes them
over and the bit test decides: byte 3 is set by the first, and a second Fire Protection -- the same
row, a higher level, another letter -- is refused `0x300c`. Grass Walk - Flow (group 260), - Speed
(262) and E (493) never meet in the GroupID branch; all three carry byte 6, so **the second is
refused `0x300c` and the first keeps running** -- retail does not cancel it. The retail client does
not either: its skill use (`FUN_0081ba10`) sends no cancel first, and `0x300c` appears in the
client only in the silk mall and the alchemy box (`infn.sh 0x300c` over the client dump). A recast
of the **same** Grass Walk group still goes through the GroupID branch (an equal or higher level
ends the old record; a lower one is refused).

**`FUN_00589d20`** answers 1 when, with no `abnb` (`+0x41c`), the row carries any of `att`, `fz`,
`fb`, `es`, `bu`, `ps`, `zb`, `se`, `rt`, `sl`, `fe`, `my`, `bl`, `dn`, `st`, `ds`, `ca`, `cssr`,
`csit`, `cspd`, `csmd`, `cshp`, `csmp`, `lfst`, `tb`, `ck`, `pdmg`, `pdm2`, `tant`, `tnt2`, `dttp`,
`terd`, `hitm`, `trap`, `hntp`, `thrd` (READ, 0x589d20; the offsets through skillparam.Field).

**Also on row 16 (READ, 0x58e2c2..0x58e2d9):** when the caster's vslot `0x100` answers 4 and the row
carries `hide` (`+0x428`), `0x300c` at once. Which state 4 is was not read -- **not modelled
(OPEN)**. And the gate orders its rows HP (0x58e292), MP (0x58e2b1), then row 16: srrevamp now
tests the costs before the recast rule (round 636; until then the other way round).

srrevamp: `buff.Books.CheckOverlap` / `CheckEngage` / `Start` (`gateLocked`, `linkLocked`,
`overlapLocked`, `gateApplies`, the bit set in the book, `engageBits` / `endBits`). The ended records
leave the book (their bits with them) before the new one's tests -- INFERRED order, as before.
**Not modelled:** the running-action half of `FUN_0059db10` (srrevamp engages a buff at its cast, so
there is none); the `hide` rule above.

### Every row, by rule (round 636)

`TestRecastRuleCensus` (`server/internal/session/buffstack_census_test.go`, run with
`SRREVAMP_SKILLS_CSV` naming the player's own export) drives the rule over every row. MEASURED on
the RE box's export, the 2,348 action-kind-3 rows by the rule that decides a recast:

| rows | rule | srrevamp |
|---:|---|---|
| 1,341 | GroupID branch; other groups meet the bit test | modelled |
| 397 | `cbuf`: the list passes them over; the bit test refuses | modelled (Fire / Cold Protection) |
| 82 | `efr` kind 2 (then the bit test) | modelled (the Bard dances and songs) |
| 36 | `dttp` | modelled (`SKILL_CH_FIRE_DESCRY_*`, `_DETECT_*`, the EU detects) |
| 31 | GroupID 0: the bit test only | modelled |
| 1 | `msch` 1: the bit test only | modelled |
| 76 | `cbuf` with no state byte: nothing stops a recast | modelled -- READ (socket stones, the WANTED rows, mall scrolls) |
| 76 | GroupID 0 with no state byte: nothing stops a recast | modelled -- READ (monster `MSKILL_*` rows) |
| 32 | `lnks` with Target_Required 0 and `efr` kind 3: the gate calls `FUN_0059dc80` | modelled (`linkLocked`, the review) |
| 276 | `lnks` with Target_Required 1: the target test calls `FUN_0059dc80` on the caster's book, then `FUN_0059d870` on the target's | modelled (the review's follow-up: a caster's link records) |

Round 636 filed 160 of the 276 as "`lks2` with no state byte: nothing stops a recast, READ". That
was wrong: every one of the 160 carries `lnks` and is Target_Required 1 (142
`SKILL_EU_WARLOCK_DOTA_*`, 18 `SKILL_EU_BARD_BATTLAA_MPSTEAL_A`), and the target test calls
`FUN_0059dc80` for every `lnks` row (0x58d27d..0x58d2a6). The Warlock DOTs have no friendly group,
so srrevamp does not start them at all (a debuff on a monster).

202 of them are Target_Required 1 rows with only hostile groups, which srrevamp does not start
(debuffs on a monster, not modelled). Every pair of rows that share a state byte and differ in
group -- 311,259 pairs -- is refused as the second, except where the first is an `lnks` row cast on
oneself (it sets no bits, READ) or the second is a `dttp` or `lnks`/Target_Required 0 row. A
same-skill recast leaves two records only for the `dttp` owner-cast stack of the rows with no state
byte (READ; the EU detects) and the "nothing stops" rows above. The 106 friendly Target_Required 1
`lnks` rows with a non-zero `lnks` value[2] (the Warrior guards, the Cleric blessings, the damage
divides, the Rogue point, the Warlock stun link) are driven to their limit: value[2] targets pass,
the next is `0x3029`, and the same target again is `0x300c`.

**`FUN_0059dc80` (the `lnks` rows) -- READ in round 636's review** (asm 0x59dc80..0x59dde2; EAX
the book, EBX the new row, one stack argument: the linked object, 0 from the gate at 0x58e315, the
target from the target test at 0x58d294). It walks the book's list (`book+0x268`) and considers a
record only when its skill's Basic_Activity (`+0x65`) is non-zero, its ctx `+0x20` is 1, it carries
the link struct (ctx `+0x68`), and its `lnks` value[0] equals the new row's. For such a record:

- **the same skill id** (`+4`): neither row carrying `lks2` (`+0x374`) -> the record is counted
  (0x59dd72), unless the argument's id (`+8`) is the struct's linked object (`+0x10`): `0x300c`;
  both carrying it -> that same match is `0x300c`, and nothing is counted; one carrying it ->
  nothing is counted;
- **another skill id**: neither carrying `lks2` and a non-zero `lnks` value[0] -> `0x300c` at once
  (0x59dda3..0x59ddae); both carrying it -> a match on the linked object is counted; otherwise
  the record is passed over.

After each record that reaches the count (0x59dd77), a non-zero `lnks` value[2] equal to the count
refuses: `0x3037` `UIIT_MSG_QUEST_ERR_CANNOT_MAKE_TRAP` when the row carries both `qest` (`+0x49c`)
and `trap` (`+0x4a0`), else `0x3029` `UIIT_STT_SKILL_USE_FAIL_OVERLAP_COUNT` ("The available
number of people for this skill is maxed.", MEASURED). The link struct (`FUN_005a9d60`) is built
by SkillAction_Buff (0x5830b0, READ) on the record of an `lnks` row in its `efr` kind-3 branch,
`+0xc` the caster's id and `+0x10` the id of the object that branch makes (`FUN_00485e70`); that
record's ctx `+0x20` keeps `FUN_005a9ae0`'s default 1 (READ). The Target_Required 1 branch builds
one too, on a second record for the caster, `+0x10` the target's id.

MEASURED: all 32 Target_Required 0 `lnks` rows carry `efr` kind 3 and `trap`, and none `lks2`: the
25 `SKILL_EU_WIZARD_FIREA_TRAP_A/B_*` rows (`lnks` 14 300 1 1) and 7 `SKILL_QNO_*` rows (`lnks` 0
300 1 0, with `qest`). So a second Fire Trap of the same skill is `0x3029`, any other Fire Trap
`0x300c`, and a second quest trap of the same skill `0x3037` (quest traps of other skills pass:
value[0] is 0). **srrevamp** (`buff.linkLocked`, skill CSV columns 77..81): an `lnks` + `efr`
kind-3 record its owner cast is the link record (INFERRED); srrevamp makes no object, and the
gate passes none, so the linked id never matters there. Whether retail's record also ends when
its object goes was not read (OPEN); srrevamp's lasts its `dura` (120 s for a Fire Trap).

**The target test's call (the review's follow-up).** For a Target_Required 1 `lnks` row the
target test calls `FUN_0059dc80` on the **caster's** book with the target as the linked object
(0x58d294: `push ebp` the target, EAX `caster+0xa30`), before `FUN_0059d870` on the target's book.
The records it counts are the second records SkillAction_Buff's Target_Required 1 branch builds for
the caster (READ, the link struct `+0xc` the caster's id, `+0x10` the target's id). srrevamp keeps
them as the caster's link entries (`buff.Books.links`): out of the caster's visible book (OURS: no
icon; an `lnks` record cast on oneself sets no bits, READ), added when the target's record starts,
dropped when it ends (INFERRED) or at the caster's teardown. So a Warrior's guard (`lnks` 1 . 2)
links two party members; a third is `0x3029`, the same one again `0x300c`, and another level of the
guard `0x300c` while a link stands. **OPEN:** retail's link record, when it ends, also ends the
target's record (SkillAction_BuffEnd's ctx `+0x68` branch, `FUN_0059eff0(1)`); srrevamp does not
end the target's buff when its caster dies or leaves.

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

**`/speed` (round 636, OURS: a GM test tool, no retail counterpart).** A per-owner multiplier kept
beside the book (`buff.Books.SetGMSpeedFactor`, 0.1..10) multiplies the speed every packet above
reports. The change itself goes out as an `OpBuffEnd` with no tokens and the new `runSpeed`; the
arriving client learns it in `sendBuffsInView`. It survives a death and a zone change, and is
cleared when the character leaves the world (round 636's review: pruned on logout, so a GM demoted by
a restart without the account in `-gm-accounts` keeps nothing), or by `/speed off`.

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
- **Category ends** (READ in round 636): `FUN_005a16c0(book, mask, row)` ends every record whose
  skill has a non-zero Basic_Activity (`+0x65`), that its owner cast on itself (ctx `+0x20 == 1`),
  and whose `skc` (`+0x490`) value[1] low byte (`+4`) intersects mask -- or for which
  `FUN_005a1840(row, record's row)` answers 1: per byte position (shifts 0, 8, 16), the row's
  Action_Overlap byte `0x1d` against the record's `0x1d`, or its `0x23` against the record's `0x23`
  or `0x1d`. Each ended record's token goes out as `0xB072`. Callers: the movement handler
  `GObjPC::FUN_004b0ea0` (slot 377; mask 1, no row), `FUN_0059b480` (mask 2, the skill's row), the
  berserk handler `0x515b30` (mask 4, no row) and `GObjPC::FUN_004d2200` (the pet
  control handler; its mask register was not traced -- OPEN). MEASURED: `skc` value[1] is 2 on the
  EU transform and illusion rows, 10 on the EU hiding and invisibility rows, 8 on
  `SKILL_FORT_REPAIR_KIT`; no row carries 1 or 4, so a move and a berserk end nothing.
  **Where `FUN_0059b480` runs (corrected by round 636's review, READ):** not before the gate. The
  gate runs at request time (`GObjPC::HandleCharacterActionRequest_7074` 0x4acc40, 0x4aced4); the
  skill tick's case 2 then posts 0x7070 -> vslot 383 `FUN_004b21b0` -> `FUN_0059b7c0` ->
  `FUN_0059b480`, which builds the use's context and runs the category end at 0x59b745 just before
  `SkillActionHandler`. So a refused cast ends nothing. **srrevamp**: `buff.Books.EndCategory` with
  mask 2, run once every refusal of `OpUseSkill` has passed (after the gate, the cost test and the
  reach test; before the sub-state 0 test and the costs) -- so a cast that goes through ends a
  stealth, and a Bard dance ends the dance before it. Movement, berserk and mask 8 are not wired (nothing carries
  them but the repair kit).

## Ghost Walk (READ, one piece not modelled)

`FUN_005862e0`, reached from `Skill_BuildUseContext_A/B` when `tele`/`tel2`/`tel3` is set:

- the requested point comes from the context's position list; the maximum distance is `tele`
  value[1] (the field's word at `+4`) — 100 for Ghost Walk B lv1, 110 for lv2, 215 for D lv1;
- the offset from the caster is measured in **all three components** (`x² + y² + z²`); within the
  maximum the point is the destination, beyond it the destination is `caster + unit(offset) × D`;
- then a navmesh test (`DAT_00cc387c` vtable `+0x30`; bit `0x10000000` refuses the cast).

**The navmesh test, read (round 616-618 integration).** `DAT_00cc387c` is `CRegionManagerBody`
(`FUN_0098a110` points it at 0xd67c80; the constructor's vtable is 0xb431fc), slot 12 is
`CRegionManagerBody::vslot_012` (0x98b300). It is called as `(flag, 1, &casterPos, &dest, 0,
caster)` and **writes the destination struct** `{cell, mesh, u16 region, f32 x, y, z}`; the move
record is filled from that struct after the call (asm 0x5866c1..0x5866ea). vslot_012 walks the
navmesh through each mesh's slot 2 (terrain: `CRTNavMeshTerrain::vslot_002` 0x9a0710, the same
library function as the client's 0x4047a0 that `NavGraph` models) and breaks out on the walk's
blocked bit (`(r & 0x10000001) != 0`), with no slide. **Corrected by the review:** on a blocked
terrain edge (0x9a0c7e..0x9a0cf8) the walk takes the crossing point and moves it toward the centre
of the mover's cell (`+0x20/+0x24`, `(min + max) × 0.5`, set by `CRTNavCellQuad::vslot_010`
0x9c1210) by **at most 0.2** (`RTNavMeshTerrain::FUN_009c1050`, the double 0xb45de8 = 0.2 at
0x9c1092/0x9c10ac; the client's twin `FUN_004472d0` uses 0xe1b850 = 0.2) — not 0.01 back along
the move (0.01, 0xe1b820, is the object entry test's). It then calls `FUN_009a05a0`, which runs
the object entry test (`FUN_009a0030`) from the walk's source point (where the walk entered that
cell) to that stop against every object the cell lists; when any is met, the destination is reset
to the source point and the walk returns 1 (the client's `0x4047a0` does the same through
`FUN_004045f0`). So **a blocked path is not refused: the caster stops at the obstacle** (or,
rarely, where it entered the obstacle's cell). Refusals (0x10000000): a
destination more than a region span away, more than six mesh hand-overs, a landing outside
`[0, 1920)` of its region or on no cell, and a failed cell check (`FUN_009a05a0`) when `flag`'s bit
0 is set — `flag` is 1 when the caster's vslot 0x1c or 0x2c answers non-zero (what those mean is
OPEN).

**The landing is kept as integers (READ).** FUN_005862e0 stores the destination in the move record
as `u16 region` at `+6` and x, y, z through `_ftol2` (0x9fbb40, truncation toward zero) at
`+8/+0xc/+0x10` (asm 0x5866c1..0x5866ea). EngageSkill (0x593540) loads them back with `fild`
(0x5935e6..0x59361b), turns them into the offset from the caster (`FUN_00430ba0`) and passes it to
slot 305: `CGObjPC::vslot_305` (0x4ef300) → `GObjPC::FUN_0048b920`, which sets the position
(slot 0x39c) to the current one plus that offset. So the character is put at the truncated point,
in its region's own coordinates, and that is the position the server then has. Which packet
tells the clients was not read.

srrevamp: `session.ghostWalkDestination` is the clamp; `moveBySkill` stores the point through
`world.Hub.Move`, saves the position the way `handleMove` does (`savePositionEvery`), stands a
seated caster (`motions.moved`), cancels the keep-up, and sends `OpSkillMove` to the zone.

**The navmesh test runs on the client** (round 616-618 integration): srrevamp's server has no
navmesh, so the client resolves the landing before it sends the cast (`GhostWalk.resolve`,
`client/scripts/world/ghost_walk.gd`): the 3-D clamp to `tele` value[1] (the catalog's
`tele_reach`), then a walk on its `NavGraph` from the player toward it with sliding off
(`step_tracked(..., false)`, which now makes the 0.2 move and the cell check above), one step per
region; the landing truncated as the record keeps it (x and z in the region's coordinates, the
player then stood at the cell's height; the sent y truncated too), except when truncating would
cross the edge the walk stopped at (then the walked stop is kept, OURS); and the sent point kept
within reach in 3-D so the server's own clamp -- still the authority on distance -- leaves it. A
reach not yet known (the skill index loading) refuses the cast (OURS). The client settles its
footing at once on `OpSkillMove`. The refusal cases above are not modelled (the client stops where
its graph ends instead). `tele` value[0] (500 on every
Ghost Walk row) is not read there — **OPEN** (a delay or a duration in ms, perhaps).

## Friendly targets (round 622)

A Target_Required 1 row with TargetGroup_Self, _Ally or _Party and no land target -- Heal, the party
buffs -- is aimed at a **character**. How retail handles it, READ from both binaries on the RE box.

**The client** (`sro_client.exe`, the skill use `FUN_0081ba10`, asm 0x81ba10..0x81c577). Its skill
row is `FUN_0093f250(skillId) + 0x774` (`FUN_0095f4d0`). In that copy Target_Required is `+0x98`,
TargetType_Animal `+0x99`, Land `+0x9a`, Building `+0x9b` and the eight groups Self..SelectDeadBody
`+0x9c..+0xa3`: the server's `+0x94..+0x9f` moved by 4. That layout is INFERRED from three uses:
`+0x98 == 0` sends the no-target form (0x81bf45); `FUN_0095f510` tests `+0x80c` (= `0x774 +
0x98`) as the Target_Required of an offensive row; the 8-byte test at 0x81bea3 covers exactly eight
groups. The selected object's id is `0x110f80c + 0x628` (`FUN_00778b70`); `FUN_00778650` writes it
from a clicked object, and 0 when nothing is selected.

- **Nothing selected.** With the selected id 0, Target_Required, Animal, no Land and no Building,
  the client shows `0x3011` and sends nothing (0x81be5e..0x81be99: `push 0x3011; call 0x778190`).
  `UIIT_SKILL_USE_FAIL_NONESELECTETARGET` is "The target is not selected." (MEASURED,
  textuisystem.txt's English column). **It does not fall back to the caster.** Every Service-1
  Target_Required 1 row with a friendly group (412 rows) carries Animal 1, Land 0 and Building 0
  (MEASURED), so this is their answer. Heal is one of them.
- **A monster selected** (`CICMonsterNPC`, descriptor 0xee77ac). An offensive row
  (`FUN_0095f510`) asks the monster's vslot 0xdc. A non-offensive one passes, and the request goes
  out: Heal carries only `heal` (client `+0x100`), which `FUN_0095f510` does not test.
- **Another player selected** (`CICUser`, 0xef1bc0). A non-offensive Target_Required 1 row first
  compares the two players' PK/job flag bytes (`FUN_009dd8f0` on each; different -> `0x3006`).
  Outside the caster's party (`FUN_00992940`) it then asks the target's vslot 0xa8 (-> `0x3006`).
  Otherwise the request goes out at that player. srrevamp has no murder or job states, so those
  two checks have nothing to test.
- **The request.** A Target_Required 0 row sends `01 04 u32 skillId 00`; a targeted one
  `01 04 u32 skillId 01 u32 targetId` (0x81c02c..0x81c0ea). A row with no target group at all
  takes the player's own id (`DAT_00eef5e8`, 0x81beeb) as its target.

**The server** (`SR_GameServer.exe`). The skill tick's phase 0 runs `PrepareAction` (`0x4ad030`)
case 4. That runs the target test `FUN_0058cc70`, and a refusal is sent in phase 0 -- before the
approach walk and before anything is spent. For each target in the context, `FUN_0058cc70`
refuses `0x3006` a target that does not resolve, one that fails the region test, and -- without
SelectDeadBody -- a dead one (life state 2 or 3). Then comes `FUN_0058d7a0` (ESI the skill, EBX
the caster, EDI the target, 0x58cf3f):

1. DontCare (`+0x9e`) passes anything;
2. a caster that is not a PC (vtable `+0x1c`) passes;
3. a target that is an NPC-NPC (`+0x24`) fails;
4. **Ally or Party (`+0x99`/`+0x9a`) with a target that is not a PC fails** -- a monster;
5. **no Self (`+0x98`) with the caster as the target fails**;
6. SelectDeadBody (`+0x9f`) with a living target fails;
7. no Enemy_M (`+0x9b`) with a monster target (`+0x28`) fails; Enemy_M without Enemy_P (`+0x9c`)
   with a PC target fails; Enemy_P without Enemy_M with a target that is not a PC fails;
8. **Party alone (no Ally, no Self): both must be in the same party** (`GObjPC::PartyID` on each);
9. a target in motion state 8 fails unless `+0x240`.

Every failure is `0x3006` `UIIT_SKILL_USE_FAIL_WRONGTARGET`, "Invalid target" (MEASURED). So **Heal
at a monster is refused by the server** in phase 0, and it costs nothing. MEASURED: the only
friendly rows with Self alone carry no Enemy_M, and no friendly row carries Enemy_M without
Enemy_P. So a monster fails every friendly row, and a character passes step 7.

**srrevamp** (`session/friendlycast.go`, `useSkillHandler`):

- **The request.** `OpUseSkill` targetType **3** names a character in the id field. This is OURS:
  monster and character ids overlap, so the kind travels with the id, as OpBuffStart's ownerKind
  does.
- **Refusals**, all before anything is spent:
  - targetType 0 on a friendly row: `"The target is not selected."`;
  - targetType 1 (a monster; a request without the suffix too): `"Invalid target"`;
  - targetType 3: `"Invalid target"` unless the target is in the world, in the caster's zone and
    alive, is not the caster unless the row has Self, and for a Party-only row shares the caster's
    party;
  - a **hostile** row at a character: `"Invalid target"` (OURS: player-versus-player is not
    modelled). The client never sends one: retail's client drops an offensive row at a player
    who is not attackable **silently** (0x81bc93..0x81bcaf: vslot 0xa8 false -> `je 0x81c577`, no
    message), and shows 0x3022 CANT_ATTACK_PARTY_MEMBER only for an attackable party member; no
    player is attackable here, so the client says nothing (round 622's review).
- **Reach.** The skill tick's band, with both BCRadius the player body's (`characterInReach`). Out
  of reach: `"too far away"`, before anything is spent. Retail walks the caster (phase 1); the
  client walks first, as round 534 arranged for monsters.
- **A friendly buff** (kind 3) starts on the **target's** book, cast by the caster. The target's
  zone hears `OpBuffStart`/`OpBuffEnd` with the target as ownerId. The recast rule runs on the
  **target's** book (the target test's `FUN_0059d870` call, "The recast rule" above): a lower level
  of an active group is refused 0x300c before anything is spent, an equal or higher one replaces
  it; the target is looked up again under its buff lock before the record starts, and a dead or
  departed target gets none. If the row has `nbuf`, its
  owner cannot cancel it, because the record's caster is not its owner (READ, `FUN_0059eff0`).
- **A heal** (kind 0, columns 62/63) restores `TargetHealHP`/`MP` to the named living character,
  capped at its maximum. This is Skill_ApplyEffectsAndNotify's target branch (`0x59461b`). It runs
  under the target's kill lock and pushes the target `OpCharacterStatsResult`, so its bars move.
  The caster's reply carries the caster's HP when it healed itself. p170/p171 are 0 (nothing
  grants `rhru` here), so the amount is exactly `v0`/`v2`.
- **Parties** use srrevamp's `party.Hub` (step 8). Server-side, retail's **Ally** means only "a PC".
  The client's PK/job checks are not modelled: there are no states to test.
- **Selecting oneself** (READ in round 622's review; implemented):
  - a **left press on the HUD's player block**: `CIFPlayerMiniInfo::vslot_030` is the
    WM_LBUTTONDOWN slot (the window dispatcher 0x46c8e0 sends 0x201 to vtable `+0x78`) and calls
    `FUN_00780ee0(own id)`, which writes the selected id `+0x628`;
  - a **Shift-click on one's own body**: the world click 0x793570 passes `((player+0x65c) & 1) == 0
    | (GetKeyState(VK_SHIFT) & 0x8000)` as the pick's include-self flag (`FUN_0078ee20`, param 3);
    with it the pick does not skip the local player, and `FUN_00778650` selects what it returns;
  - `+0x65c` is a 16-bit body-state mask indexed by the state table at `0xec5fb8` (0x28-byte
    records; setter `FUN_009c9920`, which ORs `1 << state` after clearing the record's `+0x24`
    mask; clearer `FUN_009c8810`). **Bit 0 is state 0**: the 0x30bf life-state handler
    (`FUN_008a80a0`) sets it on a revive to life state 1, and state 1, set for life state 2, clears
    it through its mask 0xffcf (the table bytes, MEASURED in the exe's `.data`). INFERRED: bit 0
    is "alive", so a plain click includes oneself only while dead -- when this client takes no
    world clicks at all (round 548). `FUN_00780ee0` also opens a type-3 box when one selects
    oneself with bit 0 clear (dead): what the box is was not read (OPEN);
  - the pick keeps the **nearest** hit across every character object (`fVar1 < local_f4`, nine
    rays around the cursor), not monsters first: the client's click now tests monsters and
    players (and, with Shift, oneself) in one ray and takes the first hit;
  - with oneself selected, a friendly cast sends targetType 3 with one's own id, from where one
    stands; the target window shows the player piece with one's own name. That piece has two
    controls, the kindred mark and the name (MEASURED, `iftw_player.txt`), and no HP gauge, so no
    HP is drawn for any selected player.
- **Not modelled (OPEN):**
  - resurrections (SelectDeadBody, `resu`);
  - the percent, bonus, weapon-term and `HLRU` heal shapes (heal.md);
  - the PK/job-flag and guild checks of the client's CICUser branch.

## The cast broadcast (round 622)

Retail tells every client in view that a cast started, and then that it acted (READ, the client):

- **0xB070**, `NetProcessInNavAndSkill::FUN_008a5fd0`. It reads `u8 result`:
  - result 1: `u16 kind` (0x3000 or 0x3002), `u32 skillId`, `u32 casterId` (asserted to resolve:
    `"pChar"`), `u32`, then the rest, parsed by the cast's own reader (`FUN_00a54f00` ->
    `FUN_00a54be0`). It builds the caster's `IDecoSkill` -- the cast clip and its READY/WAIT
    effects -- for **any** caster. Only for the player's own id does it add the cooldown and pet
    bookkeeping.
  - result 2: `u16` error, shown with `FUN_00778190` (the requester's refusal).
- **0xB071**, `FUN_008a4960` -> `FUN_00a56680`. It reads `u8 kind`, `[u16 if kind != 1]` and
  `u32 castId`, and finds the cast by id (`FUN_00a565b0`). Kind 1 reads the target/damage block
  (`FUN_00a54be0`) and forces SHOT (`FUN_00a53090`); kind 2 runs `FUN_00a50a00`.

srrevamp resolves a cast at once, so its broadcast is its own message, **OpSkillCast 0x00FA**
(OURS). 0x00FA was free: the highest session opcode in use was OpSelfID 0x00F9, and no file under
`server/` or `client/scripts/` used 0x00FA.

- **When.** Once a cast is accepted and paid for, `announceCast` sends the **start** (phase 0) to
  the caster's zone, the caster excepted. It sends the **act** (phase 1) after the row's
  PreparingTime + CastingTime, bounded at 5 s (OURS). The retail server sends 0xB071 when the
  context builder engages the cast, which waits CastingTime; the server's `+0x74` already holds
  PreparingTime + CastingTime.
- **Which casts.** A refused cast is not announced. Every accepted cast is: self casts, ground
  casts, casts at a monster (after the blow) and casts at a character. `casterKind` 1 is carried
  for monsters, but no monster cast is announced yet: srrevamp's monster AI strikes through its own
  push (OPEN).
- **The client** (`World3D._on_skill_cast`). The start plays the caster's body clip (chosen the way
  the player's own cast chooses it), its READY/SHOT-0 sounds and `SkillEffects.cast`. The act forces
  SHOT, fires SHOT/1 at the target, and plays ACT_S on the body the skill acts on: the named
  character or monster, else the caster. It adds one ACT_L cycle unless that owner's buff of the
  skill has already started, in which case the buff's token holds the aura. A client before round
  622 drops the unknown opcode.
- **The caster's own client** acts a cast at a character the same way: on the accepted reply, after
  the row's PreparingTime + CastingTime from the send, or at once on the buff's own OpBuffStart.
