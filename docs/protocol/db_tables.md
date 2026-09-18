# The server's DB surface

**Recovered 2026-09-18.** The server binary carries the names of the SQL objects it uses:
**216 identifiers of the form `_Name`**, plus the handful of statements it builds inline.
Together they say what the real server persists, which is the check srrevamp's own storage can
be read against.

## Why the names are trustworthy and the mapping mostly is not

An earlier pass found 182 functions holding `"DBTable Registering Failed: %s"` and hoped to
name each for its table. That does not work: the registration function is a **generic
get-or-create template** whose only class vtable is `CDBRecord`, the base, so the table comes
from the caller (see [string_families.md](string_families.md)).

What *does* name a function is a statement it issues, because that describes the operation
rather than a subject it mentions. **33 distinct SQL/EXEC statements** appear as literals;
22 are held by exactly one unnamed function, and 15 functions were named from them:

	DeleteSiegeFortressObject        DELETE FROM _SiegeFortressObject WHERE [ID] = %d
	DeleteSiegeFortressStruct        DELETE FROM _SiegeFortressStruct WHERE RefEventStructID=%d …
	InsertSiegeFortressStoneState    INSERT INTO _SiegeFortressStoneState VALUES (%d,%d,%d)
	UpdateSiegeFortressRow           four UPDATE _SiegeFortress variants (Tax, TempGuildID, …)
	UpdateCharRefObjIDAndScale       UPDATE _CHAR SET REFOBJID = %d, SCALE = %d WHERE CHARID = %d
	SelectCharCollectionBook         SELECT * FROM _CharCollectionBook WHERE CharID = %d
	SelectGuildGPHistoryTop100       SELECT TOP 100 * FROM _GPHistory WHERE GuildID = %d …
	SelectUsedSlotsForStorage        SELECT SLOT FROM _CHEST / _GUILDCHEST / _INVENTORY / …
	SelectUsedSlotsForLinkedStorage  SELECT SLOT FROM _INVENTORYFORLINKEDSTORAGE …
	ExecAddTrijobReward              EXEC _AddTrijobReward %d, %d
	ExecDeleteOldTrijobData          EXEC _DeleteOldTrijobData %d
	ExecAddCollectionBookItem        exec _AddCollectionBook_Item %u, %u, %u
	ExecAddFlagEventParticipant      exec _AddFlagEventParticipant %d
	ExecQuestManage                  exec _quest_manage %d,%d,%d
	ExecSkillManage                  exec _skill_manage %d, %d, %d, %d

`SelectUsedSlotsForStorage` holds four statements of one shape over four different tables, so
it is named for the shape rather than for any one table. A bare `"select"` literal was skipped:
it identifies nothing.

## The identifiers

