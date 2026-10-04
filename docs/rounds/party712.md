# Round 712 (party lane S2): the kill pays the party, the party shares its loot, and party monsters hit and pay as the original's

Built on `int/party` (dev + round 710, the party server core), from `docs/protocol/party_rules.md`
and its round-709 review. Server only; no client change, no perf gate.

## What changed

**The kill reward is the monster's death distributor** (`session/killshare.go`,
`leveldata/killreward.go`), replacing the killing blow's private award. READ, GS
`CGObjMob::vslot_399` `0x4c44a0`:

1. **Grouping.** The damage list is grouped. A player in an Exp Auto Share party groups by
   party; anyone else (no party, or an Exp Free-For-All party) is his own group.
2. **Kill credit.** The group with the most damage has the kill credit: its biggest hitter.
3. **Exp Auto Share group, the party share** (`FUN_005bca60`):
   - Who shares: members alive, in the reference's zone, and within 1000 (horizontal, inclusive)
     of the kill credit, damage or not. The kill credit may sit outside the party.
   - The split is `s_i = level_i / Σlevel`, as a float32.
   - The bonus is `1 + (others−1)·0.2 + chinese·0.1`, or `1 + (chinese−1)·0.1`.
   - Damping: a member with `s_i > 0.7`, in a party of 3 or more eligible whose top level is 21
     or more, keeps half the bonus.
   - Penalty: ×0.5 for a party monster below the eligible members' average level (integer
     division).
   - Each award is for the whole group's damage.
4. **Any other group, the individual award** (`FUN_004c4820`): the player's own damage,
   ×(1 + (n−1)·0.03) in a party (n = every member). It is halved for a party monster below the
   receiver's level.
5. **Per receiver**, `Formula_ExpRewardForContributor` `0x410110` and `Formulae::FUN_004106b0`
   `0x4106b0`, re-read in the asm this round:

   ```
   EXP = ftol(float32(base·slot359) · share · Window · lag1cd8 · Diff), floor 1
   SP  = base·slot359·100/expUnit(rcv) · share · Window · lag1cdc · Diff, floor 1, ftol (int32)
   ```

   - `base` is the victim's **ExpToGive**, characterdata col 79, for every receiver (slot 332;
     see "The base EXP" below). Without the column it falls back to the old `KillBase`.
   - `share` is damage/MaxHP clamped to [1e-6, 1] (`0xb45c84`).
   - `Window` and `Diff` are evaluated at the engine's float32 steps (`ExpWindowScale32`,
     `ExpDiffScale32`).
   - `slot359` is `leveldata.MonsterExpFactor`: 7.5 for a party monster, × the rank's factor
     (champion 2, giant 15, rank 5 60, elite 4, rank 7 30). A rank outside the table drops even
     the party factor.
   - `lag1cdc` is `MasterySPScale`, the mirror of the EXP lag scale, **clamped to [0.1, 1.9]**
     like its twin (`0x4e31af`-`0x4e31e9`). A lagging mastery earns more SP, up to x1.9.
6. **vslot_420** (`0x4ea6a0`):
   - EXP and SP are stored to a float32, × the multiplier (itself a float32 argument,
     `fld DWORD [ebp+0x10]`), and truncated. The SP formula's product is stored to a float32
     before its floor and ftol (`0x41083e`).
   - The rate bonus applies only at a rate of 1.01 or more (`0xb46178`). It adds `EXP·(r−1)` and
     `SP·(r−1)`. The rate is ExpRatioParty for a receiver in any party, otherwise ExpRatio.
   - Then GainExpAndLevel: SP through `skills.AddSkillExp` (the guild-points wrapper still sees
     it), EXP through the level table, with a level-up for any receiver.
7. **Every kill pays SP**, by the formula above. The old "a kill pays its own EXP as SP" (M = 1)
   is gone; round 709 had already corrected the census that justified it.

**Party monsters.**
- **Arming:** the nest is armed only from the share path's count: the last exp-share group's
  eligible members, against `nest.PartyArmCount` 2 (`session/nestkill.go`). A free-for-all kill
  writes 0. The measurement is from the kill credit, not the dead monster.
