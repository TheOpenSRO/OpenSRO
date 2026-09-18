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
| 1 | `40e4b0` | **base** | `FUN_0040dce0(ctx, masteryPct)` → `[esp+0x28]`; see the correction below |
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

## Stage 1 is mastery-scaled, and this page had its argument wrong (2026-09-17)

The row above used to read `FUN_0040dce0(ctx, defender, damage)`. That function
takes **no damage argument**. Its shape is:

	fVar9 = FUN_0040db50(ctx)              ; the weapon/skill damage roll
	fVar1 = (float)param_2 / 100.0 + 1.0   ; param_2 is a PERCENTAGE BYTE
	fVar3 = fVar1 * (float)fVar9

so **stage 1 is `roll * (1 + percent/100)`**, and the percentage is the
character's **mastery level**.

`Combat_ResolveDamage` builds that byte with `FUN_0059e770`, which reads the
skill's two mastery-requirement slots (`ctx+0xa0`, `ctx+0xa4` — the same pair
`docs/protocol/skill_withdraw.md`'s cost formula reads) and returns the
character's level in the higher of them:

	if (ctx == 0 || ctx[0x574] == 0) return 0;
	a = 1; b = 1;
	if (ctx[0xa0] != 0) a = masteryLevel(slot1);   ; FUN_0059e750
	if (ctx[0xa4] != 0) b = masteryLevel(slot2);
	return max(a, b);

`FUN_0059e750` resolves the mastery on the character's `+0xa30` container and
returns the byte at `record[+8] + 0x20`. So it is the **character's** level in
the mastery, not the skill's requirement — and a skill with a mastery slot the
character has never trained still contributes **1**, not 0. Only an attack with
no skill record returns 0.

### The cap is 90, and it is not a `min`

	0058f2c1  cmp al,0x5a ; mov [esp+0x68],al ; jbe done   ; p1 <= 90 -> p1
	0058f2cd  mov [esp+0x68],0x5a                          ; else 90
	0058f2d7  cmp al,0x5a ; jbe done                       ; p2 <= 90 -> keep 90
	0058f2db  mov [esp+0x68],al                            ; else p2

The percentage is computed **twice**, off two different attack records, and the
engine picks: `p1` when `p1 <= 90`, otherwise `max(90, p2)`. When both exceed 90
the result is `p2`, **above** the cap — which is exactly the case a
`min(pct, 90)` gets wrong, and the only reason four instructions exist here.
`combat.ClampMasteryPercent` reproduces it and has a test that fails if it is
ever simplified to a min.

The same constant appears at four sites (`0058f2c1`, `0058f2d7`, `0058f97d`,
`0058f993`) — the physical and magical arms of the same clamp.

**What the second record is has not been identified.** It is the object the
mitigation formula receives as its context, distinct from the one the first
percentage is read off. srrevamp passes the same value for both, which makes its
clamp a plain cap at 90 — correct for every case it can currently reach, and
wrong the day a second record exists. Said here so that day is noticed.

### How this was found

Not by reading the damage path again. After a decompiler-rendered bound nearly
shipped as 49 instead of 50 (`guild.MaxHostileGuilds`), **every unsigned bound
inside the 161 functions this project cites was re-read in assembly** — 54
comparisons. Most confirmed a shipped constant: 13 in `CGItemEquip::CanBeEquipedAt`
is `equipment.MaxEquipSlots`, 3 and 7 in `HandleSiegeRequest` are the
fortress-war requirements, 40 in the siege module is the −20…+20 tax range
biased by 20, 5 in the guild fullness predicate is `MaxLevel`. These four sites
were the largest thing the audit found that **nothing claimed**, sitting in the
one function srrevamp reimplements most closely.

## The damage resolution's full input list (2026-09-17)

`Combat_ResolveDamage` reads **38 distinct `CRefSkill` fields** through `ebx`,
and 37 of them now have names. This is the complete set of skill parameters the
engine consults to resolve one blow.

`ebx` is provably a `CRefSkill` here — it is loaded as `[arg2+8]` in the
prologue and is the base of `+0x230` (`att`) and `+0x234` (`pdmg`), both
independently confirmed. That matters, because an offset alone does NOT identify
an object type: scanning the whole server for reads in this offset range matches
1,456 functions, most of them quest and event handlers with unrelated structs.
See `docs/protocol/skill_fields.md`.

