# Support skills: heals, cures, resurrection, periodic records, debuffs (round 785)

READ from `SR_GameServer.exe` in round 785 (decomp `/var/tmp/decomp_server`, objdump; the RE box's
scratch `/var/tmp/r785-skill-srv/{sab,aspc,apply}.c`). Implemented in
`server/internal/session/{skillsupport,skillperiodic,monsterbuffs}.go` and
`server/internal/statuseffect/cure.go`. Labels READ / MEASURED / INFERRED / OURS / OPEN. Row
counts are player rows of the ENC export (6,115).

## Heals (`heal` 304, `mwhh` 106, `mwmh` 44, `eshp` 45)

`Skill_ApplyEffectsAndNotify` (0x593f50), after the flat forms of `heal.md` (rounds 503 / 622):

- **an `efr` chain (kind 6)**: every living target in the vector is healed through
  `Skill_ApplyHealToObject` (0x5a0850) with `v0' = round(v0 x share/100)`, `v2' = round(v2 x
  share/100)` (asm 0x59431b..0x594438); v1/v3 (the percent terms) unscaled. CH Heal D/E carry
  `efr [1 6 300 2 2 7]`.
- **an `efr` monster group (kind 7)** with `efr[3] == 1`: only the lowest-HP% target.
- **any other `efr`, no `resu`** (0x59461b): every living target gets the unscaled run (the party
  heal: `SKILL_EU_CLERIC_HEALA_GROUP_A [1 1 250 8 0 5]` -> the party collector, radius 250).
- `getv HLRU` adds the caster's passive variable (`setv HLRU`) to v1 and v3 (0x59425e, 0x5a0330).
- `mwhh` / `mwmh` add `Formula_WeaponAvgDamagePercent(caster, value)` (FUN_005a09f0). **OPEN in
  OpenSRO** (not added).

The amounts: `hp = v0 + trunc(MaxHP x v1/100)`, `mp = v2 + trunc(MaxMP x v3/100)`, x `(1 +
p170/100)` / `(1 + p171/100)` (`rhru`).

OpenSRO: `applySupport` heals the `efr` rows' characters (`supportTargets`: kinds 5, 6, 1, 2 over
characters, the party from `party.Hub`); rows without `efr` keep the single-target columns.

## Heal over time (action kind 3 with `heal` and `puls`)

EU HEALA_CYCLE: `dura 16000 puls 2000 heal [287 0 0 0] mwhh 105 getv HLRU`. SkillAction_Buff
builds a per-target record when the row has `heal` and no `eshp`; `FUN_005a09f0` computes the
amounts once; each `puls` ms `ApplyHPMPDelta(owner, hp, mp, 0x40)` (sab.c ~845). The first heal
one interval after the engage (INFERRED). OpenSRO: `startPeriodic` / `hotTick`.

Group auras with `eshp` (RECOVERYA_GROUP: each puls heals the lowest-HP% party member): **OPEN**.

## Cures (`curl` / `curt` / `rcur` 67 rows; `cura` 0)

`FUN_004a56c0(holder, 0, curt, curl, rcur)` at the end of Skill_ApplyEffectsAndNotify, on every
target of the vector, or the caster when it is empty and TargetGroup_Self is set:

- candidates: active slots whose bit is in `curl[0]` or `curt[0]`;
- `rcur[0]`: shuffle (0x4a6560), try `min(n, rcur[0])`;
- `curl [mask, chance, level]`: chance `curl[1]` when the state's level <= `curl[2]`, else
  `curl[1] / (level - curl[2])`; a roll that comes up ends the state;
- `curt [mask, strength]` (the elemental six): the start moves back `strength x unit(slot)`
  (`DurationUnitMs`), ending the state when that passes its duration;
- the mask is rebuilt and, changed, broadcast (INFERRED: 0x4a5c60 is the state broadcast).

Rows: CH Water CURE A..F, CUREAREA A..C; EU Bard RECOVERA_ABNORMAL A/B; Cleric SAINTA_INNOCENT
A/B. OpenSRO: `statuseffect.Holder.Cure`, `statusFX.cureCharacter`.

## Resurrection (`resu` 52, `rmut` 7)

READ 0x5946c1..0x5949b8; the offer through `trs_wait_response` (0x46c8e0 / 0x46cb30):

- targets: dead PCs (life state 2) of level <= `resu[0]`;
- the dead player is sent **0x3080** `{u8 kind (4, or 8 with rmut), u32 caster uid}`;
- on "yes" (a non-zero u8 back on 0x3080) while still dead: `Revive(1)`, the EXP its death took x
  `resu[1]/100` (rounded up) back, `ApplyHPMPDelta(hp, mp, 8)` with `hp = v0 + trunc(MaxHP x v1/100)`,
  `mp = v2 + trunc(MaxMP x v3/100)`; with `rmut`, the buff skill `rmut[0]` engages.

