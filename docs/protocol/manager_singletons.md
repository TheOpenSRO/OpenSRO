# The manager singleton array at `DAT_00d6aa18`

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
