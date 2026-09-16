# The client's naming lever: its asserts

The server's lever is the `## Illegal ##` virtual stubs that name 209 vtable
slots. **The client has none** — zero such strings — which left open what it does
have. It has this: `sro_client.exe` ships with asserts intact.

	FUN_0049e490(0x765, "D:\\vss-od\\Silkroad\\Client\\client\\CObjCharacter.cpp",
	             "dwSlotPos < EQUIP_VISUAL_COUNT");

Each carries a **source file**, a **line number**, and the **expression text**,
which names variables, members and constants from the original source.

Regenerate with `client/tools/ghidra/harvest_client_asserts.py`.

| | |
|---|---|
| assert sites | 424 |
| distinct source files | 123 |
| distinct expressions | 307 |
| functions carrying one | 295 |
| ...of those still `FUN_` | **263** |

## Read the expression, not just the guard

The guard above an assert gives the numeric bound, but **the operator in the
expression decides the off-by-one**, and both shapes occur:

| constant | expression | guard | value |
|---|---|---|---|
| `EQUIP_VISUAL_COUNT` | `dwSlotPos < ...` | `8 < p` | 9 |
| `DEFAULT_WEAR_NUM` | `nDefaultWearNum < ...` | `1 < p` | 2 |
| `AUTO_POTION_COUNT` | `byType < ...` | `2 < p` | 3 |
| `MAX_MAGPARAM_PER_ITEM` | `m_btMagicParamNum **<=** ...` | `0xc < v` | **12**, not 13 |

Taking "one past the guard" as a rule would have made the last one wrong.

`MAX_MAGPARAM_PER_ITEM` has an independent check: the **server** bounds the same
quantity with `0xc < value` at three sites and logs
`"Item's MagParamNum(%d) is out of range"`. Two binaries, one number.

**None of these is used by srrevamp**, which models no magic options, quickslots
or auto-potions, and whose equipment slots are server-side rather than the
client's visual ones. They are recorded because they are recovered.

## Functions attributable to a source file

263 still-`FUN_` functions can be placed in a translation unit. This is an
attribution, not a name — it says which part of the client a function belongs to.

### CharacterDependentData.cpp (23)

`00991d80`, `00991e80`, `00991ef0`, `00991f60`, `00992020`, `009920a0`, `00992160`, `009921e0`, `00992260`, `00992380`, `00992400`, `00992490`, `00992710`, `00996540`, `00996ba0`, `00996c70`, `00996fa0`, `00997290`, `00998cb0`, `00999120`, `00999260`, `00999550`, `0099a2e0`

### CObjCharacter.cpp (12)

`00a5ba90`, `00a5bb50`, `00a5bb90`, `00a5bbd0`, `00a5bd10`, `00a5cca0`, `00a5d460`, `00a5f3e0`, `00a5f4f0`, `00a604f0`, `00a60a90`, `00a611e0`

### MapLoader.cpp (10)

`004263e0`, `00426450`, `00426810`, `00426fe0`, `004277b0`, `00428a40`, `004295f0`, `00429670`, `0042a6e0`, `0042b8b0`

### GlobalDataManager.cpp (9)

`00936bf0`, `00939ea0`, `0093ef10`, `009447f0`, `009463e0`, `009465c0`, `00946930`, `0094ccb0`, `0094dc00`

### ResObject.cpp (9)

`00bc8050`, `00bcb2d0`, `00bdef90`, `00bdf1f0`, `00be2700`, `00be28d0`, `00be2f80`, `00be3540`, `00be41d0`

### CompoundObj.cpp (7)

`00c25990`, `00c259f0`, `00c27fd0`, `00c2b050`, `00c2be80`, `00c2bef0`, `00c2fcf0`

### NIFBattleArenaGuildWnd.cpp (6)

`005807e0`, `00580dd0`, `00580f40`, `00582310`, `00582920`, `00582980`

### rtloading.cpp (6)

`00b876b0`, `00b87700`, `00b8ac30`, `00b8b140`, `00b8bb40`, `00b8bbc0`

### CharacterVisualChangeManager.cpp (5)

`004ea570`, `004ec9d0`, `004ed040`, `004ed440`, `004ed530`

### NetProcessInObject.cpp (4)

`008a69b0`, `008a6d20`, `008a7d20`, `008abfa0`

### SkillStructureByServer.cpp (4)

`009c0ff0`, `009c1240`, `009c12b0`, `009c1750`

### IGIDObject.cpp (4)

`009c1fa0`, `009c31a0`, `009c3270`, `009c3790`

### ObjRendererVS.cpp (4)

`00bf05e0`, `00bf1840`, `00bf3b70`, `00bf67c0`

### Dx3DSoundBuffer.cpp (4)

`00c1da40`, `00c1e310`, `00c1e460`, `00c1e840`

### RTNavMeshObj.cpp (3)

`00449630`, `0044d060`, `0044d330`

### IFRadioButton.cpp (3)

`00657890`, `00657970`, `00657ad0`

### IFSlotWithHelp.cpp (3)

`0067eec0`, `00680da0`, `00687c70`

### IF_NPCTalk.cpp (3)

`006f73d0`, `006f79c0`, `006fe030`

### IFCOSInventory.cpp (3)

`007a6e00`, `007a6ee0`, `007a6fe0`

### AutoPotion.cpp (3)

`0082cd50`, `0082cdb0`, `0082ce90`

### SOItem.cpp (3)

`008bacc0`, `008bcdf0`, `008bd760`

### SkillCoolTimeManager.cpp (3)

`009bb9c0`, `009bba90`, `009bbb60`

### ICharactor.cpp (3)

`009c7930`, `009d05d0`, `009d15a0`

### GlobalEffectManager.cpp (3)

`00a7b2f0`, `00a7f5a0`, `00a9d0f0`

