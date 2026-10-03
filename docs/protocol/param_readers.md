# Buff params: the read side (param -> reader)

Recovered 2026-09-18. `param_writers.md` records which tag/skill code WRITES each
ParamKeeper param; this is the inverse for the buff params in
`skillparam.DrivesParams` -- which function READS each, i.e. what the buff actually
does. The reader column is every function that reads the param via the `GetParam`
vtable getter (slot 0x104) with a LITERAL id.

**Scope caveat, stated because it bounds the negative.** A literal scan misses reads
where the id is in a register or a loop, and the derived-stat graph
(`stat_graph.md`) propagates many params (Str/Int/MaxHP/the mitigation inputs) without
a literal `GetParam`. So a blank reader here means "no literal reader found", NOT
"dead": 24 of the 70 buff params have a literal reader; the rest are read via
register/loop/graph and are left UNRESOLVED by this scan.

## Params with a grounded literal reader

| param | driven by | reader(s) |
|---|---|---|
| 12 | `defr` | `Combat_ResolveDamage` |
| 23 | `STSP`, `hide`, `hst2`, `hst3`, `hste` | `CGObjPC::vslot_215` |
| 24 | `STSP`, `hide`, `hst2`, `hst3`, `hste` | `CGObjPC::vslot_215`, `FUN_00567190` |
| 27 | `bgra` | `FUN_00590680` |
| 28 | `bgra` | `FUN_00590680` |
| 29 | `bgra` | `FUN_00590680` |
| 30 | `bgra` | `FUN_00590680` |
| 31 | `bgra` | `FUN_00590680` |
| 32 | `bgra` | `FUN_00590680` |
| 57 | `dcri` | `Combat_ResolveDamage` |
| 141 | `dcmp` | `FUN_005830b0`, `FUN_005857b0`, `FUN_00586700`, `Skill_CheckUseConditions` |
| 145 | `reat` | `FUN_00590680` |
| 146 | `reat` | `FUN_00590680` |
| 147 | `reat` | `FUN_00590680` |
| 148 | `reat` | `FUN_00590680` |
| 149 | `reat` | `FUN_00590680` |
| 150 | `reat` | `FUN_00590680` |
| 172 | `alcu` | `Enchant_SuccessRateBasePlusBonus` |
| 173 | `luck` | `CEnchant_Reinforce::GetSuccessRate` |
| 178 | `pmdg` | `FUN_0040ebe0`, `Formula_MitigatePhysicalDamage` |
| 179 | `pmdg` | `FUN_0040eef0`, `Formula_MitigateMagicalDamage` |
| 184 | `hwir` | `FUN_00410880` |
| 187 | `tant` | `Combat_ResolveDamage` |
| 188 | `msid` | `Combat_ResolveDamage` |

## What the grounded readers settle

The readers turn several buff params from "granted, meaning unknown" into "granted and consumed
here":

- **params 172, 173 -> enchant/reinforce success.** `Enchant_SuccessRateBasePlusBonus`
  (`0x00503d30`, slot 7 of three `CEnchant_*` classes) returns `baseRate() + round(GetParam(172))`,
  and `CEnchant_Reinforce::GetSuccessRate` reads 173 the same way. `skillparam.DrivesParams` shows
  `'alcu'` and `'luck'` drive 172/173 -- so those buffs add a flat percentage to enchant and
  reinforce success. A grounded consumer for a buff family, from the read side.
- **params 27-32, 145-150 -> `Combat_ApplyStatusEffects`** (`0x00590680`) -- the per-affliction
  resist gate, recovered in `damage_pipeline.md`.
- **params 12, 57, 178/179, 187/188, 259 -> the damage pipeline** (`Combat_ResolveDamage`,
  `Formula_MitigatePhysicalDamage`/`MagicalDamage`). Already documented there; 178/179 are attacker
  percentages OpenSRO cannot reach because nothing publishes them (`combat.go`).
- **param 141 (`dcmp`) -> `Skill_CheckUseConditions`** and three skill functions -- a skill-use
  gate, not a damage term.
- **param 184 (`hwir`) -> `FUN_00410880`**; **params 23/24 -> `CGObjPC::vslot_215`** (an
  HP/MP-stamina accessor).

None is wired into OpenSRO: they feed enchant, status and buff systems the server does not have,
or are attacker/buff percentages nothing publishes. This map is reference data -- the point is that
each now has a cited consumer or a stated "unresolved by literal scan", so the buff write side
(`DrivesParams`) is no longer a set of grants with unknown effect.
