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



## Interpolating the attribution — and the 88% that is withheld

A source file attributes only the function that carries the assert. MSVC emits a
translation unit contiguously, so a function sitting **between two asserts of the
same file** ought to belong to it too. That is worth testing rather than
assuming, and testing it changed the answer twice.

### The naive form is unsound

Within a file, address order should match source-line order. **It does not** —
of 172 adjacent pairs, only 119 (69.2%) are ordered. The violations have a
shape: `line 1084 -> 23`, `line 2234 -> 897`, `line 4392 -> 2339`. Large then
small, i.e. **a translation unit emitted in several separate runs**. Splitting on
that gives 123 files across 176 ascending runs, 1.43 per file, so most are one
block and a minority are chunked.

### The rule that does hold, and how far

Rule: *if the nearest asserted function below and the nearest above name the
**same** file, the function between them is in that file.* Neighbours agree about
38% of the time.

Leave-one-out over the 295 asserted functions — predict each one's file from its
neighbours and compare against its own assert — is **110 correct out of 110**, at
every span size it could reach.

**But that test cannot reach far.** Its spans are bounded by how densely asserts
occur, and applying the rule to unnamed functions produces spans with a median of
**127** and a maximum of **516**. Only **12%** of the yield falls inside the
range leave-one-out exercised.

### A second validator, and why it does not settle it

The dump already gives 19,154 client functions a `Class::` prefix, so the
interpolated file can be compared against it. Agreement is **61.5%** — and only
72% even at span <= 30, where leave-one-out said 100%.

That is not proof the interpolation is wrong. The two measure different things:
a `.cpp` legitimately holds several classes, and the biggest disagreements are
`UI_ALCHEMYBOX` (209) and `UI_SILKMALL`, which are **module attributions from an
earlier pass rather than real class names**. Comparing one inference against
another settles nothing.

### What is published

Only the **579 functions in spans <= 30**, where leave-one-out has actual
coverage (65 predictions there, all correct). The other **4,393 are withheld**:
the rule may well hold for them, but nothing available validates a 500-function
span, and a large number that looks like success is exactly how this project has
been wrong before.

Total client functions attributed to a source file: **263 direct + 579
interpolated = 842**.

## Interpolated functions (span <= 30)

### CObjCharacter.cpp — 65 interpolated

`00a5bb00`, `00a5bc20`, `00a5bcd0`, `00a5be70`, `00a5beb0`, `00a5bfe0`, `00a5c010`, `00a5c0f0`, `00a5c110`, `00a5c150`, `00a5c1f0`, `00a5c210`, `00a5c240`, `00a5c630`, `00a5c670`, `00a5c740`, `00a5c760`, `00a5c850`, `00a5c8b0`, `00a5c9f0`, `00a5ca90`, `00a5cad0`, `00a5cb30`, `00a5cbd0`, `00a5cc70`, `00a5cef0`, `00a5cf20`, `00a5cf90`, `00a5d010`, `00a5d080`, `00a5d0d0`, `00a5d120`, `00a5d170`, `00a5d1b0`, `00a5d1f0`, `00a5d220`, `00a5d250`, `00a5d280`, `00a5d2f0`, `00a5fa50`, `00a5faf0`, `00a5fb90`, `00a5fca0`, `00a5fd30`, `00a5fd70`, `00a5fe00`, `00a5ff00`, `00a5ffd0`, `00a60080`, `00a60160`, `00a60220`, `00a60370`, `00a603f0`, `00a60430`, `00a60470`, `00a605a0`, `00a609f0`, `00a60c60`, `00a60df0`, `00a60e30`, `00a60e70`, `00a60eb0`, `00a60ef0`, `00a60f90`, `00a61010`

### RTDunBlock.cpp — 47 interpolated

