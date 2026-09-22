# The item capability flags

Recovered 2026-09-16. The engine decides whether an item may be traded, sold,
dropped, used and so on from **one flags word on the item's reference row**, at
offset `+0x8c` — reached by the `item[0xd] + 0x18` chain used throughout the
server for an object's ref row.

**STALE HEADER, CORRECTED ROUND 460.** This used to read "srrevamp models none
of this yet, and cannot until the columns are found". Both halves were wrong by
then: `server/internal/refdata/item.go` already carries `CanTrade`, `CanSell`
and `CanDrop` with their itemdata columns (**16, 17, 20**), and `shop.Sell`
already refuses on `CanSell`. The answer had reached the code and never reached
this file — and round 459 believed the header, concluded "the column hunt stays
open", and went looking for something already found.

## How it was found

`CGStorage`'s trade-offer handler (`0x00526910`) refuses with `0x183a
UIIT_MSG_STRGERR_CANNOT_BE_TRADED` when a virtual returns zero:

```c
iVar3 = (**(code **)(*piVar2 + 0xc4))();
if (iVar3 == 0) return 0x183a;
```

`0xc4` is vtable slot 49, and the base class implements it as an `## Illegal ##`
stub that names itself — the project's strongest naming lever:

```c
IGObj::CanTrade:  "## Illegal ##  IGObj::CanTrade Entered! TypeID: %u"
```

There are **nine** such stubs, consecutive in memory 0x30 apart:

```
0057de80 IGObj::CanTrade    0057df40 IGObj::CanPick     0057dfd0 IGObj::CanUse
0057deb0 IGObj::CanSell     0057df70 IGObj::CanRepair   0057e000 IGObj::CanThrow
0057dee0 IGObj::CanBorrow   0057dfa0 IGObj::CanRevive
0057df10 IGObj::CanDrop
```

## The bit map

Every row below is an **engine-named method reading a specific bit** — a name
and a use-site, not an inference. `CGObjCOS_Summoned` implements the whole
family and each override is two lines.

| bit | predicate | implementation |
|---:|---|---|
| 0 | `CanTrade` | `0x00483d50`, `flags & 1` |
| 1 | `CanSell` | `0x00483d80`, `flags >> 1 & 1` |
| 2 | **dead** | no reader **and no writer** — see below |
| 3 | `CanBorrow` | `0x00483db0` — **always answers 0**: nothing writes bit 3, see below |
| 4 | `CanDrop` | `0x00483de0` |
| 5 | `CanPick` | `0x00483e50` |
| 6 | `CanRepair` | `0x00483e80` (also `CGObjSiegeStruct::CanRepair`, `0x004cecd0`) |
| 7 | `CanRevive` | `0x00483eb0` (also `CGObjSiegeStruct::CanRevive`, `0x004cecf0`) |
| 8 | `CanUse` | `0x00483ee0` |
| 9 | `CanThrow` | `0x00483f10` |
| 10 | *unnamed* | `GObjPC::FUN_00483f40` — a tenth predicate, same shape, no stub to name it |
| 11 | *unnamed* | `GObjPC::FUN_00483f70` (round 459) |
| 12 | *unnamed* | `GObjPC::FUN_00483fa0` (round 459) |
| 13 | *unnamed* | `GObjPC::FUN_00483fd0` (round 459) |
| 14 | *unnamed* | `GObjPC::FUN_00483e10` (round 459) |

**Bits 11–14 have readers too**, found by censusing every function whose body
reads `refobj + 0x8c` as `>> N & 1`. The table above stopped at 10 because the
nine `## Illegal ##` stubs stop at 9 and bit 10 was reached another way; these
four are the same one-line shape and, like bit 10, **have no stub, so the engine
offers no name for them and none is invented here**.

**Zero means refuse.** `CanTrade` returning 0 produces `CANNOT_BE_TRADED`, so a
set bit is permission, not prohibition.

Two sibling refusals confirm the family is really used this way:
`0x183b UIIT_MSG_STRGERR_CANNOT_DEAL_AT_SHOP` is raised by `GObjPC::FUN_006182a0`
when `vslot(200)` — 200 decimal is `0xc8`, slot 50, `CanSell` — returns zero.

