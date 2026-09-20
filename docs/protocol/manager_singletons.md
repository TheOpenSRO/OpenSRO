# The server's manager singletons

**Recovered 2026-09-18.** The server reaches every subsystem through a global pointer,
and a handler that asserts one of these globals belongs to that subsystem. This page
first documented only the DB table registry, because the singletons themselves were not
identified; they are now, and the registry section is kept below.

## How each one is proven

Each manager is a singleton that registers itself on construction and **nulls its global
in its own destructor**. MSVC emits the destructor with the vtable store first, so the
function that writes the global also states, structurally, which class it belongs to:

	5bdf17  mov DWORD PTR [ecx],0xafe604   ; vtable installed on `this`
	5bdf36  mov DWORD PTR ds:0xd6a990,0x0  ; the same object's global, cleared
	5bdf4f  ret

RTTI already maps vtable -> class (`/var/tmp/vt_server.json`, 977 classes), so
`0xafe604` names it: `DAT_00d6a990` holds a **CPartyManager**.

The test is deliberately narrow: **the vtable must be installed on the same object that
is stored to the global**, tracked by register aliasing. A looser test — "any known
vtable anywhere in the writing function" — resolved 27 globals but got `DAT_00d6a8dc`
and `DAT_00d6a8e8` wrong, attributing a class that the function merely constructed in
passing. The strict test rejects both attributions and settles `d6a8dc` from its
destructor instead. Where the two disagreed, the strict answer is the one recorded here.

Two probe bugs were found and fixed while building the sweep, both of which silently
returned *fewer* results rather than failing:

- the `a3` accumulator store disassembles as `mov ds:0x…,eax` with **no `DWORD PTR`
  prefix**, so a regex requiring the prefix missed the most common store form;
- the destructors null the global with an **immediate** (`mov DWORD PTR ds:0x…,0x0`),
  not a zeroed register, so a null-detector looking only for `xor r,r` saw none of them.

## The table

| Global | Class | Vtable store proving it |
|---|---|---|
| `DAT_00d6a8dc` | `CMainProcess` | `0x004027bb` |
| `DAT_00d6a8e4` | `CFormulae` | `0x0040db27` |
| `DAT_00d6a900` | `CLobby` | `0x0043727b` |
| `DAT_00d6a94c` | `CLogBuilder` | `0x00466e47` |
| `DAT_00d6a950` | `COverlappedJobMgr` | `0x0046f0eb` |
| `DAT_00d6a958` | `COpenMarketMgr` | `0x00478f87` |
| `DAT_00d6a95c` | `CTradeMgr` | `0x0047f3ca` |
| `DAT_00d6a960` | `CGObjFactory` | `0x004896e7` |
| `DAT_00d6a964` | `CUserMsgDumpMgr` | `0x0052736a` |
| `DAT_00d6a968` | `CMap` | `0x005303ca` |
| `DAT_00d6a974` | `CAINavDataManager` | `0x0055609a` |
| `DAT_00d6a988` | `CAssociationReputationMgr` | `0x005b9707` |
| `DAT_00d6a98c` | `CCallUserMgr` | `0x005b9dd7` |
| `DAT_00d6a990` | `CPartyManager` | `0x005bdf17` |
| `DAT_00d6a994` | `CGuildManager` | `0x005c5cba` |
| `DAT_00d6a998` | `CMessengerMgr` | `0x005d73d7` |
| `DAT_00d6a99c` | `CTrainingCampManager` | `0x005dea4a` |
| `DAT_00d6a9a0` | `CVoteManager` | `0x005e7de7` |
| `DAT_00d6a9a4` | `CGameWorldMgr` | `0x005f5aea` |
| `DAT_00d6a9a8` | `CPublicInstanceWorldMgr` | `0x00606bba` |
| `DAT_00d6a9ac` | `CEventDaemonMgr` | `0x0061179a` |
| `DAT_00d6a9e4` | `CGShopFactory` | `0x00619bd7` |
| `DAT_00d6a9ec` | `CSiegeFortressMgr` | `0x0062e417` |
| `DAT_00d6aa00` | `CServerEvent_Middleman` | `0x0066f19a` |

