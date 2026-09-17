# Persistence: the AsyncQuery layer

Every write the real server makes to its database goes through one uniform
interface. This is that interface, the 39 stored procedures behind it, and the
**139 tables** it touches — 85 reference and 54 runtime — all read out of
`SR_GameServer.exe`.

Implemented as a catalogue in `server/internal/persistence`.

## The interface is enforced, not conventional

`AQ_Base` (vtable `0x00ae1110`, 12 slots) declares **seven of its twelve slots
as `__purecall`** — slots 3, 5, 6, 7, 8, 9 and 10 all point at `0x009dd3ad`.

**All 28 `AQ_*` classes implement exactly slots 0, 2, 3, 5, 6, 7, 8, 9 and 10.**
Not most of them; all 28, with the same nine indices, verified by diffing every
derived vtable against the base. Four classes add slots beyond the base's
twelve — `AQ_ItemQuotation`, `AQ_TimedJob` and `AQ_TimedJobForPet` add slot 12,
and `AQ_StorageUpdater` adds 11, 12 and 13 — and nothing else varies.

| slot | what it does | how known |
|---|---|---|
| 0 | destructor | all 28 override |
| 2 | reset — zeroes the query's own fields, chains to the base | read |
| 3 | release the attached object, if any | read |
| 4 | `return this->+0x18` (a byte); **not** overridden, shared by 38 vtables | read |
| 5 | `return 1` in most classes | read |
| 6 | **`DoWork()`** — builds and runs the query | **the engine's own name** |
| 7 | success callback | asserts state `0xb`, then one branch |
| 8 | failure callback | asserts state `0xb`, then the other |
| 9, 10 | empty in most classes | read |

### `DoWork` is the engine's word

Twelve distinct log and assert strings name the method, and every one of them
sits inside the function in slot 6:

	"AQ_COSManipulator::DoWork() - nothing to query"
	"AQ_StorageUpdater::DoWork() Failed! - %d"
	"AQ_StorageUpdater::DoWork() Failed!! - Line: %d"

So slot 6's name is recovered, not assigned.

### Slots 7 and 8 are a completion pair

Both open with the same assert on the query's state field:

	if (this->+0x20 != 0xb) Assert_BreakIfDebugger();

and then take opposite branches of the same helper — `AQ_GuildQuery`'s is
`FUN_005c7f10(1)` from slot 7 and `FUN_005c7f10(0)` from slot 8. So **`0xb` is
the state a query holds while its work is outstanding**, and the two slots are
the success and failure completions.

Each class also carries its own error format string, which is how a failing
query is attributed: `"AQ_GuildQuery::DB Query Error(%d): %s"`,
`"AQ_CharDataSaver::DB Query Error(%d): %s"`, and so on for most of the 28.

## The 39 stored procedures

Read from the ODBC call literals the binary builds — `{?=CALL _NAME (%d, %d,
…)}` — so both the name and the **argument count** are exact. The caller column
says which subsystem owns each.

