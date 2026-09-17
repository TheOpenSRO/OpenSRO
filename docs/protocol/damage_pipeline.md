# The damage pipeline, in order

`Formula_MitigatePhysicalDamage` (`0x0040e450`) read stage by stage. The magical
twin (`0x0040e830`) is the same shape with every type-specific param shifted by
one. This is the ordering that the recovered pieces needed before any of them
could be wired: the formulas were known, the sequence was not.

The running damage lives in **`[esp+0x24]`** and the pre-mitigation base in
**`[esp+0x28]`**. An earlier note called `[esp+0x24]` a "multiplier
accumulator" — it is the damage itself.

`esi` is the attack context, `edi` the **defender**, `ebp` the **attacker**,
`bl` the flags byte passed in `cl`.

| # | addr | stage | what happens |
|---|---|---|---|
| 0 | `40e45c` | guard | `[esi+0x230] != 0`; both parties `GetLifeState() == 1`; descriptor bit `0x4` (physical) |
| 1 | `40e4b0` | **base** | `FUN_0040dce0(ctx, defender, damage)` → `[esp+0x28]` |
| 2 | `40e4c3` | flat bonus | if `bl & 0x8` and the attacker's `+0xa30` map holds the key: `base += entry[+4]` |
| 3 | `40e4f7` | **bypass** | if `bl & 0x20`: skip mitigation entirely, damage = base |
| 4 | `40e502` | **mitigate** | `base / (1 + defender_p7/100) − defender_p5` |
| 5 | `40e54a` | clamp | at 0 |
| 6 | `40e56e` | **skill %** | `damage *= descriptor[+4] / 100` |
| 7 | `40e58e` | read | attacker param **128** (descriptor bit `0x1`) or **129** (bit `0x2`), held aside |
| 8 | `40e5b4` | read | if defender `IsMonster()` **and** `GetMonsterClass() == 3`: `aside = damage * attacker_p259 / 100` |
| 9 | `40e60b` | read | `SelectDaraParamForDamageType(flagsA, flagsB, defender)` → the `dara` value |
| 10 | `40e614` | apply 7 | `damage *= 1 + p128or129/100` |
| 11 | `40e62c` | apply 8 | `damage += aside` |
| 12 | `40e638` | apply 9 | `damage *= dara`, conditional on a zero test |
| 13 | `40e655` | **berserk** | `t = 1`; if `bl & 0x4`: `t = attacker_p189 + 2.0`; if `bl & 0x2`: `t += t`; `damage *= t` |
| 14 | `40e696` | level gap | if attacker `Char_GetLevel()` **>** defender's: `damage *= 1 + FUN_0040fd60(attacker)` |
| 15 | `40e6cd` | **Str ratio** | `damage *= StrLevelDamageRatio(attacker)` — the defender's is computed at `40e6d8` and discarded on this arm |
| 16 | `40e6eb` | **floor band** | see below |
| 17 | `40e758` | attacker % | param **178** (magical twin: 179) |

Stages past 17 run to `40e819` and are not yet read.

## The constants

| VA | value | used for |
|---|---|---|
| `0xb45ac0` | 1.0 | `1 + pct/100` |
| `0xb45af0` | 100.0 | every `/100` |
| `0xb45f30` | **2.0** | the berserk term's additive base |
| `0xb45f60` | **0.05** | the floor band's threshold |
| `0xb45c60` | **10** | the floor band's scale |
| `0xb45af8` | **32767** | `RAND_MAX`, the floor band's divisor |
| `0xb45ba4` | 4294967296 | the standard unsigned-to-float fixup |

## Stage 13 corroborates the shipped berserk multiplier

`t = attacker_p189 + 2.0` when the berserk flag is set, and param 189's registry
default is **0**, so an ordinary berserk multiplies by exactly **2** — which is
what `berserk.DamageNumerator/DamageDenominator` already ship, recovered by a
different route entirely (the `SetBodyMode` chain). Two independent readings,
one number.

Bit `0x2` doubles the term again, to 4.

## Stage 16, the floor band — a mechanic nothing had

	40e6eb  if (damage < base * 0.05):
	40e706      damage = damage * 10 / 100        // i.e. damage / 10
	40e716      if (damage <= 0) damage = 1
	40e729      r = rand()                        // 0x9dd338
	40e732      damage = 1 + (damage - 1) * r / 32767

So a blow mitigated below **5% of its pre-mitigation base** is not simply
floored at 1: it is divided by ten, floored at 1, and then **randomised
uniformly between 1 and that value**. Heavily out-geared hits land for a small
random amount rather than a constant.

This is separate from the floor of 1 that `Combat_ResolveDamage` applies later
(see `combat.MitigateDamage`) — that one catches a zero; this one reshapes the
whole low end.

## What this confirms that was already shipped

- **Stage 6 fixes the skill percentage's position**: after mitigation and after
  the clamp at zero, which is exactly what `combat.ApplySkillPercent`'s comment
  argues and what it implements.
- **Stage 4** is `combat.MitigateDamage`, unchanged.
- **Stage 13** is the berserk ×2, above.

## What is recovered but not wired

Stages 2, 7, 8, 9, 10, 11, 12, 15 and 17. srrevamp publishes no source for
params 128/129, 178, 189 or 259, nor for `dara`, so most are unreachable rather
than missing.