| param | offset | reads | | param | offset | reads |
|---|---|---:|---|---|---|---:|
| `att` | `0x230` | 6 | `dttp` | `0x424` | 1 |
| `pdmg` | `0x234` | 5 | `se` | `0x430` | 1 |
| `pdm2` | `0x238` | 5 | `rt` | `0x434` | 1 |
| `da` | `0x240` | 10 | `sl` | `0x438` | 1 |
| `cr` | `0x244` | 2 | `fe` | `0x43c` | 1 |
| `ck` | `0x248` | 1 | `my` | `0x440` | 1 |
| `mc` | `0x288` | 1 | `bl` | `0x444` | 1 |
| `?` | `0x28c` | 1 | `dn` | `0x44c` | 1 |
| `fz` | `0x30c` | 1 | `st` | `0x450` | 1 |
| `fb` | `0x310` | 1 | `ds` | `0x454` | 1 |
| `es` | `0x314` | 1 | `ca` | `0x458` | 1 |
| `bu` | `0x318` | 1 | `cssr` | `0x45c` | 1 |
| `ps` | `0x31c` | 1 | `csit` | `0x460` | 1 |
| `zb` | `0x320` | 1 | `cspd` | `0x464` | 1 |
| `atca` | `0x3bc` | 2 | `csmd` | `0x468` | 1 |
| `tant` | `0x3c8` | 1 | `cshp` | `0x46c` | 1 |
| `tnt2` | `0x3cc` | 1 | `csmp` | `0x470` | 1 |
| `dtnt` | `0x3d0` | 2 | `tb` | `0x474` | 1 |
| `lfst` | `0x400` | 3 | `SAAA` | `0x538` | 2 |

`0x28c` is the one field still unnamed — `reqi` and `getv` are the codes the
extractor cannot place, and one of them may own it.

### What srrevamp models of this

**One.** `att` — its percentage, minimum and maximum — plus the mastery scale
that multiplies the roll (stage 1). The other 36 are read by the engine and not
by srrevamp.

That is a measurement of scope, not a defect list. Most of these have no source
srrevamp can reach: they are consumed as pointers into a Param stream this
project reads only through the client's `skilldata_*.txt`, and
`docs/protocol/skill_params.md` decodes the *meaning* of a subset. Recording the
count matters because "srrevamp implements the damage pipeline" and "srrevamp
implements one of the pipeline's 37 inputs" are very different claims, and until
now nothing in this project could tell them apart.

The ones worth wanting, because the pipeline pages already reference them:
`pdmg` and `pdm2` (the physical damage params, stage 1's siblings), `da` (the
conditional damage percentage, read ten times — more than any other field),
`dtnt`/`tant`/`tnt2` (the target filters), and `lfst`, which selects the
alternate damage formula `FUN_0040f750`.

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
	40e706      band = base * 10 / 100            // a tenth of the BASE, not of damage
	40e716      if (band <= 0) band = 1
	40e729      r = rand()                        // 0x9dd338
	40e732      damage = 1 + (band - 1) * r / 32767

So a blow mitigated below **5% of its pre-mitigation base** is not simply
floored at 1: it is reshaped to **a random amount between 1 and a tenth of the
base**. Heavily out-geared hits land for a small random amount rather than a
constant.

**CORRECTED 2026-09-18: the tenth is of `base`, not of `damage`.** The line at
`40e706` multiplies by 10 and divides by 100 the value the FPU stack holds after
the compare, and an `fstp st(1)` at `40e6ff` pops the mitigated damage and leaves
the **base** (`[esp+0x28]`, the same value the 5% test compares against) on top.
An earlier reading took it as `damage * 10/100`, which is degenerate: in this
branch `damage` is already below 5% of base, so a tenth of it is always ~1 — the
very constant-1 this stage exists to avoid. A tenth of the base is 1..10% of the
attacker's attack, a meaningful minimum, which is what "lands for a small random
amount" means. `combat.ApplyFloorBand` shipped the `damage` reading and is now
fixed, with tests that fail under the old one.

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