- **Attack:** a party monster's attack value is ×1.2 before defence, and an **elite's (rank 6)
  ×1.5, party or not** (`combat.MonsterAttackFactor`, READ `FUN_0040da20`), applied in
  `monsterBlow` to the range, or to the flat attack.
- **HP and rolls:** HP ×10, the 50/101 roll, the level clamps and the species-rarity coverage were
  already right (`combat.ScaleHPForMonster`, `nest.RollClass`, `nest.ClampClassByLevel`, checked
  against the review's corrections).

**Items and gold** (`session/itemshare.go`, `session/grounditem.go`, `grounditem`, `party`).
- **Pick-up rights:** someone else's drop needs the party's **Item Auto Share** flag, not just the
  same party (`samePartyFunc`).
- **Item Auto Share item, the round robin** (`FUN_00525dc0`):
  - The next member of the party's rotation (`party.Hub.NextInRotation`, `FUN_004d4840`: the front
    goes to the back, a joiner is appended, a leaver removed) who is found, alive, in the zone and
    within 1000 of the picker in 3D.
  - With the EBX fallback quirk: the last member tried keeps the item when he failed on alive or
    zone; a distance failure clears him and the picker gets it.
  - Owner-only items (3/3/9 but not `ITEM_QNO_RM_ARCHEMY*`) stay the picker's.
  - A full bag on the chosen member refuses the picker **`0x18da`** and leaves the item on the
    ground.
- **The notice `0x3068`** goes to the party's members (`party.ItemNotice`):
  - u32 recipient JID, u32 RefItemID, then a u16 count for an expendable (TypeID 3/3) or the
    constant u8 1 for anything else. READ, GS `FUN_005bdc80`, client `c:0x873990`.
  - The gold branch is 8 bytes (OURS, the client's width). It is encoded and fixtured but not
    sent, see the OPEN list.
- **Gold under Item Auto Share** (`FUN_005bc7f0`): the picker and the members in the zone within
  1000 in 3D (alive or not) take `amount / n` each. The picker takes the remainder, or everything
  when `amount / n` is 0.
- **The aggro link** now needs the party's Exp Auto Share flag, the real bit
  (`monsterai.linkAggro`).
- **The unique-kill notice** groups by the exp-share flag (`partyGroupOf`).
- **A kill by a state's tick whose killer has left the world** still pays everyone else its damage
  list earns a share (`status.go settleKill`). The distributor does not depend on who landed the
  last tick.

## Files of round 710 touched (S1's lane)

- `server/internal/party/party.go`: the rotation list. The hub field `rotation`, kept in step by
  Form/Add/Remove, and `NextInRotation`. Nothing else.
- `server/internal/party/wire_test.go`: three `0x3068` rows in the fixture-coverage map.
- `client/scripts/net/fixtures/party/gen_fixtures.py` and `README.md`: three `0x3068` cases
  (`3068_expendable`, `3068_other`, `3068_gold`), built from the spec table. Rerunning the
  generator left the other 57 files byte-identical.

Tests outside the lane changed with the behaviour:
- `cmd/server/main_test.go`: DropRules carries `Expendable`.
- `session/combat_test.go`: the kill's SP is no longer equal to its EXP.
- `session/guildpoints_test.go`: the fixture kills a rank-5 monster wounded to 1 HP, because a
  level-1 kill's own SP, 119, converts to no points at 400:1.
- `systems/orphans_test.go`: `ItemShare` is now called. `KillExp`, which the kill path no longer
  calls (it is Formula_MonsterExpReward, the PC-death formula), and `DecodeItemNotice` are listed
  with reasons, and the detector's "is called" control moved from `KillExp` to `KillBase`.
- `session/partyexp_test.go` is removed with the helpers it tested (`applyPartyExpBonus`,
  `killExpFor`, `applyMasteryExpScale`). Their replacements are covered in
  `killreward_test.go` and `killshare_test.go`.

## OURS and INFERRED

| what | label |
|---|---|
| The base EXP falls back to the level table's EXP unit at the lower level (`Table.KillBase`) only for a monsters CSV without col 79 | OURS (fallback; the base itself is READ) |
| Group order: first-hit order. Ties keep the first group; the last exp-share group in that order sets the arming count | OURS (the engine's order is READ: heap-address order of the group objects, a std::map keyed by pointer; not reproducible) |
| "Same world" is the same zone bucket, for the party share, the round robin and the gold split | OURS (one world; the existing approximation) |
| The round robin's not-found member clears the kept candidate (the lookup's null) | READ (`0x525f90`-`0x525f9a`; review) |
| The formation's two members enter the rotation in member order | INFERRED (`FUN_005bc210` appends joiners; the formation's order was not read) |
| The attack factor's integer truncation | OURS (the engine keeps a float32 through the roll, `0x40dcf4`) |
| The attack factor applies to a drawn monster skill's range | INFERRED (the engine scales the attacker's own stat) |
| `0x3068`'s gold amount is 8 bytes | OURS (the spec's choice) |

