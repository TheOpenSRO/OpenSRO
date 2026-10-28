# What a buff writes, and how a stat reads it (round 785)

READ from `SR_GameServer.exe` in round 785 (`ApplySkillParamsToChar` 0x594ac0, asm checked for
`hr`, `er`, `dru`; `FUN_004b2e60` and `EvaluateParam` 0x4b3740). Implemented in
`server/internal/buff/stats.go` (`StatContributions`, `Books.ParamTotals`) and
`server/internal/session/buffstats.go`. Labels READ / MEASURED / INFERRED / OURS / OPEN.

## How a param combines its entries (READ)

Each write is an entry keyed by the buff record (so the record's end removes it). A param's value is

    value = S0 x (1 + S1/100) x M x S3/100,   then clamped to the registry's min/max

- S0 the sum of slot-0 (flat) entries -- the registry default when there is none;
- S1 the sum of slot-1 (percent) entries;
- M (slot 2) the product of `(1 + e/100)`; when `S0 x S1` is zero M stands alone, so an otherwise
  unwritten multiplier param (174..181) evaluates to `1 - v/100`;
- S3 compounding from 100.

OpenSRO's stat functions compute the gear's value (its slot-0 entries) and pass it through
`(gear + buffFlat) x (1 + buffPct/100) x buffMult` (`buff.Totals.Apply`).

## The writes (READ; vN is value[N] of the run)

| code | writes | read by |
|---|---|---|
| `defp` | p5 slot 0 = v0, p6 slot 0 = v1 (+ ctx+0x34/+0x38); a non-zero v2 caps each at round(v2 % of a param -- which one is OPEN; not applied) | flat absorption, Formula_Mitigate* 0x40e504 / 0x40e8a6 |
| `defr` | p5 / p6 slot 1 = v0 / v1 | the same |
| `ar` | p7 / p8 slot 0 | the percentage divisor (no player row) |
| `hr` | p11 slot 0 = v0, slot 1 = v1 (0x595825..0x595875) | attack rate, the damage-centre roll |
| `er` | p9 slot 0 = v0, slot 1 = v1 | parry |
| `terd` / `thrd` | p9 / p11 slot 0 = -v0 | debuffs |
| `cr` (Basic_Activity 0 only) | p12 slot 0 = v0, slot 1 = v1 | critical |
| `br` | v0 type mask -> p136..139 slot 0 = v1 | added to the block chance by the blow's type |
| `hpi` / `mpi` | p3 / p4 slot 0 = v0, slot 1 = v1 | max HP / MP |
| `apau` / `apru` | p13/p14 = v0, p15/p16 = v1, slot 0 / slot 1 | the weapon's bounds |
| `tpad` / `tpdd` | p13/p14 slot 1 = -v0 / p5 slot 1 = -v0 | debuffs |
| `dru` | p128/129 slot 0 = v0, p130/131 slot 0 = v1 (0x595a97..) | attacker damage %, Formula_Mitigate* 0x40e5a4 |
| `dru2` | v0 mask -> p128..131 slot 0 = v1 | the same |
| `odar` | v0 mask -> p174..177 slot 2 = -v1 | the defender's multiplier |
| `bgra` / `reat` | p27..32 / p145..150 by mask | status resists (status lane) |
| `irgc` | p25 / p26 slot 1 = v0 / v1 | HP / MP regeneration |
| `ru` | p33 slot 0 = v0 | attack range |
| `dcri` | p57 slot 0 = v0 | evade-critical |
| `stri` / `inti` | p1 / p2 slot 0 = v0, capped at v1 % of the current value (the cap is not applied, OPEN) | Str / Int |
| `hste`/`hst2`/`hst3` | p23/p24 slot 2 | speed (round 616) |
| `hide` | p23/p24 slot 2 = -v2 | the hidden's speed |
| `tant` (action kind 3 only) | p187 slot 0 = v1 | threat % |
| `pmhp`/`pmmp` (mode 2) | p3/p4: slot 0 = -v1, or slot 1 = -v2 when v1 is 0 | max HP/MP debuff |
| `pmdg` (mode 2) | p178/p179 slot 2 = -v1/-v2 | the attacker's blow x p178 |
| `pmdp` (mode 2) | p5/p6 slot 1 = -v1/-v2 | defence debuff |
| `rhru` | p170/p171 slot 0 | heal received |

Every player `pmhp`/`pmmp`/`pmdg`/`pmdp` row is mode 2 (value[3] == 2, MEASURED), so none is a
periodic effect.

**skillparam.Contributions is superseded for these codes**: its proximity join carried `hr` -> p9,
`defr` -> p7/8, `dcri` -> 136..139 and lacked `cr` (round 785's read).

## Where OpenSRO reads them (round 785)

| param | function |
|---|---|
| 5 / 6 | `defenderArmor` / `defenderMagicArmor` |
| 9 | `defenderParryRate` |
| 10 + 136 | `defenderBlock` (`buffedBlock`; a monster's blow is physical: p136) |
| 11 | the attack rate in `attackerDamageOf` |
| 12 | `attackerCritical` |
| 13..16 | the weapon's bounds in `attackerDamageOf` (`buffedWeaponRange`) |
| 33 | `equippedWeaponRange` |
| 1, 2, 3, 4, 57 | `character.BonusOf` (a live, uncached part: `buffBonus`) |
| 128..131, 178/179 | a skill's hits (`applyBuffDamage`, skillhit.go) |
| 174..177 | a monster's debuffs (`monsterbuffs.go`); a player's damage taken (`applyPlayerTaken`, round 838) |

OPEN: 25/26 (regeneration), 27..32 and 145..150 (status resists), 170/171 (heal received), 187
(threat, with the hate list), the `defp` cap.
