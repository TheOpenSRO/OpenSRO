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

## The stored procedures — **71, corrected 2026-09-17 from 39**

Read from the ODBC call literals the binary builds, so both the name and the
**argument count** are exact. The caller column says which subsystem owns each.

**The first harvest found 39 because it matched one spelling.** The server calls
procedures in four forms, and only the first was searched:

| form | count | example |
|---|---:|---|
| `{?=CALL _NAME (…)}` | 39 | `{?=CALL _STRG_DEL_ITEM (%d, %I64d,%d, %I64d)}` |
| `{CALL _NAME (…)}` | 26 | `{CALL _STRG_ADD_EQUIP_NORMAL (?, ?, %d,…)}` |
| `EXEC _NAME …` | 7 | `exec _skill_manage %d, %d, %d, %d` |
| `trs_sm_*job` wrappers | 5 | `trs_sm_trainingcampjob` |

**This is the same defect as the runtime-table count on this page**, which found
35 of 54 because its regex was uppercase-only. Twice now, in this one document, a
harvest has been reported as a complete enumeration when it was one pattern run
once. The lesson is specific: *a harvest is complete only once its pattern has
been falsified — by finding a second spelling and confirming there is no third —
not once it has been run.* Both counts were caught by an unrelated probe
noticing a number that did not match, not by anything in this file.

### What the 32 missing ones changed

- **Item creation was entirely absent.** `_STRG_ADD_EQUIP_NORMAL`,
  `_STRG_ADD_EXPENDABLE`, `_STRG_ADD_ALCHEMYSTONE`, `_STRG_ADD_SPECIALTY`,
  `_STRG_ADD_ITEM_MAGIC`, `_STRG_ADD_PACKAGEITEM`(`_WITH_STOCKQUANTITY`) and
  `_STRG_SPLIT_ITEM` are every route by which an item comes into existence. The
  catalogue could describe *moving* an item but not *making* one.
- **A whole cash-shop subsystem**: `_STRG_BUY_CASHITEM_*` and the five
  `_STRG_RESTORE_SOLDITEM_*` that undo a sale.
- **The claim below was false.** This page said "there is no procedure for
  gaining experience, taking damage, or changing a skill level".
  `_skill_manage` (4 args, `AQ_SkillManager`) and `_quest_manage` (3 args,
  `AQ_QuestDataManager`) both exist. Experience and damage are still not
  procedures — they really do ride the character save — but skills and quests
  are, and the original sentence drew a structural conclusion from a gap that
  was an artifact of the regex.
- **Gold is read by procedure as well as written**: `_GET_USER_GOLD`,
  `_GET_GUILD_GOLD`, both from `AQ_CharDataLoader`.
- **Five logging procedures**, each called from a `_Log*` class's slot 0. The
  uniform shape is itself the check that none was missed.

### Two procedures are variadic