`0x1838 UIIT_MSG_STRGERR_CANNOT_BE_DROPPED` is **not** one of these: its guard
(`0x004b2ab0`) is a TID lookup through `FUN_0042e750`, a different mechanism
despite the matching name.

## Every writer of the flags word, enumerated

Five instructions in the **whole binary** write it, and they are all in the two
row parsers:

	6a351b  mov [esi+0x8c],ecx      RefObjCommon_ExtractData   bits 0, 1
	6a3529  mov [esi+0x8c],ecx      RefObjCommon_ExtractData   the same, | bit 12
	6a3536  or  [esi+0x8c],0x2000   RefObjCommon_ExtractData   bit 13
	6a3595  or  [esi+0x8c],edx      RefObjCommon_ExtractData   bits 4,5,6,7,8,9,14
	6a5cb4  or  [edi+0x8c],eax      RefObjChar_ExtractData     bits 10, 11

Found by scanning every `or`/`mov`/`and`/`xor` into `[reg+0x8c]` across the
disassembly, then keeping the ones whose enclosing function is a row parser.
`RefObjItem`'s own extract touches `[esp+0x8c]` — the stack — and never the row.

### Bits 10 and 11: characterdata columns 67 and 68

Recovered 2026-09-16 by the same column arithmetic, applied to
`RefObjChar_ExtractData` and anchored twice: its reads land `+0x198` on
**column 57** (Level) and `+0x19c` on **column 59** (MaxHP), both already
established. A real characterdata confirms the anchors — column 57 holds 1/2/3
for pets, 95 for a monster, 100 for an NPC, and column 59 holds 360/441/524 and
6,000,000 for a boss, with player rows reading MaxHP 0 exactly as the
starting-stat audit found.

	bit 10  <- characterdata column 67
	bit 11  <- characterdata column 68   (always 0 in a real table)

**Column 67 splits the COS families perfectly, with no exceptions either way:**

| COS family | rows | column 67 |
|---|---:|---|
| `COS_P` (pets) | 9,826 | all 1 |
| `COS_C` | 124 | all 1 |
| `COS_T` (transports) | 94 | all 1 |
| `COS_GUILD` | 3,514 | all 0 |
| `COS_GUARD` | 3,079 | all 0 |

Set on every player-ownable COS and clear on every guild soldier and guard.
Monsters, NPCs and players are all 0 (2 of 646 NPC rows excepted).

**The predicate is NOT named here.** Bit 10's reader is
`GObjPC::FUN_00483f40`, the tenth entry in the `CGObjCOS_Summoned` block, and
unlike the nine above it **has no `## Illegal ##` stub** — so the engine offers
no word for it. A clean split between ownable and non-ownable COS is a strong
description of what the flag separates; it is not the engine's name for what the
flag *permits*, and this file does not invent one.

**So bits 10 and 11 exist only on CHARACTER rows.** `RefObjChar_ExtractData`
contributes them from two of its own columns; an item can never have them. Bit 10
is the tenth capability predicate (`GObjPC::FUN_00483f40`), which is therefore a
question only a character can answer yes to.

**And bits 2 and 3 are never written at all.** That is not "no writer found in the
places I looked" — it is every write instruction in the binary, enumerated. Two
consequences:

- **`CanBorrow` always returns 0.** Nothing in the game is borrowable, for any
  object type. The predicate exists, has a stub, has an implementation, and is
  answered "no" by construction.
- **Bit 2 is dead**: no writer and no reader. A gap in the numbering rather than a
  flag this project has failed to identify.

If srrevamp ever models borrowing, the grounded answer is *false for everything*,
and that is the engine's answer rather than an omission here.

## How the flags word is built

`RefObjCommon_ExtractData` (`0x006a3090`) assembles it from separate boolean
fields as it parses the row:

```c
uVar5 = -(uint)(local_9e != 0) & 2 | (uint)(local_b3 != 0);      // bits 1, 0
flags = uVar5;
if (local_b2 & 0x80) flags |= 0x1000;
if (local_b2 & 0x40) flags |= 0x2000;
flags |= ((local_b1 & 2) << 9 | local_b1 & 1) << 4               // bits 14, 4
       | -(uint)(cVar2 != 0) & 0x200 | -(uint)(cVar1 != 0) & 0x100
       | -(uint)(local_9f != 0) & 0x80 | -(uint)(local_9d != 0) & 0x40
       | -(uint)(local_a1 != 0) & 0x20;
```

