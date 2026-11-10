# Resisting an abnormal state: the target's side of the landing roll (round 881)

How a character's buffs, passives and worn items stand between a skill and the state it carries,
and what the states read in this round do. READ is `SR_GameServer.exe` (`s:`) as assembly unless a
line says otherwise; MEASURED, INFERRED, OURS and OPEN as everywhere. The roll itself (the level
overshoot, the six elemental blocks, the dice) is in `status_effects.md`; the cures are in
`skill_support.md` ("Cures"), `cure_pills.md` and `auto_potion.md`.

Implemented in `server/internal/statuseffect` (`resist.go`, `effects.go`),
`server/internal/session/resist.go` and `server/internal/combat` (`RollChanceClamped`).

## 1. The seventeen non-elemental states

### Where the resistance lives (READ)

A character's object at `+0xa30` (the same object whose head is the chance-memory dice) holds
**17 resist records**, 24 bytes each, the first at `+0x14`. A record is

- a map keyed by a **level**, each value a set of **(probability, buff id)** pairs, and
- a list of **(source, percent)** entries (at record `+0xc`).

The record index is the state's place in the mask walk of `FUN_0059df20` (`s:0x59df20`), and it
is what each state's block of `Combat_ApplyStatusEffects` passes in `EAX` to `FUN_0059de50`
(`s:0x59de50`, `lea eax,[eax+edx*8+0x14]` with `edx = 3 x index`):

| record | mask bit | state (code) | block's `mov eax` |
|---:|---|---|---|
| 0 | `0x40` | sleep (`se`) | `s:0x591011` |
| 1 | `0x80` | root (`rt`) | `s:0x591204` |
| 2 | `0x100` | slow (`sl`) | `s:0x5914a0` |
| 3 | `0x200` | fear (`fe`) | `s:0x591694` |
| 4 | `0x400` | myopia (`my`) | `s:0x59188d` |
| 5 | `0x800` | bleeding (`bl`) | `s:0x591b1c` |
| 6 | `0x2000` | darkness (`dn`) | `s:0x591d65` |
| 7 | `0x4000` | stun (`st`) | `s:0x591ff0` |
| 8 | `0x8000` | disease (`ds`) | `s:0x5921e4` |
| 9 | `0x10000` | confusion (`ca`) | `s:0x59244c` |
| 10 | `0x20000` | decay (`cspd`) | `s:0x592a8f` |
| 11 | `0x40000` | weakness (`csmd`) | `s:0x592c98` |
| 12 | `0x80000` | powerless (`cssr`) | `s:0x59267d` |
| 13 | `0x100000` | dissociation (`csit`) | `s:0x592886` |
| 14 | `0x200000` | panic (`cshp`) | `s:0x592ea8` |
| 15 | `0x400000` | combustion (`csmp`) | `s:0x5930c4` |
| 16 | `0x1000000` | incubation (`tb`) | `s:0x59327d` |

### Who writes it (READ)

- **A skill row's `real` [mask, probability, level]** (`CRefSkill+0x300`). `ApplySkillParamsToChar`
  (`s:0x5957ee..0x595818`) calls `FUN_0059df20(target+0xa30, mask, buff id)` with `edi` =
  value[1], `ebx` = value[2] and `esi` = 0: for every mask bit, `FUN_00599840` (`s:0x599840`)
  files `(probability, buff id)` under the key `level`. `SkillAction_BuffEnd` (`s:0x582cbd`) makes
  the same call with `esi` = 1, which takes the entry out. It runs for an active buff and for a
  learned passive alike.
- **A passive only while its own `reqi` list holds.** `GObjPC::FUN_0059f0e0` (`s:0x59f0e0`), run
  after every equipment move and durability change, walks the book: a passive (Basic_Activity 0)
  whose list fails has its `real` entries taken out (`FUN_0059df20`) and its params removed
  (`ParamKeeper_RemoveContributionsOf`), and gets them back (`ApplySkillParamsToChar`) when the
  list holds again. An armour kind with value 0 asks for **all six** body parts to be of that kind.
