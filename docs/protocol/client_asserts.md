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



## Interpolating the attribution

A source file attributes only the function carrying the assert. MSVC emits a
translation unit contiguously, so a function **between two asserts of the same
file** ought to belong to it. Testing that changed the answer three times.

### The naive form is unsound

Address order should match source-line order within a file. **It does not** — of
172 adjacent pairs only 119 (69.2%) are ordered, and the violations run
`line 1084 -> 23`, `2234 -> 897`, `4392 -> 2339`: large then small, a translation
unit emitted in **several separate runs**. 123 files span 176 ascending runs,
1.43 per file.

### The rule that holds

*If the nearest asserted function below and above name the same file, the one
between is in that file.* Neighbours agree about 38% of the time.

**Leave-one-out** over the 295 asserted functions — predict each from its
neighbours, compare against its own assert — is **110/110**. But its spans are
bounded by assert density, while real spans have a median of 127 and a maximum of
516, so it covers only the short end.

### The validator that reaches the long end

5,545 client functions carry an **RTTI-derived** class, read from the binary's
`ClassHierarchyDescriptor` — real data, unlike the call-graph and module
attributions, which are inferences and cannot validate another inference.

Do not compare class name to file name as strings. That test reports 15%,
and its failures are things like `CResObjSimple` vs `ResObject.cpp` and
`CCompChar` vs `CompoundObj.cpp` — obviously the same file, invisible to a
substring match. **Test consistency instead**: does each RTTI class land in one
file?

| class | functions | dominant file | |
|---|---|---|---|
| `CCompChar` | 32 | `CompoundObj.cpp` | 32/32 |
| `CICUser` | 16 | `ICharactor.cpp` | 15/16 |
| `CharacterVisualChange` | 8 | `CharacterVisualChangeManager.cpp` | 8/8 |
| `CICATStruct` | 5 | `ICharactor.cpp` | 5/5 |
| `CCObjCharacter` | 5 | `CObjCharacter.cpp` | 5/5 |
| `CGIGInterface` | 4 | `gwndbase.cpp` | 4/4 |
| `CGame` | 4 | `gfxmainframe.cpp` | 4/4 |
| `CResObjSimple` | 3 | `ResObject.cpp` | 3/3 |
| `CResChar` | 3 | `ResObject.cpp` | 3/3 |

**79 of 80 (98.8%)**, against a **7.2%** baseline for attribution drawn at random
over the same file distribution. And it holds at every span:

| span | consistent | n |
|---|---|---|
| <= 30 | 100% | 19 |
| <= 100 | 98% | 41 |
| <= 500 | 100% | 15 |
| > 500 | 100% | 5 |

**The long-span buckets are small — 20 samples above span 100.** That is evidence
rather than proof, and it is why the numbers are printed here instead of being
summarised as "validated".

### Published

All **4,972** interpolated functions. An earlier pass published only the 579 in
spans <= 30 and withheld the rest as unvalidated; the RTTI consistency test
reaches the long spans that leave-one-out could not, so the caution is
superseded rather than the data having changed.

Total client functions attributed to a source file: **263 direct + 4,972
interpolated = 5,235** of 43,460.

## Interpolated functions by file

### GlobalDataManager.cpp — 706

`00936e40`, `00936ee0`, `00936f30`, `00936f90`, `00937010`, `00937070`, `009370d0`, `00937130`, `00937190`, `009371f0`, `00937250`, `009372b0`, `009372f0`, `00937350`, `009373b0`, `00937410`, `00937440`, `009374a0`, `00937550`, `009375b0`, `00937610`, `00937670`, `00937690`, `009376b0`, `009376d0`, `009376f0`, `00937750`, `009377b0`, `00937850`, `00937960`, `009379c0`, `00937af0`, `00937c20`, `00937c80`, `00937ce0`, `00937d40`, `00937da0`, `00937e00`, `00937e60`, `00937ec0`, `00937f20`, `00937f80`, `00937fa0`, `00938000`, `00938030`, `00938090`, `009380c0`, `00938120`, `00938140`, `009381a0`, `009381c0`, `00938200`, `00938260`, `009382c0`, `00938310`, `00938370`, `009383e0`, `00938460`, `009384c0`, `00938520`, … and 646 more

### ResObject.cpp — 655