So `CanTrade`, `CanSell`, `CanPick`, `CanRepair`, `CanRevive`, `CanUse` and
`CanThrow` are seven separate boolean columns, and bits 12/13/14 come from
elsewhere in the row.

## The field order, recovered from the disassembly

The decompiled C could not give this — its reads take several shapes and a regex
over them captured 11 of the parser's fields. **The disassembly can**: every
field read is a `mov` through indexed addressing `[cursor + base*1]`, followed by
a field-counter increment and a cursor advance of the field's own width. That
finds **41** reads.

Binding each read to the stack slot it stores into, and each slot to the bit the
flags expression takes it from, gives an exact chain — read → slot → bit →
predicate:

| read # | stack slot | bit | predicate |
|---:|---|---:|---|
| 11 | `esp+0x11` | 0 | `CanTrade` |
| 12 | `esp+0x26` | 1 | `CanSell` |
| 13 | `esp+0x12` | 12 and 13 | two further flags, unnamed |
| 14 | `esp+0x13` | 4 (and 14) | `CanDrop` |
| 15 | `esp+0x23` | 5 | `CanPick` |
| 16 | `esp+0x27` | 6 | `CanRepair` |
| 17 | `esp+0x25` | 7 | `CanRevive` |
| 18 | `bl` | 8 | `CanUse` |
| 19 | `al` | 9 | `CanThrow` |

**Nine consecutive reads immediately before the flags word is assembled**, in the
same order as the nine stubs. `CanBorrow` (bit 3) is not among them and is set
somewhere else in the parser.

## The read-to-column arithmetic, now established

Two helpers consume a field without an inline indexed read, which is why the
read count lags the column count:

- `FUN_006b2ef0` reads a **length-prefixed string** (a 2-byte length, then that
  many bytes) — one call per string column;
- `FUN_006b1a80` ends with `param_1[10] = param_1[10] + 1`, which is the field
  counter at `+0x28` — so it consumes a column too.

Between read 1 and read 2 there are four `FUN_006b2ef0` calls and one
`FUN_006b1a80`: **five consumed columns**. So

	READ0 -> column 0      READ1 -> column 1      READn -> column n+5  (n >= 2)

**Confirmed three ways, none of them the one that produced it:**

| check | result |
|---|---|
| a real row's columns 2..6 | exactly five strings — code name, display name, `xxx`, `SN_…`, `SN_…_TT_DESC` |
| READ4..READ7 -> columns 9..12 | TypeID1..4, already known; a sword reads 3/1/6/2 and a garment mail 3/1/1/3 |
| READ9 -> column 14 | Country, already known; a sword reads 0 (China), a MALL item 3 (either) |

That arithmetic is a tool for the whole `_RefObjCommon` prefix — **but only as
far as column 51.** See "The rule's end", below: a five-iteration string loop
sits at columns 52..56, and past it `READn -> n+5` lands five columns short.

## Counting columns properly: the counter, not the reads

Pattern-matching field reads is the wrong instrument. The engine keeps its own
column index in the stream at `+0x28` and bumps it once per column, so
**counting `add DWORD PTR [reg+0x28]` plus the two helper calls** counts columns
directly — and it catches read forms a regex over addressing modes misses (42
increments against 41 matched reads).

**It also has to account for loops, and this parser has one.** `0x6a36ab..0x6a3700`
runs **four** times (`mov eax,0x4`, decremented per iteration) and consumes **two
columns per iteration** — a dword then a byte, written at `row+0xb4` and
`row+0xb8` with a stride of 8. Static counting sees two columns where the engine
consumes eight.

That loop is identifiable: four `(dword, byte)` pairs is exactly the shape of the
**four `(ReqLevelType, ReqLevel)` requirement pairs**, which `ITEM_FORMAT.md`
documents at **columns 32..39** from the data side. And the counter says the loop
begins at column **32** and ends at **39**.

That is a third anchor for the column arithmetic, independent of the two that
established it (the five-column string prefix, and Country at column 14), and the
first one *after* the capability block.