There is a second, opposite term. srrevamp did not model it until 2026-09-17;
it now does, as `combat.SkillLevelPenalty`.
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

### Which participant is the attacker — SETTLED 2026-09-17

**Resolved below; this section records the reasoning that failed first.** The
direction is *target minus attacker*, so the penalty falls on an attacker
striking something above its level.

`Combat_ResolveDamage` calls this twice, and the two sites *appear* to pass the
object pair **swapped**:

	58f4fc  push edi ; mov edx,esi ; call 0x40f5f0
	58fbab  push esi ; mov edx,edi ; call 0x40f5f0

so the argument order cannot settle the roles, and nothing else read so far
does. That matters: applied backwards, this term would penalise the wrong side.

This project settled the same question for `LevelAdvantage` by an independent
fact — the same function reads the DEFENCE params off one of the two objects,
and those are known to be the target's.

### The equivalent probe was tried, and the tempting answer is wrong

`Formula_SkillPhysDamage` opens by looking something up in one participant's
`+0xa30` and **adding** the result to the base damage:

	40f607  lea eax,[esi+0xa30]
	40f60d  call 0x5a0330          ; an STL map find, keyed off the EAX argument
	40f616  add edi,[eax+0x4]      ; edi is the damage

A bonus added to damage looks like the attacker's, which would settle the
direction. **It does not, because `+0xa30` is on every character.** It is the
character's active skill/buff container: `CMainProcess::CGame__EnterWorld`
creates it, `AQ_SkillManager::vslot_007/008` and `CGSkillObject::Update`
maintain it, `Stat_ApplyTaggedModifier` reads it, and
`Formula_MitigatePhysicalDamage` — the function whose roles this project
*already* settled — takes `lea eax,[ebp+0xa30]` off its own participant. Both
sides have one, so having one identifies nobody.

Recorded because it is a good trap: the lookup really is a damage bonus, and the
inference from "bonus ⇒ attacker" really is unsound.

### The calling convention, decoded

	ecx  the damage struct        (caller: ebx->0x234; the formula reads *ecx)
	edx  -> the formula's `ebx`
	stack -> the formula's `esi`
	eax  the map key              (caller: ebx->0x538)

and the penalty fires when `level(ebx) > level(esi)`.

### SETTLED 2026-09-17 — and the two call sites were never swapped

	58f4fc  push edi ; mov edx,esi
	58fbab  push esi ; mov edx,edi

This page read that pair as the arguments being passed in **opposite orders**.
They are not. It is register allocation, and the two sites pass the same two
things:

	58f4bc  mov edi,[esp+0x124]      58fb5d  mov esi,[esp+0x124]
	58f468  mov esi,[esp+0x28]       58fb64  mov edi,[esp+0x28]

So **both** sites push `[esp+0x124]` and put `[esp+0x28]` in `edx`. There is no
reverse direction, no counter and no second exchange; there is one call made
from two branches of the same `if`.

That was the whole blocker, and it was a misreading of two instructions rather
than a missing fact. Worth recording: the registers at a call site say nothing
until the writes that feed them are traced, and *symmetric-looking* allocation
is exactly what a compiler produces from straight-line code either side of a
branch.

### Which side is which, three ways

`Formula_SkillPhysDamage(param_1 = the pdmg record, param_2, param_3)`, with
`param_2` = `[esp+0x28]` and `param_3` = `[esp+0x124]`.

1. **`[esp+0x124]` is `Combat_ResolveDamage`'s own arg0.** Its callers —
   `FUN_005857b0` and `FUN_00586700` — call it as
   `Combat_ResolveDamage(param_2, *(param_3+0x14), *(param_3+0x18))`, where
   their `param_2` is the actor they read param `0x8d` off, whose `+0x28c`
   block they maintain and whose `[0x302]` they clear: **the caster**.
2. **The same slot is `Formula_MitigatePhysicalDamage`'s `param_3`.** At both of
   *its* call sites (`58f2f8`, `58f7e7`) `[esp+0x124]` is the last push — the
   argument immediately before the damage float, which fixes it as `param_3`
   rather than by counting. Inside that function `param_3` is `ebp`, and `ebp`
   is the object that receives the out-levelling **bonus** at `40e6b6` and the
   **Str ratio** at `40e6cb`. Both are the attacker's, and stage 14's compare
   (`level(ebp) > level(edi)`, `jbe` past the bonus) says so in one line.