## What was tested

**Go**, `go test -count=1 -p 1 ./...`: green, 65 packages ok (again after the review fixes). `go test -race` on the new tests
is clean. New tests:
- `leveldata/killreward_test.go`:
  - the spec's worked examples: 2/4/8 × level 50 → 0.55/0.325/0.2125; 80, 10, 10 →
    0.88/0.12/0.12; free-for-all 4/4 → 1.09;
  - the three damping conditions;
  - the Country bonus;
  - the party-monster penalty;
  - every vslot_359 rank;
  - the share clamp;
  - both contributor formulas, with their floors;
  - float32 rounding before the multiplier;
  - the rate floor, additive bonus and SP;
  - `MasterySPScale`.
- `session/killshare_test.go`:
  - an exp-share party of two (599/59 each from 1090/109);
  - eligibility: 1000 in, 1001 out;
  - the kill credit outside the party (the party 5000 away gets nothing and counts 0);
  - free-for-all (577/57 each to the two hitters at ×1.06, nothing to the idle member);
  - solo (1090/109);
  - a party monster ×7.5.
- `session/itemshare_test.go`:
  - the round robin in turn;
  - the fallback with a dead, other-zone or distant last candidate;
  - the gold split (the remainder, a dead member sharing, one coin);
  - the attack factors.
- `session/nest660_wire_test.go`: the count measured from the kill credit, and a free-for-all
  party arming nothing.
- `party/itemnotice_test.go`: `0x3068` against the fixtures; the rotation.

**Live, the real server binary** (in memory, `-leveldata-csv`, `-monsters-csv`, `-chargen-csv`
generated on the box into the session scratchpad and deleted after; five bots in
`-gm-accounts`), with the new `partybot -mode share`:

```
--- 1: the baseline, a solo kill (multiplier 1)
[psSolo] killed chakji #25 (HP 1031): EXP +51, SP +327
--- 2: an Exp Auto Share party of two; one member kills
[psKill] killed chakji #26 (HP 1031): EXP +28, SP +179
    killer +28 EXP, mate +28 EXP; want both trunc(51 x 0.55) = 28
--- 3: an Exp Free-For-All party of two; one member kills
[psFfa] killed chakji #27 (HP 1031): EXP +52, SP +336
    killer +52 EXP, idle member +0 EXP; want trunc(51 x 1.03) = 52 and 0
--- all share steps passed
```