These are what the binary contains, not a schema read from a database — a name here means the
server mentions the object, not that every column is known.

	_ALLIEDCLANS
	_AssociationReputation
	_BindingOptionWithItem
	_BlockedWhisperer_Add
	_BlockedWhisperer_Remove
	_BlockedWhisperers
	_CHAR
	_CHARCOS
	_CHARQUEST
	_CHARSKILL
	_CHARSKILLMASTERY
	_CHEST
	_CharCollectionBook
	_CharInstanceWorldData
	_CharTrijob
	_CharTrijobSafeTrade
	_ChestInfo
	_ClientConfig
	_DELETEDCHAR
	_DUMMY
	_EVENTDAEMON
	_EquipInvCos
	_FleaMarketNetwork
	_Friend
	_GPHistory
	_GUILD
	_GUILDCHEST
	_GUILDMEMBER
	_GUILDWAR
	_INVCOS
	_INVENTORY
	_INVENTORYFORAVATAR
	_INVENTORYFORLINKEDSTORAGE
	_ITEMQUOTATION
	_ITEMS
	_InventoryForMagicCube
	_KeepDelCharName
	_LOADED
	_LOGEVENTCHAR
	_LOGEVENTITEM
	_LOGEVENTSIEGEFORTRESS
	_LOGSERVEREVENT
	_LogSchedule
	_Memo
	_NT_ALT_SYMBOL_PATH
	_NT_SYMBOL_PATH
	_OpenMarket
	_QuickSlotData
	_REFABILITYBYITEMOPTLEVEL
	_REFACCESSPERMISSIONOFSHOP
	_REFALCHEMYMERIT
	_REFCHARDEFAULT_QUEST
	_REFCHARGEN
	_REFCLIMATE
	_REFCONDITIONTOBUYSCRAPITEM
	_REFCONDITIONTOSELLPACKAGEITEM
	_REFCONDITIONTOSELLSCRAPITEM
	_REFCUSTOMIZINGRESERVEDITEMDROPFORMONSTER
	_REFDROPCLASSSEL_ALCHEMY_ATTRSTONE
	_REFDROPCLASSSEL_ALCHEMY_MAGICSTONE
	_REFDROPCLASSSEL_ALCHEMY_TABLET
	_REFDROPCLASSSEL_AMMO
	_REFDROPCLASSSEL_CURE
	_REFDROPCLASSSEL_EQUIP
	_REFDROPCLASSSEL_RAREEQUIP
	_REFDROPCLASSSEL_RECOVER
	_REFDROPCLASSSEL_REINFORCE
	_REFDROPCLASSSEL_SCROLL
	_REFDROPGOLD
	_REFDROPITEMASSIGN
	_REFDROPITEMGROUP
	_REFDROPOPTLVLSEL
	_REFEVENT
	_REFEVENTZONE
	_REFGACHACODE
	_REFGACHAITEMSET
	_REFGACHANPCMAP
	_REFGAMEWORLDNPC
	_REFGAME_WORLD
	_REFGAME_WORLD_CONFIG
	_REFHWANLEVEL
	_REFINSTANCE_WORLD_REGION
	_REFINSTANCE_WORLD_START_POS
	_REFLEVEL
	_REFMAGICOPT
	_REFMAGICOPTASSIGN
	_REFMAGICOPTBYITEMOPTLEVEL
	_REFMAGICOPTGROUP
	_REFMAPPINGSHOPGROUP
	_REFMAPPINGSHOPWITHTAB
	_REFMONSTER_ASSIGNEDITEMDROP
	_REFMONSTER_ASSIGNEDITEMRNDDROP
	_REFOBJCHAR
	_REFOBJCHAREXTRASKILL
	_REFOBJCOMMON
	_REFOBJITEM
	_REFOBJSTRUCT
	_REFOPTIONALTELEPORT
	_REFPACKAGEITEM
	_REFPRICEPOLICYOFITEM
	_REFQUEST
	_REFREGION
	_REFREGIONBINDASSOCSERVER
	_REFREWARDPOLICYTOBUYSCRAPITEM
	_REFREWARDPOLICYTOSELLPACKAGEITEM
	_REFREWARDPOLICYTOSELLSCRAPITEM
	_REFSCRAPOFPACKAGEITEM
	_REFSETITEMGROUP
	_REFSHARDCONTENTCONFIG
	_REFSHOP
	_REFSHOPGOODS
	_REFSHOPGROUP
	_REFSHOPITEMSTOCKPERIOD
	_REFSHOPOBJECT
	_REFSHOPTAB
	_REFSHOPTABGROUP
	_REFSIEGEBLESSBUFF
	_REFSIEGEDUNGEON
	_REFSIEGEFORTRESS
	_REFSIEGEFORTRESSBATTLERANK
	_REFSIEGEFORTRESSGUARD
	_REFSIEGEFORTRESSITEMFORGE
	_REFSIEGEFORTRESSREWARDS
	_REFSIEGELVLSUMMONMONSTER
	_REFSIEGEQUEST
	_REFSIEGEQUESTREWARD
	_REFSIEGESTRUCTUPGRADE
	_REFSKILL
	_REFSKILLBYITEMOPTLEVEL
	_REFSKILLMASTERY
	_REFTELELINK
	_REFTELEPORT
	_REFTREATITEMOFSHOP
	_RefCollectionBook_Item
	_RefCollectionBook_Theme
	_RefEventReward
	_RefEventRewardItems
	_RefGameWorldBindGameWorldGroup
	_RefGameWorldBindTriggerCategory
	_RefGameWorldGroup
	_RefGameWorldGroup_Config
	_RefQuestReward
	_RefQuestRewardItems
	_RefRentItem
	_RefServerEvent
	_RefServerEventReward
	_RefServerEventReward_ExpUPForPlayers
	_RefServerEventReward_SpawnMonster
	_RefTrigger
	_RefTriggerAction
	_RefTriggerActionParam
	_RefTriggerBindAction
	_RefTriggerBindCondition
	_RefTriggerBindEvent
	_RefTriggerCategory
	_RefTriggerCategoryBindTrigger
	_RefTriggerCommon
	_RefTriggerCondition
	_RefTriggerConditionParam
	_RefTriggerEvent
	_RefTriggerVariable
	_RefUIString_Mt
	_RentItemInfo
	_SIEGEFORTRESSSTRUCT
	_STATICAVATAR
	_STRUCT
	_ServerEvent
	_ServerEventReward
	_ShopItemStockQuantity
	_SiegeFortress
	_SiegeFortressBattleRecord
	_SiegeFortressItemForge
	_SiegeFortressObject
	_SiegeFortressRequest
	_SiegeFortressStoneState
	_SupportGoldConfig
	_TIMEDJOB
	_TIMEDJOBFORPET
	_TRAININGCAMP
	_TRAININGCAMPBUFFSTATUS
	_TRAININGCAMPHONORRANK
	_TRAININGCAMPMEMBER
	_TempChest
	_TradeBagInventory
	_USER
	_accountjid
	_alliedclans
	_char
	_charcos
	_charnamelist
	_charnicknamelist
	_charquest
	_charskill
	_charskillmastery
	_chartrijob
	_chest
	_clientconfig
	_deletedchar
	_exploitlog
	_friend
	_gacha
	_guild
	_guildmember
	_guildwar
	_invcos
	_inventory
	_itempool
	_itemquotation
	_items
	_latestitemserial
	_memo
	_siege
	_staticavatar
	_timedjob
	_trijobrewards
	_user