### The residual, stated

Accounting reaches **54** columns for `_RefObjCommon`; the `RefObjChar` anchors
(Level at 57, MaxHP at 59) require **56**. Two consumers are still in a form the
counter scan does not see, so columns past 39 are not safe to derive yet. The
capability columns at 16..24 are unaffected, being long before the loop.

**Not the explanation:** the nine calls after the capability block that the
previous pass suspected. Four are CRT (`_free`, `_atol`, `__stricmp`,
`__security_check_cookie`) and the other six touch neither the cursor at `+0x1c`
nor the counter at `+0x28`. None consumes a column.

## The columns, confirmed against real data

Applying the arithmetic to the nine capability reads gives:

| column | flag bit | predicate | shape in real itemdata |
|---:|---:|---|---|
| 16 | 0 | `CanTrade` | 0/1 |
| 17 | 1 | `CanSell` | 0/1 |
| 18 | 12, 13 | two unnamed (tested `& 0x80`, `& 0x40`) | 0/1 |
| 19 | 4 (and 14) | `CanDrop` — **a bitmask, not a boolean**: the parser takes `& 1` and `& 2` | 255, 128, 223, 192, 0 |
| 20 | 5 | `CanPick` | 0/3/1 |
| 21 | 6 | `CanRepair` | 0/1 |
| 22 | 7 | `CanRevive` | 0/1 |
| 23 | 8 | `CanUse` | 0/1 |
| 24 | 9 | `CanThrow` | 0/1 |

Column 19 is the tell that the mapping is right rather than merely plausible: the
flags expression extracts **two separate bits** from that slot
(`((b & 2) << 9 | b & 1) << 4`), and column 19 is the one column in the block
that holds 255/128/223/192 instead of 0/1. A boolean column would not need
masking, and a masked column that happened to be boolean would be a coincidence.

**Verified by class, and this is what settles it:**

| group | `CanTrade` | drop mask |
|---|---|---|
| ordinary swords (136 of 160) | **1** | 255 |
| starter items, `_A_DEF` (all 52) | **0** | 0 |
| quest items, `ITEM_QNO_` (all 558) | **0** | 0 |
| cash shop, `ITEM_MALL_` (247 of 267) | 1 | 255 |

Starter gear and quest items are bound; ordinary and cash-shop items are not.
That is the real game's behaviour, predicted by the mapping rather than fitted to
it.

### The wrong exemplar that nearly sank this

The previous tick rejected this same mapping because `ITEM_CH_SWORD_01_A_DEF`
reads `CanTrade = 0` and "a sword is plainly tradeable". **The `_A_DEF` suffix is
the starter row** — the one class of sword that is bound — so the exemplar was
the fault, not the model. Choosing a representative item badly is as good a way
to get a wrong answer as choosing a bad probe.

What did survive that tick, correctly, was the refusal to publish on the strength
of an argument; the thing that resolved it was a distribution over classes rather
than one row.

### Earlier probes that failed, kept

Applying the arithmetic to the nine capability reads gives columns 16..24 — and
**the data contradicts it**. `ITEM_CH_SWORD_01_A_DEF` would read
`CanTrade = 0, CanDrop = 0, CanRepair = 0`, and a sword is plainly all three.
`ITEM_ETC_GOLD_01` would read `CanDrop = 255`, which is not a boolean at all.

Since the arithmetic is anchored three times, the fault is in the **read → slot →
bit** binding rather than in the column numbers. The likely cause is visible in
the extraction: **slots `esp+0x11` and `esp+0x12` are each written twice**, once
by reads 2 and 3 and again by reads 11 and 13, and the heuristic that paired a
read with "the next store within a few instructions" cannot tell which write is
live at the flags expression. There is no branch between the two groups, so both
execute — which makes the question real rather than academic.

Re-deriving that binding wants the store for each slot tracked to the last write
before `0x6a34e6`, not the first write after each read.

### Earlier probes that failed, kept

The read order is not the column order, and there is a clean anchor proving it.