Each kill is real. A GM `/damage` books MaxHP−1 to the killer on the monster's damage list and
pays nothing itself, then a swing lands the killing blow. The mate's EXP was read back through
`OpCharacterStats`. SP: 327 → 179 (= trunc(327 × 0.55)) → 336 (= trunc(327 × 1.03)) also follows
the multiplier. (That was the first build, whose SP lag scale was unclamped at 1 + 20 × 0.1 = 3.0; the
engine clamps it at 1.9, and the rerun after the review's fixes, below, pays 207.)

**Not tested live; unit tests only:**
- nest arming (the observer is installed only with `-full-map`);
- the item round robin, the gold split and `0x3068` (live drops need a ground hub with drop
  tables);
- the party-monster factors.

## Gaps, for other lanes

- **The berserk party share** (`Party_ShareHwanCount` `0x5bcf30`: orbs to every member alive in
  the killer's world, for exp-share parties) is still not wired; `grantKill` credits the killer
  alone. Not in S2's plan; for a later lane.

- **A receiver other than the killer is told nothing of the EXP and SP he gained.** Retail tells
  every receiver with `0x3056` (Client_ApplyExpAndLevelUp, `payload_layouts.tsv`), which neither
  side speaks yet. The row is right; the client's gauge catches up on the next stats read.
  OpLevelUp is sent to any receiver who levels.
- **The other members of a gold split, and the round robin's recipient, are told nothing.**
  - Gold: retail credits each member with reason 0x17 (`0x5bc9b8`), shown as
    UIIT_MSG_PARTYGET_GOLD; OpenSRO has no gold-change message.
  - Item: `0x3068` is sent, but the client does not decode it until lane C1/C2. The picker's own
    pick-up result still says "acquired" for an item that went to someone else. Its inventory
    refresh is right.
- **The full-bag member** is told `0x1807` in retail (op result `0xb034`); OpenSRO has no message
  for it. The picker's `0x18da` is sent; the client needs its line (`_pick_up_refusal_line`).

## OPEN

- ~~Slot 332~~ READ: ExpToGive, col 79 (below).
- ~~Whether the gold split sends `0x3068`~~ READ: it does not. `FUN_005bc7f0` calls only
  `0x485dc0`, the picker's slots 2 and 5, `0x5bdb30`, `0x4745d0` and slot 91; never `0x5bdc80`
  (review). The members are credited through the gold-gain slot only.
- **The field world's party-monster gate.** OpenSRO spawns only the field world
  (`nest/join.go`), so the instance worlds' `PARTYMONSTER_SPAWN` gate has nothing to act on; no
  gate is applied.
- ~~The group map's order~~ READ (heap-address order); first-hit order stays OURS.
- **The gold event above 1000** (vtable `0x274`, `0x4ead1f`): what it does is unread; not
  modelled.
- **Specialty goods** are excluded from the round robin in retail. OpenSRO drops none, so the
  test is not modelled.
- **The pet pick-up** (`GObjPC::FUN_004d5510`): OpenSRO has no picking pet; not modelled.


## Review fixes (`docs/rounds/party712_review.md`)

### The base EXP: col 79, ExpToGive. The review is right, and the record is overturned

Re-read with objdump on `/var/tmp/SR_GameServer.exe` and the raw PE. Every step of the chain from
a monster's death to the field:

1. **The death distributor calls the PC award.** `CGObjMob::vslot_399` `0x4c44a0` calls `0x5bca60`
   (party share, `0x4c4777`) or `0x4c4820` (individual award, `0x4c4786`). Both call `[vt+0x690]`
   on the receiver (`0x4c48b4`, `0x5bceb4`). Slot 420 of CGObjPC's vtable (`0xaf59fc`, RTTI
   `.?AVCGObjPC@@`; the only place `0x4ea6a0` appears in the image) is `0x4ea6a0` = vslot_420.
2. **vslot_420 calls the two contributor formulas**: `0x410110` at `0x4ea7a8` and `0x4106b0` at
   `0x4ea7d4`. The other callers are a twin at `0x4fcbcc`/`0x4fcbf5`.
3. **Both formulas call `[victim vt+0x530]`**, slot 332 (`0x4101e8`, `0x4107f8`). CGObjMob's vtable
   `0xaeddac` (RTTI `.?AVCGObjMob@@`; slot 359 `0x4c15c0` confirms the table) has slot 332 at
   `0xaee2dc` = **`0x4a68b0`**:

   ```
   4a68b0: mov ecx,[ecx+0x34]   ; the object's instance
   4a68b3: mov eax,[ecx]
   4a68b5: mov edx,[eax+0x34]   ; instance slot 13
   4a68b8: jmp edx
   ```

4. **Slot 13** is **`0x449340`** in every CInstanceChar-family vtable. Its five references in the
   image are exactly these vtables' `+0x34`:
   - `CInstanceChar` `0xae3724`, `CInstanceCOS` `0xae3494`, `CInstancePC` `0xb0d12c`;
   - `CInstanceSiegeFortressStruct` `0xb0d1e4`, `CInstanceSiegeFortressObject` `0xb0d86c`.

   It reads:

   ```
   449340: mov eax,[ecx+0x18]   ; the reference row
   449343: mov eax,[eax+0x250]
   449349: ret
   ```

5. **`CRefObjChar+0x250` is col 79.** This is the project's anchored map (col 78 `+0x24c`, col 82
   `+0x25c` = KO_RecoverTime 3000).
   - The package's DB `_RefObjChar.csv` names the column **`ExpToGive`**, between `CHR` (78) and
     `CreepType`, `Knockdown`, `KO_RecoverTime` (80-82).
   - The fresh export agrees: MOB_WC_GUNPOWDERGHOST L28 carries 749 = exp_unit(28);
     MOB_EU_KERBEROS 40000.

