# Named limits the engine asserts about itself

`SR_GameServer.exe` ships with its asserts intact. Each one calls

	CGameServer::FUN_00964760(line, "<source path>", "<the expression>")

and the **third argument is the assert's source text**, so the engine states its
own invariants in its own words — variable names, member names and `MAX_*`
constants included.

**There are only 49 distinct expressions, across 19 source files**, so this is a
small lever. It is a sharp one: where an expression names a `MAX_*` constant,
the compiled comparison right above the assert gives its **value**.

## The three constants recovered this way

| constant | value | the assert, and the instruction that fixes it |
|---|---:|---|
| `MAX_MAGPARAM_PER_ITEM` | **12** | `"m_InstanceInfoOfItem.m_btMagParamNum < MAX_MAGPARAM_PER_ITEM"` (ReferenceData.cpp 3011) → `cmp BYTE PTR [esi+0x24],0xc ; jb` |
| `MAX_ITEM_PER_SHOP_TAB` | **240** | `"0 <= pGoods->m_btSlotIndex && pGoods->m_btSlotIndex < MAX_ITEM_PER_SHOP_TAB"` (ReferenceData.h 1809) → `cmp BYTE PTR [esi+0x48],0xf0 ; jb` |
| `MAX_LOCALOBJID_BITS` | **21** | `"m_GID._LocalID < ::pow((double)2, MAX_LOCALOBJID_BITS)"` (GObj.cpp 382) → see below |

### `MAX_LOCALOBJID_BITS` is confirmed twice in one function

`CGObj::Create` computes `pow(2, N)` inline, by square-and-multiply, and the
exponent is a literal:

	484c3f  mov eax,0x15              ; N = 21
	484c44  fld QWORD PTR ds:0xb45f30 ; 2.0
	484c4a  fld1
	484c4c  test al,0x1 / fmul / shr eax,1 / loop
	...
	484c61  and ecx,0x1fffff          ; the local id, masked to 21 bits

so the exponent says 21 and the mask says 21, independently, eight instructions
apart. **A live object's local id is a 21-bit field** — a cap of 2,097,152
concurrent objects in a shard.

### The `0 <= x` that is not there

`MAX_ITEM_PER_SHOP_TAB`'s assert has two clauses and compiles to **one**
comparison, because `m_btSlotIndex` is a byte (`bt`) and `0 <= x` is vacuous for
an unsigned one. Reading the instruction alone would under-report what the
engine checks; reading the assert text alone would over-report what it compiles
to. Both together are what makes the reading safe.

Note also what the constant bounds: the **slot index**, not a tab's item count.
Real shop tables are far sparser than 240.

## Field offsets that came with them

| offset | on | name, in the engine's words |
|---|---|---|
| `+0x24` | the item's instance-info struct | `m_btMagParamNum` |
| `+0x48` | a shop goods record | `m_btSlotIndex` |
| `+0x08` | `CGObj` | `m_GID`, whose `_LocalID` is the low 21 bits |

`m_btMagParamNum`'s persisted counterpart is the `_ITEMS` column `MagParamNum`,
beside `MagParam` (`docs/protocol/db_columns.md`) — the same quantity, stored.

## Where they are, and are not, in srrevamp

`combat.MaxMagicOptionsPerItem` and `shop.MaxItemsPerShopTab` carry the two that
have a home, each with the citation and a test pinning it to the literal.

**Neither is enforced anywhere yet**, and both say so: srrevamp has the
magic-option tag vocabulary but no per-item option list to cap, and no shop-tab
model at all. `MAX_LOCALOBJID_BITS` has no home at all — srrevamp allocates no
live object ids — so it is recorded here only.

That is the honest shape of this recovery: three engine facts, two of them
parked where they will be needed, none of them changing a number srrevamp
computes today.

## The rest of the 49

Sixteen name no constant but do name members, which is the other half of the
lever's value — `m_dwAvailableOPs` (the item capability flags, confirming
`docs/protocol/item_capability_flags.md`'s reading), `m_dwLink` (the
common-record link `refobj_binary_format.md` recovered), `m_btItemClass`,
`m_Basic_Code`, `m_strCodeName`, `m_sDungeonInfo`, `m_sObjExtInfo` and more.

`ReferenceData.cpp` alone carries 22 of the 49, which is consistent with it
being the most defensively written file in the server — and is why the reference
tables have been the most tractable part of this project.
