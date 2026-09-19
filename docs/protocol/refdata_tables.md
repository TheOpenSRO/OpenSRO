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

*What it is (round 238):* the `.rdata` run at `0xadda70..0xade3bc` is a table of
121 five-dword descriptors `{class-name, new-size, factory, 0x8364e0, table}`,
one per `CRef*`/`CInstanceUser` class, and each factory is
`operator new(new-size)` followed by the shared constructor `FUN_007350c0`. The
`0x30`/`0x18` a loader stores is that class's descriptor `new-size` -- the size
of its DB-record wrapper object, not of the row. The row itself is parsed
elsewhere, positionally, from a byte stream (for the tactics table into a
0xbc-byte struct: `docs/protocol/monster_ai.md`); the sizes that do vary
(`CRefSkill` 0x248, `CRefQuest` 0x108, `CRefMagicOpt` 0x200, `CRefGameWorld`
0x68, ...) are the wrappers that carry their row inline.

## The row parsers: how a table actually reaches the game (round 240)

The DB loaders above only name the tables. The rows reach the game as a byte
stream, and each table has a **positional parser** that reads its columns in
order -- `u8`/`u16`/`u32` by width, strings as a 2-byte length plus bytes
through `RefData_ReadStringField` (`0x6b2ef0`) -- into a freshly allocated
record. `CGameServer::LoadReferenceData` (`0x6bd920`) calls one *list loader*
per table in a fixed order; a list loader walks its rows calling a
*parse-and-insert* (`new` of the record size, the parser, a duplicate check, the
insert). Several tables travel as a **family** whose stream rows carry a kind
byte: the inserter switches on it and attaches the sub-rows to their parent
record (shops, shop tabs, shop groups, package items).

