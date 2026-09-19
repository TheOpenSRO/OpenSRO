## Berserk orbs are earned on the killing blow, by chance -- there is no gauge

"I get berserk balls for attacking; you should get some when it dies." The
report was right, and the reason was that `berserk.FillPerHit = 8` was own
design, declared as such. The engine's rule is read now, function by function,
and it is a **kill** rule with no fractional gauge anywhere in it.

**The one piece of state.** `_CHAR.RemainHwanCount` (charData+0x86, 0..5) has
exactly one mover, `GObjPC::AddHwanCount` (`0x004e4d00`): the delta arrives in
ESI, a positive delta is refused while `GetBodyMode()==1` (berserk on), the
result is clamped to `[0, 5]`, persisted with dirty bit 0x10, and
`FUN_004e3fb0(4, ...)` announces it. The client's five orbs are that byte.

**Who calls it.** Six call sites in the disassembly (`call 0x4e4d00`):
the activation handler (-5, the spend already recovered), two item paths,
`EngageSkill` at `0x5935be` -- `movzx esi,[skill_ref+0x18]; neg esi`: **a skill
spends its own hwan cost**, the `Consume_WHAN`-style byte, gated on it being
non-zero and the caster being a PC -- the party share (below), and the one
that earns: the per-target apply pass `FUN_00593800` at `0x593b97`, with
`mov esi,[esp+0x14]`, a computed amount.

**When it fires.** The apply pass gates the earn on the effect block's
`+0x54`, and `Combat_ResolveDamage` writes that field exactly once (its line
1150): on the **killing blow** -- when the accumulated damage reaches the
target's HP (state byte `|0x80`) -- and only if the attacker's `GetBodyMode()`
is not 1 and the target's vtable slot 62, `IGObj::GetLifeState`, answered 1
(it was alive, so a corpse cannot pay twice). The apply pass then requires
the attacker to be a PC (slot 7), asks `FUN_00410880(pc, &amount)` for a
chance, and rolls `rand() % 10000 < chance`.

**How much, and how likely -- `GObjPC::HwanGainChance` (`0x00410880`), from
its asm at `0x410880-0x4109c0` with every constant read out of .rdata:**

	amount = 1
	pct    = 8.0                                        ; 0xb45e14 (float) = 8.0
	if LevelGapClass(target - attacker) == 2:           ; victim more than 3 levels below
	    pct = 8.0 - 0.25 * (attackerLvl - targetLvl - 5) ; 0xb45eb0 = 8.0, 0xb45ca8 = 0.25 (doubles)
	    pct = clamp(pct, 0.25, 8.0)                     ; 0xb45b50 = 0.25 (float)
	chance = ftol(pct * 100.0)                          ; 0xb45af0 = 100.0 -> 1/100 % units
	if target.IsMonster():                              ; slot 10
	    switch target.GetMonsterClass():                ; slot 75; jump table at 0x4109e8
	      3, 8:  amount = 5; chance = 10,000,000         ; unique: all five orbs, certain
	      4:     chance *= 5                              ; giant
	      6:     chance *= 2                              ; elite
	if p := attacker.GetParam(184); p != 0: chance = chance * p / 100
	return chance & 0xffff

`LevelGapClass` is `FUN_0040fe60`: `diff = target - attacker` as bytes; `diff <
-3 -> 2`, `diff < 11 -> 0`, else `1`. Only class 2 decays; a much higher victim
earns no bonus. So an even fight is **8% per kill for one orb**, a victim six
levels below 7.75%, ten below 6.75%, thirty-six or more below the 0.25% floor;
a giant five times that, an elite twice, and a unique fills the five outright.

**The party branch.** When the victim `IsMonster` and answers slot 193,
`CGObjMob::IsPartySupportMonster`, and the killer's party has bit 0 of
`party+0x10` set -- the exp-sharing flag `internal/party` already recovered --
`FUN_005bcf30` walks the party and gives the amount to every member that is a
PC, alive (`GetLifeState()==1`) and in the killer's region. An ordinary kill
pays the killer alone.

**Settled by use-site, not name.** Param 184 (registry: default 0, max 1000,
no tag) is the engine's own gain modifier; srrevamp publishes no source for
it. The `HwanGain` rate `internal/rates` carries from the pserver's config is
NOT read on this path in the dump build; how that build applied it, if at all,
is not established.

**Shipped.** `internal/berserk` keeps the orb count (0..5) as its state and
earns with `EarnOnKill(Kill{...})`, whose `GainChance` is the table above,
pinned point by point in `berserk_test.go` (twenty cases, including the
floor, the clamp back to base at a four-level gap, giant-far-below = 3375, and
the unique's certainty); `Gauge()` is `Charges * 20` so the HUD and the wire
are untouched. `session/combat.go` no longer fills on every attack; it calls
`EarnOnKill` inside the kill block with the monster's level and rarity and
reports the count on the same attack result. `hwan_test.go` proves both
deterministic ends at the wire: a non-killing blow earns nothing, a unique
kill pays all five. Activation still requires and spends five.

**Not wired, stated:** the party-support share (srrevamp spawns no
party-support monsters); persisting the count (the engine's is a DB column;
srrevamp clears it on disconnect); a skill's own hwan cost on cast (needs the
`Consume_WHAN` column index); param 184's source.
