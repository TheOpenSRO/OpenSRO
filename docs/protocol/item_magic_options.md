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

It also leaves the original defence question where the previous ticks left it. Params 5 and
7, the flat absorb and the percentage physical reduction, are still fed on the character side
from authored `RefObjChar` fields with no equipment term. An item can reach those params only
if one of its magic options carries a tag that maps to them, and **which tags map to 5 and 7
is not established** — the tag map resolves 19 of 37 branches and neither 5 nor 7 is among
them. srrevamp's damage model is unchanged.