`00c6aec0`, `00c6af80`, `00c6afc0`, `00c6b060`, `00c6b110`, `00c6b150`, `00c6b1b0`, `00c6b1e0`, `00c6b210`, `00c6b230`, `00c6b2f0`, `00c6b360`, `00c6b3b0`, `00c6b490`, `00c6b560`, `00c6b5f0`, `00c6b6f0`, `00c6b750`, `00c6b870`, `00c6b8f0`, `00c6b950`, `00c6b9d0`, `00c6ba50`, `00c6bad0`, `00c6bb20`, `00c6bc10`, `00c6bc60`, `00c6bcb0`, `00c6bd50`, `00c6c2a0`, `00c6c4d0`, `00c6c500`, `00c6c530`, `00c6c5d0`, `00c6ce10`, `00c6ce80`, `00c6cf40`, `00c6d010`, `00c6d040`, `00c6d2a0`, `00c6d330`, `00c6d370`, `00c6d410`, `00c6d750`, `00c6d8b0`, `00c6da30`, `00c6db00`

### GlobalDataManager.cpp — 38 interpolated

`0093f200`, `0093f250`, `0093f2f0`, `0093f370`, `0093f3f0`, `0093f460`, `0093f540`, `0093f5d0`, `0093f5f0`, `0093f630`, `0094cf60`, `0094d1b0`, `0094d1e0`, `0094d220`, `0094d270`, `0094d310`, `0094d340`, `0094d370`, `0094d3a0`, `0094d3d0`, `0094d400`, `0094d430`, `0094d460`, `0094d510`, `0094d710`, `0094d910`, `0094d960`, `0094d990`, `0094d9d0`, `0094da00`, `0094da40`, `0094da70`, `0094dab0`, `0094dae0`, `0094db20`, `0094db50`, `0094db90`, `0094dbc0`

### CharacterDependentData.cpp — 32 interpolated

`009965e0`, `00996c20`, `00996c50`, `00996d10`, `00996d60`, `00996e70`, `00996ed0`, `00996f30`, `00996f60`, `00996f80`, `00997030`, `00997080`, `009970e0`, `009971c0`, `00998e60`, `00998f70`, `009990f0`, `009993b0`, `00999960`, `009999e0`, `00999f50`, `00999f90`, `00999fd0`, `0099a010`, `0099a050`, `0099a090`, `0099a0d0`, `0099a110`, `0099a150`, `0099a210`, `0099a250`, `0099a290`

### ObjRendererVS.cpp — 30 interpolated

`00bf06f0`, `00bf0760`, `00bf07a0`, `00bf07c0`, `00bf0800`, `00bf0830`, `00bf0870`, `00bf0890`, `00bf0e20`, `00bf1250`, `00bf1cf0`, `00bf1d40`, `00bf2130`, `00bf2180`, `00bf2220`, `00bf22f0`, `00bf2360`, `00bf29a0`, `00bf31e0`, `00bf3460`, `00bf3540`, `00bf3e00`, `00bf4540`, `00bf4610`, `00bf46b0`, `00bf5700`, `00bf5780`, `00bf5e70`, `00bf5f80`, `00bf6500`

### MapLoader.cpp — 29 interpolated

`00426750`, `004267a0`, `00426bc0`, `00426c20`, `00426cf0`, `00427680`, `00427760`, `00427c00`, `00427c50`, `00428120`, `004281d0`, `00428480`, `00428970`, `004289e0`, `00428a00`, `00429260`, `004292b0`, `00429340`, `00429570`, `004296f0`, `00429720`, `00429780`, `004298e0`, `00429960`, `00429a10`, `00429cb0`, `00429f50`, `0042a670`, `0042b8a0`

### RTNavMeshObj.cpp — 25 interpolated

`0044a080`, `0044a0f0`, `0044a540`, `0044a690`, `0044a720`, `0044a790`, `0044add0`, `0044b270`, `0044b350`, `0044b690`, `0044b710`, `0044b7c0`, `0044b960`, `0044baa0`, `0044bf10`, `0044bf60`, `0044bfa0`, `0044c540`, `0044c6b0`, `0044c6d0`, `0044c6f0`, `0044c7d0`, `0044ce30`, `0044ce80`, `0044cf00`

### DungeonObj.cpp — 23 interpolated

`00c1fdd0`, `00c1fe20`, `00c1fe80`, `00c1feb0`, `00c1fee0`, `00c1ffb0`, `00c1fff0`, `00c20030`, `00c20070`, `00c20360`, `00c20390`, `00c203e0`, `00c20440`, `00c20470`, `00c204a0`, `00c204e0`, `00c20580`, `00c205d0`, `00c20610`, `00c20650`, `00c20830`, `00c20860`, `00c20910`