`00bc80d0`, `00bc80f0`, `00bc8130`, `00bc81d0`, `00bc8260`, `00bc8290`, `00bc82b0`, `00bc82f0`, `00bc8310`, `00bc8390`, `00bc83d0`, `00bc8400`, `00bc8470`, `00bc84c0`, `00bc8550`, `00bc8580`, `00bc85b0`, `00bc85e0`, `00bc8610`, `00bc8790`, `00bc8870`, `00bc88a0`, `00bc88d0`, `00bc8900`, `00bc8930`, `00bc8960`, `00bc8990`, `00bc89c0`, `00bc89f0`, `00bc8a20`, `00bc8a80`, `00bc8ab0`, `00bc8ae0`, `00bc8b40`, `00bc8b70`, `00bc8ba0`, `00bc8bd0`, `00bc8c40`, `00bc8c50`, `00bc8ea0`, `00bc8ed0`, `00bc8f10`, `00bc8f50`, `00bc8f80`, `00bc8fb0`, `00bc8fe0`, `00bc9070`, `00bc90a0`, `00bc9330`, `00bc9360`, `00bc9390`, `00bc93c0`, `00bc93f0`, `00bc9430`, `00bc9490`, `00bc94c0`, `00bc94f0`, `00bc9530`, `00bc9560`, `00bc95a0`, … and 595 more

### GlobalEffectManager.cpp — 630

`00a7b330`, `00a7b9a0`, `00a7ba40`, `00a7ba70`, `00a7bb10`, `00a7bb30`, `00a7bb60`, `00a7bc00`, `00a7bce0`, `00a7bd10`, `00a7bdb0`, `00a7be50`, `00a7bef0`, `00a7bf90`, `00a7c000`, `00a7c070`, `00a7c0e0`, `00a7c150`, `00a7c1c0`, `00a7c1f0`, `00a7c290`, `00a7c370`, `00a7c3e0`, `00a7c410`, `00a7c520`, `00a7c5c0`, `00a7c660`, `00a7c700`, `00a7c7a0`, `00a7c840`, `00a7c8e0`, `00a7c990`, `00a7ca30`, `00a7cad0`, `00a7cb70`, `00a7cc10`, `00a7ccb0`, `00a7cd50`, `00a7cdf0`, `00a7ce90`, `00a7cf30`, `00a7cfd0`, `00a7d080`, `00a7d330`, `00a7d360`, `00a7d390`, `00a7d3c0`, `00a7d3f0`, `00a7d420`, `00a7d450`, `00a7d480`, `00a7d6f0`, `00a7d730`, `00a7d760`, `00a7d790`, `00a7d7d0`, `00a7d810`, `00a7d850`, `00a7d880`, `00a7d8c0`, … and 570 more

### GScript.cpp — 321

`00507f30`, `00508000`, `005082d0`, `00508330`, `005083c0`, `00508400`, `005084e0`, `00508550`, `00508580`, `00508620`, `005086c0`, `00508760`, `005087d0`, `00508870`, `00508910`, `005089b0`, `00508a50`, `00508af0`, `00508b90`, `00508c30`, `00508cd0`, `00508e70`, `00508eb0`, `00508ee0`, `00508f90`, `00508fe0`, `00509130`, `00509170`, `005091c0`, `00509200`, `00509240`, `00509270`, `005092a0`, `005092d0`, `00509490`, `00509560`, `00509580`, `005095a0`, `005095c0`, `00509600`, `005096c0`, `005097a0`, `00509890`, `005098c0`, `00509950`, `00509a00`, `00509a30`, `00509a60`, `00509a80`, `00509aa0`, `00509ac0`, `00509af0`, `00509b50`, `00509b70`, `00509b90`, `00509bb0`, `00509bf0`, `00509c40`, `00509c90`, `00509ce0`, … and 261 more

### Map.cpp — 246