`DAT_00d6a9ec` reaches the same conclusion by the same shape; its `xor ebx,ebx` sits
0x3e bytes before the store, with no reassignment in between.

## What is NOT resolved

These globals have a `GetSingleton_*` reader but no destructor that both installs a
vtable and clears them, so they are left unnamed rather than guessed:

	DAT_00d6a8e8
	DAT_00d6a954
	DAT_00d6a96c
	DAT_00d6a970
	DAT_00d6a978
	DAT_00d6a97c
	DAT_00d6a980
	DAT_00d6a984
	DAT_00d6a9b4
	DAT_00d6a9f4
	DAT_00d6a9f8
	DAT_00d6a9fc
	DAT_00d6aa14
	DAT_00d6aa18
	DAT_00d6aa1c

`DAT_00d6aa18` is among them. The *loose* sweep pointed at `CShardDB` from its writer and
`CTableKeeper` from a nearby constructor, which is exactly the ambiguity the strict test
exists to reject. The registry section below rests on different evidence — the assert
strings and `GetTableName` — and is unaffected.

## What this settled

Of the 128 dispatch handlers still unnamed, **69 reach for one of these singletons**, and
the index blocks line up with the subsystems: guild `0x0f1`–`0x114` and `0x250`–`0x258`,
party `0x060`–`0x06d`, messenger `0x302`–`0x30c`, training camp `0x477`–`0x47e`, trade
`0x081`–`0x084`, open market `0x506`–`0x50c`. 50 were named from this.

Infrastructure singletons (`CLogBuilder`, `CMainProcess`, `COverlappedJobMgr`,
`CGObjFactory`, `CMap`, `CFormulae`, …) are reached from everywhere and identify nothing,
so they are excluded from that inference. `CSiegeFortressMgr` needed the same treatment
for a different reason: `SiegeFortressMgr::IsWarPeriodActive` is a **precondition guard**
used by guild and world handlers, so a handler counts as siege only when it reaches the
manager for something else too. Handler `0x053` was named `…SiegeMsg_053` by the first
pass on exactly that mistake, and is excluded by the rule that replaced it.

## The DB table registry at `DAT_00d6aa18`

**Refined 2026-09-18.** This page first called the array "manager singletons". It is more
specific than that: `CGameServer::vslot_011` is the DB initialisation step — it connects
through `ShardDB`, logs `"DB Connection Failed!"` and `"InitializeDB is Successful"`, and
asserts on this same global — and the per-table getters in `CGameServer::FUN_0073c…`
register their table into it, failing with `"DBTable Registering Failed: %s"` where the
`%s` is the class's own table-name string (see `GetTableName`, recovered the same day).
So the vector holds **registered DB tables**, which is why its entries line up with
systems: guild, training camp, siege, timed jobs.

Recovered 2026-09-18 while tracing `CEnchant_UpperReinforce`'s success rate.

`DAT_00d6aa18` is a global whose `+0x1c` / `+0x20` pair is a `std::vector` of pointers
to the server's manager and reference-table singletons. Code reaches a singleton by
index: `mov ecx,ds:0xd6aa18 ; mov edx,[ecx+0x1c] ; mov edx,[edx+<index*4>]`, with an
assert that the vector holds enough entries first.

**The readers identify the entries.** Nothing in the binary lists the array's contents,
but which class reads an index says what lives there. Mapped from every such access:

