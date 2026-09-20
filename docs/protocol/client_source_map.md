# The client names its own files, and a good many of its members

Recovered 2026-09-20 (round 279). The table is
`docs/protocol/client_translation_units.tsv`.

## The lever

`sro_client.exe` ships its asserts with `__FILE__` **and the failing
expression**. The helper is

	FUN_0049e490(line, file, format, ...)

-- the same call `PrimMtrlSet` makes for `"Material File[%s] Open Failed."` at
`D:\Project\SilkroadOnline\TOOLS & PLUGINS\SimpleViewer\objengine\PrimMtrlSet.cpp`.

So every call site names the `.cpp` its function was compiled from, for free,
with no reading. **165 distinct source paths** are in the binary and **736 call
sites** reference one. 364 of those resolve to a single enclosing function in
the dump, and **352 of the 364 had no name at all** -- the client's naming
coverage was 15.5 %.

An entry is evidence about a function's owning file, not a name for it. Names
still go in `recovered_names.tsv`, once the function has actually been read.

## The expressions are the richer half

89 of the rows carry a C++ expression rather than a message, and those hand
over real member and method names:

| where | the assert |
|---|---|
| `NetProcessInInterface.cpp` | `!m_pGInterface->GetMainPopup()->GetSkillAddress()->GetLearnedSkill()->IsLearnedSkill(dwSkillID)` |
| `NetProcessInInterface.cpp` | `...->IsLearnedMastery(dwMasteryID)` |
| `IFSKillBoard.cpp` | `pSkill->pSkillData->GetData()->m_nReq_Sp` |
| `IFSlotWithHelp.cpp` | `m_pObject->GetAttr() == AX_ATTR_SOBJECT_ITEM` |
| `IFSlotWithHelp.cpp` | `((CSOItem*)m_pObject)->GetOverlapCount()` |
| `IFQuickPartyWnd.cpp` | `pInfo && g_pMyPlayerObj->GetMyJID() != pInfo->m_dwJID` |
| `Game.cpp` | `CObjChild::m_pGfxEttManager->GetUsedIDNum() == 0` |

The first one is worth noticing on its own: the client has a real
`LearnedSkill` object with `IsLearnedSkill(dwSkillID)` on it, and the handler
that books a newly learned skill asserts the character does **not** already
have it. srrevamp's hotbar gate (playtest item 3) asks the same question of
the same set.

## Where this points next

`NIFOption.cpp` is the options window, which playtest item 17 wants a graphics
section in. `ResObject.cpp`, `MapLoader.cpp`, `CompoundObj.cpp`, `VertexBuffer.cpp`
and `RTDunBlock.cpp` are the world-rendering family; `CharacterDependentData.cpp`
has 23 functions and is the largest single file in the table.

## What this did NOT settle -- and what I had already been told

The same dig went looking for what `bmt_reader.gd` calls `Layer.unknown`, on the
assumption it was an unread field. **It is not, and this page said so before
round 279 ran.**

`docs/protocol/BMT_FORMAT.md` already records, from an earlier pass:

- `PrimMtrlSet::SaveToFile` and its `objengine\PrimMtrlSet.cpp` assert;
- the magic written as three integers, `JMXV` / `BMT ` / `0102`;
- the per-layer field order out of the serialiser;
- **that the flag word is the dword at material struct offset `0x60`**;
- and that bit 0 means "this layer's alpha is a cutout mask", inferred from a
  perfect correlation across ~25 layers plus the artists' `_al` naming
  convention, with the binary confirmation explicitly still open.

`object_loader.gd` then *uses* it: `LAYER_FLAG_ALPHA = 0x1` gated behind
`LAYER_FLAG_MASK = 0x40`, with a pixel-inspection fallback for layers whose word
does not look like a flag word. So the field is read, understood well enough to
ship, and only its *binary* confirmation is missing.

Round 279 re-derived the layout and briefly presented it as new. It was not.
The lesson is the one already in this project's notes and now earned twice:
**grep `docs/protocol/` for the row before going to the dump.**

What remains genuinely open is narrower and is what BMT_FORMAT.md already names:
**where material+0x60 is TESTED** in the render path. The states are set
numerically and there are no alpha-test strings to anchor a search, so the way in
is the field's readers, not its writers -- and the writers are all round 279
found.

## What IS new here

The assert lever itself, and nothing about materials: 165 source paths, 736 call
sites, 364 functions mapped to a translation unit, 352 of which had no name. That
map is the contribution, and `NIFOption.cpp`, `InventoryManager.cpp`,
`SkillManager.cpp` and the rest are where it pays off.