`00a0df20`, `00a0e010`, `00a0e030`, `00a0e500`, `00a0e520`, `00a0e7e0`, `00a0ea20`, `00a0ec60`, `00a0f380`, `00a0f390`, `00a0f3a0`, `00a0f3b0`, `00a0f3f0`, `00a0f400`, `00a0f410`, `00a0f540`, `00a0f620`, `00a0f740`, `00a0f820`, `00a0f8e0`, `00a0fae0`, `00a0fb50`, `00a0fc40`, `00a0fd00`, `00a10260`, `00a102f0`, `00a10340`, `00a104e0`, `00a105a0`, `00a10740`, `00a107c0`, `00a10810`, `00a10930`, `00a10ba0`, `00a10c50`, `00a10ce0`, `00a10da0`, `00a11060`, `00a110d0`, `00a11130`, `00a111f0`, `00a114b0`, `00a11520`, `00a115e0`, `00a118a0`, `00a11910`, `00a11bd0`, `00a11c40`, `00a11cf0`, `00a11e70`, `00a11fd0`, `00a12030`, `00a12070`, `00a121e0`, `00a12400`, `00a124b0`, `00a12580`, `00a12880`, `00a12950`, `00a12a20`, … and 186 more

### Game.cpp — 240

`008374b0`, `008375d0`, `00837670`, `008376a0`, `00837740`, `008377e0`, `00837800`, `00837830`, `008378d0`, `00837970`, `00837a50`, `00837a80`, `00837b20`, `00837bc0`, `00837c60`, `00837d60`, `00837e60`, `00837ee0`, `00837f10`, `00838050`, `008380e0`, `00838150`, `00838180`, `008381f0`, `00838270`, `008382d0`, `00838360`, `00838490`, `00838530`, `00838670`, `008386b0`, `008386d0`, `008386f0`, `00838710`, `00838730`, `00838750`, `00838770`, `00838790`, `008387b0`, `008387d0`, `00838810`, `00838830`, `00838880`, `008388b0`, `008388e0`, `00838920`, `00838950`, `008389d0`, `00838a10`, `00838a50`, `00838ac0`, `00838af0`, `00838b50`, `00838b80`, `00838e20`, `00838e50`, `00838e90`, `00838eb0`, `00838ed0`, `00838ef0`, … and 180 more

### CompoundObj.cpp — 229

`00c259d0`, `00c25aa0`, `00c25ad0`, `00c25b00`, `00c25b30`, `00c25b80`, `00c25bd0`, `00c25c10`, `00c25c90`, `00c25cc0`, `00c25dc0`, `00c25de0`, `00c25e20`, `00c25f30`, `00c25f50`, `00c25f90`, `00c26060`, `00c260a0`, `00c261a0`, `00c26210`, `00c26370`, `00c263a0`, `00c26480`, `00c26520`, `00c265b0`, `00c26620`, `00c266b0`, `00c26830`, `00c268c0`, `00c26a40`, `00c26e50`, `00c26e70`, `00c26f50`, `00c26ff0`, `00c27180`, `00c27410`, `00c275a0`, `00c275c0`, `00c275d0`, `00c275e0`, `00c27610`, `00c27640`, `00c276b0`, `00c27700`, `00c27760`, `00c277e0`, `00c27860`, `00c278d0`, `00c27930`, `00c27960`, `00c27990`, `00c279c0`, `00c279f0`, `00c27a20`, `00c27a50`, `00c27c40`, `00c27cc0`, `00c27cd0`, `00c27d40`, `00c27d50`, … and 169 more

### ICharactor.cpp — 204

`009c7a40`, `009c7a50`, `009c7a60`, `009c7a70`, `009c7a80`, `009c7a90`, `009c7aa0`, `009c7ab0`, `009c7ad0`, `009c7b00`, `009c7b10`, `009c7b20`, `009c7b50`, `009c7b60`, `009c7b70`, `009c7b80`, `009c7b90`, `009c7bc0`, `009c7c80`, `009c7d30`, `009c7e60`, `009c7e80`, `009c7ec0`, `009c82f0`, `009c8310`, `009c8440`, `009c8480`, `009c84c0`, `009c87b0`, `009c87e0`, `009c8810`, `009c8850`, `009c88a0`, `009c8900`, `009c89a0`, `009c8a00`, `009c8a50`, `009c8ac0`, `009c8b30`, `009c8bf0`, `009c8c40`, `009c8d80`, `009c8e50`, `009c9060`, `009c90b0`, `009c9200`, `009c9250`, `009c92a0`, `009c9350`, `009c93e0`, `009c9400`, `009c9630`, `009c9650`, `009c9670`, `009c96c0`, `009c9860`, `009c9890`, `009c9920`, `009c9ac0`, `009c9c80`, … and 144 more

### RTSkeleton.cpp — 196