# Appendix: the server's assert/debug flag enum

Found while scanning `.data` for function-pointer tables. The binary carries the flag names
beside their values, so the enum is read rather than inferred:

	DEBUG_OPTION_ASSERT_DONOT_SHOW_MESSAGEBOX      0x001
	DEBUG_OPTION_ASSERT_SHOW_MESSAGEBOX_OKCANCEL   0x002
	DEBUG_OPTION_ASSERT_SHOW_MESSAGEBOX_OK         0x004
	DEBUG_OPTION_ASSERT_SHOW_CALLSTACK             0x008
	DEBUG_OPTION_ASSERT_ADVANCE_BREAK              0x010
	DEBUG_OPTION_ASSERT_ADVANCE_NORMAL             0x020
	DEBUG_OPTION_ASSERT_CANCEL_EXIT                0x100
	DEBUG_OPTION_ASSERT_WRITE_MINIDUMP             0x200
	DEBUG_OPTION_ASSERT_CALL_CALLBACK              0x400

They are laid out as (name pointer, value) pairs, and the values are **not** in table order —
`WRITE_MINIDUMP` is 0x200 while sitting between 0x008 and 0x010 — so reading the order as the
bit sequence would have produced three wrong values. This governs the server's own assert
behaviour, not gameplay; it is recorded because it is a named value set the binary states
outright.