`_STRG_ADD_ITEM_MAGIC` and `_STRG_RESTORE_SOLDITEM_ITEM_MAGIC` have literals
that simply **stop**:

	{CALL _STRG_ADD_ITEM_MAGIC (?, ?, %d, %d,%d, %d,%d,%I64d,%d, %d

That is not a truncated dump — the string ends there in the binary.
`AQ_StorageUpdater::AddMagicItem` emits this head and then appends
`"%s,%I64d"` once per magic parameter, bounded by its own assert
`"Item's MagParamNum(%d) is out of range"`. So their arity depends on the item,
and `persistence.Proc.Variadic` marks them.

### Counting arguments

A quoted placeholder group is **one** argument. `_Rent_Info_Manager` passes three
datetimes as `'%d-%d-%d %d:%d:%d'` and takes **10** arguments, not the 24 a
`%d`-counter reports. That error was made and caught during this pass, which is
why the original 39 arities were re-checked rather than regenerated — they were
right, and the naive recount was wrong.

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

**The table above lists the 39 the first harvest found; the other 32 are in
`server/internal/persistence`.** What was said here about them was wrong and is
corrected above: *"there is no procedure for gaining experience, taking damage,
or changing a skill level"* — `_skill_manage` and `_quest_manage` exist.
Experience and damage do still ride the character save (`AQ_CharDataSaver`), so
half the observation survives; the half that did not was a conclusion drawn from
the regex's blind spot rather than from the binary.

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

**The 85 were exactly the set `docs/protocol/refdata_tables.md` enumerated** —
same count, same members — and that agreement was taken as proof of
completeness: "the probes share nothing". They shared one thing, an upper-case
`_REF` pattern, and on 2026-09-19 (round 242) the loader count came out at
**124**: the 85, ten `TAB_REF*` tables and 29 mixed-case `_Ref*` tables (quest
rewards, the trigger family, server events, the collection book). Two probes
with the same regex are one probe. `persistence.ReferenceTables` now carries
all 124 and the drift test compares names case-insensitively.

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

- ~~**Column layouts for any of the 35 runtime tables.**~~ **Recovered 2026-09-20
  (round 307)**: every one of the 56 `DB_Bind__<TABLE>` binders declares its
  table and then each column **by name**, so `docs/protocol/db_bind_columns.tsv`
  now carries **409 columns across 59 tables** (`persistence.BoundColumns`).
  **The offsets followed in round 308**: `docs/protocol/db_bind_offsets.tsv` has
  all **409 columns with their struct offsets** (`persistence.ColumnOffsets`,
  `OffsetOf`, `ColumnAt`), controlled against `Strength` 0x74 and
  `RemainHwanCount` 0x86 — both recorded independently by earlier rounds — and
  structurally checked: no `(table, offset)` pair repeats. What remains is the
  second per-column code the binder writes, which is **recorded but not
  interpreted**: it is not a width, and no use-site has been read.
- **The parameters of most procedures**, beyond how many there are. The call
  literal is `(%d, %d, %d)`; what each `%d` is means reading the caller's
  argument set-up. **Two are now partly traced** -- see below -- out of 72.
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

## Tracing a procedure's parameters (2026-09-20, round 284)

The list above has always said the parameters are "not recovered, beyond how
many there are". Two of the 72 are now partly traced, and the method is worth
more than the two results.

**The method: an argument that is also passed to a known accessor names
itself.** A bare `%d` in the call literal says nothing, but the same value
handed to `CGStorage::GetItem` a few lines earlier is a **storage slot index**,
because that is what `GetItem` takes. No inference about the column, no curve --
the argument's other use site is the citation.

### `_STRG_DEL_ITEM (%d, %I64d, %d, %I64d)` -- `AQ_StorageUpdater::DeleteItem` (`0x0045a840`)

| arg | source | what it is |
|---:|---|---|
| 1 | byte at `this+0x28` | the **move kind** -- `server_sql.md` had already decoded this byte (2 = bag to chest, `0x20`/`0x21` = guild chest, 10/11/12 = gold moves); round 284 called it unread without checking |
| 2 | the call's own 64-bit argument | the item, as a 64-bit id -- this is a delete-by-item call |
| 3 | byte at `this+0x2b` | a **storage slot**: the same byte is passed to `CGStorage::GetItem`, and `-1` in it makes the function log `AQ_StorageUpdater::Init() Failed` |
| 4 | 64-bit at `*(param_2+0x34) + 0x78` | **unread** -- a 64-bit id belonging to the object in `param_2` |

The guard is worth noting on its own: the function refuses when
`GetItem(this+0x2b)` returns **non-zero**, i.e. the slot must already be empty
before the row is deleted. The in-memory removal happens first and the query
follows.

### `_STRG_MOVE_ITEM (%d,%d,%d,%I64d,%d,%d,%d,%d)` -- `AQ_StorageUpdater::MoveItem` (`0x0045c9a0`)

Eight arguments, of which four are placed:

| arg | source | what it is |
|---:|---|---|
| 4 | the call's 64-bit argument pair | a 64-bit id, as in DeleteItem |
| 5 | `this[3]` | the **source slot** -- passed to `CGStorage::GetItem` |
| 6 | `this[4]` | the **destination slot** -- passed to `CGStorage::GetItem` |
| 8 | the literal `0` | a constant, whatever the column means |

Arguments 1, 2, 3 and 7 are read from fields and locals this pass did not
follow, and are **not** guessed at here.

### `_AddTrijobReward (%d, %d)` and `_DeleteOldTrijobData (%d)` (round 297)

Two more, from `AQ_Trijob`:

| procedure | argument | source |
|---|---:|---|
| `_AddTrijobReward` | 1 | a **remap of the job kind**: the job record's `+0x1c` gives 1 -> 3, 2 -> 2, and anything else hits `Assert_BreakIfDebugger` -- so the statement is only ever issued for Trader and Robber, never Hunter |
| | 2 | the async-query object's `+0` |
| `_DeleteOldTrijobData` | 1 | the object's `+0x18` -- **data, not a literal**, so no constant to recover here |

The first is the more useful shape: a procedure whose first parameter *looks*
like the enum next to it and is not. Reading the kind byte straight into the
column would have been wrong by two of three values.

Two slots side by side, both through `GetItem`, is what makes 5 and 6 a
source/destination pair rather than two unrelated numbers.

## Do any other procedures disagree with themselves? No -- swept (round 286)

Round 285 found `_STRG_MOVE_ITEM` issued from three functions with three
different format strings, which raised the obvious question: how many of the
others do that, and how many recorded signatures are therefore one call site
of several?

**Swept all three call forms across the server dump: 69 distinct procedure
names, and exactly one has more than one distinct literal.** That one is
`_STRG_MOVE_ITEM`. The other 68 are consistent wherever they are issued, so a
signature quoted from any single call site of them is the signature.

That closes the generalisation rather than leaving it open, and it scopes round
285 properly: the width disagreement on argument 4 is a one-off in this binary,
not a habit to expect.

**A false positive the probe threw, worth knowing.** The first pass reported
two procedures disagreeing, the second being `_ADDTIMEDJOB` with a form
`(%d x12, %I64d, %d)`. That is not in the binary -- it is **this project's own
shorthand**, sitting in a recovered annotation in the dump's function header
(`vtable slot 6. Builds ...`). A regex for call literals will match the prose
written *about* those literals, because the dumps carry both. Checked before
the count was recorded; the count above is the checked one.

## The character save is a SCOPE BITMASK, not a field list (round 391)

`SYSTEMS.md` asked for `AQ_CharDataSaver`'s argument set-up. It is not where the
arguments are: `AQ_CharDataSaver::DoWork` (`0x004412e0`, 220 bytes) is only a
loop over a queue at `+0x38`, executing already-built queries and counting
failures into `+0x30` — the `"AQ_CharDataSaver::DB Query Error(%d): %s"` log.

**The enqueue is `AQ_CharDataSaver::FUN_00441260`**, and it stores three things
before handing off:

	job+0x28 = (chardata+0x11 == 1)      a character-state byte, as a boolean
	job+0x2c = character id              vtable slot 2
	job+0x34 = the query queue           built by vtable slot 0x500 on the character

`chardata+0x11` is **kind `0xc` of `CGObjPC::SetCharacterState`** — the field
dispatcher read in round 361 — so the save records a flag derived from the same
state vocabulary the party and interaction bytes belong to.

**Slot `0x500` is `CGObjPC::vslot_320` (`0x004e63f0`), and it is a scope
dispatcher.** Its third argument is a bitmask and each bit enqueues a different
sub-save:

| mask | sub-object saved | handler |
|---|---|---|
| `0x80` | `this` itself | `0x4a7180` |
| `0x40` | `this + 0x1c10` | `0x4b7b50` |
| *(always)* | `this + 0x1ce8` — **the summoned COS** | `0x4fc770` |
| `0x10` | `this + 0x1d98` — **the quest state** | `0x56fdf0` |
| `0x01` | `this + 0x1d74` | `0x4b7b50` (same handler as `0x40`, different sub-object) |
| `0x100` | `this + 0x1dfc` — **the timed-job list** | `0x656220` |
| `0x200` | `this + 0x74` | `0x484300` |
| `0x400` | `this + 0x1fb4` | `0x60e240` |
| `0x800` | `this + 0x22d0` | `0x4082b0` |

**Each bit saves a different MEMBER SUB-OBJECT of the character**, which is what
the decompiled C could not show: the sub-object is loaded with `lea` into a
register and Ghidra drops it. `objdump -d --start-address=0x4e63f0` shows every
one.

**Three are identified, each from evidence recorded elsewhere for another
purpose** — not from position in the dispatcher, which is how round 391 went
wrong:

- `+0x1d98` is the **quest state**: twelve functions touch it and six of the
  named ones are quest accessors — `GetQuestStatus`, `GetQuestStatusByName`,
  `GetQuestEndDate`, `GetQuestAchievementCount`, `GetQuestAchievementCountByName`,
  `AddQuestAchievementCount`.
- `+0x1dfc` is the **timed-job list**, which `academy.md` already walks for the
  24-hour penalties and `SYSTEMS.md` records as the manager embedded in `GObjPC`.
- `+0x1ce8` is the player's **summoned COS**, per `monster_ai.md`.

**The other six are NOT identified.** `+0x1c10` and `+0x1d74` are touched by two
functions each, both `vslot_214`, which says nothing; `+0x74` is touched by 197
and is far too generic to read anything from; and **`+0x1fb4` and `+0x22d0`
appear in NO decompiled function at all** — they exist only as the dispatcher's
`lea`, so the C cannot reach them and a different probe is needed.

**A correction to the first version of this table (round 391):** the `0x4a7180`
call is gated on **bit `0x80`** (`test bl,bl ; jns`), not always-run; the
`[this+0x34]+0x20` test guards a different call entirely (`0x964b60`). Only
`0x4fc770` runs unconditionally.

**`AQ_CharDataSaver` passes `0xffffffff`** — every bit — so its own save is a
full one. The mask exists so that *partial* saves can be requested by whoever
else calls slot `0x500`, which is what makes this a scope vocabulary rather than
a parameter list.

**"Sub-saver" was a structural label and round 392 found it does not hold
uniformly.** The dispatch is real — the mask, the bits and the eight call targets
are all read off the code. What those targets ARE was inferred from position in
the dispatcher, not from reading them, and two reads show they are not one kind
of thing:

- `FUN_004b7b50` (bits `0x01`/`0x40`) is a **string-building loop** — the MSVC
  small-buffer pattern (`capacity = 0xf`, `_free` once it grows past it),
  appending in a loop bounded by `[obj+0x20]`. Consistent with assembling query
  text, though the procedure it names is not in the function.
- `FUN_004082b0` (bit `0x800`) is **not a builder at all**: it walks a vector at
  `+0xc..+0x10` calling `FUN_00408330` on `+4`, `+0xb`, `+0x1a`, `+0x20`, `+0x26`
  and `+0x2b`, which is a free/teardown shape, and it takes no visible argument.

So the bits select *something* per scope, and at least one of them is a
container teardown rather than a save. **None of the eight is named**, and none
should be until it is read: the naming lever hoped for — a procedure name or a
table string inside each — **does not exist**, as all eight are literal-free.

