# The server's own SQL: tables, keys and joins

Extracted from `SR_GameServer.exe` on 2026-09-16 -- **67 distinct statements
naming 25 tables**, read straight out of the binary's string table. This is the
least ambiguous evidence this project has about the game's database: the server
states its own column names, its own join conditions, and which id each table is
keyed by. Nothing here is inferred.

The statements are reproduced verbatim below (tabs collapsed), grouped by the
system they serve.


## Item containers, and how each is keyed

```sql
SELECT BIND.* FROM _Chest C JOIN _ITEMS IT ON C.ItemID=IT.ID64 JOIN _BindingOptionWithItem BIND ON IT.ID64=BIND.nItemDBID WHERE C.UserJID=%d AND C.ItemID IS NOT NULL AND C.ItemID<>0 ORDER BY C.Slot ASC
SELECT BIND.* FROM _GuildChest C JOIN _ITEMS IT ON C.ItemID=IT.ID64 JOIN _BindingOptionWithItem BIND ON IT.ID64=BIND.nItemDBID WHERE C.GuildID=%d AND C.ItemID IS NOT NULL AND C.ItemID<>0 ORDER BY C.Slot ASC
SELECT BIND.* FROM _InvCOS INV JOIN _ITEMS IT ON INV.ItemID=IT.ID64 JOIN _BindingOptionWithItem BIND ON IT.ID64=BIND.nItemDBID WHERE INV.COSID=%d AND INV.ItemID IS NOT NULL AND INV.ItemID<>0 ORDER BY INV.Slot ASC
SELECT BIND.* FROM _Inventory INV JOIN _ITEMS IT ON INV.ItemID=IT.ID64 JOIN _BindingOptionWithItem BIND ON IT.ID64=BIND.nItemDBID WHERE INV.CharID=%d AND INV.ItemID<>0 ORDER BY INV.Slot ASC
SELECT BIND.* FROM _Inventory INV JOIN _ITEMS IT ON INV.ItemID=IT.ID64 JOIN _BindingOptionWithItem BIND ON IT.ID64=BIND.nItemDBID WHERE INV.CharID=%d AND INV.ItemID=%I64d
SELECT BIND.* FROM _OpenMarket OM JOIN _ITEMS IT ON OM.ItemID=IT.ID64 JOIN _BindingOptionWithItem BIND ON IT.ID64=BIND.nItemDBID WHERE OM.JID=%d AND OM.PersnalID=%d
SELECT IT.* FROM _Chest C JOIN _ITEMS IT ON C.ItemID=IT.ID64 WHERE C.UserJID=%d AND C.ItemID IS NOT NULL AND C.ItemID<>0 ORDER BY C.Slot ASC
SELECT IT.* FROM _GuildChest C JOIN _ITEMS IT ON C.ItemID=IT.ID64 WHERE C.GuildID=%d AND C.ItemID IS NOT NULL AND C.ItemID<>0 ORDER BY C.Slot ASC
SELECT IT.* FROM _INVENTORYFORLINKEDSTORAGE INV JOIN _ITEMS IT ON INV.ItemID=IT.ID64 WHERE INV.LinkedItemID=%I64d AND INV.ItemID<>0 AND INV.ItemID IS NOT NULL ORDER BY INV.Slot ASC
SELECT IT.* FROM _InvCOS INV JOIN _ITEMS IT ON INV.ItemID=IT.ID64 WHERE INV.COSID=%d AND INV.ItemID IS NOT NULL AND INV.ItemID<>0 ORDER BY INV.Slot ASC
SELECT IT.* FROM _Inventory INV JOIN _ITEMS IT ON INV.ItemID=IT.ID64 WHERE INV.CharID=%d AND INV.ItemID<>0 ORDER BY INV.Slot ASC
SELECT IT.* FROM _Inventory INV JOIN _ITEMS IT ON INV.ItemID=IT.ID64 WHERE INV.CharID=%d AND INV.ItemID=%I64d
SELECT IT.* FROM _InventoryForAvatar INV_AVA JOIN _ITEMS IT ON INV_AVA.ItemID=IT.ID64 JOIN _BindingOptionWithItem BIND ON IT.ID64=BIND.nItemDBID WHERE INV_AVA.CharID=%d AND INV_AVA.ItemID>0 ORDER BY INV_AVA.Slot ASC
SELECT IT.* FROM _InventoryForAvatar INV_AVA JOIN _ITEMS IT ON INV_AVA.ItemID=IT.ID64 WHERE INV_AVA.CharID=%d AND INV_AVA.ItemID>0 ORDER BY INV_AVA.Slot ASC
SELECT IT.* FROM _OpenMarket OM JOIN _ITEMS IT ON OM.ItemID=IT.ID64 WHERE OM.JID=%d AND OM.PersnalID=%d
SELECT R.* FROM _Chest C JOIN _ITEMS IT ON C.ItemID=IT.ID64 JOIN _RentItemInfo R ON IT.ID64=R.nItemDBID WHERE C.UserJID=%d AND C.ItemID IS NOT NULL AND C.ItemID<>0 ORDER BY C.Slot ASC
SELECT R.* FROM _GuildChest C JOIN _ITEMS IT ON C.ItemID=IT.ID64 JOIN _RentItemInfo R ON IT.ID64=R.nItemDBID WHERE C.GuildID=%d AND C.ItemID IS NOT NULL AND C.ItemID<>0 ORDER BY C.Slot ASC
SELECT R.* FROM _InvCOS INV JOIN _ITEMS IT ON INV.ItemID=IT.ID64 JOIN _RentItemInfo R ON IT.ID64=R.nItemDBID WHERE INV.COSID=%d AND INV.ItemID IS NOT NULL AND INV.ItemID<>0 ORDER BY INV.Slot ASC
SELECT R.* FROM _Inventory INV JOIN _ITEMS IT ON INV.ItemID=IT.ID64 JOIN _RentItemInfo R ON IT.ID64=R.nItemDBID WHERE INV.CharID=%d AND INV.ItemID<>0 ORDER BY INV.Slot ASC
SELECT R.* FROM _InventoryForAvatar INV_AVA JOIN _ITEMS IT ON INV_AVA.ItemID=IT.ID64 JOIN _RentItemInfo R ON IT.ID64=R.nItemDBID WHERE INV_AVA.CharID=%d AND INV_AVA.ItemID>0 ORDER BY INV_AVA.Slot ASC
SELECT SLOT FROM _CHEST WHERE UserJID=%d AND ItemID<>0 AND ItemID IS NOT NULL ORDER BY Slot ASC
SELECT SLOT FROM _GUILDCHEST WHERE GuildID=%d AND ItemID<>0 AND ItemID IS NOT NULL ORDER BY Slot ASC
SELECT SLOT FROM _INVCOS WHERE COSID=%d AND ItemID<>0 AND ItemID IS NOT NULL ORDER BY Slot ASC
SELECT SLOT FROM _INVENTORY WHERE CharID=%d AND ItemID<>0 ORDER BY Slot ASC
SELECT SLOT FROM _INVENTORYFORAVATAR WHERE CharID=%d AND ItemID>0 ORDER BY Slot ASC
UPDATE _ITEMS SET REFITEMID = %d WHERE ID64 = %I64d
```