```
   +0x10   (entry 4  ) 18 site(s)   CGObjCOS_Summoned::ForceDropItem, CGObjMob::vslot_349, CGPCInventoryOP
   +0x14   (entry 5  )  2 site(s)   FUN_0059bfe0
   +0x1c   (entry 7  )  4 site(s)   AQ_CharDataLoader::FUN_0043e770, FUN_00477880
   +0x24   (entry 9  )  8 site(s)   AQ_ItemQuotation::vslot_006, CGObjNPCNPC::vslot_214, GObjNPCNPC::FUN_0
   +0x28   (entry 10 )  8 site(s)   CGObjPC::FUN_00570f10, CGObjPC::FUN_00571170, GObjPC::FUN_0056f9a0
   +0x2c   (entry 11 )  6 site(s)   CGuildMgrCommon::vslot_001, CMainProcess::FUN_005d20b0, FUN_005d0340
   +0x30   (entry 12 )  2 site(s)   CMainProcess::FUN_005ca3f0
   +0x34   (entry 13 )  6 site(s)   CGuildMgrCommon::vslot_001, CMainProcess::FUN_005ca5a0, FUN_005b8bf0
   +0x38   (entry 14 )  7 site(s)   CGuildManager::FUN_005d1c40, CGuildMgrCommon::vslot_001, CMainProcess:
   +0x3c   (entry 15 )  4 site(s)   CMainProcess::FUN_005d1490, FUN_005d0340
   +0x44   (entry 17 )  2 site(s)   CTimedJobManagerForPC::vslot_002
   +0x48   (entry 18 )  4 site(s)   AQ_CharDataLoader::FUN_0043e630, CTimedJobManagerForPet::vslot_002
   +0x50   (entry 20 )  4 site(s)   CMainProcess::FUN_005d6550, CMainProcess::FUN_005d6650
   +0x54   (entry 21 )  2 site(s)   AQ_CharDataLoader::FUN_00431340
   +0x58   (entry 22 )  6 site(s)   CMainProcess::FUN_005e4970, CTrainingCampCommon::FUN_005e3d90, CTraini
   +0x5c   (entry 23 )  6 site(s)   CMainProcess::FUN_005e0790, CMainProcess::FUN_005e0a30, CTrainingCampC
   +0x60   (entry 24 )  2 site(s)   AQ_TrainingCampQuery::vslot_006
   +0x68   (entry 26 )  4 site(s)   CWicket::FUN_00484500, FUN_00484610
   +0x6c   (entry 27 ) 10 site(s)   CRgnObject::FUN_00538c10, CTriggeredPortalSpawner::FUN_006435f0, FUN_0
   +0x74   (entry 29 )  2 site(s)   CQEV_PANDORA_BOX_100LV::CEventDaemonMgr__GenerateEventDaemon
   +0x84   (entry 33 )  1 site(s)   GObjPC::FUN_00408120
   +0x8c   (entry 35 )  4 site(s)   CPackageItem::FUN_008657e0, CShopApp::FUN_00867000
   +0x90   (entry 36 )  2 site(s)   AQ_CharDataLoader::FUN_004313b0
   +0x94   (entry 37 )  2 site(s)   CSiegeFortressMgr::FUN_0062e680
   +0x98   (entry 38 )  2 site(s)   CSiegeFortress::FUN_00628ee0
   +0x9c   (entry 39 )  2 site(s)   CSiegeFortress::FUN_00629100
   +0xa0   (entry 40 )  6 site(s)   AQ_Siege__QUERY_SIEGE_REQUEST_ADD, CSiegeFortress::FUN_00629340, GObjP
   +0xa4   (entry 41 )  4 site(s)   CSiegeFortress::FUN_00629590, GObjPC::AQ_Siege__QUERY_SIEGE_BATTLE_REC
   +0xa8   (entry 42 )  2 site(s)   FUN_00629a40
   +0xac   (entry 43 )  4 site(s)   CSiegeFortress::FUN_006297e0, GObjPC::AQ_Siege__QUERY_SIEGE_STONE_STAT
   +0xbc   (entry 47 )  2 site(s)   CGObjPC::vslot_214
   +0xc0   (entry 48 )  2 site(s)   AQ_CharDataLoader::FUN_0043eec0
   +0xcc   (entry 51 )  8 site(s)   CEnchant_SocketMaker::vslot_009, CEnchant_UpperReinforce::vslot_009, F
   +0xd0   (entry 52 )  4 site(s)   FUN_00618fe0, RefItemDrop::CRefDropData__AddAssignedItemDrop
   +0xd4   (entry 53 )  2 site(s)   CMainProcess::FUN_0066f9d0
   +0xd8   (entry 54 )  2 site(s)   CMainProcess::FUN_0066fce0
   +0xdc   (entry 55 )  4 site(s)   AQ_CharDataLoader::FUN_0043f1b0, GObjPC::FUN_0069e2d0
   +0xe0   (entry 56 )  2 site(s)   AQ_OpenMarket::FUN_00452e90
```