`00c4a280`, `00c4a2b0`, `00c4a2e0`, `00c4a310`, `00c4a350`, `00c4a380`, `00c4a3c0`, `00c4a460`, `00c4a4f0`, `00c4a590`, `00c4a650`, `00c4a660`, `00c4a750`, `00c4a760`, `00c4a7f0`, `00c4a850`, `00c4a890`, `00c4a910`, `00c4a930`, `00c4a9a0`, `00c4aa20`, `00c4aaf0`, `00c4abe0`, `00c4ac80`, `00c4acc0`, `00c4ad40`, `00c4ade0`, `00c4ae90`, `00c4aee0`, `00c4afa0`, `00c4aff0`, `00c4b0b0`, `00c4b100`, `00c4b160`, `00c4b1a0`, `00c4b2b0`, `00c4b320`, `00c4b360`, `00c4b390`, `00c4b3f0`, `00c4b470`, `00c4b480`, `00c4b4b0`, `00c4b4e0`, `00c4b530`, `00c4b580`, `00c4b620`, `00c4b6c0`, `00c4b770`, `00c4b7b0`, `00c4b850`, `00c4b8f0`, `00c4b990`, `00c4b9c0`, `00c4ba60`, `00c4bcb0`, `00c4bf30`, `00c4bf70`, `00c4bfa0`, `00c4bff0`, … and 136 more

### CharacterDependentData.cpp — 151

`009928f0`, `00992940`, `009929c0`, `00992a80`, `00992a90`, `00992ba0`, `00992c10`, `00992ca0`, `00992e00`, `00992e50`, `00992ec0`, `00992fe0`, `00993040`, `00993120`, `00993230`, `00993360`, `009933e0`, `00993450`, `00993520`, `009935b0`, `00993650`, `009936e0`, `009937d0`, `00993890`, `00993900`, `009939c0`, `00993c80`, `00993cf0`, `00993db0`, `00994070`, `009940e0`, `009941a0`, `00994460`, `009944d0`, `00994590`, `00994600`, `00994660`, `00994720`, `00994790`, `00994940`, `009949c0`, `00994a30`, `00994ad0`, `00994ba0`, `00994bd0`, `00994cc0`, `00994d80`, `00994e10`, `00994ea0`, `00994f10`, `00994f80`, `00995050`, `00995120`, `009951f0`, `009952c0`, `00995390`, `00995460`, `00995530`, `009958a0`, `009959e0`, … and 91 more

### rtloading.cpp — 99

`00b87750`, `00b87810`, `00b87830`, `00b87870`, `00b87980`, `00b879a0`, `00b879e0`, `00b87cf0`, `00b87d10`, `00b87eb0`, `00b87f20`, `00b88120`, `00b88190`, `00b882c0`, `00b88310`, `00b88420`, `00b885c0`, `00b88600`, `00b88640`, `00b886b0`, `00b886e0`, `00b88830`, `00b888e0`, `00b88910`, `00b88950`, `00b88990`, `00b889d0`, `00b88a10`, `00b88a50`, `00b88a90`, `00b88b40`, `00b88b70`, `00b88ba0`, `00b88bd0`, `00b88c00`, `00b88c30`, `00b88c60`, `00b88cb0`, `00b88d80`, `00b88e00`, `00b88e80`, `00b88f00`, `00b88fe0`, `00b89060`, `00b89110`, `00b89180`, `00b891e0`, `00b89250`, `00b892b0`, `00b89320`, `00b89530`, `00b89540`, `00b89550`, `00b89560`, `00b89570`, `00b89580`, `00b89720`, `00b89960`, `00b89b60`, `00b89b70`, … and 39 more

### CObjCharacter.cpp — 97

