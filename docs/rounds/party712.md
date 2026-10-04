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

   - `share` is damage/MaxHP clamped to [1e-6, 1] (`0xb45c84`).
   - `slot359` is `leveldata.MonsterExpFactor`: 7.5 for a party monster, × the rank's factor
     (champion 2, giant 15, rank 5 60, elite 4, rank 7 30). A rank outside the table drops even
     the party factor.
   - `lag1cdc` is `MasterySPScale`, the unclamped mirror of the EXP lag scale. A lagging mastery
     earns more SP.
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
| The base EXP (slot 332) is the level table's EXP unit at the lower of the receiver's and the victim's levels (`Table.KillBase`, what `KillExp` always paid). The engine's slot 332 is the victim's alone; CGObjMob slot 332 → the ref object's vtable +0x34 is unread | OURS (OPEN base) |
| Group order: first-hit order. Ties keep the first group; the last exp-share group in that order sets the arming count | OURS (the engine's map order is OPEN) |
| "Same world" is the same zone bucket, for the party share, the round robin and the gold split | OURS (one world; the existing approximation) |
| The round robin's not-found member clears the kept candidate (the lookup's null) | INFERRED |
| The formation's two members enter the rotation in member order | INFERRED (`FUN_005bc210` appends joiners; the formation's order was not read) |
| The attack factor's conversion back to an integer truncates | INFERRED |
| `0x3068`'s gold amount is 8 bytes | OURS (the spec's choice) |

## What was tested

**Go**, `go test -count=1 -p 1 ./...`: green, 65 packages ok. `go test -race` on the new tests
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
the multiplier. The level-20 bots have no masteries, so the SP lag scale is 1 + 20 × 0.1 = 3.0.

**Not tested live; unit tests only:**
- nest arming (the observer is installed only with `-full-map`);
- the item round robin, the gold split and `0x3068` (live drops need a ground hub with drop
  tables);
- the party-monster factors.

## Gaps, for other lanes

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

- **Slot 332**, the monster's base EXP: OpenSRO keeps today's base (above).
- **Whether the gold split sends `0x3068` too.** The client has a gold branch in its handler, and
  `FUN_005bdc80` has a gold-class branch. But its two callers (`0x4d517a`, `0x5263dd`) are the
  item paths, and `FUN_005bc7f0` was not traced to it. Not sent until read.
- **The field world's party-monster gate.** OpenSRO spawns only the field world
  (`nest/join.go`), so the instance worlds' `PARTYMONSTER_SPAWN` gate has nothing to act on; no
  gate is applied.
- **The group map's order** (above).
- **The gold event above 1000** (vtable `0x274`, `0x4ead1f`): what it does is unread; not
  modelled.
- **Specialty goods** are excluded from the round robin in retail. OpenSRO drops none, so the
  test is not modelled.
- **The pet pick-up** (`GObjPC::FUN_004d5510`): OpenSRO has no picking pet; not modelled.
