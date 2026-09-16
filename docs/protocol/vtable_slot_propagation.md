# Naming by vtable slot, and the trap in it

A systematic naming lever for the server, and the two ways it goes wrong. Read
the second half before using it.

## The lever

The server dump carries, for every function reached through a vtable:

	RTTI: reached as CGObj slot 212.
	RTTI hierarchy: CGObj : IGObj : CBase

Both lines are the binary's own — recovered by walking MSVC's
`vftable[-1] -> COL -> TypeDescriptor` chain and the COL's
`ClassHierarchyDescriptor`. **5,992 server functions carry a slot tag**, and
only **520** of those had a real leaf name.

MSVC lays a derived class's vtable out with the base's slots as a **prefix**, so
slot *N* of a base is the same method as slot *N* of any descendant. A name
known anywhere in a hierarchy therefore belongs to every class in it that has
not overridden the meaning.

**Validated before use**: run the rule against the 466 slot-functions that
already had a name and see whether it reproduces them. It does, **458/466
(98.3%)**.

Of the eight it misses, five are not misses at all — they are this project's own
descriptive renames of the engine's word (`Char_GetLevel` for `GetLevel`,
`GObjPC_GainExpAndLevel` for the engine's `OffsetExpPoint`,
`GObjPC_AddSkillPoints` for `OffsetSkillPoint`), or an override named after its
own class (`RefObjChar_ExtractData` overriding `RefObjCommon_ExtractData`).

The remaining three are the failure mode that matters, and they are worth
memorising:

	COnDead       slot 1 = QuestHandler_OnDead
	COnUpdate     slot 1 = QuestHandler_OnUpdate
	COnSetupQuest slot 1 = QuestHandler_SetupQuest

Three sibling classes overriding one slot with three semantically distinct
implementations. **Sibling agreement is not guaranteed.** Only accept a
candidate when every name the rule finds for that slot normalises to the same
method; where they disagree, the slot is a dispatch point and each override
needs its own name.

## Trap one: the slot number is not the method

Propagating by slot **number alone** offers 271 names. **209 of them are
`GetRefObjID` at slot 1**, and slot 1 on those classes holds this:

```c
undefined4 * __thiscall CBase::vslot_001(undefined4 *param_1, byte param_2) {
    *param_1 = &PTR_vslot_000_00ae0b00;
    if ((param_2 & 1) != 0) { _free(param_1); }
    return param_1;
}
```

That is the MSVC **scalar deleting destructor** — set the vptr, conditionally
free, return `this`. `GetRefObjID` is a real name for slot 1 of a *different*
hierarchy. Applying the naive rule would have named 209 destructors after an
accessor.

## Trap two: a universal base makes "shares an ancestor" vacuous

The obvious fix — require the two classes to share a base that itself has a
function at that slot — **does not work**, because `CBase` is an ancestor of
almost everything and has its own slot 1. Every pair "shares an ancestor", so
the guard passes and the destructors come straight back.

The fix that works: ignore ancestors that are too generic to establish identity.
Ancestors of more than a fifth of all 747 classes are excluded —

	CBase, CDBRecord, CQuestBase, CBasicQuest, IQuest

— which drops the offer from 271 to 69 while leaving ground-truth agreement
unchanged at 98.3%.

## Trap three: a name is not the same as the method's name

Several recovered names carry the class they were found on:
`CGEventDaemon__Create`, `CTJ_OpenMarketTicketKeeper__Create`,
`CGItemEquip__DoJob`, `RefObjChar_ExtractData`. Propagating those verbatim would
name `RefObjItem`'s parser `RefObjChar_ExtractData`. Strip the class prefix and
propagate the **method**: `ExtractData`, `Create`, `DoJob`.

## Read the bodies anyway

After all three fixes, 69 candidates remained and **14 were still wrong**:

| offered | x | why rejected |
|---|---|---|
| `GetRefObjID` | 7 | still destructors — `_free(this-4)`, `_eh_vector_destructor_iterator_` |
| `Assert_BreakIfDebugger` | 6 | a global helper's name leaking through a mislabelled function |
| `TerminateMenu` | 1 | a bare thunk; nothing to corroborate |

The 53 accepted each had structural corroboration in the body — an override
chaining to its base (`CGObjMobile::vslot_212` is literally
`return CGObj::vslot_212(...)`), or a body doing the named work
(`RefObjStruct::vslot_001` calls `RefObjCommon_ExtractData` and continues).

## What was applied

53 names, 2026-09-16, in `docs/protocol/recovered_names.tsv`:

| method | x | slot |
|---|---|---|
| `Create` | 23 | 212 (game objects), 3 (`CTimedJob` family) |
| `Update` | 11 | 211 — takes a float delta and accumulates at `this+0x3c` |
| `OnTimeout` | 4 | 1, on the `trs_*` transaction classes |
| `DoJob` | 4 | 306 — `CGItem`'s own is `Assert; return 2`, a default |
| `CreateWorld` | 4 | 13, on the `CGameWorld_*` family |
| `PublishStats` | 2 | 346 |
| `ExtractData` | 2 | 1 — `RefObjItem` and `RefObjStruct`, the per-table parsers |
| `GetWorldLayerEventHandlers` | 1 | 182 |
| `PostTempleReputationSetReq` / `CheckReq` | 2 | 201, 202 |

`ExtractData` on `RefObjItem` and `RefObjStruct` is the one that matters most
here: those are the siblings of `RefObjChar_ExtractData`, the table parsers this
project has been reading columns out of all week.

## Re-running it

The rule is in the tick log rather than a committed script, because it should be
re-derived and re-validated against ground truth each time rather than trusted:
the agreement number is the thing that says whether it is safe, and it changes
as names are added. Apply results with
`client/tools/ghidra/ApplyRecoveredNames.java`, which needs a **non-`-readOnly`**
`analyzeHeadless` run — the dump tick uses `-readOnly` and can never write a
name back.