**And the other formula is PvP.** `0x4105d0` (`Formula_MonsterExpReward`, the min-level rule) opens
with `call [eax+0x1c]` on both ESI and EDI and returns unless both are PCs (`0x4105d9`-`0x4105f3`).
Its only callers are `0x4e6a09` and `0x4e6d88`, in the PC death code.

**Why the 2026-09-14 probe missed it.** It looked for integer readers of `+0x250` by
**intersecting** the readers of `0x250` with the readers of the proven MaxHP field `0x19c`, as a
proxy for "is this CRefObjChar". `0x449340` is a ten-byte accessor that reads `0x250` and nothing
else, so the intersection could not keep it. It is also reached only through the slot-332 vcall
thunk (no direct caller), and the decompile files it as `CInstanceCOS::FUN_00449340`, which reads
like a pet-only helper. **Lesson: an intersection with a "type marker" field filters on function
size, not on type. An accessor reads one field.**

**What changed:**
- `species.ColExpToGive` = 79 is exported as the monsters CSV's appended `ExpToGive` column. It is
  optional on read, so an older CSV still loads, with `HasExpToGive` false.
- It is carried on `monsterSpec`, `combat.Species` and `combat.Monster`.
- It is used as the base for every receiver.
- `Table.KillBase` remains only as the fallback.
- `party_rules.md`'s OPEN row is closed; WORLD_ISSUES' round-175 col-79 note and its kill-EXP note
  carry "(Round 712)" corrections; `combat.ExpFor` and `leveldata.go` have the same correction.

**For the memory note `reference_characterdata_columns.md`** (the coordinator updates the file).
Two claims are wrong:
- "No function reads CRefObjChar+0x250 as an integer ... col 79 is dead data" is false: `0x449340`
  reads it, through slot 332.
- "MOB EXP SOLVED: a kill is worth leveldata col 5 at min(killerLevel, victimLevel)" is false for
  monster kills. That is the PvP formula. A monster kill's base is the victim's col 79, ExpToGive,
  which for an ordinary monster equals leveldata col 5 at the **monster's own** level, and is
  larger for uniques.

What the note still has right: the column map itself, the 95.3 % match and the death penalty's use
of col 5.

### Fixes table