`00a5bb00`, `00a5bc20`, `00a5bcd0`, `00a5be70`, `00a5beb0`, `00a5bfe0`, `00a5c010`, `00a5c0f0`, `00a5c110`, `00a5c150`, `00a5c1f0`, `00a5c210`, `00a5c240`, `00a5c630`, `00a5c670`, `00a5c740`, `00a5c760`, `00a5c850`, `00a5c8b0`, `00a5c9f0`, `00a5ca90`, `00a5cad0`, `00a5cb30`, `00a5cbd0`, `00a5cc70`, `00a5cef0`, `00a5cf20`, `00a5cf90`, `00a5d010`, `00a5d080`, `00a5d0d0`, `00a5d120`, `00a5d170`, `00a5d1b0`, `00a5d1f0`, `00a5d220`, `00a5d250`, `00a5d280`, `00a5d2f0`, `00a5d5c0`, `00a5d640`, `00a5d6f0`, `00a5d750`, `00a5d7c0`, `00a5d820`, `00a5d8e0`, `00a5d920`, `00a5d930`, `00a5d940`, `00a5d950`, `00a5da10`, `00a5db40`, `00a5dbe0`, `00a5dde0`, `00a5dfe0`, `00a5dff0`, `00a5e000`, `00a5e010`, `00a5e100`, `00a5e190`, … and 37 more

### InterfaceNetSender.cpp — 92

`0081cad0`, `0081cb70`, `0081cc30`, `0081cd20`, `0081ce00`, `0081cef0`, `0081cfd0`, `0081d090`, `0081d150`, `0081d210`, `0081d2f0`, `0081d3b0`, `0081d470`, `0081d530`, `0081d610`, `0081d6f0`, `0081d790`, `0081d9a0`, `0081da40`, `0081dae0`, `0081db80`, `0081dc60`, `0081dd20`, `0081ddf0`, `0081df20`, `0081e0d0`, `0081e170`, `0081e250`, `0081e2f0`, `0081e3b0`, `0081e690`, `0081e750`, `0081e810`, `0081e8d0`, `0081e990`, `0081ea70`, `0081eb50`, `0081ec20`, `0081ece0`, `0081eda0`, `0081ee60`, `0081f030`, `0081f100`, `0081f1a0`, `0081f270`, `0081f330`, `0081f410`, `0081f4e0`, `0081f5a0`, `0081f710`, `0081f7d0`, `0081f890`, `0081f9e0`, `0081fab0`, `0081fb70`, `0081fce0`, `0081fdc0`, `0081fe80`, `0081ff50`, `00820010`, … and 32 more

### IF_NPCTalk.cpp — 80

`006f7460`, `006f7470`, `006f74a0`, `006f74c0`, `006f74f0`, `006f76a0`, `006f77c0`, `006f7cc0`, `006f7d00`, `006f7d40`, `006f7d80`, `006f7e20`, `006f7ef0`, `006f7f20`, `006f7f80`, `006f7fc0`, `006f8080`, `006f8140`, `006f8160`, `006f8180`, `006f81c0`, `006f8200`, `006f8240`, `006f8260`, `006f82e0`, `006f8300`, `006f8330`, `006f84d0`, `006f8560`, `006f87b0`, `006f8cb0`, `006f91b0`, `006f9370`, `006f9510`, `006f9640`, `006f98d0`, `006f9b60`, `006f9be0`, `006f9c60`, `006f9ce0`, `006f9d60`, `006f9de0`, `006f9e90`, `006f9f30`, `006f9fb0`, `006fa0b0`, `006fa250`, `006fa2a0`, `006fa2e0`, `006fa300`, `006fa380`, `006fa530`, `006fa540`, `006fa720`, `006fa740`, `006fa760`, `006fa7c0`, `006fa810`, `006faa50`, `006faa60`, … and 20 more

### ObjRendererVS.cpp — 80

`00beef60`, `00bef010`, `00bef040`, `00bef070`, `00bef0a0`, `00bef0d0`, `00bef100`, `00bef150`, `00bef1f0`, `00bef220`, `00bef250`, `00bef280`, `00bef2b0`, `00bef2e0`, `00bef380`, `00bef4c0`, `00bef570`, `00bef5b0`, `00bef730`, `00bef760`, `00bef790`, `00bef7c0`, `00bef7f0`, `00bef830`, `00bef870`, `00bef940`, `00befa10`, `00befa80`, `00befb90`, `00befc10`, `00befc70`, `00befca0`, `00befd00`, `00befd30`, `00befdd0`, `00befe20`, `00befe30`, `00beff90`, `00beffd0`, `00bf00a0`, `00bf00c0`, `00bf00f0`, `00bf0130`, `00bf01b0`, `00bf0250`, `00bf0310`, `00bf03f0`, `00bf04a0`, `00bf04d0`, `00bf0580`, `00bf06f0`, `00bf0760`, `00bf07a0`, `00bf07c0`, `00bf0800`, `00bf0830`, `00bf0870`, `00bf0890`, `00bf0e20`, `00bf1250`, … and 20 more

