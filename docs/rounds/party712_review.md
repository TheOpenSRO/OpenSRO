## Round 712 review: party lane S2 (kill distributor, EXP/SP sharing, round robin, gold split, `0x3068`, party monsters)

*Adversarial review of `3fbdd82f` (`int/party..worktree-agent-a0080a11b004fde9d`). No code was changed.*

*Method.*
- **Disassembly.** Every address below was re-read with `objdump -d -M intel` on
  `/var/tmp/SR_GameServer.exe`.
- **Constants.** Every float was read from the raw `.rdata` bytes
  (`/var/tmp/r709review_rules/rd.py`), and its type was taken from the operand size.
- **Vtables.** Slots and classes were read from the PE's RTTI with a throwaway script
  (`/var/tmp/r712rev`, deleted after).
- **Hand computation.** The numbers come from an independent Go model of the asm,
  written in the worktree and not committed.
- **Live run.** The real server binary and `partybot` ran with the leveldata, monster and
  chargen CSVs, which were copied off the box for the run and deleted after.

**Bottom line.**
- **What holds.** The sharing rules are right:
  - the grouping and the kill credit;
  - the split by level, the 10 %/20 % bonus and the 70 % damping;
  - the party-monster halving and the free-for-all 3 %;
  - the per-receiver formula's structure, and the `vslot_420` multiplier and rate bonus;
  - the round robin's EBX rule and the gold split;
  - arming from the share count.
- **Two numbers that every player earns are wrong.**
  - The SP mastery-lag scale is clamped in the engine, and the round leaves it unclamped
    while labelling that READ.
  - The kill's base EXP (slot 332) can be read: it is the monster's own `ExpToGive`,
    characterdata column 79. The stand-in underpays anyone below the monster's level, in
    and out of parties.
- **Smaller issues.** One new race, a float32 precision gap, two `0x3068` details and
  four labels.

---

### Findings, most severe first

#### 1. BUG + WRONG-LABEL: the SP mastery-lag scale `pc+0x1cdc` is clamped to [0.1, 1.9]; the round leaves it unclamped and calls that READ