## Characters and progression

```sql
SELECT * FROM _CHARCOS WHERE OWNERCHARID = %d ORDER BY ID DESC
SELECT * FROM _CharCOS WHERE ID = %d
UPDATE _CHAR SET REFOBJID = %d, SCALE = %d WHERE CHARID = %d
UPDATE _Char SET RemainGold = %I64d WHERE CharID = %d
```

## Everything else

```sql
DELETE FROM %s
DELETE FROM _SiegeFortressObject WHERE [ID] = %d
DELETE FROM _SiegeFortressStruct WHERE RefEventStructID=%d AND RefObjID=%d
DELETE _SiegeFortressBattleRecord WHERE FortressID = %d AND CharID = %d
DELETE _SiegeFortressItemForge WHERE FortressID = %d AND ItemRefID = %d
DELETE _SiegeFortressRequest WHERE FortressID = %d AND GuildID = %d
DELETE _SiegeFortressStoneState WHERE FortressID = %d AND GuildID = %d
DELETE _TIMEDJOB WHERE ID = %d
DELETE _TIMEDJOBFORPET WHERE ID = %d
Delete allied guild error!! (guild is not alliance) Alliance[%d] Guild [%d]
INSERT INTO %s(
INSERT INTO _SiegeFortressBattleRecord VALUES (%d,%d,%d,%d,'%s',%d)
INSERT INTO _SiegeFortressItemForge VALUES (%d, %d, %d, %d, '%s', '%s')
INSERT INTO _SiegeFortressStoneState VALUES (%d,%d,%d)
Insert %s to the _ItemQuotation table
Insert Skill Info [SkillName:%s][Lvl:%d]
Insert Skill is Invalid!! [SkillID:%d][Lvl:%d]
SELECT 
SELECT * FROM %s
SELECT * FROM _CharCollectionBook WHERE CharID = %d 
SELECT COUNT(%s) 
SELECT SLOT FROM _INVENTORYFORLINKEDSTORAGE WHERE LinkedItemID = %I64d AND ItemID <> 0 AND ItemID IS NOT NULL ORDER BY SLOT ASC
SELECT TOP 100 * FROM _GPHistory WHERE GuildID = %d AND UsedTime >= ( GETDATE() - 30 ) ORDER BY ID DESC
SELECT TOP 500 * FROM [dbo].[_OpenMarket] WHERE TidGroupID=%d AND ItemClass=%d AND Status=%d AND (0 > DATEDIFF(minute, enddate, '%d-%d-%d %d:%d:%d')) ORDER BY RegDate DESC
SELECT TOP 500 * FROM [dbo].[_OpenMarket] WHERE TidGroupID=%d AND Status=%d AND (0 > DATEDIFF(minute, enddate, '%d-%d-%d %d:%d:%d')) ORDER BY RegDate DESC
UPDATE %s SET 
UPDATE _SiegeFortress SET CreatedDungeonCount = %d, CreatedDungeonTime = GETDATE() WHERE FortressID = %d
UPDATE _SiegeFortress SET CreatedDungeonCount = 0 WHERE FortressID = %d
UPDATE _SiegeFortress SET Introduction = '%s' WHERE FortressID = %d AND GuildID = %d
UPDATE _SiegeFortress SET Tax = %I64d WHERE FortressID = %d
UPDATE _SiegeFortress SET TempGuildID = %d WHERE FortressID = %d
UPDATE _SiegeFortressStruct SET OwnerGuildID=%d,RefObjID=%d,HP=%d,State=%d, MakeDate='%s' WHERE RefEventStructID=%d
delete _CharInstanceWorldData where CharID = %d and WorldID = %d
insert a PricePolicyConditionLevel %s
insert cost to %s
select 
update tactics::tactics is null!! active tactics count(%d)
```