3. **`[esp+0x28]` is a target, not a participant passed in.** It is written
   exactly once, at `58e908`, inside a walk over the container the caller
   passes as args 1 and 2 — `cmp ecx,edx / je`, `cmp ecx,[eax+8] / jae`,
   `mov ecx,[ecx]`, `call FUN_00485d90` — and each resolved object is filtered
   on vtable slots `0x18` and `0x28` before it is damaged. One attacker, many
   targets.

**So `param_2` is the TARGET and `param_3` the ATTACKER**, the subtraction
`level(param_2) − level(param_3)` is *target minus attacker*, and the penalty
fires when **the target out-levels the attacker**. The bonus and the penalty
therefore act on opposite sides of the same difference, at different rates.

`FUN_0040f750` — the sibling called on the other arm of the same `if`, when
`[ebx+0x400]` is set — carries the **identical** level test with the roles in
the same two slots (`this` = the target, stack = the attacker), which is a
fourth reading of the direction from a function this probe did not set out to
read.

### Where the term applies

The result is **added into `[ebp+0x20]`** (`58f522`, `58fbd1`), one of three
accumulators on the damage record; the mitigated weapon blow lands in `+0x28`
(physical) and `+0x24` (magical). So this scales the **skill's own flat damage
contribution**, not the weapon blow — and it is not part of the mitigation
chain at all.

### Wired

`combat.SkillLevelPenalty`, applied in `session.performAttack` to `damageBonus`
— srrevamp's name for exactly that half — before it joins the roll. The rate,
the floor and the truncation (`__ftol2`, not rounding) are all from the
disassembly; `TestSkillLevelPenaltyIsNotTheLevelAdvantage` fails if a later
refactor collapses the two level terms into one.

A consequence worth stating, since it is arithmetic on recovered constants
rather than a further claim: `1 − 0.025·d` reaches the 10% floor at exactly
**d = 36**, so the penalty saturates 36 levels below the target and every
deeper deficit is identical.

## The pipeline above is ONE of five damage kinds (2026-09-18)

