# The database column names are in the binary

`SR_GameServer.exe` carries its runtime schema as a contiguous, 4-byte-aligned
string pool in `.rdata` at **`0x00b11b08`–`0x00b12a70`**: **310 identifiers**, of
which **54 are table names** and the rest are column names.

**The pool is not the whole schema, and 54 is not the runtime table count (round
307).** The 56 `DB_Bind__<TABLE>` binders cover **59 tables**: the 54 here plus
`_OpenMarket`, `_ShopItemStockQuantity`, `_RentItemInfo`, `_ChestInfo` and
`_BindingOptionWithItem`, none of which appears anywhere in the 310 strings.
They are not missing by accident — their binders declare the table name as an
**inline literal** instead of a pointer into the pool, and a literal never gets
registered. `_ChestInfo` corroborates from two directions: the warehouse work
had already cited its binder at `0x8586e0`, which the binder sweep found
independently.

**And the binders give the full column list the pool cannot.** See
`docs/protocol/db_bind_columns.tsv` — 56 binders, 409 columns, with the `_CHAR`
control landing exactly on `character_schema.md`'s 42 plus the key `CharID`.
**Round 308 added the struct offsets** (`db_bind_offsets.tsv`), which also
settled the `Name*N` question: `_ITEMS` `MagParam` is twelve rows at
`0x60`–`0xb8`, an exact 8-byte stride, directly after the `MagParamNum` count
field at `0x58`.

Extracted into `server/internal/persistence` (`ColumnPool`, `TableColumns`,
`SchemaTableOrder`), with tests that would catch a regenerated pool losing a
name another spec cites.

## Why the names are in the binary and the indices are not

`Database::FUN_00972b40` binds a table's schema **by name**:

	numCols = Ordinal_13(stmt);                   // an ODBC import
	for (rec = schema.begin; rec != schema.end; rec += 0x54) {
	    name = (rec[0x18] < 0x10) ? rec + 4 : *(char **)(rec + 4);   // declared
	    if (CompareStringA(0x400, 0x10001, name, ..., odbcName, ...) == 2) {
	        rec[0x2c] = (short)...;
	        rec[0x30] = odbcColumnIndex;          // <- the index comes from ODBC
	        rec[0x34] = ...;                      // a skip flag
	    }
	}

So **the executable declares the names and the live database supplies the
ordinals**. `ODBC32.dll` is imported by ordinal, 18 functions, and the column
metadata is fetched at runtime.

That settles, from the other side, the question the previous two ticks were
chasing: a **static column index is not recoverable from the binary**, because
the binary does not have one. It matches on the name and takes whatever position
the database reports. A column **name**, on the other hand, is right there.

## The column record

`FUN_006b1a80` walks the same records to skip a column, which is what fixes the
layout:

| offset | what | how known |
|---|---|---|
| `+0x04` | column **name**, an SSO `std::string` | read by the SQL builder and compared by the binder |
| `+0x18` | that string's capacity | the `< 0x10` SSO test |
| `+0x24` | column **width** | added to the stream cursor when skipping |
| `+0x2c` | an ODBC-reported value | written by the binder |
| `+0x30` | column **index** | matched against `stream->col + 1`; written by the binder |
| `+0x34` | a flag: `1` excludes the column | tested before emitting a name into `INSERT` |

Record stride is `0x54`, and the arrays are bounded by `[0x4c]`/`[0x50]` on a
schema node.

## THE POOL IS DEDUPLICATED — read this before using the table below

Each name appears **once, at first use**. So the table below gives the names
each table **introduces**, not its full column list. The binders do give the
full list (`db_bind_columns.tsv`, round 307), including for the seven tables
that introduce nothing at all. `_TIMEDJOBFORPET` and
`_INVENTORYFORAVATAR` list nothing at all because every name they use was
already pooled by `_TIMEDJOB` and `_INVENTORY`, and shared names (`ID`,
`CharID`, `Slot`, `Data1`, `Data2`) belong to many tables.

Recovering a complete per-table list means reading the schema-construction code
that references these literals. That is not done, and nothing here should be
read as a column count.

## The pool