The wait (READ, round 785 review): `trs_wait_response`'s constructor (0x46c7e0 / base 0x46c6c0)
stores f32 **30.0** (0xb45b48) at +0x1c, and `CMainProcess::FUN_0046f1e0` times it out in seconds;
on lapse a kind 4/8 sends nothing (`OnTimeout` 0x46ce20). There is one pending request per
receiver, whatever the kind: a second is refused (0x46f420), and a refused resurrection offer is
dropped silently. The answer (handler 0x80 -> 0x5157f0 -> 0x46f2d0) is matched by the receiver's
uid. The "yes" re-tests that the PC is dead. Only the answer and the timeout remove a request; a
revive or a logout does not.

OpenSRO: a `resu` row's friendly target must be DEAD (every other friendly row's alive); the
offer is retail's 0x3080 kind 4/8 (the party lane's opcode); "yes" revives in place with the row's
amounts (`reviveWith` + the row's heal, `sendRevived`). OpenSRO keeps the offer and the party
invitation in separate tables, so an answer is the **invitation's first** and the offer's only
when no invitation is pending (the client ignores kinds 4/8, so an answer must never be taken by
an offer it never drew). An offer lives 30 s (READ above); an expired one is absent. It is also
cleared when its target revives by any path or logs out. That early clear is OURS and has
retail's effect: a late "yes" there finds the PC alive and does nothing. **OPEN**: the EXP return (OpenSRO keeps no
per-death EXP record), the `rmut` buff, the 0.5 factor (`[target+0x30]+0xc == 2`).

## Debuffs on monsters (action kind 3, Target_Required 1, hostile groups)

SkillAction_Buff registers the record on each target; `ApplySkillParamsToChar` writes its stats
into the target's ParamKeeper -- a monster has one (GObjMob +0x1ec). OpenSRO keeps monster books
apart (`monsterBooks`, keyed `^id` so that no monster key equals a character id, its casters'
and links' key space; round 785 review), sends `OpBuffStart` / `OpBuffEnd` with
ownerKind 1 to the monster's watchers, ends a timed record at its `dura`, and reads the books in
a skill's blow: params 5 / 7 (defence, `monsterDefence`) and 174..177 (damage taken,
`applyMonsterTaken`). The cast's answer carries a block whose hits are kind 0, hitFlags 0x10
("effect only", READ) and the states that landed. A plain swing reads the same books (round 785
review: it is resolved by the cast's per-hit path).

Which rows take this path (round 785 review, OURS): the action kind, Target_Required and groups
above, **and** a Param block that is present, with no `att`, or an `att` whose `lnks` link deals
it pulse by pulse. A hostile kind-3 row with an `att` and no `lnks` strikes like any attack row,
and so does every row of a database whose Param block was never imported. MEASURED on the
round-785 export: 202 such rows, 190 of them debuffs (142 `att`+`lnks`, 48 with no `att`), 12
monster rows that strike, and 0 without a block.

**Linked blows** (the Warlock DOTs, 142 rows: `nbuf bbuf lnks [9 0 2 0] lks2 dura 12000 puls
2000 att [8 37 ..] mc [2 1]` + a state): each `puls` the caster's link resolves a full blow of the
row's `att`/`mc` on the linked monster, its states rolled again (sab.c ~1095..1165). The link ends
when `lnks[1]` is set and the caster is farther, or the object is gone. OpenSRO: `linkedBlowTick`,
announced as an `OpSkillCast` act with the block to the monster's watchers (the caster included).
A broken link ends **its own record** (by token), not every caster's record of the skill. A
pulse's kill sends the caster OpLevelUp and then its 0x3056, as a cast's kill does (round 785
review).

## Per-hit link effects on a defender (`dmgr` 21, `lkdr` 26, `lkdd` 20, `lkag` 12, `abnb` 9, `lkdh` 18)

READ (`FUN_005a0b80`, per hit): `dmgr` reflects a share of a hit to an attacker in range; `lkdr`
redirects part of a hit to the linked caster; `lkdd` (Damage Divide) spreads a share over the
party; `lkag` moves aggro; `abnb` applies the link skill's states to the attacker. All act on blows
a CHARACTER takes -- from monsters (the AI lane's blow) or other players (no PvP). **OPEN** in
OpenSRO.

## Stealth (`hide` 47), detection (`dttp` 36, `dtt` 9), transforms (`msch` 12), summons (`summ` 24), traps (`trap` 25)

READ in part (hide: body mode 6 rogue stealth / 7 wizard invisible, speed -hide[2], broken by
`skc` on a hit); the rest OPEN. **Not implemented** (OPEN): they need body modes on the wire,
spawned objects (summons, traps) and the AI's stealth filter.