**Read 9 writes row `+0x88`.** `CanBeEquipedAt` reads `+0x88` as the item's
Country — refusing with `0x182f COUNTRY_MISMATCH` unless it is 3 — and
`ITEM_FORMAT.md` pins Country to **itemdata column 14**. So read 9 is column 14:
a gap of five at that point.

The cause is visible in the pattern: **string columns are consumed by a helper
call, not by an inline indexed `mov`**, so they never increment this count. The
gap is therefore not a constant to add — it grows by one for every string column
passed, and `_RefObjCommon` has several near the front (code name, object name,
the two string ids).

Closing this needs the string-consuming calls counted alongside the inline reads,
so that every column is accounted for. Until then the bits are known, their order
is known, and their columns are not.

#### Two of them

**A partial extraction that looked complete.** A regex over the decompiled reads
captured 11 of the parser's fields and produced indices 2, 3, 4… — positions
within that subset, which look exactly like column numbers. Promoting them would
have invented seven columns.

**A shape prediction that failed cleanly.** If seven of these were consecutive
boolean columns, itemdata should hold a run of seven columns containing only 0
or 1. There is exactly one — columns 41..47 — and `ITEM_CH_SWORD_01_A_DEF` reads
**0 across all seven**. A sword must be tradeable and a set bit is permission, so
that run is not the flags. A discriminator search (sword 1, quest item 0) gave
17, 22, 23, 26, 33 — scattered, no run of seven.

## The rule's end: the prefix is 58 columns, not 56 (2026-09-16)

The "counting columns properly" instrument above is the right one, and it was
still undercounting, because it counted **call sites rather than executions**.
Two loops sit inside `RefObjCommon_ExtractData` and each site inside one runs
more than once:

| loop | address | trips | per trip | columns |
|---|---|---|---|---|
| requirement pairs | `6a36ab..6a3700` | 4 (`mov eax,0x4` at `6a3690`) | a 4-byte field + a 1-byte field | 32..39 |
| asset paths | `6a3a30..6a3a45` | 5 (`mov [esp+0x28],0x5` at `6a3a1f`) | one `RefData_ReadStringField` | 52..56 |

The second was the one that hid: its single `call 0x6b2ef0` at `6a3a36` counts
as one string column when it is five. That `[esp+0x28]` is the loop's own trip
counter on the stack, unrelated to the stream's column counter at `[edi+0x28]`
— which is exactly why an earlier pass dismissed it as "stack, not the stream"
and moved on. Both readings of `+0x28` were correct; only one of them was the
relevant one.

Expanded, and with every increment register pinned to a literal 1 (`ebx` at
`6a30f0`, `esi` at `6a34c1` and `6a388d`, a `mov ecx,0x1` before each `ecx`
bump, one literal at `6a3bc5`):

	42 inline bumps + 4 standalone string calls + 5 in-loop string calls
	+ 1 FUN_006b1a80 + loop 1 expanded 4x  =  58 columns, 0..57

**`RefObjCommon_ExtractData` consumes columns 0..57.** There were never two
missing columns; the count was two short of a row width that was itself wrong.
A real client's itemdata rows have **160** columns and characterdata **104** —
56 was never either table's width, it was a mis-measured prefix.

Four independent anchors land exactly on the expanded map, none of them the
thing that produced it:

| anchor | lands on |
|---|---|
| `export-refdata`'s `fID = 1` | col 1, a 4-byte store at `+0x8` |
| `fCountry = 14` | col 14, a 1-byte store at `+0x88` |
| `fMaxStack = 57` | col 57, the last column, a 4-byte store at `+0x184` |
| the four requirement pairs | cols 32..39, the 4x loop's (4-byte, 1-byte) pairs |

### Columns 52..56, the block that was invisible

Five `std::string`s at `_RefObjCommon+0xf4`, stride `0x1c`. Read from real rows
in both tables:

| col | itemdata | characterdata |
|---|---|---|
| 52 | worn/world model `.bsr` | model `.bsr` (`mob\europe\movoi.bsr`) |
| 53 | ground-drop model `.bsr` (48 distinct, e.g. `item\etc\drop_ch_equip.bsr`) | always `xxx` |
| 54 | inventory icon `.ddj` (3,616 distinct) | icon `.ddj` for COS/pet rows |
| 55 | `xxx`, with a handful of `GP:5000` | `xxx`, plus `FORTRESS_*` on 9 rows |
| 56 | always `xxx` | always `xxx` |

