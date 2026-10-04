## Round 709 review: `docs/protocol/party_rules.md` (lane party709b), the party rules and formulas

*Adversarial review, docs only. Reviewer scope: `party_rules.md`. `party_protocol.md` and `party_gui.md`
were read only for cross-checks. Every address below was re-read with `objdump -d -M intel` on the exe
(GS `/var/tmp/SR_GameServer.exe`, SM `/var/tmp/party709a/SR_ShardManager.exe`) or in
`/var/tmp/sro_client.asm`. Every float was re-read from the raw `.rdata` bytes with a PE reader
(`/var/tmp/r709review_rules/rd.py` on the box), and its type was taken from the instruction's operand
size, not from the decompiler.*

**Bottom line.** The formulas hold. Every constant the doc cites has the value and type it says, and
the EXP/SP share, the bonus, the 70 % damping, the cap, the job and purpose tables and the
party-match ladder all trace end to end. The doc is wrong in two places. The first is a negative grep
over the wrong directory: the claim that nest arming is never called. The second is an edge case in the
item round robin, which the doc says falls back to the picker when it does not. It also misses one
contradiction (10 s against 15 s for the join request) and one gate (the per-world
`PARTYMONSTER_SPAWN` key).

---

### Findings, most severe first

#### 1. WRONG: "`ArmParty` has no caller" (doc lines 410-413; gap list #12, line 704; `party709b.md` line 54)

The doc says:

> nothing in `server/internal/session` calls it (MEASURED: `grep ArmParty server/internal/session` finds
> no caller). OpenSRO has no party share to produce the count, so no nest is ever armed.

**Evidence.** The grep searched only `internal/session`. The call goes through an observer that
`cmd/server` installs:
- `server/cmd/server/main.go:1877`: `session.SetMonsterKillObserver(respawns.armParty)`;
- `server/cmd/server/nest.go:271`: `s.sched.ArmParty(m.ID, members)`;
- `server/internal/session/combat.go:1466` and `status.go:606` call `noteMonsterKilled`;
- `nestkill.go` `partyMembersNear` counts the members.

Round 660 wired all of this. The `party=0` in the nest log is `s.party` in the scheduler summary
(`nest.go:231`), the number of party monsters hatched so far. It reads 0 because no qualifying party
kill has happened, not because arming is unwired.

**Correction.** Rewrite gap #12 and the "Why ... `party=0`" paragraph. Arming exists, but it differs
from the original in five ways, all READ in this review:
- **Party type.** OpenSRO arms for any party of two or more (`inPartyWithOthers`). The original arms
  only from the exp-share path; free-for-all kills never arm (finding 13).
- **Reference point.** OpenSRO measures from the dead monster, on the ground plane, in the same zone.
  The original measures from the kill credit, in the same world, horizontally with 1920-unit region
  steps, inclusive at 1000.
- **Whose count.** OpenSRO counts the killer's party. The original takes the count written by the
  exp-share groups that damaged the monster; the last one iterated wins (finding 5).
- **World gate.** OpenSRO has no `PARTYMONSTER_SPAWN` gate (finding 4).
- **The INFERRED comments are wrong.** `docs/protocol/monster_ai.md:3751` and the `nestkill.go`
  comment both record "measured from the dead monster" as INFERRED. That is wrong (READ:
  `0x5bcacb`-`0x5bcb29`, ECX = the kill credit). Add both to the doc's "Corrections" table.

#### 2. WRONG: the round robin's fallback (line 335 "If none qualifies, the picker gets it"; pet pickup, line 341)

**Evidence.** GS `FUN_00525dc0` loop, `0x525f82`-`0x526063`:

```
525f90: call 0x485dc0        ; ebx = member found by id
525fae: cmp al,0x1 ; jne 0x526057   ; not alive      -> next, EBX STILL = this member
525fd7: cmp ecx,[eax] ; jne 0x526057 ; other world   -> next, EBX STILL = this member
526048: fcomp QWORD [0xb45c68] ; test ah,0x41 ; jne 0x526069   ; <=1000 -> accept
526055: xor ebx,ebx          ; only the distance failure clears EBX
526057: ... add edi,1 ; cmp edi,[eax+0x1c] ; jl 0x525f82
526069: test ebx,ebx ; jne 0x52606f ; mov ebx,ebp   ; picker only when EBX == 0
```

The pet path `0x4d5510` has the same shape: `jne 0x4d56b8` at `0x4d560e` (alive) and `0x4d563a`
(world) without clearing, and `xor ebx,ebx` at `0x4d56b6` only on the distance failure.

**Correction.** When no member qualifies, the picker (or the pet's owner) gets the item **only if the
last member tried failed on distance**. If the last member tried was dead or in another world, **that
member** is the recipient, because his pointer is still in EBX. To match the original exactly, keep the
"last candidate" variable this way. Add a sentence and mark it READ.

#### 3. CONTRADICTION: how long a join request lasts (lines 628-629; user-assertion row, line 672)

The doc says "the requester's progress bar and the leader's accept/deny box both run 15 seconds.
INFERRED".

**Evidence.** `party_gui.md` READ both client timers:
- The leader's popup sends answer code **2** after **10 s** (timer `0x2710` ms, set at client
  `0x7406de`; handler `0x73fb70`).
- The progress bar fills at 10 s (client `0x7322e0`, the double 10000.0 at `0xdb3720`).
- `party_protocol.md` row `0x306e` agrees: answer 2 is pushed at `0x73fb8d`.

The 15.0 s server timer is real: SM `0x44fb15` `fld DWORD 0x79b018` = `00007041`, stored at `+0x2c` by
`0x4206fc`, ticked by `0x421e08`/`0x421e56`. But when the leader's client is connected, it answers 2
at 10 s, before the server's timer can fire.

**Correction.** Visible behaviour: 10 s, ended by the leader's client sending reply code 2 (READ,
client). The server's 15 s transaction timeout (READ, SM) is the fallback when the leader's client
sends nothing. Change the user-assertion row to match.

#### 4. MISSING: the per-world `PARTYMONSTER_SPAWN` gate (lines 377-413)

**Evidence.**
- **The key.** GS `CDataDrivenGameWorld::vslot_055` reads the world's `PARTYMONSTER_SPAWN` config value
  (`0x6086eb` `mov ecx,0xb014bc` = "PARTYMONSTER_SPAWN"). Only when the value compares equal to "ON"
  (`0xb012f4`, `CompareStringA` at `0x60872e`, `cmp eax,2`) does it set `world+0x58 = 1` (`0x608739`).
- **The strip.** A world virtual at `0x609900` runs on a spawn's class byte. When the world's `+0x58`
  is 0, it removes the party nibble:

```
609900: cmp DWORD PTR [ecx+0x58],0x0 ; jne 0x609928
60990c: and al,0xf0 ; cmp al,0x10 ; jne ... ; xor eax,eax   ; party nibble -> 0
60991f: and dl,0xf ; or al,dl ; mov [esp+0x20],al           ; keep the rank
```

- **The vtables.** Its address sits in the vtables at `0xb01cf4`/`0xb01de4`/`0xb78fd8`.
- **This package's config.** `/opt/sro-files/db/csv/world_config_keys.csv` has 30 `PARTYMONSTER_SPAWN`
  rows:
  - `ON` only for `GROUP_JUPITER_A3`, `_B3` and `_FIELD`;
  - `OFF` for the Pharaoh tombs, Togui, God Flame, Wreck and Arabia groups.

**Correction.**
- Add a third spawn condition: in a data-driven (instance) world, a party monster survives only when
  the world's `PARTYMONSTER_SPAWN` is `ON` (READ, GS). The values are this package's config and may be
  modded.
- Whether the main field world has an equivalent gate was not read. Mark it OPEN, with the next probe:
  the base `CGameWorld` slot at the same vtable index.
- The sentence "the roll keys on the nest's armed state, not on a table value" is incomplete; qualify
  it.

