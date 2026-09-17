# The server's reference-table catalogue

Every reference table `SR_GameServer.exe` loads, with the class it loads into and
the address of its loader. **85 tables.** This is the server's entire
reference-data surface: if a value is not in one of these, the server does not
read it from reference data at all.

## How it was found, and why it is a census rather than a sample

Each loader has the same shape — it builds its table's name and hands it to the
generic reader:

	008341b0  DB_Load_RefQuest
	            FUN_00401fc0("_REFQUEST", 9);        <- name, length
	            _DAT_00d1b7b8 = &PTR_s_CRefQuest_…;  <- the class it fills

Finding every function that names a `_REF*` table therefore finds every table the
server loads. That is what makes the list below an **enumeration**: not "these
are the tables we found", but "these are the tables that exist".

**A constant that is NOT a record size.** Each loader also stores `0x30` or
`0x18` near the class pointer, and it is tempting to read that as the record
width. It is not: `_REFOBJITEM` — the item table with 160 columns — and
`_REFCLIMATE` carry the same `0x30`/`0x18` pair as everything else, and the
value does not vary with table complexity. It is an allocator constant. Recorded
because the wrong reading was made and discarded during this pass.

## What is NOT here

There is **no quest-objective table**. The quest-related entries are exactly
four — `_REFQUEST`, `_REFCHARDEFAULT_QUEST`, `_REFSIEGEQUEST`,
`_REFSIEGEQUESTREWARD` — and none of them is a list of objectives.

Combined with the client's two quest files, which were checked the same day:

| source | rows | objectives? |
|---|---|---|
| `questdata.txt` | 696 | no — id, codename, required level, title, `SN_*` text ids. A scan of all 12 columns for `MOB_`/`ITEM_`/`NPC_` codenames returns nothing |
| `questcontentsdata.txt` | 989 | no — the quest's description text, up to eight `SN_CON_*` string-id slots |
| the server's 85 reference tables | — | **no** |

So this project's standing conclusion, *quest objectives are code, not data*, is
now settled by **enumerating the server's whole reference surface** rather than
by failing to find a table. That is the same strong form as the stored-procedure
enumeration that settled starting Str: not "we looked and it was not there", but
"here is everything there is, and it is not among it".

## The tables