### AniMixer.cpp — 65

`00c52a70`, `00c52ae0`, `00c52b10`, `00c52b60`, `00c52b90`, `00c52be0`, `00c52c10`, `00c52c60`, `00c52d90`, `00c52dc0`, `00c52df0`, `00c52e10`, `00c52e40`, `00c52ef0`, `00c52f20`, `00c52f90`, `00c530f0`, `00c53160`, `00c531d0`, `00c53320`, `00c53410`, `00c53440`, `00c53470`, `00c534a0`, `00c53500`, `00c535a0`, `00c535f0`, `00c536b0`, `00c53700`, `00c537a0`, `00c537d0`, `00c53800`, `00c53830`, `00c53880`, `00c53920`, `00c539c0`, `00c53a60`, `00c53a90`, `00c53ae0`, `00c53bf0`, `00c53c90`, `00c53dc0`, `00c53e80`, `00c54200`, `00c54510`, `00c545b0`, `00c54610`, `00c54630`, `00c54710`, `00c54730`, `00c54780`, `00c547c0`, `00c54860`, `00c548f0`, `00c54910`, `00c54980`, `00c549d0`, `00c549f0`, `00c54a80`, `00c54b00`, … and 5 more

### gwndbase.cpp — 59

`00b8f380`, `00b8f390`, `00b8f3c0`, `00b8f3d0`, `00b8f420`, `00b8f440`, `00b8f460`, `00b8f480`, `00b8f4c0`, `00b8f4d0`, `00b8f4e0`, `00b8f4f0`, `00b8f500`, `00b8f530`, `00b8f540`, `00b8f560`, `00b8f6f0`, `00b8f710`, `00b8f950`, `00b8f9a0`, `00b8fa60`, `00b8fab0`, `00b8fb50`, `00b8fba0`, `00b8fbe0`, `00b8fc20`, `00b8fc70`, `00b8fca0`, `00b8fcd0`, `00b8fe20`, `00b8fef0`, `00b8ff70`, `00b90050`, `00b900b0`, `00b90210`, `00b90240`, `00b90440`, `00b90450`, `00b90500`, `00b90740`, `00b90750`, `00b90760`, `00b90a80`, `00b90ac0`, `00b90b00`, `00b90b70`, `00b90bd0`, `00b90c00`, `00b90c30`, `00b90c60`, `00b90cf0`, `00b90d90`, `00b90db0`, `00b90dd0`, `00b90e30`, `00b90ff0`, `00b91050`, `00b910d0`, `00b91190`

### CharacterVisualChangeManager.cpp — 58

`004ea860`, `004eab10`, `004eab80`, `004eac00`, `004eac80`, `004ead00`, `004eadb0`, `004eae10`, `004eae80`, `004eaf00`, `004eaf80`, `004eafb0`, `004eb070`, `004eb1c0`, `004eb290`, `004eb2d0`, `004eb380`, `004eb3c0`, `004eb4d0`, `004eb540`, `004eb580`, `004eb5d0`, `004eb700`, `004eb810`, `004eb940`, `004eb9e0`, `004eba60`, `004ebc60`, `004ebca0`, `004ebd10`, `004ec030`, `004ec0b0`, `004ec0e0`, `004ec120`, `004ec170`, `004ec1f0`, `004ec260`, `004ec2e0`, `004ec300`, `004ec320`, `004ec340`, `004ec360`, `004ec420`, `004ec490`, `004ec4b0`, `004ec580`, `004ec5a0`, `004ec960`, `004ec9b0`, `004ecb50`, `004ecb90`, `004ecc50`, `004ecc70`, `004ecd30`, `004ece40`, `004ecf50`, `004ecf90`, `004ed4f0`

### process.cpp — 57

