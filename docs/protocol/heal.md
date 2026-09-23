# The heal formula

Recovered 2026-09-18 from `Skill_ApplyHealToObject` (`0x005a0850`), the function that applies a
skill's healing to one object, and its getter `ParamKeeper_GetParamChecked` (`0x004b3740`). This is
the "what a non-damaging skill DOES" question, opened for the heal case.

**Corrected in round 503**, from the function's asm rather than the decompile (which drops the x87
arithmetic): `'nmh'` takes its percent from value[1], not value[0]; outside `'nmh'`, value[1] is a
+% bonus on value[0]; the rounding is a truncation; `'HLRU'` adds to value[1] and value[3]; and the
caller heals only for action kind 0. Round 503 also wires the one exact case, a flat self-heal (see
"What srrevamp does" below).

## The formula

The caller passes the four `'heal'` values as `ECX = v0`, `EAX = v1`, then the caster, `v2`, `v3`
and the skill on the stack. `ESI` points at the healed object's skill book (object `+0xa30`), whose
first word is the object. For that object `T`:

	hp = v0
	if v1 != 0:
	    if skill carries 'nmh':  hp = trunc(T.MaxHP * v1 / 100)       # 5a086e: percent of MaxHP, from v1
	    else:                    hp = v0 - trunc(v0 * v1 / -100.0)    # 5a08b0: v1 is a +% bonus on v0
	mp = v2
	if v3 != 0:                  mp = v2 - trunc(v2 * v3 / -100.0)    # 5a08de: v3 is a +% bonus on v2
	dHP = trunc((GetParam(170) / 100 + 1.0) * hp) + mwhhTerm         # 5a0914
	dMP = trunc((GetParam(171) / 100 + 1.0) * mp) + mwmhTerm         # 5a093d
	ApplyHPMPDelta(T, dHP, dMP, 0x40)                                 # 5a09bb

- **`trunc`** is `_ftol2` at `0x9fbb40` (`cvttsd2si`). It truncates; it does not round. An earlier
  version of this page wrote `round`.
- **The constants**, read from `.rdata`: `-100.0` at `0xb462d0` (`00000000 000059c0`), `100.0` at
  `0xb45af0`, `1.0` at `0xb45ac0`. The `2^32` float at `0xb45ba4` is the unsigned fix-up after an
  `fild` of a negative word. Dividing by `-100.0` and subtracting is the compiler's way of adding
  `trunc(v0 * v1 / 100)` for a positive product.
- **`'heal'`** (skill+0x324) carries the four values. 333 real skills carry it, the cleric/water
  heal and resurrection families, and no real row carries it twice.
- **`'nmh'`** (skill+0x598) switches the HP amount to a **percent of the target's MaxHP**, read
  through vtable slot 68 (`GetMaxHP`, `+0x110`). The percent is **value[1]**, and the branch runs
  only when value[1] is non-zero. 10 real skills carry it.
- **Params 170 (0xaa) and 171 (0xab)** scale the HP and MP halves as `1 + p/100`. They are read via
  `ParamKeeper_GetParamChecked` from **the healed object's own keeper**. The receiver is confirmed
  from the call site, since the same object pointer feeds both `ApplyHPMPDelta`'s target and the
  `GetParam` reads. The buff that grants them is **`'rhru'`** (skill+0x2a4): `ApplySkillParamsToChar`
  (`0x00594ac0`) writes its value[0] → param 170 and value[1] → param 171, both at slot 0 (base) —
  verified from that write site, matching `skillparam.DrivesParams["rhru"]`. So param 170/171 are a
  **"healing received" buff on the target**, zero by default (`param_registry.md`). Real data: 8
  skills carry `'rhru'`, all `SKILL_EU_BARD_DANCEA_CLERIC_*` — the Bard's cleric-dance line, granting
  +18/22/26/… % HP recovery with a zero MP term. It never co-occurs with `'heal'` on the same skill,
  which is the design: the dance buffs an ally, and a separate heal landing on that ally later reads
  param 170 from them. `skillparam.HealHPScaleParam` / `HealMPScaleParam` / `HealScaleBuffCode`.
- **`'mwhh'`** (skill+0x328) and **`'mwmh'`** (skill+0x32c) add a further HP / MP term, now read in
  full. Each is `Formula_WeaponAvgDamagePercent(caster, value)` = `trunc( avgWeaponDamage *
  IntLevelDamageRatio * value/100 )`, where `avgWeaponDamage = (weapon+0x1c0 + weapon+0x1c4) * 0.5`
  from the caster's equipped weapon (storage slot 6, via `GObjPC_GetItem`), and 0 when the caster
  holds no weapon. So `'mwhh'`/`'mwmh'` add a heal term equal to their percent of the healer's
  average weapon damage, scaled by the Int/level ratio. 107 skills carry `'mwhh'`, 44 `'mwmh'`. The
  SAME helper drives `'mwhs'` (`skill+0x404`, `AltDamageExtra`) in `Combat_ResolveDamage`, which is
  the cross-check that it is a general "percent of weapon damage" term rather than a heal special
  case.

## Where the values come from: the caller

`Skill_ApplyEffectsAndNotify` (`0x593f50`), step 5 of `EngageSkill` (`skill_params.md`):

	5941f1  cmp [skill+0x168],0 ; jne      only ACTION KIND 0 (the first raw Param word) heals here
	594235  cmp [skill+0x324],0 ; je       no 'heal', no heal
	594242  v0..v3 = heal values[0..3]
	59425e  getv 'HLRU' (skill+0x558) set: look its value up in the caster's book
	        (0x5a0330 on caster+0xa30) and ADD the entry's +4 to v1 and to v3
	594293  the context's target vector is EMPTY:
	5942b1    Target_Required (skill+0x94) == 0, and
	5942c0    the caster's GetLifeState (vtbl +0xf8) == 1  ->  heal the CASTER (5942f3)
	5942fd  otherwise, with no 'efr' field 1 (skill+0x28c) and no 'resu' (skill+0x330):
	59461b    heal each living target in the vector with the same v0..v3 (59463c)

