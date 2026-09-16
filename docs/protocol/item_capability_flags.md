# The item capability flags

Recovered 2026-09-16. The engine decides whether an item may be traded, sold,
dropped, used and so on from **one flags word on the item's reference row**, at
offset `+0x8c` — reached by the `item[0xd] + 0x18` chain used throughout the
server for an object's ref row.

srrevamp models **none** of this yet, and cannot until the columns are found
(see the last section). It is written down because the bit map is settled and
the column hunt is not, and those are different states.

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
| 2 | *unaccounted* | no reader found |
| 3 | `CanBorrow` | `0x00483db0` |
| 4 | `CanDrop` | `0x00483de0` |
| 5 | `CanPick` | `0x00483e50` |
| 6 | `CanRepair` | `0x00483e80` (also `CGObjSiegeStruct::CanRepair`, `0x004cecd0`) |
| 7 | `CanRevive` | `0x00483eb0` (also `CGObjSiegeStruct::CanRevive`, `0x004cecf0`) |
| 8 | `CanUse` | `0x00483ee0` |
| 9 | `CanThrow` | `0x00483f10` |
| 10 | *unnamed* | `GObjPC::FUN_00483f40` — a tenth predicate, same shape, no stub to name it |

**Zero means refuse.** `CanTrade` returning 0 produces `CANNOT_BE_TRADED`, so a
set bit is permission, not prohibition.

Two sibling refusals confirm the family is really used this way:
`0x183b UIIT_MSG_STRGERR_CANNOT_DEAL_AT_SHOP` is raised by `GObjPC::FUN_006182a0`
when `vslot(200)` — 200 decimal is `0xc8`, slot 50, `CanSell` — returns zero.

`0x1838 UIIT_MSG_STRGERR_CANNOT_BE_DROPPED` is **not** one of these: its guard
(`0x004b2ab0`) is a TID lookup through `FUN_0042e750`, a different mechanism
despite the matching name.

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

That arithmetic is a tool for the whole `_RefObjCommon` prefix, not just these
flags.

## What is STILL not established: which columns the flags are

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