`00ba7740`, `00ba7760`, `00ba77a0`, `00ba7960`, `00ba79b0`, `00ba79d0`, `00ba79f0`, `00ba7c00`, `00ba7da0`, `00ba7de0`, `00ba7e40`, `00ba7e70`, `00ba7ea0`, `00ba7f40`, `00ba8020`, `00ba8060`, `00ba80a0`, `00ba80e0`, `00ba8110`, `00ba8140`, `00ba8170`, `00ba81a0`, `00ba8220`, `00ba82d0`, `00ba8340`, `00ba83a0`, `00ba8450`, `00ba8580`, `00ba8590`, `00ba8630`, `00ba8720`, `00ba8920`, `00ba8930`, `00ba8970`, `00ba8980`, `00ba8a40`, `00ba8d00`, `00ba8d90`, `00ba8e60`, `00ba8e70`, `00ba8ed0`, `00ba8f30`, `00ba8f70`, `00ba8ff0`, `00ba9030`, `00ba9310`, `00ba9350`, `00ba9420`, `00ba9460`, `00ba9490`, `00ba94d0`, `00ba9500`, `00ba9540`, `00ba9580`, `00ba95c0`, `00ba95f0`, `00ba9620`

### NetProcessInObject.cpp — 50

`008a6ab0`, `008a6b40`, `008a6b90`, `008a6bd0`, `008a6cc0`, `008a7720`, `008a7820`, `008a7a20`, `008a7a70`, `008a7ac0`, `008a7b30`, `008a7b80`, `008a7bd0`, `008a7c50`, `008a7ee0`, `008a7fd0`, `008a8030`, `008a80a0`, `008a8490`, `008a84c0`, `008a85b0`, `008a8c20`, `008a8ea0`, `008a9040`, `008a90b0`, `008a9130`, `008a9170`, `008a91b0`, `008a91e0`, `008a9220`, `008a9260`, `008a9560`, `008a9e30`, `008aa340`, `008aaaf0`, `008aacc0`, `008aad40`, `008aade0`, `008aae60`, `008aaee0`, `008aafe0`, `008ab060`, `008ab0e0`, `008ab590`, `008ab6f0`, `008ab880`, `008abbd0`, `008abc70`, `008abcc0`, `008abf60`

### GameGuideData.cpp — 48

`009781e0`, `00978260`, `00978310`, `00978370`, `009783f0`, `009784a0`, `00978510`, `00978580`, `00978630`, `009786f0`, `00978700`, `00978710`, `00978770`, `00978870`, `009788c0`, `00978ac0`, `00978af0`, `00978b00`, `00978b80`, `00978bf0`, `00978cb0`, `00978d20`, `00979000`, `00979090`, `00979160`, `00979360`, `009794e0`, `00979600`, `00979650`, `00979690`, `00979720`, `00979880`, `00979910`, `00979960`, `009799a0`, `009799f0`, `00979a20`, `00979b80`, `00979bd0`, `00979c90`, `00979cd0`, `00979ed0`, `00979f10`, `0097a200`, `0097a2c0`, `0097a330`, `0097a4c0`, `0097a4f0`

### NetProcessInInterface.cpp — 47

`00880db0`, `00880f80`, `008811e0`, `008812b0`, `008814b0`, `00881690`, `00881740`, `00881820`, `00881890`, `00881950`, `008819e0`, `00881a70`, `00881bd0`, `00881c60`, `00881cb0`, `00881d00`, `00881d80`, `00881dd0`, `00881e20`, `00881e70`, `00881ec0`, `00881f30`, `00881f80`, `00881fd0`, `00882030`, `008820b0`, `00882130`, `00882ff0`, `00883070`, `008830f0`, `008832a0`, `00883400`, `00883520`, `00883620`, `00883780`, `008838d0`, `00883960`, `008839e0`, `00883b10`, `00883cc0`, `00883f90`, `008840d0`, `008841f0`, `00884660`, `008847d0`, `00884a30`, `00884ca0`

### RTDunBlock.cpp — 47

`00c6aec0`, `00c6af80`, `00c6afc0`, `00c6b060`, `00c6b110`, `00c6b150`, `00c6b1b0`, `00c6b1e0`, `00c6b210`, `00c6b230`, `00c6b2f0`, `00c6b360`, `00c6b3b0`, `00c6b490`, `00c6b560`, `00c6b5f0`, `00c6b6f0`, `00c6b750`, `00c6b870`, `00c6b8f0`, `00c6b950`, `00c6b9d0`, `00c6ba50`, `00c6bad0`, `00c6bb20`, `00c6bc10`, `00c6bc60`, `00c6bcb0`, `00c6bd50`, `00c6c2a0`, `00c6c4d0`, `00c6c500`, `00c6c530`, `00c6c5d0`, `00c6ce10`, `00c6ce80`, `00c6cf40`, `00c6d010`, `00c6d040`, `00c6d2a0`, `00c6d330`, `00c6d370`, `00c6d410`, `00c6d750`, `00c6d8b0`, `00c6da30`, `00c6db00`