| procedure | args | called from |
|---|---:|---|
| `_STRG_DEL_ITEM` | 4 | `AQ_StorageUpdater::DeleteItem` |
| `_STRG_MOVE_ITEM` | 8 | `AQ_StorageUpdater::MoveItem` |
| `_STRG_SWAP_ITEM` | 8 | `AQ_StorageUpdater::RearrangeItem` |
| `_STRG_MERGE_ITEM` | 8 | `AQ_StorageUpdater::RearrangeItem` |
| `_STRG_MOVEITEM_NEW` | 9 | `AQ_ItemXChanger::vslot_006` |
| `_UPDATE_USER_N_CHAR_GOLD` | 4 | `AQ_StorageUpdater::MoveItemWithGold` |
| `_UPDATE_GUILD_N_CHAR_GOLD` | 4 | `AQ_StorageUpdater::MoveItemWithGold` |
| `_UPDATE_CHAR_GOLD_FOR_GUILDCHEST` | 2 | `AQ_StorageUpdater::MoveItemWithGold` |
| `_OpenMarket_Insert` | 17 | `AQ_OpenMarket` |
| `_OpenMarket_Purchase` | 9 | `AQ_OpenMarket` |
| `_OpenMarket_Cancle` | 6 | `AQ_OpenMarket` |
| `_OpenMarket_Update` | 5 | `AQ_OpenMarket` |
| `_OpenMarket_Receipt` | 3 | `AQ_OpenMarket` |
| `_AddNewCOS` | 12 | `GObjPC` |
| `_DeleteCharCOS` | 3 | `GObjPC` |
| `_ChangeCOSState` | 2 | `GObjPC` |
| `_COS_Naming` | 2 | `GObjPC` |
| `_ADDTIMEDJOB` | 14 | `FUN_00650980` |
| `_ADDTIMEDJOBFORPET` | 13 | `FUN_0065fc60` |
| `_SiegeFortressRequestSiege` | 4 | `AQ_Siege` |
| `_AddSiegeFortressObject` | 10 | `AQ_Siege` |
| `_SiegeFortressHireNPC` | 5 | `GObjPC` |
| `_SiegeFortressTaxCollect` | 3 | `GObjPC` |
| `_SiegeFortressEngageBlessBuff` | 3 | `GObjPC` |
| `_SiegeFortressEntryDungeon` | 2 | `GObjPC` |
| `_UpdateSiegeFortressTaxRatio` | 2 | `GObjPC` |
| `_SiegeFortressFinished` | 1 | `GObjPC` |
| `_SiegeFortressTempFinished` | 1 | `GObjPC` |
| `_CharInstanceWorldDataUpdate` | 12 | `AQ_GameWorld` |
| `_CharInstanceWorldDataMarkUpLastWorld` | 4 | `AQ_GameWorld` |
| `_Bind_Option_Manager` | 9 | `AQ_BindOptionWithItem`, `AQ_StorageUpdater` |
| `_Rent_Info_Manager` | 10 | `AQ_StorageUpdaterForPacakageItem` |
| `_DelExpiredRentItemInStorage` | 3 | `AQ_CharDataLoader`, `AQ_COSManipulator` |
| `_InsertCharTrijobSafeTradeData` | 3 | `AQ_Trijob` |
| `_DeleteCharTrijobSafeTradeData` | 1 | `AQ_Trijob` |
| `_Guild_Master_Election_Available` | 2 | `AQ_GuildQuery` |
| `_CanAssignThisNickName` | 1 | `FUN_004650b0` |
| `_AssignNickName` | 2 | `FUN_00465160` |
| `_DeleteGPHistory` | 1 | `FUN_005d05e0` |

Worth noticing what is *not* here: there is no procedure for gaining
experience, taking damage, or changing a skill level. Those live in the
character save, not in individual calls — the write path for ordinary play is
`AQ_CharDataSaver`, and the procedures above are for things that must be
transactional.

`_STRG_MOVEITEM_NEW` sitting beside `_STRG_MOVE_ITEM` with one extra argument is
the engine's own migration, kept because `AQ_ItemXChanger` uses the new one and
`AQ_StorageUpdater` still uses the old.

`_OpenMarket_Cancle` is the engine's typo, and is quoted as it is spelled.

## The 139 tables, and a completeness proof

Two disjoint sets, found by different means: **85 reference tables** and **54
runtime tables**.

An early harvest of `_UPPERCASE` identifiers found 120 — the 85 plus only 35 of
the runtime ones — because its pattern was uppercase-only. See the correction
below.

**The 85 are exactly the set `docs/protocol/refdata_tables.md` enumerated** —
same count, same members, no difference in either direction. That catalogue was
built by finding the 85 loader *functions*; this list was built by harvesting
*strings*. The probes share nothing, and they agree, which is what turns "85
reference tables" from a count of what was found into a complete count.
`server/internal/persistence` has a test that fails if the two ever drift.

The runtime tables are the ones the server reads and writes as it runs.

