# Who writes each ParamKeeper param

**Recovered 2026-09-18.** `GObjPC::ParamKeeper_SetParam` (`0x004b3510`) takes the param id
in **EDI** and the keeper in ESI; the visible arguments are `(slot, ctx, value)`. Resolving
EDI at every call site gives the complete writer map for the stat system.

	338 of 367 call sites resolved, covering 99 distinct params.

The resolver walks back from each call to the last write to EDI, following
`mov edi,IMM`, `xor edi,edi` and chained `lea edi,[edi+disp]` — the `lea` chaining is the
same MSVC idiom that made the derived-stat graph unreadable one call at a time (see
[stat_graph.md](stat_graph.md)).

## What is NOT resolved, and why

29 sites resist, and they are listed rather than guessed at:

	15  edi is clobbered by a call between the load and the use
	 8  edi is computed from another register (eax, ebx, edx) by a lea
	 2  edi is copied from ebx
	 4  other lea forms off a register the walk does not carry

An id that only appears at an unresolved site is therefore **absent from this table**, so
the table proves "this function writes that param", never "nothing else does".

## The table

param 0     4 site(s)  CGObjSiegeObject::PublishStats, GObjPC::GObjMob_PublishStats, GObjPC::GObjPC_InitStats, GObjPC::
param 1     4 site(s)  FUN_00594ac0, GObjPC::GObjPC_InitStats, GObjPC_SpendStatPoints, Stat_ApplyTaggedModifier
param 2     4 site(s)  FUN_00594ac0, GObjPC::GObjPC_InitStats, GObjPC_SpendStatPoints, Stat_ApplyTaggedModifier
param 3    10 site(s)  ?, CGObjCOS_Mercenary::vslot_403, CGObjMob::PublishStats, CGObjSiegeObject::PublishStats
param 4     8 site(s)  ?, CGObjSiegeObject::PublishStats, FUN_00594ac0, FUN_00596a40
param 5    12 site(s)  CGObjSiegeObject::PublishStats, FUN_004a4cc0, FUN_004a5160, FUN_005830b0
param 6    11 site(s)  ?, CGObjSiegeObject::PublishStats, Char_PublishCombatStats, FUN_004a4cc0
param 7     4 site(s)  CGObjSiegeObject::PublishStats, Char_PublishCombatStats, FUN_00594ac0, GObjPC::GObjMob_PublishSt
param 8     4 site(s)  CGObjSiegeObject::PublishStats, Char_PublishCombatStats, FUN_00594ac0, GObjPC::GObjMob_PublishSt
param 9    11 site(s)  ?, CGObjCOS_Mercenary::vslot_403, CGObjSiegeObject::PublishStats, Char_PublishCombatStats
param 10    4 site(s)  CGObjSiegeObject::PublishStats, Char_PublishCombatStats, GObjPC::GObjMob_PublishStats, Stat_Appl
param 11   11 site(s)  ?, CGObjCOS_Mercenary::vslot_403, CGObjSiegeObject::PublishStats, Char_PublishCombatStats
param 12    6 site(s)  CGObjSiegeObject::PublishStats, Char_PublishCombatStats, FUN_00594ac0, GObjPC::GObjMob_PublishSt
param 13    6 site(s)  Char_PublishCombatStats, FUN_00594ac0, GObjPC::FUN_004d60a0
param 14    6 site(s)  Char_PublishCombatStats, FUN_00594ac0, GObjPC::FUN_004d60a0
param 15    4 site(s)  Char_PublishCombatStats, FUN_00594ac0, GObjPC::FUN_004d60a0
param 16    4 site(s)  Char_PublishCombatStats, FUN_00594ac0, GObjPC::FUN_004d60a0
param 23   22 site(s)  ?, CGObjMob::vslot_215, CGObjSiegeObject::PublishStats, Char_PublishCombatStats
param 24   28 site(s)  ?, CGObjMob::vslot_215, CGObjSiegeObject::PublishStats, Char_PublishCombatStats
param 25    5 site(s)  CGObjCOS_Mercenary::vslot_403, FUN_00594ac0, GObjPC::FUN_004a9d00, Stat_ApplyTaggedModifier
param 26    5 site(s)  FUN_00594ac0, GObjPC::FUN_004a9d00, Stat_ApplyTaggedModifier
param 27    4 site(s)  CGObjSiegeObject::PublishStats, FUN_00594ac0, GObjPC::GObjMob_PublishStats, Stat_ApplyTaggedModi
param 28    4 site(s)  CGObjSiegeObject::PublishStats, FUN_00594ac0, GObjPC::GObjMob_PublishStats, Stat_ApplyTaggedModi
param 29    4 site(s)  CGObjSiegeObject::PublishStats, FUN_00594ac0, GObjPC::GObjMob_PublishStats, Stat_ApplyTaggedModi
param 30    4 site(s)  CGObjSiegeObject::PublishStats, FUN_00594ac0, GObjPC::GObjMob_PublishStats, Stat_ApplyTaggedModi
param 31    5 site(s)  CGObjSiegeObject::PublishStats, FUN_00594ac0, GObjPC::GObjMob_PublishStats, Stat_ApplyTaggedModi
param 32    4 site(s)  CGObjSiegeObject::PublishStats, FUN_00594ac0, GObjPC::GObjMob_PublishStats, Stat_ApplyTaggedModi
param 33    5 site(s)  CGObjSiegeObject::PublishStats, Char_PublishCombatStats, FUN_00594ac0, GObjPC::GObjMob_PublishSt
param 34    3 site(s)  Char_PublishCombatStats, GObjPC::GObjPC_InitStats, RemoveParamKeeperItemEntry
param 35    3 site(s)  Char_PublishCombatStats, GObjPC::GObjPC_InitStats, RemoveParamKeeperItemEntry
param 36    3 site(s)  Char_PublishCombatStats, GObjPC::GObjPC_InitStats, RemoveParamKeeperItemEntry
param 37    3 site(s)  Char_PublishCombatStats, GObjPC::GObjPC_InitStats, RemoveParamKeeperItemEntry
param 52    1 site(s)  Stat_ApplyTaggedModifier
param 53    1 site(s)  Stat_ApplyTaggedModifier
param 54    2 site(s)  GObjPC::GObjPC_InitStats, GObjPC::GObjPC_SetLevel
param 55    2 site(s)  GObjPC::GObjPC_InitStats, GObjPC::GObjPC_SetLevel
param 56    1 site(s)  Stat_ApplyTaggedModifier
param 57    2 site(s)  FUN_00594ac0, Stat_ApplyTaggedModifier
param 58    1 site(s)  Char_PublishCombatStats
param 59    2 site(s)  Char_PublishCombatStats, RemoveParamKeeperItemEntry
param 60    1 site(s)  GObjPC::GObjPC_InitStats
param 128   5 site(s)  CGObjCOS_Mercenary::vslot_403, FUN_005830b0, FUN_00594ac0, Stat_ApplyTaggedModifier
param 129   5 site(s)  CGObjCOS_Mercenary::vslot_403, FUN_005830b0, FUN_00594ac0, Stat_ApplyTaggedModifier
param 130   5 site(s)  CGObjCOS_Mercenary::vslot_403, FUN_005830b0, FUN_00594ac0, Stat_ApplyTaggedModifier
param 131   4 site(s)  CGObjCOS_Mercenary::vslot_403, FUN_005830b0, FUN_00594ac0
param 132   2 site(s)  CGObjCOS_Mercenary::vslot_403, FUN_00594ac0
param 133   2 site(s)  CGObjCOS_Mercenary::vslot_403, FUN_00594ac0
param 134   2 site(s)  CGObjCOS_Mercenary::vslot_403, FUN_00594ac0
param 135   2 site(s)  CGObjCOS_Mercenary::vslot_403, FUN_00594ac0
param 136   1 site(s)  FUN_00594ac0
param 137   1 site(s)  FUN_00594ac0
param 138   1 site(s)  FUN_00594ac0
param 139   1 site(s)  FUN_00594ac0
param 140   7 site(s)  ?, CGObjSiegeObject::PublishStats, GObjPC::GObjMob_PublishStats, GObjPC::GObjPC_InitStats
param 141   4 site(s)  Char_PublishCombatStats, FUN_00594ac0, GObjPC::GObjPC_InitStats, RemoveParamKeeperItemEntry
param 143   1 site(s)  ?
param 144   1 site(s)  ?
param 145   1 site(s)  FUN_00594ac0
param 146   1 site(s)  FUN_00594ac0
param 147   1 site(s)  FUN_00594ac0
param 148   1 site(s)  FUN_00594ac0
param 149   1 site(s)  FUN_00594ac0
param 150   1 site(s)  FUN_00594ac0
param 169   1 site(s)  ?
param 170   1 site(s)  FUN_00594ac0
param 171   1 site(s)  FUN_00594ac0
param 172   1 site(s)  FUN_00594ac0
param 173   1 site(s)  FUN_00594ac0
param 174   3 site(s)  FUN_00594ac0, GObjPC::FUN_004aaf80, Stat_ApplyTaggedModifier
param 175   3 site(s)  FUN_00594ac0, GObjPC::FUN_004aaf80, Stat_ApplyTaggedModifier
param 176   3 site(s)  FUN_00594ac0, GObjPC::FUN_004aaf80, Stat_ApplyTaggedModifier
param 177   3 site(s)  FUN_00594ac0, GObjPC::FUN_004aaf80, Stat_ApplyTaggedModifier
param 178   3 site(s)  ?, FUN_00594ac0, FUN_00596a40
param 179   3 site(s)  ?, FUN_00594ac0, FUN_00596a40
param 180   1 site(s)  ?
param 181   1 site(s)  ?
param 182   1 site(s)  FUN_00594ac0
param 183   1 site(s)  ?
param 184   1 site(s)  FUN_00594ac0
param 185   1 site(s)  FUN_00594ac0
param 186   2 site(s)  FUN_00594ac0
param 187   1 site(s)  FUN_00594ac0
param 188   1 site(s)  FUN_00594ac0
param 189   1 site(s)  CGObjCOS_Summoned::SetBodyMode
param 190   1 site(s)  Char_PublishCombatStats
param 191   1 site(s)  Char_PublishCombatStats
param 192   1 site(s)  Char_PublishCombatStats
param 193   1 site(s)  Char_PublishCombatStats
param 194   2 site(s)  FUN_00594ac0, GObjPC::GObjPC_InitStats
param 195   2 site(s)  FUN_00594ac0, GObjPC::GObjPC_InitStats
param 196   2 site(s)  FUN_00594ac0, GObjPC::GObjPC_InitStats
param 197   2 site(s)  FUN_00594ac0, GObjPC::GObjPC_InitStats
param 198   2 site(s)  FUN_00594ac0, GObjPC::GObjPC_InitStats
param 199   2 site(s)  FUN_00594ac0, GObjPC::GObjPC_InitStats
param 200   2 site(s)  FUN_00594ac0, GObjPC::GObjPC_InitStats
param 202   1 site(s)  FUN_00594ac0
param 256   3 site(s)  CTJ_PremiumKeeper::vslot_008, CTJ_PremiumKeeper::vslot_012
param 257   1 site(s)  CTJ_PremiumKeeper::vslot_012
param 258   3 site(s)  CTJ_PremiumKeeper::vslot_008, CTJ_PremiumKeeper::vslot_012
## What this settled immediately