So entries cluster by system — guild at 11/13/14/15, training camp at 22/23/24, siege at
37-43, timed jobs at 17/18 — which is a useful index whenever a singleton needs
identifying.

## Entry 51 and the alchemy question

**Still unidentified as of 2026-09-18.** A probe looking for the per-table getter that
uses index 51 returned exactly one function, `FUN_004e0130`, and it is a **false
positive**: it reads `[param_1+0x34]+0xcc`, a record's own fields, not the table array at
`+0xc`. No getter indexes 51 through the array, so the table is registered some other way
and the identification did not fall out.

Entry 51 is read by exactly four functions:

	GObjPC::FUN_0042a730                 (twice)
	FUN_00477880                         (four times, a struct initialiser)
	CEnchant_SocketMaker::vslot_009      the socket maker's commit step
	CEnchant_UpperReinforce::vslot_009   the upper reinforce's commit step

That is how far the rate question goes for now: `UpperReinforce`'s outcome is decided in
its commit step, which consults **this** singleton, and the singleton is shared with the
socket maker rather than being alchemy-specific. **Which manager it is has not been
named** — neither non-alchemy reader names it, and the vector is filled elsewhere by
index rather than by a visible per-entry write.

## A probe note

The first version of the mapping scan returned **nothing at all**, because it allowed 14
instructions between the array load and the indexed read. In
`CEnchant_UpperReinforce::vslot_009` the two are about 20 apart. The empty result was a
fact about the window, and it was caught by comparing against an access already read by
hand.

## `DAT_00d6aa14`, which the strict test rejected (round 292, 2026-09-20)

The list above records this global as one the strict test could not identify.
It is still unidentified, but it is no longer featureless, and the facts are
worth having before the next attempt:

- **It is installed as a singleton.** `FUN_007158f0` (`0x007158f0`) asserts it
  is null and then sets `DAT_00d6aa14 = &DAT_00d16c80`, going on to initialise
  a run of members at that address.
- **Its object is in uninitialised `.data`.** `0xd16c80` lies past the section's
  raw size, so there is no vtable to read statically and **no RTTI to walk** --
  which is why the class-name levers that work elsewhere do not reach it.
- **It holds a vector of row pointers, indexed by level.**
  `CGObjCOS_GoldPet::vslot_215` and `GObjPC::FUN_004d6210` both do
  `rows[n]` out of it, bounds-checked by `(end - begin) >> 2`, and store the
  result on the object at `+0x1ce0`. `CGObjCOS_GoldPet::OffsetExpPoint` reads a
  64-bit at `row+8`/`+0xc` as a **per-level experience threshold**.
- It is referenced on **961 decompiled lines**, so it is a major singleton
  rather than a corner of one subsystem.

**What it is, from a use site (round 293).** `GObjPC::GObjPC_SetLevel` indexes
the same vector with `level - 1` and stores the row on the character at
`+0x1cb0`. So `DAT_00d6aa14` holds **the per-level row table**, indexed by
level, read by the character's own level-set and by the gold pet's experience
function alike. Six call sites index it that way
(`GObjPC_SetLevel`, `FUN_004d6210`, `FUN_004e6820`, `FUN_0060dd90`,
`CGObjCOS_GoldPet::vslot_215`, `OffsetExpPoint`).

By `refdata_tables.md`'s enumeration the per-level table is `_REFLEVEL`
(`leveldata.txt`). The link from this global to that loader is still not
traced: the rows are placed from further out than `0x0082afc0`, and no function
references both this global and a `"_REF…"` literal. `FUN_006f8950` frees the
vector's rows, so it is teardown rather than the fill.

**It has a named accessor** (round 296): `GetSingleton_00d6aa14` (`0x00404ca0`)
returns the singleton's `+0x10`. And its vector's `begin`/`end` sit at `+0x14`
and `+0x18` -- worth knowing before reading any sweep of this global, because
those are also the offsets a *row's* columns 3 and 4 would occupy, and the
decompiler routinely reuses one variable for the singleton and then the row it
indexes out of it.