The catalogue below is every parser found by the cursor-advance shape
(`/var/tmp/parsers3.py` on the render box regenerates it). Widths are the read
sequence (`b`/`w`/`d`/`q` = 1/2/4/8 bytes; strings are not in the sequence but
are counted); the table column is filled only where the parser's own assert
string names it (`check _RefX` / `at RefX`) or a family inserter's case 0 does.
Column NAMES live in the database; the client's `textdata` files carry more
columns than the server reads (the shop tab's file has 7, the parser reads 5),
so the layouts here are the server's, not the files'.

| parser | table | cols (strings) | widths | record | inserter | list loader |
|---|---|---|---|---|---|---|
| `0x6a2e40` | | 11 (3) | `wbbbdddd` | 0xb0 | `0x6e33b0` | `0x6e33b0` |
| `0x6a3090` | `_RefObjCommon` (prefix) | 47 (5) | `ddbbbbbbdbbbbbbbbbbbbdddddddbdwwwwwwwdwwdd` | | | |
| `0x6a3d50` | `_RefObjItem` | 44 (1) | `ddbddbdddddddddddddddbbbbwddddddddddddddbbd` | | | |
| `0x6a58f0` | `_RefObjChar` | 31 (0) | `dbbdddbbbbbbbbwdddddddddddbdddd` | | | |
| `0x6a61b0` | `_RefMonster_AssignedItemDrop` | 10 (1) | `ddbbbbdwd` | 0x34 | `0x6b66a0` | `0x6e13e0` |
| `0x6a6660` | `_RefMagicOptByItemOptLevel` | 11 (3) | `bdbdbddd` | 0x70 | `0x6b6c40` | `0x6e14a0` |
| `0x6a68e0` | (magic-opt group + item refs) | 6 (1) | `bdddd` | 0x2c | `0x6b6a30` | `0x6e1510` |
| `0x6a6aa0` | `_RefMonster_AssignedItemRndDrop` | 10 (1) | `bddbbbddd` | 0x34 | `0x6b68f0` | `0x6e1580` |
| `0x6a6d10` | `_RefCustomizingReservedItemDropForMonster` | 5 (0) | `dbdbd` | 0x24 | `0x6b67e0` | `0x6e1440` |
| `0x6a6e10` | (SetMagicMask / MagicGroupID rows) | 9 (4) | `bdbdd` | 0x14 | `0x6b6db0` | `0x6e0690` |
| `0x6a7460` | | 10 (0) | `ddddbbbddd` | 0x1c | `0x6b5200` | `0x6e04e0` |
| `0x6a7650` | (`TELEPORT` string, `dwID != 0`) | 6 (3) | `ddd` | 0xe0 | `0x6e3650` | `0x6e3650` |
| `0x6a7980` | (`dwID != 0`) | 4 (2) | `bd` | 0x3c | `0x6e3730` | `0x6e3730` |
| `0x6a7ab0` | | 5 (1) | `bdbb` | 0x24 | `0x6e3810` | `0x6e3810` |
| `0x6a7be0` | `_RefTeleport` | 13 (1) | `dd S d wwwww bb w b` | 0x4c | `0x6e3570` | `0x6e3570` |
| `0x6a8300` | `_RefTreatItemOfShop` | 3 (1) | `bd` | 0xd4 (shop family case 3) | `0x6b4590` | `0x6dfcb0` |
| `0x6a84d0` | `_RefAccessPermissionOfShop` | 3 (1) | `bd` | 0x94 (shop family case 2) | `0x6b4590` | `0x6dfcb0` |
| `0x6a8690` | `_RefRewardPolicyToSellPackageItem` | 3 (1) | `bd` | 0x94 (package family case 3) | `0x6b41b0` | `0x6dfac0` |
| `0x6a8850` | | 2 (0) | `bd` | 0xd0 | `0x6b58d0` | `0x6dff00` |
| `0x6a88e0` | `_RefConditionToSellPackageItem` | 3 (1) | `bd` | 0x94 (package family case 4) | `0x6b41b0` | `0x6dfac0` |
| `0x6a8ae0` | | 5 (2) | `bdd` | 0x54 | `0x6b4fe0` | `0x6dfb40` |
| `0x6a8b80` | `_RefPricePolicyOfItem` | 7 (2) | `bdddd` | 0x98 (package family case 2) | `0x6b41b0` | `0x6dfac0` |
| `0x6a8d80` | `_RefScrapOfPackageItem` | 11 (3) | `bdbqdbqd` | 0x110 (package family case 1) | `0x6b41b0` | `0x6dfac0` |
| `0x6a94a0` | `_RefPackageItem` | 8 (3) | `bddwd` | 0x188 (package family case 0) | `0x6b41b0` | `0x6dfac0` |
| `0x6a9ab0` | `_RefShopGoods` | 7 (3) | `bdbd` | 0xcc (tab family) | `0x6b4950` | `0x6dfc30` |
| `0x6a9d80` | `_RefShopTab` | 5 (2) | `bdd` | 0x58 (tab family) | `0x6b4950` | `0x6dfc30` |
| `0x6a9e80` | `_RefShop` | 6 (2) | `bddd` | 0xd4 (shop family case 0) | `0x6b4590` | `0x6dfcb0` |
| `0x6a9fb0` | `_RefShopGroup` | 7 (3) | `bdwd` | 0xbc (group family) | `0x6b4d20` | `0x6dfd30` |
| `0x6aa1f0` | `_RefMappingShopGroup` | 4 (2) | `bd` | (group family) | `0x6b4d20` | `0x6dfd30` |
| `0x6aa300` | `_RefMappingShopWithTab` | 4 (2) | `bd` | (shop family case 1) | `0x6b4590` | `0x6dfcb0` |
| `0x6aa410` | | 8 (2) | `bddb` | 0x68 | `0x6e3030` | `0x6e3030` |
| `0x6aa550` | | 4 (0) | `bddd` | 0xc | `0x6e3ab0` | `0x6e3ab0` |
| `0x6aa620` | | 3 (0) | `bdd` | 0xc | `0x6e3b10` | `0x6e3b10` |
| `0x6aa6d0` | | 2 (0) | `dd` | 0xc | `0x6e3be0` | `0x6e3be0` |
| `0x6aa960` | | 9 (0) | `dbddddbww` | 0x30 | `0x6e39d0` | `0x6e39d0` |
| `0x6aaab0` | `_RefTactics` | 43 (1) | see `monster_ai.md` | 0xbc | `0x6e38f0` | `0x6e0700` |
| `0x6ab230` | `_RefNest` | 17 (0) | `dddwdddwddddddbbb` | 0x3c | `0x6e3110` | |
| `0x6ab4b0` | | 5 (1) | `dbdd` | 0x2c | `0x6b5570` | `0x6e07e0` |
| `0x6ab9f0` | | 3 (0) | `bdb` | 0x64 | `0x6b6610` | `0x6e0d10` |
| `0x6abb50` | | 5 (1) | `bbdb` | 0x2c | `0x6e31f0` | `0x6e31f0` |
| `0x6abc00` | | 4 (1) | `bbd` | 0x28 | `0x6e32d0` | `0x6e32d0` |
| `0x6abd20` | (`CLAMP()` assert) | 9 (1) | `bddwwdbd` | 0x9c | `0x6b54c0` | `0x6e0e10` |
| `0x6ac880` | (`Invalid Region!![ID:%d][ObjName128:%s]`) | 11 (1) | `ddwwwwwwwd` | 0x40 | `0x6e40f0` | `0x6e40f0` |
| `0x6acaa0` | | 17 (2) | `dwwwwdddddddddd` | 0x6c | `0x6b7400` | `0x6e16d0` |
| `0x6accd0` | | 6 (4) | `dd` | 0x74 | `0x6b76f0` | `0x6e17f0` |
| `0x6acd70` | | 3 (0) | `ddd` | 0x54 | `0x6e1740` | `0x6e1740` |
| `0x6ace10` | (`CMakeStuff_ResolveEquip`) | 13 (4) | `bbddddqqq` | 0xa0 | `0x6bf2b0` | `0x6bf2b0` |
| `0x6ad010` | | 14 (1) | `bdbdbbwdbdb` | 0x5c | `0x6b79b0` | `0x6e1860` |
| `0x6ad630` | | 9 (1) | `ddbbdb` | 0x3c | `0x6b7d30` | `0x6e1980` |
| `0x6ad880` | (`TEMPLE_ANUBIS`) | 18 (4) | `bddddddbbbbddd` | 0x9c | `0x6b7e50` | `0x6e1a00` |
| `0x6adb60` | | 12 (5) | `bdbdddd` | 0x8c | `0x6b7f80` | `0x6e1a70` |
| `0x6ade00` | | 16 (3) | `bdddddbbbbddd` | 0x7c | `0x6b8250` | `0x6e1ae0` |
| `0x6ae030` | | 10 (4) | `bddddd` | 0x6c | `0x6b8370` | `0x6e1b50` |
| `0x6ae280` | | 7 (4) | `bdd` | 0x8c | `0x6b8540` | `0x6e1bc0` |
| `0x6ae350` | | 7 (5) | `bd` | 0x98 | `0x6b8720` | `0x6e1c30` |
| `0x6ae460` | | 5 (2) | `ddd` | 0x40 | `0x6b8b30` | `0x6e1dc0` |
| `0x6ae510` | | 7 (2) | `ddbbd` | 0x44 | `0x6b8cd0` | `0x6e1ee0` |
| `0x6ae5f0` | | 4 (0) | `dddd` | 0xc | `0x6e24b0` | `0x6e24b0` |
| `0x6ae6a0` | | 8 (2) | `ddwwww` | 0x44 | `0x6b9040` | `0x6e21d0` |
| `0x6ae7b0` | | 3 (0) | `ddd` | 0x8 | `0x6e2240` | `0x6e2240` |
| `0x6ae830` | | 7 (3) | `dddw` | 0x60 | `0x6b91e0` | `0x6e22f0` |
| `0x6ae900` | | 6 (4) | `dd` | 0x74 | `0x6b97e0` | `0x6e2440` |
| `0x6ae9a0` | | 5 (1) | `dddd` | 0x28 | `0x6b93b0` | `0x6e2360` |
| `0x6aea60` | | 7 (3) | `dddd` | 0x60 | `0x6b8e70` | `0x6e1f50` |
| `0x6b3d40` | | 8 (0) | `ddbbbbbb` | 0x540 | `0x6b3d40` | `0x6e03f0` |

Nineteen of these are named (`recovered_names.tsv`, `RefX_ExtractData`, with
their inserters and list loaders). The blank rows are the next lever: a row's
table is settled by an assert string inside it, by a family inserter's case
number, or by a use-site that reads the record -- never by matching column
counts against the client's files, which read more columns than the server
does.

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