### rtloading.cpp — 22 interpolated

`00b8acb0`, `00b8ad80`, `00b8ae70`, `00b8aef0`, `00b8afc0`, `00b8b000`, `00b8b040`, `00b8b080`, `00b8b100`, `00b8b200`, `00b8b240`, `00b8b280`, `00b8b2c0`, `00b8b300`, `00b8b390`, `00b8b3d0`, `00b8b410`, `00b8b520`, `00b8b550`, `00b8b580`, `00b8b5d0`, `00b8bac0`

### IFSlotWithHelp.cpp — 21 interpolated

`006809a0`, `00680b20`, `00680cf0`, `00682040`, `006821f0`, `00682410`, `006827c0`, `00682ba0`, `00682df0`, `00683040`, `00683290`, `00684740`, `00685b80`, `00685f20`, `006860a0`, `00686c50`, `006871d0`, `00687710`, `00687800`, `00687a10`, `00687bc0`

### GInterface.cpp — 17 interpolated

`007887e0`, `00788840`, `00788fb0`, `007890c0`, `007891f0`, `00789290`, `00789300`, `00789380`, `007893f0`, `00789450`, `007894c0`, `00789590`, `007895d0`, `00789610`, `00789650`, `007896e0`, `007897b0`

### ScreenDistortion.cpp — 17 interpolated

`00bc6f30`, `00bc6f60`, `00bc6fc0`, `00bc7090`, `00bc70f0`, `00bc71a0`, `00bc7240`, `00bc72b0`, `00bc72d0`, `00bc7300`, `00bc7320`, `00bc7390`, `00bc73b0`, `00bc73d0`, `00bc7810`, `00bc7850`, `00bc78d0`

### RegionManagerBody.cpp — 14 interpolated

`00411f60`, `00412120`, `004121e0`, `00412ef0`, `00412f60`, `00413080`, `004130e0`, `00413170`, `004131c0`, `00413c50`, `00413ca0`, `00414410`, `00414460`, `00414510`

### NetProcessInObject.cpp — 14 interpolated

`008a6ab0`, `008a6b40`, `008a6b90`, `008a6bd0`, `008a6cc0`, `008a7720`, `008a7820`, `008a7a20`, `008a7a70`, `008a7ac0`, `008a7b30`, `008a7b80`, `008a7bd0`, `008a7c50`

### CompoundObj.cpp — 14 interpolated

`00c259d0`, `00c2b0c0`, `00c2b1d0`, `00c2b200`, `00c2b260`, `00c2b2d0`, `00c2b870`, `00c2b930`, `00c2ba60`, `00c2bb40`, `00c2bbb0`, `00c2bc30`, `00c2bc80`, `00c2bd20`

### ICharactor.cpp — 13 interpolated

`009d0660`, `009d06a0`, `009d06e0`, `009d0780`, `009d07c0`, `009d0960`, `009d09a0`, `009d0a30`, `009d0a80`, `009d0da0`, `009d11c0`, `009d1220`, `009d1300`

### NIFBattleArenaGuildWnd.cpp — 11 interpolated

`005808f0`, `00580a40`, `00580a90`, `00580ab0`, `00580ad0`, `00580c80`, `00582370`, `00582410`, `00582490`, `00582510`, `00582600`

### Dx3DSoundBuffer.cpp — 11 interpolated

`00c1db10`, `00c1db70`, `00c1dc90`, `00c1dd00`, `00c1dd60`, `00c1dde0`, `00c1dea0`, `00c1dfd0`, `00c1e000`, `00c1e1e0`, `00c1e2a0`

### RTNavMeshDungeon.cpp — 10 interpolated

`0043dd20`, `0043dd50`, `0043dfa0`, `0043e100`, `0043e410`, `0043e4f0`, `0043e650`, `0043e760`, `0043e7b0`, `0043e8b0`

### IGIDObject.cpp — 10 interpolated

`009c3220`, `009c32f0`, `009c33a0`, `009c3540`, `009c3580`, `009c35e0`, `009c3640`, `009c3690`, `009c3710`, `009c3750`

