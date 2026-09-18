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

## The accumulator, traced

The accumulator left untraced above is now read. The block that produces param 7's source
is gated and assembled like this:

	49691e  mov edx,[ebx]            ; the character's vtable
	496920  mov eax,[edx+0x90]       ; virtual slot 36
	496928  call eax
	49692a  cmp eax,0x1
	49692d  jne 0x496a32             ; whole block skipped unless it returns 1
	496933  fild DWORD PTR [esp+0xc] ; an integer count, widened
	496937  mov ecx,[ebx+0x34]
	49693a  mov eax,[ecx+0x18]       ; -> the reference record
	496941  fld DWORD PTR [eax+0x1dc]
	496947  fmul [esp+0xc]           ; ref[0x1dc] * count
	49694b  fstp [esp+0x18]          ; -> the accumulator

So both defence sources are the same shape, param 6 from `[ebx+0x1a8]` and param 7 from
`[ebx+0x1a0]`:

	field = ref[0x1dc] * count  +  lerp(ref[0x1d4], ref[0x1d8], t)

Every term comes from the reference record at `[[char+0x34]+0x18]` or from a
character-derived scalar. **No equipment value enters this computation**, so equipment does
not reach param 7 along this path.

**The gate is not identified.** Virtual slot 36 resolves to the *same address* in
`CGObjPC`, `CGObjChar`, `CGObjMob` and `CGObjCOS_Summoned`, so MSVC folded four identical
implementations into one. It currently carries the label
`CGObjCOS_Summoned::IsAccessory`, recovered from one class's assert — that label is an
artifact of the folding and is **not** evidence of what the gate means here.

## The reference record is a RefObjChar — settled

`[[char+0x34]+0x18]` is a **RefObjChar**, the characterdata row. Proven by a named accessor
that walks the identical path and reads a field the extractor names:

	004a66e0  CGObjCOS_Summoned::GetGender
	          mov eax,[ecx+0x34] ; mov ecx,[eax+0x18] ; mov al,BYTE PTR [ecx+0x199]

and `RefObjChar_ExtractData` writes `+0x199` as its `CharGender` byte. Two independent
routes to the same class.

`RefObjChar_ExtractData` does write `+0x1d4`, `+0x1d8` and `+0x1dc`, despite no such text
appearing in its decompile. It fills them through a **pointer walk**:

	local_4c = param_1 + 0x1a4;   local_48 = 0x20;
	do { *local_4c = *(cursor + base); cursor += 4; counter += 1; local_4c++; }
	while (--local_48);

— a run of **32 consecutive dwords from `+0x1a4` to `+0x220`**, of which `+0x1d4`, `+0x1d8`
and `+0x1dc` are entries 12, 13 and 14.

So the two floats param 7 interpolates between, and the per-count term added to them, are
**authored characterdata values**. That settles the identity question left open above and
confirms the finding: no equipment term is involved.

## Why no column numbers are quoted here

The obvious next step is to turn those field positions into characterdata column numbers by
counting. **It does not work, for two independent reasons**, and the repo already knew the
first: `server/cmd/export-refdata/main.go` records that for itemdata "binary field 57 and
text column 57 are simply different fields at the same index".

The second reason is structural, and it makes the arithmetic invalid rather than merely
risky. **The two extractors do not read one stream.** `RefObjCommon_ExtractData` parses the
row its caller hands it. `RefObjChar_ExtractData` looks its own row up:

	iVar11 = RefTable_FindRowById(0xd, this->id);
	iVar7  = <read dword at cursor>; counter++; cursor += 4;
	if (iVar7 != this->id) { assert }

Reading a field and asserting it **equals the object id** is what a stream sitting at the
start of a row looks like. So `RefObjChar`'s field indices are counted within its own row,
and adding them to `RefObjCommon`'s 48 puts two different axes on one number.

That 48 is itself now verified rather than inferred: the one loop that contributes to it
initialises its counter to 4 and reads **two** fields per trip — a dword and a byte, with
the destination pointer advancing by 8 — so it contributes exactly 8, and the total is 48.

`RefTable_FindRowById` is the accessor that makes this readable. An index picks the table
through a bounds-checked vector accessor, it walks that table's linked list of rows, and it
compares a key chosen by a selector — the row's **first dword** for selectors `0xc`, `0xd`
and `0xe`, or the field at `+0x30` for `3` and `0x11`. While probing it saves the row's
cursor and field counter, zeroes them to read the key at offset 0, then restores both, so a
probe never disturbs a parse in progress.

So `+0x1d4`/`+0x1d8`/`+0x1dc` stay recorded as **RefObjChar binary fields 17, 18 and 19**
(entries 12-14 of the `+0x1a4` run) and are deliberately **not** given column numbers. The
`+0x25c defaulting to 3000 = col 82` note carried in that function's own recovered comment
mixes the two axes the same way and should not be relied on.


## Who READS each param