| table | new names | the names it introduces |
|---|---:|---|
| `_USER` | 1 | `CharID` |
| `_CHAR` | 42 | `Deleted`, `RefObjID`, `CharName16`, `NickName16`, `Scale`, `CurLevel`, `MaxLevel`, `ExpOffset`, `SExpOffset`, `Strength`, `Intellect`, `RemainGold`, `RemainSkillPoint`, `RemainStatPoint`, `RemainHwanCount`, `GatheredExpPoint`, `HP`, `MP`, `LatestRegion`, `PosX`, `PosY`, `PosZ`, `AppointedTeleport`, `AutoInvestExp`, `InventorySize`, `DailyPK`, `TotalPK`, `PKPenaltyPoint`, `GuildID`, `LastLogout`, `TelRegion`, `TelPosX`, `TelPosY`, `TelPosZ`, `DiedRegion`, `DiedPosX`, `DiedPosY`, `DiedPosZ`, `WorldID`, `TelWorldID`, `DiedWorldID`, `HwanLevel` |
| `_CHARCOS` | 9 | `ID`, `OwnerCharID`, `RefCharID`, `KeeperNPC`, `State`, `Lvl`, `HGP`, `PetOption`, `RentEndTime` |
| `_INVENTORY` | 1 | `Slot` |
| `_INVENTORYFORAVATAR` | 0 | *(introduces none — reuses a sibling's)* |
| `_INVENTORYFORLINKEDSTORAGE` | 0 | *(introduces none — reuses a sibling's)* |
| `_CHEST` | 0 | *(introduces none — reuses a sibling's)* |
| `_INVCOS` | 0 | *(introduces none — reuses a sibling's)* |
| `_ITEMQUOTATION` | 9 | `Service`, `AssocNPC`, `RefItemID`, `BaseQuot`, `Quot_LB`, `Quot_UB`, `BaseStockAmount`, `FluctuateAmount`, `CurStockAmount` |
| `_ITEMS` | 8 | `ID64`, `OptLevel`, `Variance`, `Data`, `CreaterName`, `MagParamNum`, `MagParam`, `Serial64` |
| `_CHARSKILL` | 2 | `SkillID`, `Enable` |
| `_CHARSKILLMASTERY` | 2 | `MasteryID`, `Level` |
| `_STRUCT` | 0 | *(introduces none — reuses a sibling's)* |
| `_DUMMY` | 0 | *(introduces none — reuses a sibling's)* |
| `_EVENTDAEMON` | 0 | *(introduces none — reuses a sibling's)* |
| `_SIEGEFORTRESSSTRUCT` | 4 | `FortressID`, `OwnerGuildID`, `RefEventStructID`, `MakeDate` |
| `_CHARQUEST` | 7 | `QuestID`, `Status`, `AchievementCount`, `StartTime`, `EndTime`, `QuestData1`, `QuestData2` |
| `_TRAININGCAMP` | 7 | `CreationDate`, `Rank`, `GraduateCount`, `EvaluationPoint`, `LatestEvaluationDate`, `CommentTitle`, `Comment` |
| `_TRAININGCAMPMEMBER` | 7 | `CampID`, `JoinDate`, `MemberClass`, `CharJoinedLevel`, `CharCurLevel`, `CharMaxLevel`, `HonorPoint` |
| `_TRAININGCAMPHONORRANK` | 1 | `Ranking` |
| `_TRAININGCAMPBUFFSTATUS` | 6 | `RecipientCharID`, `BuffSlotIdx`, `DonorCharID`, `StartingTime`, `RemainBuffPoint`, `BuffType` |
| `_GUILD` | 10 | `Name`, `GatheredSP`, `FoundationDate`, `Alliance`, `MasterCommentTitle`, `MasterComment`, `Booty`, `LastCrestRev`, `CurCrestRev`, `MercenaryAttr` |
| `_GUILDMEMBER` | 8 | `CharLevel`, `GP_Donation`, `Permission`, `Contribution`, `GuildWarKill`, `GuildWarKilled`, `Nickname`, `SiegeAuthority` |
| `_ALLIEDCLANS` | 1 | `Ally` |
| `_GUILDWAR` | 8 | `WarType`, `VictoryPointIndex`, `LodgedGold`, `WarEndTime`, `Guild`, `PointGain`, `Data1`, `Data2` |
| `_GUILDCHEST` | 0 | *(introduces none — reuses a sibling's)* |
| `_Friend` | 2 | `FriendCharID`, `FriendCharName` |
| `_GPHistory` | 3 | `UsedTime`, `UsedGP`, `Reason` |
| `_Memo` | 3 | `FromCharName`, `Message`, `Date` |
| `_DELETEDCHAR` | 1 | `DeletedDate` |
| `_TIMEDJOB` | 10 | `Category`, `JobID`, `TimeToKeep`, `Data3`, `Data4`, `Data5`, `Data6`, `Data7`, `Data8`, `JID` |
| `_TIMEDJOBFORPET` | 0 | *(introduces none — reuses a sibling's)* |
| `_STATICAVATAR` | 1 | `Param1` |
| `_CharInstanceWorldData` | 7 | `DungeonKeyID`, `LayerID`, `OpenedTime`, `RegionID`, `IsActivated`, `EnterCount`, `LastEnterTime` |
| `_CharTrijob` | 3 | `JobType`, `Exp`, `Reward` |
| `_FleaMarketNetwork` | 6 | `AbleOpen`, `TidGroupID`, `ItemClass`, `ItemCount`, `MakeZone`, `Cash` |
| `_SiegeFortress` | 8 | `TaxRatio`, `Tax`, `NPCHired`, `TempGuildID`, `Introduction`, `CreatedDungeonTime`, `CreatedDungeonCount`, `IntroductionModificationPermission` |
| `_SiegeFortressObject` | 3 | `Region`, `Direction`, `OwnerLevel` |
| `_SiegeFortressItemForge` | 5 | `ItemRefID`, `Amount`, `Finished`, `StartDate`, `FinishDate` |
| `_SiegeFortressRequest` | 1 | `RequestType` |
| `_SiegeFortressBattleRecord` | 4 | `KillCount`, `KilledCount`, `RankUpDate`, `CurRank` |
| `_SiegeFortressStoneState` | 2 | `AccumulateDamage`, `ChestSize` |
| `_ServerEvent` | 3 | `CompletionValue`, `AchievementCondition`, `ProgressCount` |
| `_ServerEventReward` | 3 | `ServerEventID`, `RewardID`, `RemainRewardTime` |
| `_LOGEVENTCHAR` | 4 | `EventTime`, `EventID`, `EventPos`, `strDesc` |
| `_LOGEVENTITEM` | 6 | `dwData`, `TargetStorage`, `Operation`, `Slot_From`, `Slot_To`, `Gold` |
| `_LOGEVENTSIEGEFORTRESS` | 0 | *(introduces none — reuses a sibling's)* |
| `_LOGSERVEREVENT` | 1 | `LogType` |
| `_LogSchedule` | 5 | `ServerType`, `ServerBodyID`, `ScheduleDefine`, `ScheduleIdx`, `OccureTime` |
| `_ClientConfig` | 3 | `ConfigType`, `SlotSeq`, `SlotType` |
| `_BlockedWhisperers` | 7 | `OwnerID`, `TargetName`, `Country`, `RefShopGroupCodeName`, `RefPackageItemCodeName`, `ConstStockQuantity`, `StockQuantity` |
| `_CharTrijobSafeTrade` | 2 | `AbleCount`, `LastSafeTrade` |
| `_AssociationReputation` | 28 | `AssociationCodeName`, `Reputation`, `PriorOccupation`, `nItemDBID`, `bOptType`, `nSlot`, `nOptID`, `nOptLvl`, `nOptValue`, `nParam1`, `nParam2`, `nRentType`, `nCanDelete`, `nCanRecharge`, `PeriodBeginTime`, `PeriodEndTime`, `MeterRateTime`, `nPackingState`, `nPackingTime`, `PersnalID`, `ItemID`, `SellCnt`, `RegDate`, `EndDate`, `Price`, `Deposit`, `SellFee`, `UseCash` |
| `_CharCollectionBook` | 2 | `ThemeID`, `SlotIndex` |

## No reference table declares a column name, and that is structural

**Not one of the 85 `_REF*` tables appears in the pool.** They sit elsewhere in
`.rdata` as a bare run of table names with nothing between them — table name,
table name, table name — while the 54 runtime tables each carry their columns.

The reason is in `Database::BuildStatement`: a table with no column records is
queried with

	SELECT * FROM %s

and the reference loaders consume the result **positionally**, through the
field-by-field `ExtractData` deserializers. The server never needs a reference
table's column names, so the binary does not carry them.

**This closes the item-column-naming question for good.** Three ticks looked for
a way to name or index `_REFOBJITEM`'s columns — by counting binary fields, then
by the per-column schema. Neither could work, and now the reason is one fact
rather than two failures: *the server does not know those names either.*

What a reference-table column can still be identified by is its **offset in the
deserialised record**, which `client/tools/re/fields.py` reads and which
`alchemy.md` and `durability.md` already cite. An offset is enough to implement
against; a name would only have been nicer.

## What this closes elsewhere

| spec | what it said was unrecovered | the name now in hand |
|---|---|---|
| `timed_jobs.md` | "what the thirteen non-timestamp columns are" | `Category`, `JobID`, `TimeToKeep`, `Data3`…`Data8`, `JID` — and `TimeToKeep` is the obvious candidate for the one `%I64d` |
| `siege.md` | the dungeon caps "are read from a structure, not compared against literals" | `_SiegeFortress.CreatedDungeonCount` and `.CreatedDungeonTime` name the fields the caps are compared against |
| `academy.md` | which of the two membership levels is the master role | `_TRAININGCAMPMEMBER.MemberClass` names the field that distinguishes them |
| `academy.md` | "honour points: how they are earned, what the ranks are" | `HonorPoint`, `Rank`, `GraduateCount`, `EvaluationPoint`, `_TRAININGCAMPHONORRANK.Ranking` |
| `guild.md` | the permission bitmask's storage | `_GUILDMEMBER.Permission`, alongside `Contribution`, `GP_Donation`, `SiegeAuthority` |

**These are names, not values.** None of them gives a number, and each spec says
so where it cites one. Naming the field a cap is compared against is not the
same as knowing the cap.