**Where.**
- `server/internal/leveldata/killreward.go:80-93` (`MasterySPScale`; the comment says "READ … with no
  clamp").
- `docs/rounds/party712.md:40` ("the unclamped mirror"), and line 172 ("the SP lag scale is
  1 + 20 × 0.1 = 3.0").
- The source of the error is older: `leveldata.go:157` and `:317` (`pc[0x1cdc] = 1 - (ref - charLevel) * 0.1 // the mirror`).

**Evidence**, from `GObjPC_RecalcLevelDiffExpScale` `0x4e30d0`. The FPU stack was traced instruction by instruction.

```
4e3149: fstp DWORD [esp+0x8]          ; SPv = f32(1 - (ref-char)*0.1)
4e3151: fst  DWORD [esi+0x1cdc]       ; first store: unclamped  <- what was read before
...                                   ; the 0x1cd8 clamp, then:
4e31af: fxch st(4)                    ; st0 = 0.1 (double 0xb45ec0)
4e31b1: fcomp st(3)                   ; 0.1 vs SPv
4e31b5: test ah,0x41 ; jne 0x4e31d3   ; SPv <= 0.1 falls through:
4e31ba..4e31c8: ... fstp DWORD [esi+0x1cdc] = 0.1f    ; floor (0xb45eb8 = 0.1f)
4e31d3: fstp st(3) ; fcomp st(1)      ; X (0xb45f10 = double 1.89999997615814) vs SPv
4e31d9: test ah,0x41 ; jne 0x4e31be   ; SPv >= X:
4e31be..4e31c8: fstp DWORD [esi+0x1cdc] = 1.9f        ; cap (0xb45f18 = 1.9f)
4e31de..4e31e9: else [esi+0x1cdc] = SPv
```

The first store at `0x4e3151` is overwritten by the clamped value at the end. That is how a
quick read turns into "no clamp". The upper compare is against the double `1.8999999761…`, the
float 1.9 widened, so in practice the clamp is [0.1f, 1.9f], the same as the EXP scale.

**Effect.** Every character whose best mastery is more than 9 levels below his own level is
overpaid SP. The overpayment has no bound.

Solo, same-level kill, real leveldata, no masteries:

| level | Go SP | engine SP |
|---|---|---|
| 10 | 218 | 207 |
| 20 | 327 | 207 |
| 50 | 654 | 207 |
| 100 | 1199 | 207 |

Live (below): the killer's SP is **175** where the engine pays **83**. The round's own live
baseline, `SP +327`, is 207 in the engine.

**Fix.**
- `MasterySPScale`: clamp the result to `[MasteryExpScaleMin, MasteryExpScaleMax]`, as
  `MasteryExpScale` already does, with 1.0 above 120.
- Correct the three comments and the round notes, and add a test at level 20, ref 0, that
  expects 1.9.

#### 2. BUG: slot 332, the kill's base EXP, is the victim's `ExpToGive` (characterdata col 79), not the stand-in "EXP unit at min(receiver, victim)"

**Where.**
- `server/internal/leveldata/killreward.go:206-219` (`KillBase`).
- `server/internal/session/killshare.go:298-303`.
- The base is labelled OURS/OPEN honestly (`party712.md:116`). This finding is not about the
  label: the spec's next probe ("read the ref-char vtable slot 13", `party_rules.md` OPEN table)
  answers it.

**Evidence.**
- **The call.** `0x410110` and `0x4106b0` call `[vt+0x530]` on the victim. CGObjMob's vtable
  (`0xaeddac`, RTTI `.?AVCGObjMob@@`) has slot 332 = `0x4a68b0` (and slot 359 = `0x4c15c0`,
  confirming the table).
- **The thunk.** `0x4a68b0`: `mov ecx,[ecx+0x34] ; mov eax,[ecx] ; mov edx,[eax+0x34] ; jmp edx`.
  That is slot 13 of the object's instance.
- **Slot 13.** It is `0x449340` in every CInstanceChar-family vtable:
  - `CInstanceChar` `0xae3724`, `CInstanceCOS` `0xae3494`, `CInstancePC` `0xb0d12c`;
  - `CInstanceSiegeFortressStruct` `0xb0d1e4`, `CInstanceSiegeFortressObject` `0xb0d86c`.
- **No other candidate.** The runtime-class table at `0xade3e4` gives CInstanceChar no create
  function; the only concrete char instances are COS (`0x841420`, size 0x80), PC and the siege
  pair, all with the same slot 13. No other instance class has a real slot 13: the
  item/slot/inventory ones are short vtables. The mob's exact instance class was not traced
  (INFERRED by elimination), but every candidate answers the same.
- **What slot 13 returns.** `0x449340` is `return *(*(this+0x18) + 0x250)`: the ref row's
  `+0x250`.
- **Which column.** `RefObjChar_ExtractData` (`0x6a58f0`) writes `+0x24c`, `+0x250`, `+0x254`,
  the byte at `+0x258`, then `+0x25c` in sequence. The project's anchored map
  (characterdata-columns note) puts col 78 at `0x24c`, col 79 at `0x250` and col 82 at `0x25c`
  (default 3000).
- **The server's own name for it.** The package's DB export
  `/opt/sro-files/db/csv/_RefObjChar.csv` names the column after `PD,MD,PAR,MAR,ER,BR,HR,CHR`
  as **`ExpToGive`**, followed by `CreepType,Knockdown,KO_RecoverTime`. That is the same run of
  offsets.

**What it is in data.** For ordinary monsters, `ExpToGive` equals leveldata col 5 at the
**monster's own level**. In the client data that holds for 95.3 % of the MOB rows, with uniques
overridden upward (KERBEROS 40000 against 12550). In this package's DB, MANGNYANG, GYO, YEOHA,
CHAKJI, TIGERWOMAN and KERBEROS all equal `exp_unit(own level)`. The receiver's level plays no
part.

**Effect.** Any receiver below the monster's level is underpaid, in EXP and in SP:

| receiver | monster | Go EXP / SP | engine EXP / SP |
|---|---|---|---|
| 20 | 25 | 582 / 124 | 779 / 165 |
| 20 | 30 | 653 / 139 | 1170 / 249 |
| 1 | 5 | 29 / 121 | 142 / 594 |

In a party share, the low-level members are underpaid. In the three-member case below the
level-20 member gets 24 EXP where the engine pays 39. Uniques with an overridden `ExpToGive` are
mispaid too.

At or above the monster's level, `min()` already picks the victim's level, so solo farming at
or above level is unchanged.

**Fix.**
- Export characterdata col 79 into `monsters.csv` (`export-refdata -mode monsters`) and carry it
  on `combat.Monster`.
- Pass it as `RewardInput.Base` for every receiver.
- Drop the min-level rule from the kill path. It belongs to `Formula_MonsterExpReward`
  `0x4105d0`, which requires both sides to be PCs (`0x4105d9`/`0x4105e8` slot 7 tests), so it is
  the PvP formula.
- Keep `KillBase` only as the fallback for a CSV without the column, and say so.
- Close the OPEN row in `party_rules.md`.

#### 3. RACE: `lockExp` guards only the kill path; the other `SetLeveling` writers race with a party share

**Where.**
- `server/internal/session/killshare.go:217-227` and `:254`.
- The unlocked writers:
  - `session/stats.go:440` (stat-point spend);
  - `session/monsterstrike.go:488` (death penalty);
  - `gm/gm.go:592` (`/level`).

**Evidence.** All four writers do GetByID, then SetLeveling with the full row: level, EXP, stat
points, Str and Int.
- **What was already exposed.** Before this round, a character's row was written by its own
  session plus the monster AI and status goroutines.
- **What is new.** Since this round, any party member's kill writes every eligible member's row
  from the killer's goroutine.

Interleaving with a stat spend:
1. `payAward` reads the row.
2. `stats.go` reads the row.
3. `payAward` writes the level-up.
4. `stats.go` writes the old level and EXP with the spent points.

The level-up is lost. The reverse order silently undoes the spend. A death penalty that lands
during a share loses either the share or the penalty. `go test -race` cannot see this: it is a
lost update, not a data race.

**Fix.** Either:
- take `lockExp(characterID)` around the read-modify-write in the three other writers; or
- make EXP and level changes a single conditional `UPDATE` in the store.

#### 4. BUG (minor, precision): the level scalers and the share bonus are rounded once in Go, twice in the engine

**Where.**
- `killreward.go:136-147` and `:293-312`.
- `leveldata.ExpWindowScale` and `ExpDiffScale`, which return float64.

**Evidence: the window.** `0x40ff41`-`0x40ff4f` stores `(n)×0.15` (and `0x40ff76`-`0x40ff84`
stores `(gap−10)×0.02`) to a float32 before the `1 −`, which is stored again at `0x40ff8c`. For
example, rcv 14 against vic 7 gives `1 − f32(0.6)` = 0.39999998, where Go gives
`f32(1 − 0.6)` = 0.40000001.

**Evidence: Diff.** `0x41008b`-`0x41009a` stores `f32(bonus + 1.0)` before adding `steps×0.03`
(`0x4100be`-`0x4100cc`). The bonuses themselves are float32 (`0xb45dd0` 0.15f and so on), while
Go uses float64 decimals.

**Evidence: the party bonus.** It is stored as a float32 (`0x5bcd62`/`0x5bcd6a` for the
`c×0.1` term and the sum; the damped bonus at `0x5bcea3`). The multiplier is
`f32(s × b × penalty)` with `b` a float32 (`0x5bcea7`-`0x5bcec8`). `PartyShareMultipliers`
multiplies the float64 bonus.

**Effect.**
- At share 1 and lag 1, real leveldata, the same base on both sides: **19 kills in the 110×110
  level grid pay one EXP point more in Go**. All of them are out-levelled by 7 (14→7: Go 66,
  engine 65; 17→10: 94 against 93; 27→20: 188 against 187).
- **2930** level pairs differ by an ulp in a scaler.
- **69 of 300** party multipliers differ by an ulp; one can flip a truncation.

**Fix.**
- Evaluate `Window` and `Diff` in float32 steps exactly as the asm does, as new functions used
  by `ContributorExp`/`ContributorSP`, leaving `KillExp`'s callers alone.
- Store `PartyShareBonus` and the damped bonus as `float32`, and form the multiplier as
  `float32(s)*float32(b)*float32(p)`.

#### 5. BUG (minor): `0x3068` goes to every member but the recipient, and is sent for owner-only items too

**Where.** `server/internal/session/itemshare.go:124-131` and `session/grounditem.go:538-545`.

**Evidence: the exclusion.**
- `FUN_005bdc80`: `0x5bdcce` `call [vt+8]` on the recipient (`[esi+0x28]`) gives
  `[esp+0x10]`, which is written as the notice's first u32 (`0x5bdcf1`) and passed again as the
  second argument of `CParty::BroadcastToLocalMember` (`0x5bdd59 push edx` = `[esp+0x10]`,
  `0x5bdd61 call 0x5bb770`).
- `0x5bb770` skips the member whose id equals that argument when it is non-zero
  (`0x5bb811`-`0x5bb81d`).
- So the recipient is excluded. The chat broadcast passes 0 instead (`0x5bf062 push ebx`,
  ebx = 0), which is why chat echoes.

**Evidence: the gate.**
- `FUN_00526090` calls `0x5bdc80` on any successful add when `[esp+0x1c]` is 0 and the picker
  has a party (`0x5263c8`-`0x5263dd`).
- `[esp+0x1c]` is item slot 31 (`0x5262a1`-`0x5262aa`), which is `CGObj::IsGold` (`0x483120`,
  CGItem vtable `0xae9384`).
- The owner-only path sets EBX = the picker (`0x525f59` → `0x52606d`) and still returns 1.
- So an owner-only item picked up in an Item Auto Share party is announced; only gold is not.

**Fix.**
- `sendItemNotice`: skip `recipient`.
- `grounditem.go`: drop `!it.OwnerOnly()` from the notice condition. Keep it for the round robin.

#### 6. WRONG-LABEL: the attack factor's "conversion back to an integer truncates" (INFERRED); applied to a drawn skill's range (READ)

**Where.** `server/internal/combat/rarity.go:111-121`, `session/combat.go:1658-1664`,
`party712.md:121`.

**Evidence: there is no conversion.**
- `Combat_ComputeWeaponDamage` `0x40db50` returns a **float**: `fstp DWORD [esp+4]`, then a clamp
  to [0, 999999] (`0xb45f20` double, `0xb45f1c` float).
- Its caller keeps the min and max as float32 through the roll (`0x40dcf4 fstp DWORD [esp+0x14]`,
  `0x40dd2a`-`0x40dd2e`).
- The truncation is OpenSRO's, forced by its integer ranges.

**Evidence: what the factor scales.** It scales the attacker's own stat, `vt+0x104` with param
`0xd`/`0xe` plus an item bonus (`0x40db5d`-`0x40dba4`). OpenSRO applies it to whatever range the
swing uses, including a drawn monster skill's `att` block (`monsterstrike.go:296`). Whether that
is the same quantity was not shown.

**Fix.**
- Label the truncation OURS: the engine keeps float32 (READ `0x40dcf4`).
- Label "applied to the skill's att range" INFERRED.

#### 7. WRONG-LABEL (upgrades): three OURS/INFERRED/OPEN rows can be READ

- **The round robin's not-found member clears the candidate** (`itemshare.go:53-55`,
  `party712.md:119`, INFERRED). This is READ: `0x525f90 call 0x485dc0 ; 0x525f95 mov ebx,eax ;
  test ebx,ebx ; je 0x526057`. EBX *is* the null.
- **The group map's order** (`killshare.go:39-41`, `party712.md:117`, "OPEN").
  - It is a `std::map` keyed by the group's object pointer, the party or the PC: the key
    `[esp+0x4c]` at `0x4c45ca`, compared unsigned in `0x9a25c0` (`cmp [ecx+0xc],edi ; jae`).
  - The top group is the first strict maximum in that order (`0x4c46ed cmp ecx,esi ; jbe`), and
    the last exp-share group in that order writes the count.
  - Heap-address order cannot be reproduced, so first-hit order stays OURS. The OPEN row can
    close, with "READ: address order".
  - The engine does **not** order individuals before parties. The flag is not part of the key.
- **Whether the gold split sends `0x3068`** (`party712.md` OPEN).
  - `FUN_005bc7f0`'s only calls are `0x485dc0`, the picker's slots 2 and 5, `0x5bdb30`,
    `0x4745d0` and slot 91 (`[vt+0x16c]`, reason `0x17`).
  - There is no `0x5bdc80`. READ: the gold split sends no `0x3068`. The members are credited
    through the gold-gain slot only.

#### 8. MINOR: `party_protocol.md:191` calls `0x3068`'s first field "picker JID"; it is the recipient

**Evidence.** `0x526074`/`0x52607e` store EBX, the round robin's recipient, at the transaction's
`+0x2c`/`+0x28`, and `0x5bdc95` reads `+0x28`. The code is right (`RecipientJID`); only the
protocol row is wrong.

**Fix.** Change the row's wording.

#### 9. MINOR / scope: the berserk party share (gap 15) is still not wired

**Evidence.** `Party_ShareHwanCount` `0x5bcf30` gives orbs to every member alive in the killer's
world, for exp-share parties and party-monster kills. `grantKill` still credits the killer alone.
This is not a regression (nothing changed), and lane S2's plan (`party_protocol.md:654`) does not
list it.

**Fix.** Assign it to a lane, or list it in the round's gaps.

---

### Hand-computed examples (engine model from the asm, against the Go)

**Real leveldata.**
- `exp_unit`: L1 24, L10 235, L20 470, L25 629, L28 749, L30 842, L50 2029, L100 9338.
- A normal monster's `ExpToGive` is `exp_unit(own level)`.

**Solo, same level, share 1, masteries at level.**
- Window 1, lag 1, Diff `f32(1+3×0.03)` = 1.09.

| level | EXP: Go / engine | SP: Go / engine | before round 712 (SP = EXP) |
|---|---|---|---|
| 1 | 26 / 26 | 109 / 109 | 26 |
| 10 | 256 / 256 | 109 / 109 | 256 |
| 20 | 512 / 512 | 109 / 109 | 512 |
| 50 | 2211 / 2211 | 109 / 109 | 2212 (rounded before) |
| 100 | 10178 / 10178 | 109 / 109 | 10178 |

**SP economy change, correct per the asm.** A same-level kill now pays 109 skill EXP at every
level (0.27 SP at 400:1), where it paid the kill's EXP before (25 SP a kill at level 100). This is
`ExpToGive × 100 / exp_unit(receiver)` (`0x4107f0`-`0x41082c`) and is what the engine does; tell
the user, because it changes every player's SP income by up to 90×.

**Same, no masteries** (finding 1): EXP lag 0.1 (clamped), SP lag 1.9.
- L20: EXP 51 on both; SP 327 in Go, 207 in the engine.
- L100: EXP 1017 on both; SP 1199 in Go, 207 in the engine.

**Exp-share party of two, level 50, one member deals all the damage** (the round's test): bonus
1.1, s = 0.5, multiplier 0.55, so both get trunc(1090 × 0.55) = 599 EXP and trunc(109 × 0.55) =
59 SP. This agrees.

**The worked examples:**
- 2/4/8 × level 50: 0.55, 0.325, 0.2125;
- levels 80, 10, 10: the 80 is damped to b = 1.1, giving 0.88; each 10 gets 0.12;
- free-for-all 4/4: 1.09.

All agree with `0x5bcd38`-`0x5bcee4` and `0x4c4820`.

**Three-member exp-share party (the live case).**
- Levels 30/25/20, all Chinese and within 1000; no masteries; a level-28 monster with HP 1535;
  the leader deals all the damage.
- Bonus `1+(3−1)×0.1` = 1.2.
- s = 30/75, 25/75, 20/75 = 0.4, 0.3333, 0.2667. No damping, since the largest s is 0.4.
- Multipliers 0.48, 0.4, 0.32.

| member | Go (KillBase, SP lag unclamped) | engine (`ExpToGive` 749, SP lag 1.9) |
|---|---|---|
| L30 | base 749: EXP trunc(749×0.1×1.03) = 77, ×0.48 = **36**; SP 749×100/842 × 4.0 × 1.03 = 366, ×0.48 = **175** | EXP **36**; SP 88.955 × 1.9 × 1.03 = 174, ×0.48 = **83** |
| L25 | base 629: EXP **29** | EXP 749×0.1×(1+6×0.03) = 88, ×0.4 = **35** |
| L20 | base 470: EXP trunc(470×0.1×1.63) = 76, ×0.32 = **24** | EXP 749×0.1×(1.33+0.30) = 122, ×0.32 = **39** |

**Live.** The real server binary ran in memory with the leveldata, monster and chargen CSVs, with
`partybot` rebuilt from this branch plus a throwaway `-mode rev3` (not committed):

```
[rva] killed MOB_WC_GUNPOWDERGHOST #25 (HP 1535): EXP +36, SP +175
REV3 rva L30 +36 EXP
REV3 rvb L25 +29 EXP
REV3 rvc L20 +24 EXP
REV3 killer SP +175
```

The server pays exactly what the Go model predicts: 36/29/24 EXP and 175 SP. The engine would pay
36/35/39 EXP and 83 SP (findings 1 and 2).

`partybot -mode share` was rerun, and all its steps passed:

| case | EXP | SP |
|---|---|---|
| solo | +51 | +327 (engine 207, finding 1) |
| share, killer and mate | +28 each | +179 |
| free-for-all, killer / idle member | +52 / +0 | +336 |

---

### Verified correct

**Grouping, `0x4c44a0`.**
- Entries with zero damage are skipped (`0x4c455b`).
- A COS counts for its owner (`0x4c4587`).
- Only PCs count (slot 7).
- The flag comes from `party+0x10 & 1`.
- A group sums its damage, and its biggest hitter is the strictly largest entry
  (`0x4c466b`-`0x4c467c`).
- The kill credit is the biggest hitter of the first strict-max group.
- Exp-share groups go to `0x5bca60(credit, party, victim, groupDamage, &count)`; any other group
  goes to `0x4c4820(pc, victim, groupDamage)`.

**The share, `0x5bca60`.**
- Eligibility:
  - found, alive (slot 62 == 1), same world;
  - horizontal distance ≤ 1000, inclusive (`0x5bcc84`);
  - measured from the credit, or from the victim when there is no credit.
- The bonus counts Country 0 against other Countries (`0x5bccc4`).
- The count is written as a WORD (`0x5bcd3a`).
- The penalty uses the integer average (`idiv` at `0x5bcddf`, then `0x410fd0`, strictly `<`).
- `s` is a float32 (`0x5bce5f`).
- The damping needs `s > 0.7`, at least 3 eligible (unsigned) and a top level ≥ 21.
- The award is `vslot_420(victim, groupDamage, mult, 3)`.

**The free-for-all award, `0x4c4820`.**
- `f32(1+(n−1)×0.03)` with `n = party+0x1c`.
- ×0.5 for a monster that is a party monster and below the receiver's level.
- Flags `0xffffffff`.

**The per-receiver formulas, `0x410110` and `0x4106b0`.**
- **Base:** `u32(slot332)×slot359` stored as a float32 (EXP only; SP keeps it in extended
  precision).
- **Share:** `f32(dmg)/f32(MaxHP)` clamped to [1e-6 (`0xb45c84`), 1].
- **Window and Diff:** evaluated for the receiver (`ecx=edi`; `esi=receiver`, `eax=victim`).
- **Diff's party gate:** receiver is a PC with a party and bit 0 (`0x410018`-`0x410027`).
- **Country:** `== 1` selects Europe (`0x410033`).
- **Out-levelled:** `vic+3 <= rcv` gives 1.0.
- **Steps:** capped at 13, the result clamped to [1, 4].
- **Window:**
  - −4..−6 gives 0.9f;
  - ≤ −7 gives `1−n×0.15`;
  - > +10 gives `1−(g−10)×0.02`;
  - clamped to [0.1, 1].
- **EXP:** ftol int64, a result ≤ 0 becomes 1 (`0x410352`-`0x410366`).
- **SP:** the product stored to a float32 (`0x41083e`), below 1 becomes 1, ftol int32
  (`0x9fbb40`).
- **SP divisor:** the **receiver's** level row `+0x1c` (`0x4107c6`-`0x410821`).
- **Monster factors:** 7.5f (`0xb45b9c`), then ×2 (`fadd st,st`), ×15/60/4/30 (doubles
  `0xb45e88`/`e80`/`cf0`/`e58`). The jump table `0x4c1668` sends rank 2 and ranks above 8 to 1.0.
- **EXP lag:** `0x1cd8` clamped to [0.1f, 1.9f]; slot ref > 120 gives 1.0.

**`vslot_420`, `0x4ea6a0`.**
- EXP and SP each pass through a float32 (`0x4ea7e8`, `0x4ea82a`), are multiplied by the float
  multiplier (`0x4ea863`-`0x4ea88b`), then truncated.
- The rate bonus needs flags bit 1, which both callers set (`0x4ea89f`/`0x4ea8e9`). It is
  ExpRatioParty `0xc8251c` when `pc+0x1cb8` is set, else ExpRatio `0xc82518`.
- The rate is compared with `1.01f` (`0xb46178`, `test ah,1` skips below).
- The bonus adds `ftol(EXP×(r−1))` and `ftol32(SP×(r−1))`.
- Then `[vt+0x170]` (GainExpAndLevel).
- **Not modelled, and correctly out of scope:**
  - the premium parameters `0x100`/`0x102`/`0xba`/`0xca`/`0xc2`;
  - the event rates `0xc82568`/`0xc8256c` (0 at boot, `0x427597`; raised by `0x6716b0`);
  - the training-camp bonus capped at 30 % (`pc+0x1ccc`, `0x4eaa68`-`0x4eabb7`).

**Round robin, `0x525dc0`.**
- Owner-only items: the TID shape and the `ITEM_QNO_RM_ARCHEMY` compare (`0x525f0d`-`0x525f59`).
- Flags bit 1.
- `memberCount` iterations.
- Rotation id 0 exits with EBX kept (`0x525f89`).
- Alive and world failures keep EBX; a distance failure clears it (`0x526055`).
- 3D, ≤ 1000, from the **picker** (`[ebp+0x88]`).
- Picker when EBX = 0.
- **Full bag:** `0x18da` only when the recipient is not the picker and the add failed with
  `0x1807` (`0x526343`-`0x5263a8`).

**Gold, `0x5bc7f0`.**
- The picker is included, wherever he stands in the member list (`0x5bc8b8`).
- Others: found, same world, 3D ≤ 1000 from the **picker's position**. The caller `0x4eacbd`
  passes `[esi+0x7c..0x90]`, the picker's own.
- No alive test.
- `each = amount/n` (unsigned); the picker gets `each+rest`.
- `each == 0`: the picker gets `rest`, which is the whole amount (`0x5bca1a`-`0x5bca48`).
- Reason `0x17`.

**Party monsters.**
- `0x40da20`: monster type 1 gives 1.2f (`0xb45d90`); then rank 6 gives ×1.5 (double
  `0xb45d78`).
- `0x40db50` applies it only to monsters (slot 10 at `0x40dbaa`).
- `nest.RollClass`: species rarity 1/3/4/5/6/7/8 copied; otherwise `%101 < 50` on an armed nest,
  TypeID4 ≠ 4.
- `ClampClassByLevel`: matches the review-709 table, and the giant at level ≤ 10 becomes a
  champion.
- Arming: only from the share path's count, ≥ 2, measured from the kill credit; a free-for-all
  kill writes 0 (`nest660_wire_test`, `killshare_test`).

**`0x3068` layout.** u32 id, u32 RefItemID, then the TID tests `0x42fe10`/`0x42fe80`: a u32 amount
in this GS / a u16 count / a u8 1. The notice is sent only with flags bit 1 (`0x5bdc87`).

**Regressions checked.**
- **Solo EXP:** unchanged at or above the monster's level, apart from truncation in place of
  rounding (`ftol`, correct).
- **Level-up:** any receiver levels; `OpLevelUp` reaches non-killers; HP and MP are refilled.
- **Guild points:** they still pass through `AddSkillExp`.
- **Quests and unique kills:** quest credit is unchanged and still the killer's;
  `AnnounceUniqueKill` groups by the exp-share flag (`partyGroupOf`), as `vslot_399` does.
- **Aggro link:** needs the exp-share flag.
- **Item Auto Share pick-ups:** the picker's client re-lists its inventory after a pick-up
  (`World3D.gd:18061`), so an item handed to someone else leaves no phantom. The "acquired" line
  is the disclosed gap.

**Tests.**
- `go test -count=1 -p 1 ./...` against `opensro_test`: 65 packages ok, none failed.
- `go test -race -count=1`:
  - `internal/party`, `leveldata`, `grounditem`, `combat`: ok;
  - `internal/session -run 'KillShare|ItemShare|RoundRobin|Gold|Nest660|GuildPoint|PartyMonster|AttackFactor|Combat|Unique|Status'`:
    ok (70.7 s).

### Not verified

- the `0x42fe10`/`0x42fe80` TID predicates;
- the HP ×10;
- how far the per-receiver window/diff precision gap (finding 4) reaches outside share 1 and
  lag 1.

### Perf gate

Not run: server-only round.