The writer map above has a counterpart. Params are read back through a virtual getter at
vtable offset `0x104`, so sweeping `(**(code **)(*obj + 0x104))(<literal>)` gives the reader
side. **189 call sites, of which 44 params are read with a literal id**; the rest pass a
variable and are not counted.

	param 1    CGItemEquip::CanBeEquipedAt, FUN_00594ac0, FUN_0059e450, GObjPC::FUN_0049aa70
	param 2    CGItemEquip::CanBeEquipedAt, FUN_00594ac0, FUN_0059e450, GObjPC::FUN_0049aa70
	param 3    CBattleArenaInfo::vslot_004, FLAG_WORLD_EVENT_HANDLERS::OnUpdate_FlagChecker::Handle, FUN_0050fee0, GObjPC::FU
	param 4    CBattleArenaInfo::vslot_004, FLAG_WORLD_EVENT_HANDLERS::OnUpdate_FlagChecker::Handle, FUN_0050fee0, GObjPC::FU
	param 5    FUN_0040f1b0, Formula_MitigatePhysicalDamage
	param 6    FUN_0040f3d0, Formula_MitigateMagicalDamage
	param 7    FUN_0040f1b0, Formula_MitigatePhysicalDamage
	param 8    FUN_0040f3d0, Formula_MitigateMagicalDamage
	param 10   Combat_ResolveDamage
	param 12   Combat_ResolveDamage
	param 23   CGObjPC::vslot_215
	param 24   CGObjPC::vslot_215, FUN_00567190
	param 27   FUN_00590680
	param 28   FUN_00590680
	param 29   FUN_00590680
	param 30   FUN_00590680
	param 31   FUN_00590680
	param 32   FUN_00590680
	param 56   Combat_ResolveDamage
	param 57   Combat_ResolveDamage
	param 140  GObjPC::FUN_004aa530
	param 141  FUN_005830b0, FUN_005857b0, FUN_00586700, Skill_CheckUseConditions
	param 145  FUN_00590680
	param 146  FUN_00590680
	param 147  FUN_00590680
	param 148  FUN_00590680
	param 149  FUN_00590680
	param 150  FUN_00590680
	param 169  FUN_00590680
	param 172  Enchant_SuccessRateBasePlusBonus
	param 173  CEnchant_Reinforce::GetSuccessRate
	param 178  FUN_0040ebe0, Formula_MitigatePhysicalDamage
	param 179  FUN_0040eef0, Formula_MitigateMagicalDamage
	param 180  FUN_0040ebe0, FUN_0040f1b0, Formula_MitigatePhysicalDamage
	param 181  FUN_0040eef0, FUN_0040f3d0, Formula_MitigateMagicalDamage
	param 184  FUN_00410880
	param 187  Combat_ResolveDamage
	param 188  Combat_ResolveDamage
	param 189  FUN_0040ebe0, FUN_0040eef0, Formula_MitigateMagicalDamage, Formula_MitigatePhysicalDamage
	param 190  Formula_RollWeaponDamage
	param 191  Formula_RollWeaponDamage
	param 192  Formula_RollMagicalDamage
	param 193  Formula_RollMagicalDamage
	param 259  Formula_MitigateMagicalDamage, Formula_MitigatePhysicalDamage

Params 27 and 29 are now named: `DumpItemOptionsVerbose` prints them as **"anti-burn"** and
**"anti-eshock"**, so the 25-32 run listed as unidentified above is the **resist family** (see
[stat_tags.md](stat_tags.md)).

Readers are how a param's *meaning* gets settled, because the formula that consumes it says
what it does. Two were settled this way immediately, and one of them corrected this page.

## Correction: the physical mitigation formula reads six params, not two

This page previously described `Formula_MitigatePhysicalDamage` as reading params 5 and 7.
That is what the first half of the function does, and it is where the reading stopped. The
function reads **seven values in all**:

	param 5     subtracted flat
	param 7     divides as X / (1 + param7/100)
	param 128 or 129   on the ATTACKER, selected by flag bits 1 and 2; enters as
	                   (v/100 + 1.0) * damage
	param 259   on the ATTACKER, only when the defender's type check returns 3;
	            adds (v/100) * damage
	param 189   on the ATTACKER when flag bit 4 is set; becomes a multiplier v + K
	param 178   on the ATTACKER, result discarded in the decompile
	param 180   on the DEFENDER: `if (v != 0) damage = v * damage`

The understatement mattered. Concluding from params 5 and 7 alone that equipment contributes
nothing to physical mitigation was reading two terms out of seven.

## What that changes, and what it does not

**`'mdu'` -> param 259 is not a defensive bonus.** It is read off the *attacker* and applies
only when the defender's type check returns 3, so it is conditional offence. The tempting
reading — "equipment reaches the mitigation formula, so equipment defends" — is wrong on the
side it acts from.

**Param 180 is a genuine defender-side multiplier**, read off the defender and multiplying
the final damage outright. Its writer is **not identified**: the `SetParam` sweep finds a
single write site in an unnamed function, and 180 is *not* in the tag dispatcher's writable
set, so an item magic option cannot produce it. Where it comes from is the next question.

