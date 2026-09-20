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

## What this did NOT settle: the material layer's flags word

The same dig went looking for what `bmt_reader.gd` calls `Layer.unknown` -- a
dword every material layer carries, parsed and then ignored, which is the
obvious candidate for the alpha/blend flags that playtest items 6 and 14
(see-through clothes, hair as a solid block) turn on.

**Its location is now exact.** `PrimMtrlSet::WriteLayer` (`0x00bf8970`) writes a
layer in this order: the name string, four 16-byte colour blocks (member `+0x10`,
`+0x00`, `+0x20`, `+0x30` -- note the file order is not the member order), the
dword at member `+0x40` (`power`), **the dword at member `+0x60`**, then the
texture path at `+0x64`. So the field we do not understand is `CPrimMtrl+0x60`.

**What it means is not read**, and nothing here promotes a guess. The next step
is the reader of `+0x60` on a `CPrimMtrl`, which is where the renderer decides
a blend mode -- and until that is read, the client's character materials keep
their current, honest state: no transparency set at all, which is why hair with
an alpha channel draws as a block.