| # | finding | fix | test |
|---|---|---|---|
| 1 | SP lag `0x1cdc` clamped [0.1, 1.9] | `MasterySPScale` clamps; comments in `leveldata.go` and this page corrected | `TestMasterySPScale` (level 20, ref 0: 1.9); live solo SP 327 -> **207** |
| 2 | base = ExpToGive (col 79) | verdict and evidence above; export, carry, use, fallback | `TestKillShareReviewThreeMembers` (36/35/39 EXP, 83 SP, the review's hand numbers); `TestKillShareExpToGiveFallback`; `species.TestExpToGiveColumn`; the sentinel-line test reads col 79 |
| 3 | lost updates on the row | `character.LockLeveling` around every GetByID -> SetLeveling: the kill award, the stat spend (`stats.go`), the death penalty (`monsterstrike.go`, the EXP re-read under the lock) and `/level` (`gm.go`) | `TestKillShareNoLostUpdate` (50 concurrent awards, none lost) |
| 4 | float32 steps | `ExpWindowScale32`/`ExpDiffScale32` (the asm's stores) used by both formulas. The party bonus, the damped bonus, the penalty and the multiplier are float32 (`0x5bcd62`/`0x5bcd6a`/`0x5bcea3`/`0x5bcec8`). The free-for-all multiplier is a float32 | `TestLevelScalersFloat32` (14 vs 7: 0.39999998); the worked examples at float32 |
| 5 | `0x3068` recipients and gate | sent to every member but the recipient (`0x5bb770` skips him); sent for owner-only items too; never for gold | `TestItemNoticeSkipsTheRecipient` |
| 6 | attack-factor labels | the truncation is OURS (the engine keeps a float32); applying to a skill's range is INFERRED | -- |
| 7 | three rows upgraded | the not-found candidate is READ; the group order is READ as address order (OURS kept); the gold split sends no `0x3068` (READ) | -- |
| 8 | `party_protocol.md:191` | "recipient JID", with the addresses; and "to every member but the recipient" | -- |
| 9 | berserk party share | listed in the gaps above | -- |

**Live again** (`partybot -mode share`, the real server binary, the monsters CSV re-exported with
col 79 on the box and deleted after):

```
[psSolo] killed chakji #25 (HP 1031): EXP +51, SP +207
    killer +28 EXP, mate +28 EXP; want both trunc(51 x 0.55) = 28        (SP +113)
    killer +52 EXP, idle member +0 EXP; want trunc(51 x 1.03) = 52 and 0  (SP +213)
--- all share steps passed
```

The same run against MOB_WC_GUNPOWDERGHOST (L28, ExpToGive 749) with level-20 bots:
- **Solo: EXP +99.** That is 749 x 0.1 x 1.33, where the old base paid 62. **SP +402.**
- **Exp-share party: +67 each.** That is 749 x 0.1 x 1.63 x 0.55. From 5 levels up an exp-share
  member also earns the party gap bonus +0.30, so the share mode's x0.55-of-solo check (which
  failed as designed there) holds only below a 5-level gap. The mode's help now says so.

### What players will notice

**Skill points from kills drop sharply; EXP rises for anyone fighting above his level.**
- **Before round 712**, a kill paid its own EXP again as skill EXP (OpenSRO's disclosed M = 1).
- **Now** it pays the engine's own skill formula: `ExpToGive x 100 / your level's EXP unit`. That
  is about **109 skill EXP for an even-level kill at any level** (0.27 skill points at 400:1),
  rising to 207 for a character whose masteries lag his level by 9 or more.
- **EXP is unchanged at or above the monster's level.** It rises against a monster above you,
  because the base is now the monster's own value. Uniques pay their own, larger values.

Solo kills of an ordinary monster, real leveldata, computed with the round's functions (EXP / SP;
"before" SP was the EXP):

| player | monster | masteries | before EXP / SP | after EXP / SP |
|---|---|---|---|---|
| L10 | L10 | at level | 256 / 256 | 256 / 109 |
| L10 | L15 | at level | 291 / 291 | 437 / 186 |
| L10 | L10 | none | 26 / 26 | 25 / 207 |
| L50 | L50 | at level | 2212 / 2212 | 2211 / 109 |
| L50 | L55 | at level | 2516 / 2516 | 2988 / 147 |
| L50 | L50 | none | 221 / 221 | 221 / 207 |
| L100 | L100 | at level | 10178 / 10178 | 10178 / 109 |
| L100 | L105 | at level | 11579 / 11579 | 13424 / 143 |
| L100 | L100 | none | 1018 / 1018 | 1017 / 207 |

So a level-100 player who kept his masteries up earned about 25 skill points a kill and now earns
about 0.27, roughly 90x less. This is what the original's formula pays (READ, `0x4107f0`-
`0x41082c`). Before release the user should hear it, since it changes everyone's SP income.