These are paths into the user's own archives, not data this repo carries.

### Why the rule broke where it did

`READn -> col n+5` holds while the inline reads are contiguous, which is true
from column 7 through column 51. The five-string block then consumes 52..56
without an inline read, so the *next* inline read is column **57**, not 52.
Anything applying `n+5` past that point is five columns low. srrevamp's own
column constants are raw indices rather than derived through the rule, so none
of them were wrong — but the rule as written would have produced wrong ones.

## Column 55 is a tagged string: `"GP:<n>"` (2026-09-16)

Column 55 is the 4th of the five `std::string`s at `+0xf4` stride `0x1c`, i.e.
`_RefObjCommon+0x148`. The parser does not store it and move on -- it **scans
it for a tag** and parses a number out, into the adjacent field `+0x180`:

	+0x180 = 0                                     6a3a4e
	s = this+0x148                                 6a3a9e   (column 55)
	if (strcmp(s, "xxx") == 0) goto skip           6a3add / 6a3ae7
	pos = s.find("GP:")                            6a3b0f
	if (pos == npos) goto skip                     6a3b17
	+0x180 = atoi(s.substr(pos + 3))               6a3b31 / 6a3b94
	skip:                                          6a3ba2

Both literals are the binary's own: `0xb090cc` = `"GP:"` (pushed with length 3
at `6a3a71`), `0xae8110` = `"xxx"`, the table's null placeholder.

The real values agree exactly. Across 23,327 enabled itemdata rows column 55
has **five** distinct values:

| value | rows |
|---|---|
| `xxx` | 23,298 |
| `GP:5000` | 24 |
| `GP:20000` | 2 |
| `GP:30000` | 2 |
| `GP:1000` | 1 |

Characterdata uses the same column for a different tag -- `FORTRESS_SAMARKAND`,
`FORTRESS_CONSTANTINOPLE` and seven more, on 37 rows of 13,291 -- which the
`"GP:"` search simply does not match, leaving `+0x180` at 0. One column, a
tagged vocabulary, and the common parser only understands the one tag.

This closes one of the columns that opened up when the prefix turned out to be
58 wide rather than 56.

### The 58-column walk re-verified

The walk assumed every consuming site executes once. That was checked for loops
but never for **branches**, so it has now been tested directly: of 81 forward
jumps inside `RefObjCommon::ExtractData`, exactly **one** skips a consuming site
-- `6a3104 jmp 0x6a3c70`, the early return taken when column 0 (service) is
zero. No conditional skips anything on the success path, so the linear walk and
its 58 columns stand.

### `RefObjCommon::ExtractData` is a `__thiscall`, and the dump's signature is wrong

`6a30dc mov DWORD PTR [esp+0x14],ecx` stashes `this`; `edi` is the stream from
`[ebp+8]`. Ghidra dropped the `ecx` parameter, the same failure as
`Stat_ApplyTaggedModifier`'s EDI argument -- the decompiled signature reads
`(param_1, param_2)` where the truth is `(this, stream)`.

`RefObjItem` and `RefObjChar` pass **their own `this`**:

	6a3d93  mov ebx,ecx      6a3d9a  mov ecx,ebx      6a3da0  call 0x6a3090
	6a58ff  mov edi,ecx      6a5906  mov ecx,edi      6a5908  call 0x6a3090

So they do not own a separate common record -- they **are** one, by
inheritance, which is why `6a3da5 cmp BYTE PTR [ebx+0x88],0x2` reads Country
(column 14) straight off `this` after the call.



## How the flags word is assembled, field by field (round 459)

The writers were enumerated in 2026-09-16 as five instructions. This is what
they actually compute, read out of `RefObjCommon_ExtractData`:

	flags  =  (sell  != 0) << 1  |  (trade != 0)
	if (packed & 0x80)  flags |= 1 << 12
	if (packed & 0x40)  flags |= 1 << 13
	flags |= ((dropf & 2) << 9 | dropf & 1) << 4     // bit 4 and bit 14
	       |  (throw  != 0) << 9
	       |  (use    != 0) << 8
	       |  (revive != 0) << 7
	       |  (repair != 0) << 6
	       |  (pick   != 0) << 5