## What this settles, and one thing it does NOT

**The item containers are keyed by four different owners**, and the binary is
unanimous about which:

| table | keyed by | meaning |
|---|---|---|
| `_Inventory` | `CharID` | the bag, per character |
| `_InventoryForAvatar` | `CharID` | the avatar slots, per character |
| `_Chest` | **`UserJID`** | **the warehouse, per ACCOUNT** |
| `_InvCOS` | `COSID` | a pet's own bag |
| `_GuildChest` | `GuildID` | guild storage |

`_Chest` is the one worth stopping on. Every statement that touches it filters on
`C.UserJID`, never on a character id -- four separate queries agree -- and the
server's own error text says `failed to load user's chest size [UserJID: %d]`,
so the warehouse's CAPACITY is an account property too. **All of an account's
characters share one warehouse.**

The warehouse GOLD is the user's too. The deposit/withdraw path
(`AQ_StorageUpdater::MoveItemWithGold`, `0x45af70`) issues

```
{?=CALL _UPDATE_USER_N_CHAR_GOLD (%d,%I64d, %d,%I64d)}
```

with `(userJID, user gold, charID, character gold)` -- the first id from the
player object's vslot at `+8`, its balance the int64 at player `+0x1ca8`; the
second id from the vslot at `+0x380`, its balance the int64 at char-data `+0x78`
-- and the guild counterpart is `_UPDATE_GUILD_N_CHAR_GOLD`. The item
procedures (`_STRG_MOVE_ITEM (%d,%d,%d,%d,%d,%d,%d,0)`) receive *both* ids and
a move kind (`+0x28`: 2 = bag to chest, `0x20`/`0x21` = guild chest, 10/11/12 =
the gold moves), leaving the choice of key to the procedure -- which the
`SelectUsedSlotsForStorage` queries above show.

**srrevamp follows this since 2026-09-19 (v0.1.390).** Its warehouse table is
`account_storage_slots` keyed by `account_id`, its stored gold is
`accounts.storage_gold`, and every character on an account opens the same
warehouse. The per-character warehouse it kept until then (`storage_slots`,
`characters.storage_gold`) is moved over once at boot by
`storage.MigrateToAccounts`, losslessly: a row keeps its slot where free and
takes the lowest free slot otherwise, gold is summed, and `schema_migrations`
records the run.

**The capacity (read 2026-09-19).** It is a per-user row: the server's binder
`DB_Bind__ChestInfo` (`0x8586e0`) names the table `_ChestInfo` and its column
`ChestSize`; `AQ_CharDataLoader::DoWork` (`0x43d980`) loads it by UserJID through
the bound query (`GetSingleton_00d6aa18(1,0,1, userJID)`) into the character
object at `+0x110`, and a user WITHOUT the row fails to load
(`LOADTARGET_CHEST Failed` / `failed to load user's chest size [UserJID: %d]`) --
so the binary carries no default. The ceiling is the expander's `0x70` = 112
(`inventory.MaxStorageSlots`). The client shows the warehouse in PAGES of 30:
`CIFStorageRoom::Create` (`0x6cc780`) builds exactly `0x1e` slot controls, the
move handler (`0x6cd350`) addresses a warehouse slot as `cell + page * 0x1e`,
and the authored `GDR_STORAGE_SPIN_PAGE` (a `CNIFSpinButtonCtrl`: left arrow at
(0,0) 16x16, value label at (16,4) 18x12 showing value+1, right arrow at (34,0),
over `store\str_slot_02.ddj` -- constructor `0x49d2e0`) picks the page. The
starting `ChestSize` is written by the database's user-creation procedure, which
is in no archive this project holds: `storage.DefaultCapacity` (50) is therefore
DISCLOSED, the server sends it as the trailing field of the storage list, and the
client pages from it.

Two smaller facts fall out of the same queries and cost nothing:

- **`_ITEMS.ID64` is the item instance id**, and every container stores a
  reference to it rather than the item's own columns. Bindings
  (`_BindingOptionWithItem.nItemDBID`) and rentals (`_RentItemInfo.nItemDBID`)
  hang off that same instance id.
- **A slot of 0 or NULL is empty**, not absent: the queries all carry
  `ItemID<>0 AND ItemID IS NOT NULL`, so rows exist for empty slots.

