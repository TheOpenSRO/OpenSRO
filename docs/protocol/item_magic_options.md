# How an equipped item reaches the ParamKeeper

**Recovered 2026-09-18.** This closes the question left open by the equipment retraction in
[stat_graph.md](stat_graph.md): equipment *does* reach the ParamKeeper, but not through the
base defence chain. It arrives through an item's **magic options**, using the tag vocabulary
in [stat_tags.md](stat_tags.md).

## The chain

	IBindingOptionOP slot 3   (SetParamKeeperForMagicOpt, per the base class's own assert)
	  -> Item_DecodeMagicOption        one entry of the item's magic-option array
	  -> MagicOption_ResolveTag        code -> three-character tag
	  -> Stat_ApplyTaggedModifier      tag -> ParamKeeper param

Three classes implement slot 3. Two are real — `CAlchemyMagicOptionOP` (an item's own
options) and `CSetMagicOptionOP` (set bonuses). The third, `CSocketOptionOP`, is a **stub**
that logs `## Illegal ## CSocketOptionOP::SetParamKeeperForMagicOpt Entered!` and asserts, so
socket options do not travel this path in this build.

## The on-item layout, and the one constant it states

`CAlchemyMagicOptionOP::SetParamKeeperForMagicOpt` reads the count and loops:

	iVar3 = item->record;                     // +0x34 on the item
	n     = *(byte *)(record + 0x58);         // MagParamNum
	if (0xc < n)
	    "Item's MagParamNum(%d) is out of range"

**The field name and its cap are the binary's own**: the format string names `MagParamNum`,
and the comparison `0xc < n` puts the valid range at 0..12 — so **at most 12 magic options
per item**. This is read off the assert, not inferred from data.

The options themselves are an array of **8-byte entries at `record + 0x60`**, indexed
`record + 0x60 + i*8`. `Item_DecodeMagicOption` splits one entry:

	4904f2  mov edx,[eax+esi*8+0x64]   ; high dword
	4904fa  mov esi,[ecx]              ; low dword
	4904fe  mov cl,0x20
	490500  call __allshr              ; EDX:EAX >> 32
	49050a  mov [ecx],eax              ; out: the VALUE  (the high dword)
	49050f  shr edx,0x10
	490519  mov WORD PTR [eax],dx      ; out: bits 16..31 of the low dword
	490531  call MagicOption_ResolveTag ; on the low dword

So each entry is a packed 64-bit pair: the **high dword is the magnitude**, and the low dword
carries the option code, with its bits 16..31 handed back separately.

`MagicOption_ResolveTag` looks the code up in the reference container at
`DAT_00d6aa14 + 0x268` (`+0x5c0` within it) and writes the matched record's **`+4`** field
into the caller's out-pointer. That field is the three-character tag
`Stat_ApplyTaggedModifier` dispatches on, which is where this joins the recovered
vocabulary.

## What this does and does not settle

It settles **that** equipment reaches the params and **by what route**. It does not identify
which authored table the option records come from, nor what bits 16..31 of the low dword are
for — both are read as structure, not as meaning.

**It also settles the original defence question, in the negative.** Params 5 and 7 — the
flat absorb and the percentage physical reduction — cannot be written through this path at
all. `Stat_ApplyTaggedModifier` writes exactly 31 literal param ids plus two computed ones
that are both pinned (`lea edi,[ebx+0x2]` on a branch reached only when `ebx == 0`, so 2; and
a deferred id that is only ever -1 or 28), and neither 5 nor 7 is among them — see
[stat_tags.md](stat_tags.md) for the enumeration.

Combined with the character-side reading, where params 6 and 7 come from authored
`RefObjChar` fields with no equipment term in the arithmetic, **equipment does not reach
params 5 or 7 by either route** in this build.

That is a statement about the engine, not a verdict on OpenSRO. OpenSRO's `defenderArmor`
adds equipment armour into the flat term, which the engine does not do — but what equipment
*does* contribute defensively is still unread (several of the writable ids, 25-32 and
128-131, are unidentified), so there is nothing yet to replace it with. The damage model is
left alone.
## Round 769: the plus and the options count

Read 2026-10-11 from SR_GameServer.exe (gs) and sro_client.exe (c); implemented in
`server/internal/session/equipstats.go`, `combat.WeaponRange` / `WeaponAttackRate`, and
`character.Bonus`.

- **The effective plus** (FUN_00459c70, READ): OptLevel + the type-2 binding entries' value (the
  advanced elixir, INFERRED from the wire) + a 'rein' option's column 9, as a byte.
- **The plus term** (Char_BuildAggregateStats 0x495d60, READ): `field = L + q*(U-L) + Inc*plus`,
  a float with no rounding (asm 0x495f26..0x495f97). The increments are itemdata columns 67
  (physical defence), 70 (parry), 73 (physical absorb), 78 (magical defence), 81 (magical absorb),
  99 (physical attack, both ends), 104 (magical attack, both ends) and 115 (attack rate). The block
  and the critical have none; the reinforce pairs (105-112) have none. MEASURED over 17,935
  equipment rows: 70 and 115 are 0 on every row.
- **Then the rate options** (ApplyDurabilityAndRateOptions 0x496a70, after the builder, READ):
  'hr' scales the weapon's attack rate and 'er' a body piece's parry, `x (1 + v/100)`.
- **Stat_ApplyTaggedModifier** (0x498690, READ) writes slot 0 with the item as its context, and
  slot 0 SUMS (FUN_004b2e60):
  - 'str' / 'int' add to params 1 / 2. Max HP is `Str_total * 10 * 1.02^(level-1)` (the chain
    3 <- 54 <- 52 <- 1) plus the items' flat 'hp': the level growth multiplies the item Str, not the
    item HP. Max MP the same over Int and 'mp'.
  - 'cri' REPLACES the weapon's param-12 entry with `round(white crit) + v`; 'bri' the shield's
    param-10 entry with `round(white block) + v`. Both are percentage points (RollChance 0x5a1a20).
  - 'evbl' / 'evcr' add into params 56 / 57 (clamped at 100), which divide the opponent's block and
    critical: `chance / (1 + p/100)` (Combat_ResolveDamage 0x58e5f0) -- combat.EvadedChance.
- **The panel** (c, READ): the 0x303D builder sends `round(GetParam(1))`, and CIFPlayerInfo prints
  it with one "%d": Str and Int are shown as one total.
- A broken item contributes nothing: CGObjPC::ChangeItemDurability (0x4e7100) removes a breaking
  item's param entries and does not publish them again, and PublishEquipItemParams (0x4e3760) runs
  the option operations only when the item's own publication succeeds (READ, round 769's review).
- Every worn item's 'cri' / 'bri' is an entry of the same param, so they sum across items (a
  non-weapon's own critical and a non-shield's own block are taken as 0, INFERRED).

**Not built (OPEN or OURS):** the absorbs (params 7/8; OpenSRO models no flat absorb); the
regeneration, resist and avatar options; 'hpna' (a percent of the HP chain); the requirement gate
(PublishEquipItemParams first checks CheckEquipRequirements 0x4919e0; OpenSRO checks requirements
only when an item is put on); the set items' opt-level bonus (0x4bb680). A character's bonus is
cached and cleared whenever its worn items change, and the stored HP is clamped when a lower max
leaves it above (OURS: the server's own bookkeeping; whether retail clamps there is OPEN).