**Stage 14 was already shipped** — `combat.LevelAdvantage`, with `FUN_0040fd60`
read as `clamp((attackerLevel - defenderLevel) * 0.03, 0, 0.3)` and both
constants cited. **Stage 16 is now shipped too**, as `combat.ApplyFloorBand`,
wired into `combat.ResolveBlow` after the level term.

**Stage 15** (the Str ratio) stays unwired, and the reason is now measured
rather than procedural. Threading the Str through is trivial — it was done, it
compiles, and it changes seven integration tests by exactly the predicted
factor. The blocker is the INPUT.

The ratio is calibrated against the engine's stat scale, and that scale is not
readable: `GObjPC_InitStats` publishes `charData+0x74` into param 1, and that
column comes from a table this project does not have (`_REFCHARGEN`). The one
statement the binary does make about the scale is the ratio's own ceiling —
solving `1.2 = (Str + 2L + 14) / (6*(L+7))` gives **Str = 5.2*L + 36.4**, the
point past which more Str does nothing (`combat.StrForMaxRatio`).

Against that, srrevamp's stats are systematically low:

| level | srrevamp Str, all points invested | engine ceiling |
|---|---|---|
| 1 | 20 | 41.6 |
| 20 | 96 | 140.4 |
| 50 | 216 | 296.4 |

So every srrevamp character lands below 1.0 on a multiplier the engine designed
to straddle 1. Wiring it would apply an exactly-recovered formula to a
differently-scaled input and produce a flat ~25% damage cut that is an artifact
of `character.StartingStr` — which is own design — rather than anything
recovered. `combat.TestSrrevampStatScaleIsBelowTheEnginesCeiling` fails the day
that stops being true, so the decision gets revisited deliberately instead of by
drift.

**Grounding `character.StartingStr` is the unblocker**, and the ledger already
names where it lives: `_REFCHARGEN`.

### srrevamp's order against the engine's

`combat.ResolveBlow` implements stages 4, 13, 14 and 16 and runs them in the
engine's order: mitigate (4) -> critical/berserk (13) -> level gap (14) ->
floor band (16). The skill percentage (stage 6) is applied by the caller, after
mitigation, which is also where the engine puts it.

One thing worth stating because it looks like a difference and is not: the
engine folds berserk and critical into a **single** term at stage 13 —
`t = attacker_p189 + 2.0`, then `t += t` on flag bit `0x2` — where srrevamp
applies two separate doublings. With param 189 at its default of 0 both give x2
alone and x4 together, so the two agree.


## A second level-difference term, in `Formulae.cpp` (2026-09-17)

This page records `LevelAdvantage` — 3% per level, capped at 30%, the **bonus**
an attacker gets for out-levelling its target, from
`Formula_MitigatePhysicalDamage`.

There is a second, opposite term, and srrevamp does not model it.
`Formulae::Formula_SkillPhysDamage` (`0x0040f5f0`, 248 bytes) scales skill
physical damage **down** when the level difference runs the other way:

	40f62c  <level of the ebx object>
	40f63b  sub eax,esi              ; d = level(ebx) - level(esi)
	40f643  jle done                 ; only when d > 0
	40f651  fild  d
	40f655  fmul  QWORD ds:0xb45e50  ; * 2.5
	40f65b  fld   QWORD ds:0xb45af0  ; 100.0
	40f661  fdiv  st(1),st           ; (d * 2.5) / 100
	40f663  fld1
	40f665  fsubrp st(2),st          ; 1 - (d * 2.5)/100
	40f66d  fmulp                    ; damage * that
	40f671  call  __ftol2
	40f678  lea ecx,[edi+edi*4] / add ecx,ecx / imul 0x51eb851f / sar edx,5
	                                 ; floor = damage * 10 / 100

So:

	scale  = 1 - 0.025 * d
	floor  = damage * 10 / 100
	result = clamp(damage * scale, floor, damage)

**2.5% per level, floored at 10% of the base.** Note the asymmetry with the
bonus: the advantage is 3% per level to +30%, the penalty 2.5% per level down to
10%. Two different rates, which is why neither can be assumed from the other.

The `imul 0x51eb851f ; sar edx,5` pair is the compiler's magic-number division
by 100, not a constant of the game.

### WHICH PARTICIPANT IS THE ATTACKER IS NOT SETTLED

`Combat_ResolveDamage` calls this twice, and the two sites pass the object pair
**swapped**:

	58f4fc  push edi ; mov edx,esi ; call 0x40f5f0
	58fbab  push esi ; mov edx,edi ; call 0x40f5f0

so the argument order cannot settle the roles, and nothing else read so far
does. That matters: applied backwards, this term would penalise the wrong side.

This project settled the same question for `LevelAdvantage` by an independent
fact — the same function reads the DEFENCE params off one of the two objects,
and those are known to be the target's. **The equivalent probe here is to
identify `esi` and `edi` inside `Combat_ResolveDamage`** (8,298 bytes, unread),
and that is this term's next probe.

**Nothing is wired into `server/internal/combat` for exactly that reason.** A
cap or a floor can be parked in code with "nothing enforces this yet"; a damage
multiplier whose direction is unknown cannot, because the obvious way to use it
is also the way to get it backwards.