Everything on this page is what `Combat_ResolveDamage` (`0x0058e5f0`) does for **damage kind 0**.
The function switches on a byte at `+5` of the per-hit record, which the allocator leaves 0 and a
selector sets to 1..4 in four cases — all of them only when the **attacker is a PC**
(`IGObj::IsPC`, slot 7). A blow from anything else is always kind 0.

	if (attacker->IsPC()) {
	    if (attacker[0x308] ... its skill's 'msch' value[0] == 1)    kind = 1;
	    else if (target->IsFortressStructure() == 1 ||
	             target->IsFortressFlag()      == 1)                 kind = 3;
	    else if ((Equip_GetWeaponTID() & 0xf800) == 0x8000)          kind = 4;
	    else if (target->IsMonster() && EventMobList_Contains(id))   kind = 2;
	}

| kind | selected when | damage | status |
|---|---|---|---|
| 0 | none of the below | the computed blow — this page | implemented |
| 1 | the attacker's attached object carries `'msch'` with value[0] == 1 | `Formula_RollLevelDamage` — a roll from the two levels, no weapon | identified, **not modelled** |
| 2 | the target is on the hard-coded event list | the list's own 16-bit value | implemented |
| 3 | the target is a fortress structure or flag | `FUN_0040f990` (736 bytes) | identified, **formula unread** |
| 4 | the weapon-slot item has TypeID4 == 16 | exactly **1** | implemented |

The order is part of the rule: a fortress weapon swung at a structure is kind 3, not 4, and a
fortress weapon swung at the event monster is kind 4, not 2. `combat.SelectDamageKind` reproduces
it and has a test for each of those.

**How each condition was grounded.** The binary gave a pattern and real data named it; neither was
taken alone.

- **Slots 244 and 248 are TID bit tests with ONE implementation each**, shared by all 30 object
  classes — so the answer is data, not an override. Read against real `characterdata`:
  TypeID (1,2,4,2) is **exactly 5 rows, all `STRUCTURE_*_FLAG`**, and TypeID (1,2,5,\*) is
  **exactly 71 rows, all `STRUCTURE_*`** — fort stones, guard and lightning towers, gates, defensive
  positions, headquarters, barricades. Zero exceptions either way. Named
  `CGObj::IsFortressFlag` / `CGObj::IsFortressStructure`.
- **`TID >> 11` is TypeID4** — already proven by the weapon gate — so `& 0xf800 == 0x8000` is
  TypeID4 == 16, which `skill_params.md` had already recorded as the fortress weapon
  (`SKILL_*_FORTRESSWEAPON`). `Equip_GetWeaponTID` reads storage slot 6, the weapon slot.
- **The event list has one record builder in the whole binary**, and it looks up the string literal
  `"MOB_EV_WINTER_SNOWMAN"` and stores `1` at the record's `+0x1c`, the value kind 2 deals. Real
  `characterdata` has that monster: **level 1, MaxHP 11** — eleven blows from anyone, whatever they
  hold.
- **`'msch'` is `skill+0x4a4`.** 25 real skills carry it and **exactly one** has value[0] == 1:
  `SKILL_ETC_TRANS_MONSTER_01`, the transform-into-a-monster skill. That the kind-1 damage is a
  level roll "used when no weapon range applies" was annotated on `Formula_RollLevelDamage` days
  before this, from a different read.

**The TID layout, which these predicates spell out** (`& 2`, `& 0x1c`, `& 0x60`, `& 0x780`,
`& 0xf800`):

	bit 1        characterdata col 8      1 on all 17,868 rows; both predicates require it
	bits 2-4     col 9    TypeID1
	bits 5-6     col 10   TypeID2
	bits 7-10    col 11   TypeID3
	bits 11-15   col 12   TypeID4         independently proven by the weapon gate

Bit 0 is *consistent with* column 7 by adjacency and is **not** confirmed by a use-site.

**What this means for srrevamp.** None of the four is reachable with the content it spawns — no
transform, no structures, no fortress weapons in play, no snowman — so kind 0 was the right thing
to have built first, and that is now a statement with the conditions written down rather than an
assumption. Kinds 2 and 4 are wired into `session.performAttack` anyway, because they are fully
read and cheap, and so the winter event or a fortress weapon cannot arrive ahead of the rule.

## Status effects are a phase of the blow, gated by the target's resists (2026-09-18)

After the damage kinds, `Combat_ResolveDamage` calls `Combat_ApplyStatusEffects` (`0x00590680`) to
apply the afflictions a skill carries. This is the READ side of `combat.ResistParams` (27–32),
recovered from that function and settling what those params mean from a use site.

A skill carries up to six afflictions, one per field, and each is gated by the target's matching
resist param:

	skill field 0x30c 'fz' -> GetParam(27)      0x318 'bu' -> GetParam(30)
	skill field 0x310 'fb' -> GetParam(28)      0x31c 'ps' -> GetParam(31)
	skill field 0x314 'es' -> GetParam(29)      0x320 'zb' -> GetParam(32)

a **1:1 mapping in field order**, so params 27–32 are the six per-affliction **resist percentages**,
read from the afflicted target (a resist gates the affliction, so it belongs to the target). For
each:

	resist = GetParam(target, 27+i)
	if resist >= 100:  skip -- fully resisted
	mag = (100 - resist)-scaled effect strength - GetParam(target, 145+i)   # second term at resist+0x76
	if mag > 0:  build an effect record and queue it

The second param (145–150 = resist + 0x76) is a further reduction; what it represents beyond that
is not read.

`'fb'` is **not** an item magic-option tag (zero comparisons in `Stat_ApplyTaggedModifier`), while
the item tag `'fz'` writes **both** params 27 and 28 (`combat.SecondParamFor`). So anti-frostbite
gear covers the `fz` and `fb` afflictions together — the write side grants two resists from one tag
because the read side has two afflictions sharing that gear. The two sides, from two functions,
agree.

Recorded as `combat.AfflictionResistParam` / `AfflictionSecondParam` with a cross-check test. **Not
wired** — srrevamp has no status-effect system — so these are reference data, read by no game code.