The previous tick's negative stands unchanged and is narrower than it sounded: equipment
cannot reach params **5 or 7**. It says nothing about 180, which was not enumerated because
the formula's reads had not been fully read.


## The abnormal-state applier table

**Recovered 2026-09-18.** `GObjPC_InstallParamContributionCallbacks` (`0x004a40c0`) builds a
table of **23 function pointers** at `+0xe0c` onward, stepping by four, and every one of them
is a contribution applier: a function taking a mode byte (0 applies, 2 removes) plus a record,
which writes or clears specific ParamKeeper params.

**The table belongs to the abnormal-state (buff/debuff) system.** That is not adjacency:
`AbnormalState_UpdateOwnerClear` logs the binary's own tag
`"[ABNORMAL] update owner clear[%d:%d]"` **and indexes this very table twice**, and
`AbnormalState_PushVitalInfo` (`"[ABNORMAL] push vital info active/mask"`) indexes it too.
`AbnormalState_CompareForSlot` asserts the code at record`+5` against `0x1f`, so the type
space is **0..31**, alongside a per-object array of 32 slots of `0x1c` bytes at
`obj+0xc + code*0x1c`. The appliers were renamed from `ParamApplier_*` to
`AbnormalState_Apply*` on that evidence. What is **not** established is that every slot is an
abnormal state — the table is reached from abnormal-state code, which is weaker than the table
being exclusively theirs.

**Twenty of the twenty-three targets were functions Ghidra had never defined.** They are real
game logic that was absent from the decompiled dump entirely, which is why a call-graph search
for them found nothing and why the param writer sweep attributed their writes to `?`. They
have been created from their install sites and named `ParamApplier_Slot<NN>`, with the params
they write in the name where a write was found.

	0     +0xe0c  004a4570  UNDEFINED                -
	1     +0xe10  004a45d0  UNDEFINED                23,24,140
	2     +0xe14  004a46f0  UNDEFINED                -
	3     +0xe18  004a4850  UNDEFINED                9
	4     +0xe1c  004a4940  UNDEFINED                -
	5     +0xe20  009371f0  FUN_009371f0             -
	6     +0xe24  004a49f0  UNDEFINED                -
	7     +0xe28  004a4a50  UNDEFINED                -
	8     +0xe2c  004a4a90  UNDEFINED                23,24,140
	9     +0xe30  004a4bd0  UNDEFINED                -
	10    +0xe34  004a4c60  UNDEFINED                183
	11    +0xe38  004a4cc0  Param5And6_ApplyOrRemoveContribution 5,6
	13    +0xe40  004a4e20  UNDEFINED                11
	14    +0xe44  004a4ec0  UNDEFINED                -
	15    +0xe48  004a4f20  UNDEFINED                169
	16    +0xe4c  004a4f70  UNDEFINED                -
	17    +0xe50  004a5160  Param5_ApplyOrRemoveContribution 5
	18    +0xe54  004a5240  UNDEFINED                6
	19    +0xe58  004a5000  UNDEFINED                178,179
	20    +0xe5c  004a50b0  UNDEFINED                180,181
	21    +0xe60  004a5320  UNDEFINED                3,143
	22    +0xe64  004a54a0  UNDEFINED                4,144
	24    +0xe6c  004a5620  UNDEFINED                -

Slots 12 and 23 are not installed by this function.

The params were read at each applier's `ParamKeeper_SetParam` (id in EDI) and `0x004b3570`
(id pushed) call sites, with each body's extent **bounded by the next installed target** so a
scan cannot run past its function into the next one. Bounding changed nothing, which is the
check that the attributions were not over-scanning to begin with.

### What this settles

**Param 180's writer is slot 20** (`0x004a50b0`), paired with 181. Param 180 is the
defender-side multiplier the physical mitigation formula applies to the final damage, so this
is the applier that produces the game's real defensive multiplier — and it is reached through
the abnormal-state table, not through an item's magic options, which is why the tag dispatcher
could not produce it. **Params 178-181 are status-effect contributions**, which is the reason
no equipment path was ever going to reach them.

Slot 19 (`0x004a5000`) is its twin for params 178 and 179, the attacker-side pair the same
formula reads.

**What the slot index means is not read.** The table is indexed by something the caller
supplies; nothing here says what an index *is*, only which applier sits at it and which params
that applier touches.

## Two traps this cost

**A struct-offset sweep does not establish struct identity.** Sweeping every writer of
`+0x1a0` turned up `CGItemEquip::vslot_000` — the equipped-item class writing the exact
field that feeds param 7, alongside `+0x1a8` and the gate `+0x190`. It reads as the answer.
It is a **field-reset constructor zeroing its own object**, and `CGItemEquip` merely happens
to have fields at those offsets. Offsets collide across unrelated classes, and the base
register is the only thing that says whose struct it is.

**The decompiler prints some struct offsets in decimal.** `*(undefined4 *)(param_1 + 400)`
is `+0x190`, and `+0x1d4` appears as `+ 468`. A hex-only grep for a field silently returns
nothing, which reads as "this function does not touch that field".
