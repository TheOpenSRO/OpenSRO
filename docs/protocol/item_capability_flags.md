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

## What is NOT established: which columns they are

Two probes failed, and both failures are worth keeping.

**The parser's field order was extracted only partially.** A regex over the
decompiled reads captured 11 of the parser's fields where it has many more, and
the indices it produced (2, 3, 4, …) are positions *within that subset*, not
column numbers. They look exactly like column numbers, which is the danger.

**A shape prediction failed cleanly.** If seven of these are consecutive boolean
columns, itemdata should contain a run of seven columns holding only 0 or 1.
There is exactly one such run — columns 41..47 — and `ITEM_CH_SWORD_01_A_DEF`
reads **0 across all seven**. A plain sword must be tradeable, and a set bit is
permission, so that run cannot be the flags.

**A discriminator search found no run either.** Columns where a sword reads 1 and
a quest item reads 0 are 17, 22, 23, 26 and 33 — scattered, no run of seven. That
is not conclusive on its own (a quest item may still be repairable or usable, so
not every flag need differ between the pair) but it does not support the reading.

Until the parser's full field order is recovered, the columns are unknown and
nothing here is wired into srrevamp.