### NIFBattleArenaGuildWnd.cpp — 43

`005808f0`, `00580a40`, `00580a90`, `00580ab0`, `00580ad0`, `00580c80`, `005810a0`, `005810e0`, `00581130`, `00581170`, `005811b0`, `005811e0`, `00581280`, `00581320`, `005813a0`, `005813c0`, `005813f0`, `00581410`, `00581450`, `00581490`, `005814e0`, `00581500`, `00581530`, `00581550`, `00581580`, `00581780`, `00581820`, `005818a0`, `00581920`, `005819a0`, `00581aa0`, `00581b00`, `00581d10`, `00581d20`, `00581d80`, `00581ec0`, `00581ed0`, `00582190`, `00582370`, `00582410`, `00582490`, `00582510`, `00582600`

### SOItem.cpp — 39

`008bae30`, `008baed0`, `008baf10`, `008bb070`, `008bb130`, `008bb210`, `008bb230`, `008bb260`, `008bb280`, `008bb510`, `008bb540`, `008bb570`, `008bb9a0`, `008bbd40`, `008bbd80`, `008bbdb0`, `008bbde0`, `008bbe10`, `008bbee0`, `008bbf10`, `008bc050`, `008bc0c0`, `008bc130`, `008bc1b0`, `008bc2c0`, `008bc490`, `008bc660`, `008bc730`, `008bc930`, `008bc9e0`, `008bcaa0`, `008bcb30`, `008bcbc0`, `008bcce0`, `008bd0e0`, `008bd220`, `008bd3e0`, `008bd510`, `008bd660`

### icscriptobj.cpp — 39

`009e28c0`, `009e28e0`, `009e2a00`, `009e2a50`, `009e2ac0`, `009e2b00`, `009e2c00`, `009e2c90`, `009e2cc0`, `009e2d00`, `009e2d30`, `009e2db0`, `009e2e30`, `009e2eb0`, `009e2f60`, `009e31e0`, `009e3520`, `009e3540`, `009e3670`, `009e36f0`, `009e3760`, `009e3780`, `009e37a0`, `009e3800`, `009e3890`, `009e3c40`, `009e4520`, `009e4640`, `009e4770`, `009e47a0`, `009e48c0`, `009e4960`, `009e49e0`, `009e4ac0`, `009e4b70`, `009e4c20`, `009e4c80`, `009e4d20`, `009e4da0`

### IGIDObject.cpp — 37

`009c2180`, `009c21d0`, `009c2220`, `009c2250`, `009c22f0`, `009c2340`, `009c2440`, `009c2460`, `009c2590`, `009c25d0`, `009c26b0`, `009c26e0`, `009c2710`, `009c2750`, `009c27d0`, `009c2830`, `009c28a0`, `009c2980`, `009c2b80`, `009c2b90`, `009c2be0`, `009c2bf0`, `009c2c20`, `009c2c60`, `009c2f20`, `009c3010`, `009c30d0`, `009c3220`, `009c32f0`, `009c33a0`, `009c3540`, `009c3580`, `009c35e0`, `009c3640`, `009c3690`, `009c3710`, `009c3750`

### gfxmainframe.cpp — 37

`00ba3c40`, `00ba3ca0`, `00ba3cb0`, `00ba3cc0`, `00ba3cf0`, `00ba3d40`, `00ba3fa0`, `00ba3fc0`, `00ba4020`, `00ba4250`, `00ba42b0`, `00ba42f0`, `00ba4360`, `00ba4390`, `00ba4450`, `00ba4630`, `00ba4660`, `00ba4730`, `00ba47d0`, `00ba4910`, `00ba4960`, `00ba4990`, `00ba49e0`, `00ba4a30`, `00ba4d10`, `00ba4d90`, `00ba4e10`, `00ba4f10`, `00ba5000`, `00ba50a0`, `00ba5460`, `00ba5690`, `00ba5800`, `00ba59a0`, `00ba5a50`, `00ba5c10`, `00ba5f70`