So each named predicate has **its own source field** — except three that share:

- **bits 12 and 13 come from ONE field**, tested as `& 0x80` and `& 0x40`. That
  field is a bit-packed value, not a boolean.
- **bit 14 shares a field with `CanDrop`** — bit 0 of it is `CanDrop`, bit 1 is
  bit 14.

**And `CanDrop` is forced off when `CanTrade` is off.** Immediately before the
word is built:

	if (trade == 0 && dropf == 1) dropf = 0;

which is a real rule, not a parse artifact: an untradeable item is also
undroppable even when its own column says otherwise.

### The columns, anchored against real data (round 460)

Round 459 could not give column numbers because counting the parser's field
reads disagreed with the grounded anchors by nine. That was the right caution
and the wrong method: **read index is not file column index**. Anchoring against
a real table instead settles the whole run.

**The alignment is fixed by the two PACKED columns, not by counting.** The parse
needs one field tested `& 0x80`/`& 0x40` (bits 12, 13) and one tested
`& 1`/`& 2` (bit 4 `CanDrop`, and bit 14), adjacent and in that order. A real
itemdata has exactly one such adjacent pair in the region — column **19** reads
`0/128/223/255` and column **20** reads `0/1/3`, where every neighbour is a
plain `0/1`. That pins the run:

| flags bit | predicate | itemdata / characterdata column |
|---:|---|---:|
| 0 | `CanTrade` | **16** |
| 1 | `CanSell` | **17** |
| — | read, but feeds no bit of this word | 18 |
| 12 and 13 | *unnamed* — one packed column, `& 0x80` and `& 0x40` | **19** |
| 4 and 14 | `CanDrop` (bit 0) and bit 14 (bit 1) | **20** |
| 5 | `CanPick` | **21** |
| 6 | `CanRepair` | **22** |
| 7 | `CanRevive` | **23** |
| 8 | `CanUse` | **24** |
| 9 | `CanThrow` | **25** |

**Two of them are confirmed by MEANING, not position** — the check that would
fail if the run were shifted:

- **column 22 (`CanRepair`)**: `1` on **676 of 676** armour rows and `0` on
  **1,339 of 1,339** potions/etc. A potion cannot be repaired; armour can.
- **column 24 (`CanUse`)**: the exact inverse — `0` on all 676 armour rows,
  non-zero only among consumables. Armour is equipped, not used.

A shifted mapping cannot produce both splits at once.

### `CanRepair` is measured redundant for srrevamp, and deliberately not wired

The obvious wiring is to refuse repair when bit 6 is clear. **Measured across
three itemdata parts — 3,879 rows — column 22's set is *exactly* the non-zero
set of the repair-cost columns 27/28, with no exception in any file.**
srrevamp's `RepairHandler` already skips items with `DurabilityMax <= 0`, so the
flag would change no behaviour. Recorded rather than implemented.

**`CanRevive` is not the same flag**, despite tracking `CanRepair` closely:
column 23 matches column 22 exactly in two of the three parts and diverges in
the third, so they are distinct and only coincide for ordinary equipment.

### Why round 459 gave no file column numbers

The obvious next step is to turn those fields into `itemdata`/`characterdata`
column numbers. **A control says the arithmetic for that does not hold, so no
column numbers are claimed.**

Walking `RefObjCommon_ExtractData` while tracking the parser's own column
counter (`cursor + 0x28`, incremented once per field) yields **47 columns with 5
strings — exactly the signature `refdata_tables.md` records independently**, so
the walk itself is sound. But feeding that 47 into the same walk of
`RefObjChar_ExtractData` puts the `+0x198` field at **column 48**, and `+0x198`
is Level, **grounded as characterdata column 57**. Off by nine.

The explanation is already in `refdata_tables.md`'s own caveat — *"the client's
textdata files carry more columns than the server reads"*. **The parser's read
index is not the file's column index**, the offset is not a constant, and the
bits-10/11 recovery above got its column numbers by anchoring against a real
characterdata table rather than by counting reads. Until that anchoring is
redone for the common prefix, the fields above are identified by *what they
feed*, not by where they sit in a file.