The `'efr'` modes take other branches (mode 6 at `0x59431b`, the others at `0x59443d`), which
this page does not cover.

## `ApplyHPMPDelta`

`GObjPC::ApplyHPMPDelta` (`0x4a86a0`) first scales the HP amount by `(1 - GetParam(143)/100)` and
the MP amount by `(1 - GetParam(144)/100)`. Those are the panic and combustion states
(`session/useitem.go` has the citation). A negative result is floored at 0. The pool adjust
(`0x4a87d0`) runs only while the object's `GetLifeState` is 1. It adds each amount to the current
pool and writes the pool through the setters `0x4a66f0` (HP) and `0x4a6790` (MP). Each setter
clamps to `[0, GetMaxHP]` or `[0, GetMaxMP]` (vtable `+0x110` / `+0x114`). After comparing each
pool with its snapshot at `+0xa00` / `+0xa04`, the adjust ORs the `0x40` flag into the word at
`+0xa0e` (`0x4a88d5`). What reads that word was not read.

## What srrevamp does (round 503)

It wires **one case: a flat self-heal.** The rule is `skillparam.SelfHealAmounts`, and
`cmd/export-refdata` writes its result as skill CSV columns 43/44 (`SelfHealHP`, `SelfHealMP`). A
row gets a non-zero amount only when all of these hold:

- its action kind (raw column 68) is 0 and its `Target_Required` (raw column 22) is 0;
- its Param walk completes, carries one `'heal'`, and carries no combat parameter;
- it carries none of `'efr'`, `'nmh'`, `'mwhh'`, `'mwmh'` or getv `'HLRU'`;
- for HP, value[1] is 0; for MP, value[3] is 0.

With p170/p171 at 0 (their one writer is the `'rhru'` buff, and srrevamp has no buff system),
`dHP = v0` and `dMP = v2` exactly.

On the retail table that selects **57 rows**:

- the 49 `SKILL_CH_WATER_SELFHEAL_A..E` rows, HP 89 (A_01) to 6964 (E_07);
- the 8 `SKILL_EU_BARD_RECOVERA_ABNORMALTIME_A/B` rows, MP 594 to 6183.

127 of the 333 `'heal'` rows pass the kind and `Target_Required` gates. The other 70 carry
`'efr'` (60 rows, 42 of them also `'mwhh'` and `'HLRU'`, 7 `'mwmh'`) or `'nmh'` with a percent in
value[1] (10 rows, the `SKILL_ITEM_ETC_SOCKET_STONE_HEAL` stones). Measured by code-word presence
in the row.

The cast handler (`session/skill.go`, the no-blow branch) heals a **living** caster by
`SelfHealHP`, capped at max HP, and restores `SelfHealMP` to the mana pool, capped at max MP. Every
cast on that branch now reports the caster's real HP in `PlayerHP`, where it used to report 0.

**Who is healed (round 507).** The handler heals the caster whatever the request's
`TargetMonsterID` names. The engine heals the caster only when the use context's target vector is
empty (`0x594293`-`0x5942ab`). With a non-empty vector it heals each living target instead
(`0x59459f`-`0x59463c`), not the caster. On the path a player's cast takes, the two agree:
`Tick_UseSkill` phase 0 (`0x4ae6f0`-`0x4ae717`) sets the context's `+0xc` to 0 and clears its
target vector (`SkillContext_ClearTargets` `0x48dc30`) for every row with `Target_Required` 0,
before phase 2 posts the 0x7070 command. `SelfHealAmounts` passes only `Target_Required` 0 rows.
**Not read:** whether the 0x7070 consumer can put a target back into the vector for such a row. If
it can, a targeted self-heal is a divergence. (A `Target_Required` 1 row with an empty vector heals
nothing: `0x5942b8` `jne 0x594664`.)

**The MP half is not shown at once.** `SelfHealMP` reaches the pool (`mana.Tracker`), but the
cast's reply (`AttackResult`) has no MP field. The HUD's MP bar moves on the next
`OpCharacterStatsResult`: a stats request, or the push `session/regen.go` sends when a regen
tick restores HP.

**Not modelled, disclosed:**

- heals on other characters, and the percent, bonus, weapon-term and `'HLRU'` shapes;
- p170/p171 above 0;
- the panic/combustion scaling inside `ApplyHPMPDelta`;
- the `'resu'` and `'efr'` branches.

## What is grounded and what is not

- **Grounded**: the formula above, including the `'nmh'` and bonus branches, the truncation and the
  constants; the two `1 + GetParam/100` scalings and their param ids; that the scaling params are
  read from the healed object; that 170/171 are skill-granted (single writer); the caller's gates
  (action kind 0, the empty target vector, `Target_Required`, the living caster) and the `'HLRU'`
  addition; `ApplyHPMPDelta`'s scaling and its clamp to the maximum.
- **Not read**: what the `'HLRU'` lookup (`0x5a0330`) returns; the `'efr'` mode branches; who reads
  the `+0xa0e` word the `0x40` flag lands in; and the exact field identity of the weapon floats at
  `+0x1c0`/`+0x1c4` (read as the damage bounds from the `*0.5`-average and the weapon slot).