- **A worn item's blue option** (`Stat_ApplyTaggedModifier` `s:0x498690` ->
  `Char_InsertResistEntry` `s:0x59de70`, the record in `EAX`, the value in `EDX`) adds
  `(item, value)` to a record's percent list:

  | tag | option | record | site |
  |---|---|---|---|
  | `rsli` | MATTR_RESIST_SLEEP (earring) | 0 sleep | `s:0x4990c1` |
  | `rfei` | MATTR_RESIST_FEAR (ring) | 3 fear | `s:0x4990d7` |
  | `rsti` | MATTR_RESIST_STUN (necklace) | 7 stun | `s:0x4990f0` |
  | `rdii` | MATTR_RESIST_DISEASE (ring) | 8 disease | `s:0x49905e` |
  | `rcsi` | MATTR_RESIST_CSMP (earring) | 15 combustion | `s:0x499077` |
  | `rals` | MATTR_RESIST_ALL_SET (a set's) | 15, 8, 0, 3 -- and params 27..32 | `s:0x498fef..0x499018` |

### What the block reads back, and the roll (READ)

`FUN_005999e0` (`s:0x5999e0`) returns three numbers for a record: **B**, the highest level filed
(the map's last key); **A**, the highest probability filed at that level; **C**, the sum of the
percent list. The sleep block, `s:0x590f06..0x59107a` -- the other sixteen are the same code with
their own record, kind and out-of-line halving loop:

    d      = max(GetLevel() - 10 x (value[2] + diseased), 0)        ; diseased = (param 169 != 0)
    chance = max(ftol(value[1] x (1 - 0.05 d)), ftol(0.1 x value[1]))
    if B != 0:
        n = value[2] - B
        if n > 0: A is halved n times            ; s:0x59133f: cdq; sub eax,edx; sar eax,1
    chance = chance - A + param 169
    if C != 0 and chance > 0:
        chance = ftol((1 - C / 100) x chance)
    RollChance(chance) on the CASTER's dice, the state's kind

So a resist at or above the state's level takes its whole probability off the chance, each level
the state stands above it halves what it takes, only the highest level filed counts, and the
items' percent cuts what is left. The duration is not touched by any of it.

### A chance of zero or less (READ)

The dice (`FUN_00599cc0`, `s:0x599cc0`) return 0 at once for a chance of exactly 0. A **negative**
chance is clamped to 0 and **still rolled** against the caster's accumulator for the kind: it
comes up when the accumulator is at or above `rand() % 101`. A caster that has never rolled the
state has 0 there and a failed roll adds the clamped 0, so each of its rolls of a fully resisted
state lands once in 101; having landed once, its accumulator stands at -100 and nothing is ever
added, so it never lands it again. A caster
with points banked from earlier failed rolls (against anyone: the accumulator is the caster's,
keyed by the state alone) lands it as often as its balance says.

## 2. The six elemental states (READ)

    roll value[1] + param 169 first; then
    strength = ftol((100 - p[27 + bit]) / 100 x value[0]) - ftol(p[145 + bit])
    p[27 + bit] >= 100 or strength <= 0: nothing lands
    duration = strength x the state's unit (97 / 250 / 500 / 750 / 1000 / 750 ms)

`bit` is the state's client bit: 0 freezing, 1 frostbite, 2 electric shock, 3 burn, 4 poison,
5 zombie. Writers:

| writer | params | site |
|---|---|---|
| a row's `bgra` [mask, percent] | 27 + bit for each mask bit | `s:0x595698..0x5957ea` |
| a row's `reat` [mask, value] | 145 + bit for each mask bit | `s:0x595542..0x595689` |
| an item's `fz` (MATTR_RESIST_FROSTBITE) | **27 and 28** | `s:0x4987fc` |
| an item's `es` / `bu` / `ps` / `zb` | 29 / 30 / 31 / 32 | `s:0x498745`, `s:0x4987f5`, `s:0x498824`, `s:0x49881d` |
| an item's `rals` | 27..32 | `s:0x498f46` |

Every write is a slot-0 entry, so they sum; 27..32 are capped at 100 (`param_registry.md`). An
accessory's option reads "20 % shorter" because the strength is the duration: four accessories
with 20 each leave a fifth of a poison's or a burn's time.

**A burn's tick** is `table[value[2]] / (1 + param 8 / 100)` (`s:0x4a4720..0x4a4756`): param 8 is
the magical absorption, the accessories' own stat on a character.

## 3. The states read in this round (READ)

Each is its slot's applier (mode 0 apply, 1 tick, 2 remove) and the record fields its own block
writes; `vN` is value[N] of the run.

| state | applier | what it writes |
|---|---|---|
| darkness `dn` | `s:0x4a4e20` | param 11 (attack rate), a percent entry of `-v3` (record `+0x48`) |
| disease `ds` | `s:0x4a4f20` | param 169 = `v3` (record `+0x44`): every state's chance + v3, and one level more of reach for the non-elemental ones |
| powerless `cssr` | `s:0x4a5000` | params 178 and 179, a multiplier entry of `-v3` (`+0x38`): the owner's blows x (1 - v3/100) (`Formula_Mitigate*` `s:0x40e761`, `s:0x40eb13`) |
| dissociation `csit` | `s:0x4a50b0` | params 180 and 181, a multiplier entry of `+v3`: the blows the owner takes x (1 + v3/100) (`s:0x40e793`, `s:0x40eb45`) |
| panic `cshp` | `s:0x4a5320` | param 3 (max HP) scaled to `max(100 - v3, 1)` %; param 143 = `v4`; a tick every > 2000 ms |
| combustion `csmp` | `s:0x4a54a0` | param 4 (max MP) scaled the same; param 144 = `v4`; the same tick |

- Params 143 / 144 cut what the owner recovers: `ApplyHPMPDelta` (`s:0x4a86a0`) turns every HP
  gain into `ftol((1 - p143/100) x hp)` and every MP gain the same with p144 -- potions, heals
  and regeneration all pass through it.
- The tick's amount is the low word of `ftol(max x v5 / 100)`, max being the max HP (panic) or the
  max MP (combustion) as the state has just cut it, and it is handed to `ConsumeHpMp`
  (`s:0x4a8770`) as `(0, amount, 2)`: **MP in both states**. Panic's drain is worked from the max
  HP and still comes off the MP. (MEASURED: 161 of the 178 `cshp` rows are `0,50,0` -- no cut of
  the max, half the recovery, no drain -- and at most 12 rows drain at all.)

MEASURED (the skill table, value[3..5] by rows): `dn` 206 rows -- 30 on 188, 50 on 16; `ds` 232
rows -- 40 on 189, 20 on 43; `cssr` 212 rows -- 20 on 175, 35 on 34; `csit` 85 rows -- 30 on 51,
35 on 32; `cshp` 178 rows -- `0,50,0` on 161, else 30..40 / 50..70 / 0..5; `csmp` 50 rows --
`30,50,5` on 30, `50,50,5` on 17; `tb` 14 rows (ten ranks of one Warlock skill, four skills of
two uniques); `sl` 777 rows, none with a level of 0.

## 4. The skills that resist (MEASURED, the skill table and the client's text)

| skill | kind | `real` mask | prob / level | elemental | needs |
|---|---|---|---|---|---|
| Holy Word (`SKILL_EU_CLERIC_SAINTA_ABNORMAL_A`, 10 ranks) | buff on one character, 300 s, cool-down 60 s | every state with a record but stun | 50 % / rank + 1 (2..11) | `reat` all six, 48..228 | a cleric rod to cast; no `reqi` |
| Holy Spell (`..._ABNORMAL_B`, 4 ranks) | the same on the party in 30 m | the same | 50 % / 8..11 | `reat` 172..232 | a cleric rod to cast |
| Charity (`SKILL_EU_CLERIC_PRAISEP_ABILITY_A`, 17 ranks) | passive | bleeding, darkness, decay, weakness, powerless, dissociation | 50 % / 1..11 | `reat` electric shock, burn, poison 20..116 | **a whole light-armour set and a cleric rod** |
| Faith (`SKILL_EU_CLERIC_PRAISEP_HEAL_A`, 17 ranks) | passive | fear, myopia, disease, confusion, panic, combustion, incubation | 50 % / 1..11 | `reat` zombie 20..116 | **a whole robe set and a cleric rod** |
| Protection (`SKILL_EU_WARRIOR_DUALP_ABNORMAL_A`, 9 ranks) | passive | as Holy Word | 50 % / 3..11 | `reat` all six, 40..120 | a dual axe |
| Poison Circle / Vein Circle (`SKILL_EU_ROG_POISONA_GUARD_*`) | buff, 30 min | as Faith | 50 % / 3..11 | `reat` zombie 38..118 | `reqi` 6:12 or 6:13 (the Rogue's weapons) |
| Fire Shield (`SKILL_CH_FIRE_SHIELD_*`) | buff | none; the last rank as Holy Word | (35 % / 11) | `bgra` all six, 18..58 %; the last rank `reat` 232 instead | |

Holy Word's mask is `0x17fafc0`: sleep, root, slow, fear, myopia, bleeding, darkness, disease,
confusion, decay, weakness, powerless, dissociation, panic, combustion, incubation -- everything
with a record but stun. Charity's is `0x1e2800`, Faith's `0x1618600`.

MEASURED on the original: Holy Word's buff runs 300.0 s; the client refuses the cast with no
target ("The target is not selected.") and takes it with oneself selected; the skill window shows
Charity "Essential Item: Light Armor, Cleric Rod" and Faith "Essential Item: Robe, Cleric Rod";
the next rank of Holy Word asks for the mastery level and for a rank of Charity.

A buff with no `reqi` list is not looked at by the equipment re-check (`s:0x59f0e0` skips a
record whose skill has an empty list), so Holy Word, cast with the rod, outlives the swap back to
another weapon (READ).

## 5. What OpenSRO does

- `statuseffect.Target` carries the records (`Resist`), the elemental params and the disease;
  `Resolve` applies sections 1 and 2; the session's `statusRoller` rolls through
  `combat.RollChanceClamped`.
- `session.statusTargetOf` gathers a character's entries at each roll: its running buffs'
  (`buff.Record.Resists`, `buff.StatContributions` for `bgra` / `reat`), its passives' when their
  list holds (`passiveReqsHold`), its worn items' options and its own disease.
- The states of section 3: `attackRateStat`, `applyBuffDamageVs`, `applyPlayerTaken`,
  `character.Bonus.HPScale / MPScale`, `statusRuntime.recovered`, the MP drain and the burn's
  param 8 in `dealCharacterTick`.

OURS / OPEN:

- A monster resists nothing (its characterdata resist columns are 0 on every row, MEASURED) and a
  monster's own darkness, powerless or dissociation -- a player's curse on it -- changes nothing
  yet (one player row carries `cssr`).
- Passive params other than the resists are still counted whatever is worn (`passives.go`), and
  an active buff whose `reqi` list fails after an equipment move is still not ended
  (`buffreqs.go`).
- The slow block's level from the caster when value[2] is 0 (no row has it) and the stun block's
  own guards are not built; **`tb` (incubation) is still not applied** -- its block is unread,
  and 14 rows carry it.
- Whether the engine lowers a pool that stands above a max a panic has just cut is not read;
  OpenSRO lowers the HP to the new max.