| table | class | loader |
|---|---|---|
| `_REFABILITYBYITEMOPTLEVEL` | `CRefAbilityByItemOptLevel` | `0x008383b0` |
| `_REFACCESSPERMISSIONOFSHOP` | `CRefAccessPermissionOfShop` | `0x0082ee30` |
| `_REFALCHEMYMERIT` | `CRefAlchemyMerit` | `0x008397a0` |
| `_REFCHARDEFAULT_QUEST` | `CRefDefaultQuest` | `0x0082dec0` |
| `_REFCHARGEN` | `CRefCharGenData` | `0x0082b4c0` |
| `_REFCLIMATE` | `CRefClimate` | `0x0082b240` |
| `_REFCONDITIONTOBUYSCRAPITEM` | `CRefConditionToBuyScrapItem` | `0x0082f7f0` |
| `_REFCONDITIONTOSELLPACKAGEITEM` | `CRefConditionToSellPackageItem` | `0x0082f580` |
| `_REFCONDITIONTOSELLSCRAPITEM` | `CRefConditionToSellScrapItem` | `0x0082fcd0` |
| `_REFCUSTOMIZINGRESERVEDITEMDROPFORMONSTER` | `CRefCustomizingReservedItemDropF` | `0x0082c100` |
| `_REFDROPCLASSSEL_ALCHEMY_ATTRSTONE` | `CRefDropClassSel_AlchemyATTRSton` | `0x00832d90` |
| `_REFDROPCLASSSEL_ALCHEMY_MAGICSTONE` | `CRefDropClassSel_AlchemyMagicSto` | `0x00832b20` |
| `_REFDROPCLASSSEL_ALCHEMY_TABLET` | `CRefDropClassSel_AlchemyTablet` | `0x008328b0` |
| `_REFDROPCLASSSEL_AMMO` | `CRefDropClassSel_Ammo` | `0x00832160` |
| `_REFDROPCLASSSEL_CURE` | `CRefDropClassSel_Cure` | `0x00831ef0` |
| `_REFDROPCLASSSEL_EQUIP` | `CRefDropClassSel_Equip` | `0x008317a0` |
| `_REFDROPCLASSSEL_RAREEQUIP` | `CRefDropClassSel_RareEquip` | `0x00831a10` |
| `_REFDROPCLASSSEL_RECOVER` | `CRefDropClassSel_Recover` | `0x00831c80` |
| `_REFDROPCLASSSEL_REINFORCE` | `CRefDropClassSel_Reinforce` | `0x00832640` |
| `_REFDROPCLASSSEL_SCROLL` | `CRefDropClassSel_Scroll` | `0x008323d0` |
| `_REFDROPGOLD` | `CRefDropGold` | `0x008312c0` |
| `_REFDROPITEMASSIGN` | `CRefDropItemAssign` | `0x00833000` |
| `_REFDROPITEMGROUP` | `CRefDropItemGroup` | `0x0082c5e0` |
| `_REFDROPOPTLVLSEL` | `CRefDropOptLevelSel` | `0x00831530` |
| `_REFEVENT` | `CRefEvent` | `0x0082dc50` |
| `_REFEVENTZONE` | `CRefEventZone` | `0x0082d9e0` |
| `_REFGACHACODE` | `CRefGachaCode` | `0x00835fb0` |
| `_REFGACHAITEMSET` | `CRefGachaItemSet` | `0x00836280` |
| `_REFGACHANPCMAP` | `CRefGachaNpcMap` | `0x00836510` |
| `_REFGAMEWORLDNPC` | `CRefGameWorldNPC` | `0x00839050` |
| `_REFGAME_WORLD` | `CRefGameWorld` | `0x008346b0` |
| `_REFGAME_WORLD_CONFIG` | `CRefGameWorldConfig` | `0x00839530` |
| `_REFHWANLEVEL` | `CRefHWANLevel` | `0x00834440` |
| `_REFINSTANCE_WORLD_REGION` | `CRefInstanceWorldRegion` | `0x00834940` |
| `_REFINSTANCE_WORLD_START_POS` | `CRefInstanceWorldStartPos` | `0x00834bc0` |
| `_REFLEVEL` | `CRefLevel` | `0x0082afc0` |
| `_REFMAGICOPT` | `CRefMagicOpt` | `0x0082cfb0` |
| `_REFMAGICOPTASSIGN` | `CRefMagicOptAssign` | `0x0082d250` |
| `_REFMAGICOPTBYITEMOPTLEVEL` | `CRefMagicOptByItemOptLevel` | `0x00838620` |
| `_REFMAGICOPTGROUP` | `CRefMagicOptGroup` | `0x0082c850` |
| `_REFMAPPINGSHOPGROUP` | `CRefMappingShopGroup` | `0x0082e950` |
| `_REFMAPPINGSHOPWITHTAB` | `CRefMappingShopWithTab` | `0x00830690` |
| `_REFMONSTER_ASSIGNEDITEMDROP` | `CRefMonster_AssignedItemDrop` | `0x0082be90` |
| `_REFMONSTER_ASSIGNEDITEMRNDDROP` | `CRefMonster_AssignedItemRndDrop` | `0x0082c370` |
| `_REFOBJCHAR` | `CRefObjChar` | `0x0082bc20` |
| `_REFOBJCHAREXTRASKILL` | `CRefObjCharExtraSkill` | `0x008392c0` |
| `_REFOBJCOMMON` | `CRefObjCommon` | `0x0082b730` |
| `_REFOBJITEM` | `CRefObjItem` | `0x0082b9b0` |
| `_REFOBJSTRUCT` | `CRefObjStruct` | `0x0082cd30` |
| `_REFOPTIONALTELEPORT` | `CRefOptionalTeleport` | `0x00838b00` |
| `_REFPACKAGEITEM` | `CRefPackageItem` | `0x008301b0` |
| `_REFPRICEPOLICYOFITEM` | `CRefPricePolicyOfItem` | `0x0082ff40` |
| `_REFQUEST` | `CRefQuest` | `0x008341b0` |
| `_REFREGION` | `CRefRegion` | `0x0082ac50` |
| `_REFREGIONBINDASSOCSERVER` | `CRefRegionBindAssocServer` | `0x00834e40` |
| `_REFREWARDPOLICYTOBUYSCRAPITEM` | `CRefRewardPolicyToBuyScrapItem` | `0x0082f310` |
| `_REFREWARDPOLICYTOSELLPACKAGEITEM` | `CRefRewardPolicyToSellPackageIte` | `0x0082f0a0` |
| `_REFREWARDPOLICYTOSELLSCRAPITEM` | `CRefRewardPolicyToSellScrapItem` | `0x0082fa60` |
| `_REFSCRAPOFPACKAGEITEM` | `CRefScrapOfPackageItem` | `0x00830420` |
| `_REFSETITEMGROUP` | `CRefSetItemGroup` | `0x0082cac0` |
| `_REFSHARDCONTENTCONFIG` | `CRefShardContentConfig` | `0x00838dd0` |
| `_REFSHOP` | `CRefShop` | `0x00830de0` |
| `_REFSHOPGOODS` | `CRefShopGoods` | `0x00830900` |
| `_REFSHOPGROUP` | `CRefShopGroup` | `0x0082e6e0` |
| `_REFSHOPITEMSTOCKPERIOD` | `CRefShopItemStockPeriod` | `0x00831050` |
| `_REFSHOPOBJECT` | `CRefShopObject` | `0x0082e200` |
| `_REFSHOPTAB` | `CRefShopTab` | `0x00830b70` |
| `_REFSHOPTABGROUP` | `CRefShopTabGroup` | `0x0082e470` |
| `_REFSIEGEBLESSBUFF` | `CRefSiegeBlessBuff` | `0x00837960` |
| `_REFSIEGEDUNGEON` | `CRefSiegeDungeon` | `0x00837be0` |
| `_REFSIEGEFORTRESS` | `CRefSiegeFortress` | `0x008367a0` |
| `_REFSIEGEFORTRESSBATTLERANK` | `CRefSiegeFortressBattleRank` | `0x00836f30` |
| `_REFSIEGEFORTRESSGUARD` | `CRefSiegeFortressGuard` | `0x00836a30` |
| `_REFSIEGEFORTRESSITEMFORGE` | `CRefSiegeFortressItemForge` | `0x00836cb0` |
| `_REFSIEGEFORTRESSREWARDS` | `CRefSiegeFortressRewards` | `0x008376e0` |
| `_REFSIEGELVLSUMMONMONSTER` | `CRefSiegeLvlSummonMonster` | `0x00837460` |
| `_REFSIEGEQUEST` | `CRefSiegeQuest` | `0x00837e60` |
| `_REFSIEGEQUESTREWARD` | `CRefSiegeQuestReward` | `0x00838130` |
| `_REFSIEGESTRUCTUPGRADE` | `CRefSiegeStructUpgrade` | `0x008371d0` |
| `_REFSKILL` | `CRefSkill` | `0x00833f10` |
| `_REFSKILLBYITEMOPTLEVEL` | `CRefSkillByItemOptLevel` | `0x00838890` |
| `_REFSKILLMASTERY` | `CRefSkillMastery` | `0x00833c30` |
| `_REFTELELINK` | `CRefTeleLink` | `0x0082d770` |
| `_REFTELEPORT` | `CRefTeleport` | `0x0082d500` |
| `_REFTREATITEMOFSHOP` | `CRefTreatItemOfShop` | `0x0082ebc0` |