**CORRECTED 2026-09-17: there are 54, not 35.** The list below came from
harvesting `_UPPERCASE` identifiers with the pattern `_[A-Z][A-Z0-9_]{3,}` —
**uppercase only** — which silently dropped every mixed-case table name. All
twenty it missed are mixed-case, so the regex accounts for the gap exactly:
`_SiegeFortress`, `_SiegeFortressObject`, `_SiegeFortressBattleRecord`,
`_SiegeFortressItemForge`, `_SiegeFortressRequest`, `_SiegeFortressStoneState`,
`_CharTrijob`, `_CharTrijobSafeTrade`, `_CharInstanceWorldData`,
`_CharCollectionBook`, `_FleaMarketNetwork`, `_Friend`, `_Memo`, `_GPHistory`,
`_ServerEvent`, `_ServerEventReward`, `_ClientConfig`, `_LogSchedule`,
`_BlockedWhisperers`, `_AssociationReputation`.

The authoritative list is now the binary's own schema pool
(`docs/protocol/db_columns.md`), which is what `Database::BindTableSchema`
binds, rather than a regex over strings. `server/internal/persistence` holds it
as `SchemaTableOrder`, and a test keeps `RuntimeTables` equal to it.

**`_LOADED` is gone from the list.** This page hedged that it "may be a flag
rather than a table"; it is absent from the schema pool, which resolves the
hedge.

The old 35, for the record:

	_USER  _CHAR  _DELETEDCHAR  _STATICAVATAR  _DUMMY  _LOADED
	_INVENTORY  _INVENTORYFORAVATAR  _INVENTORYFORLINKEDSTORAGE  _ITEMS
	_CHARCOS  _INVCOS  _CHARQUEST  _CHARSKILL  _CHARSKILLMASTERY
	_GUILD  _GUILDMEMBER  _GUILDCHEST  _GUILDWAR  _ALLIEDCLANS  _CHEST
	_TIMEDJOB  _TIMEDJOBFORPET  _ITEMQUOTATION
	_TRAININGCAMP  _TRAININGCAMPMEMBER  _TRAININGCAMPBUFFSTATUS
	_TRAININGCAMPHONORRANK
	_SIEGEFORTRESSSTRUCT  _STRUCT  _EVENTDAEMON
	_LOGEVENTCHAR  _LOGEVENTITEM  _LOGEVENTSIEGEFORTRESS  _LOGSERVEREVENT

Unlike the reference tables these have **no loader to enumerate** — but they do
have something better, found later: the binary declares their **column names**,
and the set of tables it declares them for is exactly this list plus the twenty
the uppercase regex missed. `_DUMMY` is in the schema pool and is a real table;
`_LOADED` is not in it, which is why it has been dropped.

A table reached solely through a stored procedure and never bound by name would
still not appear, so the list is "every table the server binds a schema for"
rather than "every table it touches".

## What is not recovered

- **Column layouts for any of the 35 runtime tables.** `_CHARQUEST` is the one
  partial exception, from `docs/protocol/quest_scripting.md`.
- **The parameters of any procedure**, beyond how many there are. The call
  literal is `(%d, %d, %d)`; what each `%d` is means reading the caller's
  argument set-up.
- **The ordering and transactionality guarantees.** The queries are
  asynchronous and each carries a state field, but the queue that runs them,
  and what happens when one fails mid-sequence, is unread.

## A hazard this recovery exposed, worth knowing before trusting a name

`AQ_GuildQuery`'s slots 9 and 10 both point at `0x0066b100`, which the dump
calls `CGObjCOS_Summoned::SaveCurPosAsLastTelPosition`. That function is **one
byte** — a bare `ret` — and **281 vtables in the image point at it**.

The compiler folded every identical empty override onto one address, and the
naming pass attached whichever class it reached first. The name is not wrong
about the byte; it is wrong about the owner, for 280 of the 281.

Measured across the whole image: **240 class-qualified names in the dump sit on
a function shared by ten or more vtables**, and 19 functions of four bytes or
fewer are shared by ten or more. See `docs/RE_LOOP.md` for how to check before
attaching a name, and note that two different things are being counted there —
genuine COMDAT folds of tiny functions, where even the method name is
arbitrary, and inherited base-class methods, where the method name is right and
only the class prefix names an arbitrary member of the sharing set.
