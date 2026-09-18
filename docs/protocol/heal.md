# The heal formula

Recovered 2026-09-18 from `Skill_ApplyHealToObject` (`0x005a0850`), the function that applies a
skill's healing to one object, and its getter `ParamKeeper_GetParamChecked` (`0x004b3740`). This is
the "what a non-damaging skill DOES" question, opened for the heal case; srrevamp has no heal system
yet, so nothing here is wired in — it is the grounded spec a heal system would be built from.

## The formula

For a healed object `T`, an HP amount `hp` and an MP amount `mp` (the caller derives `hp` from the
skill's `'heal'` value[0]):

	if skill carries 'nmh':        hp = T.MaxHP * hp / 100      # 'nmh' (skill+0x598) = percent mode
	dHP = round( (1 + GetParam(170)/100) * hp ) + mwhhTerm
	dMP = round( (1 + GetParam(171)/100) * mp ) + mwmhTerm
	ApplyHPMPDelta(T, dHP, dMP, 0x40)

- **`'heal'`** carries the base amount (value[0]). 333 real skills carry it — the cleric/water heal
  and resurrection families.
- **`'nmh'`** (skill+0x598) switches the HP amount from a flat number to a **percent of the target's
  MaxHP**, read through vtable slot 68 (`GetMaxHP`). 10 real skills carry it.
- **Params 170 (0xaa) and 171 (0xab)** scale the HP and MP halves as `1 + p/100`. They are read via
  `ParamKeeper_GetParamChecked` from **the healed object's own keeper** — the receiver is confirmed
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

## What is grounded and what is not

- **Grounded**: the two `1 + GetParam/100` scalings and their param ids; the `'nmh'` percent mode
  and its `GetMaxHP` slot; that the scaling params are read from the healed object; that 170/171 are
  skill-granted (single writer); the `ApplyHPMPDelta` sink.
- **Not read**: `ApplyHPMPDelta`'s `0x40` flag, and the exact field identity of the weapon floats at
  `+0x1c0`/`+0x1c4` (read as the damage bounds from the `*0.5`-average and the weapon slot). The
  `'mwhh'`/`'mwmh'` magnitude and the `'rhru'` grant are now both read.
- **Not wired**: srrevamp has no heal system, so `'heal'`, `'nmh'`, `'mwhh'`, `'mwmh'` and params
  170/171 are recorded in `internal/skillparam` but read by no game code.