## Using it

For a value srrevamp needs, the table is the place to look first, and the loader
address is where to read how it is parsed. Eight of these have been read so far
(`_REFOBJCOMMON`/`_REFOBJITEM`/`_REFOBJCHAR` via the shared parser,
`_REFSHOP*` for the goods chain, `_REFQUEST`, `_REFCHARGEN`, `_REFDROPGOLD`);
the other 77 are unread, and the catalogue is what makes that a known quantity
rather than an open-ended search.


## 51 of the 85 are readable right now (2026-09-17)

This page has said "77 of 85 tables unread" since it was written, and that
conflated **not yet read** with **not readable**. Most of them were sitting in
`Media.pk2` the whole time.

Matching all 85 table names against the archive's
`server_dep\silkroad\textdata\` directory gives a clean partition:

| | count |
|---|---:|
| have a client file — **readable now** | **51** |
| server-only, the loot tables | 17 |
| server-only, other | 17 |

`server/internal/persistence` holds the mapping as `ClientTextdata`,
`ServerOnlyLootTables` and `ServerOnlyOtherTables`, with a test that the three
partition the 85 exactly.

Seven filenames could not be derived from the table name and were resolved by
reading the archive's own listing: `_REFTELELINK` is `teleportlink`,
`_REFOBJITEM` is `itemdata`, `_REFOBJCHAR` is `characterdata`, `_REFMAGICOPT` is
`magicoption`, `_REFMAGICOPTASSIGN` is `magicoptionassign`,
`_REFSIEGEFORTRESSREWARDS` is `siegefortressreward` (singular), and `_REFSHOP`
is `shopdata`.

### Every loot table is server-only, and that is measured

All **seventeen** tables with `DROP` in their name have no client file:

	_REFDROPCLASSSEL_ALCHEMY_ATTRSTONE   _REFDROPCLASSSEL_ALCHEMY_MAGICSTONE
	_REFDROPCLASSSEL_ALCHEMY_TABLET      _REFDROPCLASSSEL_AMMO
	_REFDROPCLASSSEL_CURE                _REFDROPCLASSSEL_EQUIP
	_REFDROPCLASSSEL_RAREEQUIP           _REFDROPCLASSSEL_RECOVER
	_REFDROPCLASSSEL_REINFORCE           _REFDROPCLASSSEL_SCROLL
	_REFDROPGOLD                         _REFDROPITEMASSIGN
	_REFDROPITEMGROUP                    _REFDROPOPTLVLSEL
	_REFMONSTER_ASSIGNEDITEMDROP         _REFMONSTER_ASSIGNEDITEMRNDDROP
	_REFCUSTOMIZINGRESERVEDITEMDROPFORMONSTER

**The probe was checked before the negative was believed**, as this project's
rules require: exactly **one** file in the whole of `Media.pk2` has "drop"
anywhere in its path, and it is not one of these. The reward files that do ship
(`refquestrewarditems`, `refeventreward`, `siegefortressreward`) are quest,
event and siege rewards, not monster loot.

So **drop rates are not recoverable from the client**, and that is by design
rather than by omission — you do not ship loot tables to players. A
reimplementation needs its own numbers or a real database, and this is the
citation for saying so.

### The other seventeen

	_REFALCHEMYMERIT  _REFCHARDEFAULT_QUEST  _REFCHARGEN  _REFCLIMATE
	_REFGACHACODE  _REFGAMEWORLDNPC  _REFINSTANCE_WORLD_REGION
	_REFINSTANCE_WORLD_START_POS  _REFOBJCHAREXTRASKILL  _REFOBJCOMMON
	_REFOBJSTRUCT  _REFREGIONBINDASSOCSERVER  _REFSHARDCONTENTCONFIG
	_REFSHOPOBJECT  _REFSIEGELVLSUMMONMONSTER  _REFSIEGEQUEST
	_REFSIEGEQUESTREWARD

One of these is explained rather than merely absent: **`_REFOBJCOMMON` has no
file because it is the shared prefix denormalised into `itemdata` and
`characterdata`**, which `docs/protocol/refobj_binary_format.md` established from
the other end. The rest are simply not shipped, and no reason is claimed.

### The full readable list

| table | file |
|---|---|
| `_REFABILITYBYITEMOPTLEVEL` | `refabilitybyitemoptleveldata.txt` |
| `_REFACCESSPERMISSIONOFSHOP` | `refaccesspermissionofshop.txt` |
| `_REFCONDITIONTOBUYSCRAPITEM` | `refconditiontobuyscrapitem.txt` |
| `_REFCONDITIONTOSELLPACKAGEITEM` | `refconditiontosellpackageitem.txt` |
| `_REFCONDITIONTOSELLSCRAPITEM` | `refconditiontosellscrapitem.txt` |
| `_REFEVENT` | `eventdata.txt` |
| `_REFEVENTZONE` | `eventzonedata.txt` |
| `_REFGACHAITEMSET` | `gachaitemset.txt` |
| `_REFGACHANPCMAP` | `gachanpcmap.txt` |
| `_REFGAME_WORLD` | `gameworlddata.txt` |
| `_REFGAME_WORLD_CONFIG` | `gameworldconfigdata.txt` |
| `_REFHWANLEVEL` | `hwanleveldata.txt` |
| `_REFLEVEL` | `leveldata.txt` |
| `_REFMAGICOPT` | `magicoption.txt` |
| `_REFMAGICOPTASSIGN` | `magicoptionassign.txt` |
| `_REFMAGICOPTBYITEMOPTLEVEL` | `refmagicoptbyitemoptleveldata.txt` |
| `_REFMAGICOPTGROUP` | `refmagicoptgroup.txt` |
| `_REFMAPPINGSHOPGROUP` | `refmappingshopgroup.txt` |
| `_REFMAPPINGSHOPWITHTAB` | `refmappingshopwithtab.txt` |
| `_REFOBJCHAR` | `characterdata.txt` |
| `_REFOBJITEM` | `itemdata.txt` |
| `_REFOPTIONALTELEPORT` | `refoptionalteleport.txt` |
| `_REFPACKAGEITEM` | `refpackageitem.txt` |
| `_REFPRICEPOLICYOFITEM` | `refpricepolicyofitem.txt` |
| `_REFQUEST` | `questdata.txt` |
| `_REFREGION` | `refregion.txt` |
| `_REFREWARDPOLICYTOBUYSCRAPITEM` | `refrewardpolicytobuyscrapitem.txt` |
| `_REFREWARDPOLICYTOSELLPACKAGEITEM` | `refrewardpolicytosellpackageitem.txt` |
| `_REFREWARDPOLICYTOSELLSCRAPITEM` | `refrewardpolicytosellscrapitem.txt` |
| `_REFSCRAPOFPACKAGEITEM` | `refscrapofpackageitem.txt` |
| `_REFSETITEMGROUP` | `refsetitemgroup.txt` |
| `_REFSHOP` | `shopdata.txt` |
| `_REFSHOPGOODS` | `refshopgoods.txt` |
| `_REFSHOPGROUP` | `shopgroupdata.txt` |
| `_REFSHOPITEMSTOCKPERIOD` | `refshopitemstockperiod.txt` |
| `_REFSHOPTAB` | `shoptabdata.txt` |
| `_REFSHOPTABGROUP` | `refshoptabgroup.txt` |
| `_REFSIEGEBLESSBUFF` | `refsiegeblessbuff.txt` |
| `_REFSIEGEDUNGEON` | `refsiegedungeon.txt` |
| `_REFSIEGEFORTRESS` | `siegefortress.txt` |
| `_REFSIEGEFORTRESSBATTLERANK` | `siegefortressbattlerank.txt` |
| `_REFSIEGEFORTRESSGUARD` | `siegefortressguard.txt` |
| `_REFSIEGEFORTRESSITEMFORGE` | `siegefortressitemforge.txt` |
| `_REFSIEGEFORTRESSREWARDS` | `siegefortressreward.txt` |
| `_REFSIEGESTRUCTUPGRADE` | `siegestructupgradedata.txt` |
| `_REFSKILL` | `skilldata.txt` |
| `_REFSKILLBYITEMOPTLEVEL` | `refskillbyitemoptleveldata.txt` |
| `_REFSKILLMASTERY` | `skillmasterydata.txt` |
| `_REFTELELINK` | `teleportlink.txt` |
| `_REFTELEPORT` | `teleportdata.txt` |
| `_REFTREATITEMOFSHOP` | `reftreatitemofshop.txt` |

`itemdata`, `characterdata` and `skilldata` are **sharded** — `itemdata_1000`,
`itemdata_5000` and so on — so the stem above is the family, not one file.