**`Formula_MitigatePhysicalDamage` reads params 5 and 7** off the defender through the
virtual getter at vtable offset `0x104`: param 5 is subtracted flat, param 7 divides as
`X / (1 + param7/100)`. The derived-stat graph has **no edge feeding param 7**, so it is
written directly, and this table says by whom: `Char_PublishCombatStats`,
`GObjMob_PublishStats`, `CGObjSiegeObject::PublishStats` and `FUN_00594ac0`.

Reading the character's write site (`0x004978e4`) gives the source field:

	4978ca  fld DWORD PTR [ebp+0x1a0]   ; 0.0 instead when [ebp+0x190] == 0
	4978d9  mov edi,0x7
	4978e4  call ParamKeeper_SetParam   ; push 0 -> SLOT 0, the base slot

The block index is the offset over four, which the already-known pair confirms: param 58
comes from `+0x1b0` = block `[0x6c]` and param 59 from `+0x1b4` = `[0x6d]`. So **param 7's
source is block `[0x68]`** and param 6's is `[0x6a]`.

`Char_BuildAggregateStats` writes block `[0x68]` exactly once, at `0x004969af`, and the
value is a **level interpolation between two reference floats** `[eax+0x1d4]` and
`[eax+0x1d8]` (the pair is assert-checked `lo <= hi` at `0x00496974`), added to an
accumulator held in `[esp+0x18]`. **That accumulator was not traced**, so this does not yet
say whether equipment can reach param 7.

## The param 5 correction

[stat_graph.md](stat_graph.md) said "nothing writes param 5 for a player except the
publisher, skill effects and timed debuffs". That is too loose. Param 5 has **twelve write
sites in eight functions**, and two of them are a matched pair:

	004a4cc0  writes params 5 and 6      installed as a callback at +0xe38
	004a5160  writes param 5             installed as a callback at +0xe50

`FUN_004a5160` does `ParamKeeper_SetParam(slot 0, param 5, -min(record+0x34, …))` under an
`isRemove` flag — an apply/unapply pair contributing to the flat absorb. Neither is called
directly anywhere (**zero** direct call sites) and neither appears in any vtable; both are
reached only through the pointers `GObjPC::FUN_004a40c0` installs at `+0xe38` and `+0xe50`,
0x18 apart, which is why a call-graph search for them comes back empty.

## Still open: where equipped defence enters

This tick narrowed it without closing it. The item-entry writer
`RemoveParamKeeperItemEntry` touches params **34, 35, 36, 37, 59 and 141** — and the graph
feeds 34→17, 36→18, 35→19, 37→20, which is not the 5/7 defence pair. So the item path and
the defence params still do not meet anywhere that has been read. The untraced accumulator
at `0x004969a3` is the next place to look.