#### 5. MISSING: the kill credit can sit outside the sharing party, and several groups share one count (lines 259-261, 304-305, 379-383, 683)

**Evidence.**
- **One kill credit for all groups.** `vslot_399` computes the kill credit once (`0x4c4708`-`0x4c4711`,
  `ebx = [topGroup+0x20]`) and passes the same `ecx,ebx` to `0x5bca60` for **every** exp-share group
  (`0x4c4775`). `0x5bca60` uses ECX only as the reference position and world.
- **One count for all groups.** The count pointer is the same `[ebp+0x8]` for every group (`0x4c4768`).
  Each share call overwrites it (`mov WORD PTR [esi],ax`, `0x5bcd3a`); a free-for-all group does not
  write it.

**Correction.**
- When two parties, or a party and a solo player, damage one monster, the second party's 1000-unit
  radius is measured from the **other** group's top hitter. If that point is more than 1000 from all
  of its members, that party gets no EXP or SP at all.
- The count that reaches the nest is the **last exp-share group iterated**, in the group map's order
  (OPEN, the map's ordering).
- Say both explicitly.
- "INFERRED that it is always non-null" can become READ. Groups are built only from entries with damage
  > 0 (`0x4c455b`), so a top group, and with it a kill credit, exists whenever a share call is made.

#### 6. UNSUPPORTED / CONTRADICTION: "refuses while a job item is worn (`0x2c26`)" (line 560)

**Evidence.** GS `CParty::CheckCanCreateForMatch` `0x514196`: `cmp BYTE PTR [ecx+0x13],0x0` on
`chardata+0x13` → `0x2c26`. The job state the purpose table needs is a different byte, `chardata+0xf`,
and it is **derived from the worn job suit**. `0x4e124e` writes 4, then the item in equipment slot 8
(`push 0x8; call 0x4b8000`) sets 1, 2 or 3 through item slots `0x418`/`0x41c`/`0x420`
(`0x4e128a`/`0x4e12a9`/`0x4e12c8`, each `call 0x4e0b20`).

Purpose 2 needs job state 1 or 3, and purpose 3 needs state 2 (finding list, row 29). If `0x2c26`
meant "a job suit is worn", nobody could ever register a trade or thief listing.

**Correction.**
- Line 560: `0x2c26` (`JOBITEM_WEAR_ERR_PARTYMATCH`) when `chardata+0x13` is non-zero. What `+0x13`
  holds is OPEN; it is not the worn suit.
- Lines 149-151: the INFERRED sentence ("a player who has a job but is not wearing the suit is a 4")
  can be upgraded to READ from `0x4e124e`-`0x4e12cc`.
- The same "wearing a job item" wording is in `party_protocol.md:330` and `party.md:69` (for the
  coordinator).

#### 7. MISSING: the ExpRatio bonus has a 1.01 floor and also pays SP (lines 186, 309-310)

**Evidence.** GS `vslot_420`:

```
4ea8a5: fld DWORD PTR ds:0xb46178     ; 1.01 (float, bytes ae47813f)
4ea8ab: fld DWORD PTR ds:0xc8251c     ; ExpRatioParty (0xc82518 = ExpRatio when not in a party)
4ea8b1: fcom st(1) ; ... test ah,0x1 ; jne 0x4ea8fd   ; ratio < 1.01 -> no bonus at all
4ea8bc: fsub QWORD [0xb45ac0] ; fild QWORD [esp+0x38] ; fmul st,st(1) ; call ftol   ; EXP*(r-1)
4ea8cd: fimul DWORD PTR [esp+0x1c] ; call ftol                                        ; SP*(r-1)
```

**Correction.**
- The rate is an **additive** bonus, `EXP×(r−1)` and `SP×(r−1)`, on top of the shared amounts. It
  applies to **skill EXP too**, and only when `r ≥ 1.01`; a rate below 1.01 changes nothing.
- OpenSRO's `rates.ExpFor` multiplies EXP alone by any `m ≠ 1` (`session/combat.go`), so it diverges
  in both respects. Add this to the gap list.
- The doc already says the rates themselves are config and this package's config is modded.

#### 8. UNSUPPORTED (minor): "damage it deals ×1.2" (line 403; user-assertion row, line 682; gap #13)

**Evidence.**
- `FUN_0040da20` multiplies a value that `0x40db50`/`0x40dc10` build from the attacker's own stat:
  vtable `0x104` with param `0xd + (edi≠0)` or `0xf + (edi≠0)`, plus an item bonus.
- That happens before mitigation, and the result is clamped against `0xb45f20` afterwards
  (`0x40dbe2`).
- The 1.2 (`fld DWORD 0xb45d90` = `9a99993f`) and the elite ×1.5 (`fmul QWORD 0xb45d78`) are correct.

**Correction.** Say "×1.2 on its attack value (the min/max stat pair `Combat_ComputeWeaponDamage` reads),
before defence". Final damage is ×1.2 only if the rest of the pipeline is linear in that value, which
was not shown.

#### 9. WRONG (minor): "A pickup of 1000 gold or more" (line 370)

**Evidence.** GS `0x4ead1f`: `cmp edi,0x3e8 ; jbe 0x4ead3a`.

**Correction.** It fires only for **more than** 1000 gold (1001 or more).

#### 10. MISSING (minor): EXP and SP go through float32 before the multiplier (line 185)

**Evidence.**
- `0x4ea7d9` `fild QWORD` EXP, then `0x4ea7e8` `fstp DWORD PTR [esp+0x34]`, then `fld DWORD`; the
  multiplier is applied to that float (`0x4ea876`).
- SP takes the same path (`0x4ea81d`-`0x4ea82e`).

**Correction.** `EXP = ftol(float32(EXP) × multiplier)`: EXP above 2^24 is rounded to single precision
first. This matters for an exact match at high levels.

#### 11. UNSUPPORTED (minor): the level clamp's summary (lines 389-390)

**Evidence.** GS `0x5eb9a0`, switch on `level/10` (jump table `0x5ebf14` → `0x5eba3e`, `0x5eba48`,
`0x5eba57`, `0x5eba6a`, fall-through).

**Correction.** "Unless the rank is a low one" is not what the code says. Exactly:

| level | party flag kept for |
|---|---|
| 0-9 | never |
| 10-19 | rank 0 only |
| 20-29 | ranks 0 and 1 |
| 30-39 | ranks 0, 1, 4 (giant) and 6 |
| 40 and up | always |

Before the switch, a level ≤ 10 giant becomes a champion (`0x5eb9f9`-`0x5eba14`).

#### 12. MISSING (minor): the roll is not only for rarity 0 (line 386)

**Evidence.** GS `0x56086e`-`0x5608c6`: species rarity 5, 3, 8, 6, 7, 4 and 1 copy straight to the
class. Everything else reaches the party roll at `0x5608cf`.

**Correction.** The roll applies to rarity 0, 2 and 9 or above, not "rarity-0" alone.

#### 13. OPEN item that can be closed: the out-count in a free-for-all kill (line 386, OPEN row at line 722)

**Evidence.** The mob death function `0x529de0` zeroes the count before the distributor runs:
`0x529e0a` `mov DWORD PTR [esp+0xc],0x0`, then the slot-311 call (`0x4c42f0` → `vslot_399`). It then
passes `movzx edx,WORD PTR [esp+0x8]` to the AI's slot 7 (`0x529e2a`-`0x529e3f`). `0x52d010` does the
same.

**Correction.** A free-for-all kill leaves the count at 0 and never arms a nest. Change INFERRED to READ
and delete the OPEN row.

#### 14. Stale against `party_gui.md` (lines 519, 541-543, 598-601, 659)

- **Lines 598-601, search.** Name, purpose and level search are marked INFERRED client-side.
  `party_gui.md` READ the filter: `0x73bb80` → `0x73b780`, exact name match, purpose unless All, level
  ranges overlapping.
- **Line 659, auto-match.** "How candidates are chosen is OPEN". `party_gui.md` READ it at
  `0x73ebc0`: purpose, race unless Open, type flags, level inside the range, up to 10 queued.
- **Lines 519 and 541-543, icons.** The "(hunting; the red flag)" label and the Type-icon remark come
  from the user's screenshots. `party_gui.md` reports that this exe draws Race and Purpose as **text**,
  and that the icons belong to another client. Label them as screenshot observations, not READ.

#### 15. CONTRADICTION (cross-doc, for the coordinator): `party_protocol.md` against this doc

- **Range.** `party_protocol.md:246,289` say "range 38". This doc's 600 is right: GS `0x4a8f00`
  `fld DWORD 0xb46198` = `00001644` = 600.0 for a PC target, with a 3D delta (`0x430ba0` at
  `0x4a8ff4`). `0x26` is the interaction-kind argument checked by `0x4a8d90`.
- **Timeouts.** `party_protocol.md:381,483,532` call 30.0 and 15.0 "INFERRED seconds, consumers not
  traced". This doc traced both: GS `0x46c817` → `+0x1c`, then the tick, then `0x2c10`; SM `0x4206fc`
  → `+0x2c`, ticked by `0x421e08`. Both are seconds, READ.
- **Purpose values.** `party_protocol.md:202` calls purposes 0 and 1 OPEN. This doc read them from the
  client's labels.
- **No contradiction on succession.** Leader succession agrees. "Longest-standing member" and "oldest
  remaining member" are the same rule: SM `0x44e27e` erases the leaver with a memmove that keeps
  order, then `0x44e2a1`-`0x44e2aa` sets `party+4 = members[0]+0x78`. That assignment runs after
  **every** removal, not only the leader's.

---

### Claims verified correct (48)

**Constants.** Each is checked by raw bytes and by the operand size at the cited instruction.

1. **1000.0**, a double (`0000000000408f40`):
   - party share: `fcomp QWORD` at `0x5bcc84`;
   - item round robin: `0x526048`;
   - pet pickup: `0x4d56a9`;
   - gold: `0x5bdba9`;
   - SM tick: `0x79ada8` read by `fdiv QWORD` at `0x421e08`.
2. **0.03** (`fmul QWORD 0xb45dc8`) and **1.0** (`fadd QWORD 0xb45ac0`), both doubles, at
   `0x4c4843`/`0x4c4849`.
3. **0.5** for out-levelling, a float: `fld DWORD 0xb45b68` = `0000003f` at `0x410fd6`.
4. **0.2** (`0xb45ee8`) and **0.1** (`0xb45ec0`), doubles, at `0x5bcd50`, `0x5bcd5c` and `0x5bcd90`.
5. **0.7**, a double (`fcom QWORD 0xb46050` at `0x5bce67`). The test is strictly greater:
   `test ah,0x41 ; jne` skips at ≤ 0.7.
6. **The half bonus.** 0.5 double (`fmul QWORD 0xb45c50` at `0x5bce9b`); the arithmetic
   `(bonus−1)×0.5+1` is traced on the FPU stack at `0x5bce91`-`0x5bcea3`.
7. **7.5**, a float (`fld DWORD 0xb45b9c` = `0000f040`) at `0x4c15e8`.
8. **The rank multipliers.** The jump table at `0x4c1668` decodes to
   `[0x4c160e, 0x4c1613, 0x4c1664, 0x4c160e, 0x4c1620, 0x4c1631, 0x4c1642, 0x4c1653, 0x4c160e]`, which
   gives:
   - ranks 0, 3, 8: ×1;
   - rank 1: ×2 (`fadd st,st`);
   - rank 2: **1.0, dropping the party factor**;
   - rank 4: ×15 (double);
   - rank 5: ×60;
   - rank 6: ×4;
   - rank 7: ×30;
   - rank 9 and up: 1.0.
9. **HP ×10.** Base 100.0 (`fld DWORD 0xb45e10`) becomes 1000.0 (`fld DWORD 0xb462ac` = `00007a44`) for
   monster type 1 (`CGObjMob::PublishStats` `0x4c19fe`/`0x4c1a28`).
10. **1.2** (float, `0x40da46`) for monster type 1, and **1.5** (double, `0x40da5e`) for rank 6.
11. **600.0** (float) for a PC target and **320.0** (float) by default, at
    `0x4a8f00`/`0x4a8eea`.
12. **30.0** (float, `0000f041`) stored at the transaction's `+0x1c` (`0x46c817`-`0x46c81d`); the
    timeout code is `0x2c10` (`0x46ce44`).
13. **15.0** (float, `00007041`) at SM `0x44fb15`, stored at `+0x2c` by `0x4206f0`.
14. **The distance helpers.**
    - 1920.0 (double) per region step.
    - 1e38 (float) across the field/dungeon boundary.
    - `0x430ad0` zeroes y (`fldz` → `[eax+4]`) and is used by the party share.
    - `0x430ba0` keeps y and is used by the items, gold and invite.
15. **The SP formula's constant and floor.** 100.0 (double, `fmul QWORD 0xb45af0` at `0x4107f0`); a
    result below 1.0 becomes 1 (`0x410842`-`0x41084f`).
16. **The share clamp.** 1e-6 (float, `0xb45c84`) to 1.0 in both formulas.
17. **HP quantisation.** `1 − ftol(HP/MaxHP × −10.0)` (`0x5bb13b`, double −10.0).

**Formulas and control flow.**

18. **Grouping in `vslot_399`.**
    - A COS counts for its owner through `+0x1cd8` (`0x4c4587`).
    - The flag comes from `party+0x10 & 1` (`0x4c45b2`).
    - A group key is (flag, party) or (0, self).
    - Damage accumulates at `+0x18`; the biggest single entry is kept at `+0x20`/`+0x24`
      (`0x4c466b`-`0x4c467c`).
    - The kill credit is returned in EAX (`0x4c47b5`).
19. **Branching.** Flag set → `0x5bca60` (ECX credit, EDX party, then victim, damage and the count
    pointer); flag clear → `0x4c4820` (`0x4c475f`-`0x4c4786`).
20. **Free-for-all multiplier.** `1 + (n−1)×0.03`, with `n = party+0x1c` (`0x4ea230`), counting every
    member; it applies only when the receiver is in a party.
21. **Free-for-all party-monster halving.** The victim must be a monster (slot 10) and a party monster
    (slot 193), and `0x410fd0` halves when victim level < receiver level (signed `cmp`/`jge`).
22. **Party-share eligibility.** The member must be:
    - found (`0x485dc0`);
    - alive (slot `0xf8`, `cmp al,1`);
    - in the same world (slot 5);
    - within 1000, horizontally, inclusive (`je` skips only when greater).
23. **The reference point** is the kill credit when non-null, else the victim (`0x5bcacb`).
24. **The bonus.**
    - When e > 0: `1+(e−1)×0.2+c×0.1`.
    - Otherwise, when c equals the eligible count: `1+(c−1)×0.1`.
    - Otherwise 1.
    - The Country byte is ref `+0x88`, the same byte `leveldata` reads at `0x410033`.
25. **The party-monster penalty.** It uses the integer average of the eligible members' levels
    (`idiv` at `0x5bcddf`, then `0x410fd0`).
26. **The split.**
    - `s = level/Σlevel`, stored as a float.
    - Damping needs an eligible count ≥ 3 (unsigned `jb`) and an eligible maximum level ≥ 21.
    - The multiplier passed is `s×b×penalty`, with flags 3 and the **group's** damage
      (`0x5bcea7`-`0x5bced7`).
27. **The eligible count** is written as a WORD to the out pointer (`0x5bcd3a`).
28. **`vslot_420`.**
    - EXP and SP are both scaled by the multiplier (`0x4ea876`-`0x4ea88b`).
    - `GainExpAndLevel` is called through the vtable at `[vt+0x170]` (`0x4eabef`). CGObjPC's vtable
      `0xaf59fc` has slot 92 = `0x4e5250` (`GObjPC_GainExpAndLevel`) and slot 420 = `0x4ea6a0`.
    - ExpRatioParty is chosen when `pc+0x1cb8` is non-null, ExpRatio otherwise.
29. **`Formula_ExpRewardForContributor` `0x410110`.**
    - ESI is the victim and EDI the receiver.
    - slot 332 × slot 359 × share × Window × `rcv+0x1cd8` × Diff.
    - Damage is clamped to MaxHP, the share to [1e-6, 1], and a result ≤ 0 becomes 1.
30. **`FUN_004106b0`.** slot 359 × 100 × slot 332 / the level row's `+0x1c` × share × Window ×
    `rcv+0x1cdc` × Diff. `+0x1c` is leveldata column 5 per `leveldata.go:98`.
31. **The class-byte accessors.**
    - `IsPartySupportMonster`: `(class&0xf0)==0x10` (`0x4c0dd0`).
    - `GetMonsterType`: `class>>4` (`0x4c1c70`).
    - `GetMonsterClass`: `class&0xf` (`0x4c1c60`).
32. **Arming.** `0x558f20`: `cmp DWORD [esp+8],2 ; jb` → `nest+0x30 = 1`.
33. **The nest roll.** It needs an armed nest (`cmp [ebp+0x30],1`), then `rand()%0x65 < 0x32`, then the
    TID test `0x561020`; it sets class `0x10` (`0x5608cf`-`0x5608f4`). A party class disarms the nest
    (`0x560cad`-`0x560cb3`).
34. **No party monster below level 10** (`0x5eba3e`, `and bl,0xf` for `level/10 == 0`).
35. **The 8/4 cap by bit 0**, in three binaries:
    - GS `0x5145cc`-`0x51460c`: `cmp [party+0x1c],8` or `,4`, and `0x2c13` when bit 0 is set,
      `0x2c14` otherwise;
    - SM `0x44de70`;
    - client `0x987050` (`cmp [ecx+0x30],4` when `[ecx+0x20]==0`, `,8` when it is 1).
36. **Who may invite.** The leader (`party+0xc`) or anyone when bit 2 is set (`0x5145ac`-`0x5145b6`).
37. **Job compatibility.** GS `0x5bc1c0` (jump table `0x5bc1f8`) and SM `0x44ed20` (table `0x44ed58`):
    - 1 or 3 → {1, 3};
    - 2 → {2};
    - 4 → {4};
    - 0 or ≥ 5 → refused.

    So "no job" cannot be 0: a state of 0 matches nobody, not even another 0.
38. **Purpose table.** GS `0x5bf240` (table `0x5bf284`) and SM `0x44f7f0` (table `0x44f834`) are
    identical:
    - 1 or 3 → purpose 2;
    - 2 → purpose 3;
    - 4 → anything but 2 or 3 (strictly, not only 0 or 1);
    - other values → assert, then refused.

    The purpose is the record's `+9` (`0x5bf358`, `[ebp+0x5d]` with the record at `+0x54`).
39. **The job state's storage.** It lives at `chardata+0xf` (`0x4ddc80`) and is initialised to 4
    (`0x4de3eb`).
40. **The SM join ladder** (`0x44fa10`-`0x44fb08`), in order:
    - `0x2c18`;
    - `0x2c25`;
    - `0x2c1c`;
    - full: `and bl,1 ; neg ; sbb ; add 0x2c14`, giving `0x2c13` or `0x2c14`;
    - no leader: `0x2c1c`;
    - job against the leader's `+0x49`: `0x2c23`;
    - purpose: `0x2c23`;
    - level outside `[+0xa, +0xb]`, inclusive: `0x2c1e`;
    - pending `+0x34`: `0x2c1f`;
    - owner gone: `0x2c0e`.

    Then pending is set to 1 and the request is sent with 15.0 s.
41. **The SM transaction tick.** It adds GetTickCount ms / 1000.0 to `+0x30` and compares the result
    with `+0x2c` (`0x421de0`).
42. **The listing counter** is `++[mgr+0x8c]`, skipping 0 on wrap (`0x44def0`). **The page size** is 23
    (`cmp al,0x17` at `0x4517ed`). **Leave rebuilds the pages** (`0x44f62e`).
43. **Leaving.**
    - A party of exactly 2 is dismissed (`0x44f5c1` → `0x44eb30`).
    - Otherwise notice 3 is broadcast before removal (`0x44f5d8`-`0x44f61d`).
    - The listing moves to the new leader (`0x44e2d7`-`0x44e2eb`, notice `0x12`).
44. **The item round robin, apart from finding 2.**
    - It runs only with bit 1 set.
    - It loops `memberCount` times.
    - The rotation takes the front of `party+0x20` and appends it to the back (`0x4d4840`).
    - Each candidate must be alive, in the same world, and within 1000 in 3D, inclusive.
    - The owner-only TID shape and the 0x13-character `ITEM_QNO_RM_ARCHEMY` name compare are checked
      (`0x525f0d`-`0x525f59`).
45. **Pet pickup.**
    - The item must pass CanTrade (`0xc4`) and CanDrop (`0xd0`).
    - The distance is measured from the pet (`[ebp+0x88]`); the world compared is the owner's
      (`[ebp+0x1cd8]`).
46. **The gold split** (`0x5bc7f0`).
    - The picker is always included.
    - Other members must be found, in the same world, and within 1000 in 3D of the picker's position.
      Being alive is not tested.
    - Each gets `amount/n`; the picker gets `each + amount%n`.
    - When each is 0, the picker gets everything.
    - Reason `0x17`; outside item share, reason `0x19` (`0x4ead16`).
47. **The berserk share.**
    - `0x5bcf30` requires bit 0, then pays every member found, alive and in the same **world**
      (slot 5); there is no region test.
    - The call site `0x593b4f`-`0x593b82` also requires the victim to be a monster and a party
      monster.
    - The doc's "world, not region" correction to `recovered_names.tsv`/`SYSTEMS.md` is right.
48. **Chat echoes to the sender.** `CMainProcess::FUN_005bef50` calls `CParty::BroadcastToLocalMember`
    with `ebx = 0` (`0x5bef84` `xor ebx,ebx`, then `0x5bf062` `push ebx`). The broadcaster skips a
    member only when the exclusion id is non-zero and matches (`0x5bb811`-`0x5bb81d`).

**Gap-list spot checks against the current code: 7 confirmed, 1 wrong.**
- **#2 confirmed.** `party.go:47` `MaxSize = 8`, with no flags field.
- **#3 confirmed.** `applyPartyExpBonus` scales the killer's EXP alone, for any party of two or more
  (`combat.go:1247`).
- **#4 confirmed.** `killExpFor` passes `inPartyWithOthers` (`combat.go:1190`).
- **#5 confirmed.** The kill's skill EXP is the kill's EXP, disclosed in the comment block in
  `combat.go` around line 2160.
- **#7 confirmed.** `leaveLocked` takes `Members[0]` after removal and has no two-member dismissal
  (`party.go:263-271`).
- **#8 confirmed.** Party chat skips the sender (`chat.go:295`).
- **#14 confirmed.** No rank or party EXP multiplier was found, by two probes with different patterns
  (rank/rarity words, and the constant 7.5).
- **#12 wrong.** See finding 1.

### Not verified (out of time or scope)

- the default title per purpose (client `0x73f610`);
- the requester's own listing on every page (`0x44f640`);
- the `0x061` reason codes;
- the member-update triggers other than the HP step;
- the slot-332 base (already OPEN in the doc);
- whether the main field world has a `PARTYMONSTER_SPAWN` equivalent.

### Perf gate

Not run: a docs-only review.
