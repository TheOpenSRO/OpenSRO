# Database schema (facts derived from DB backups)

Findings from the `SRO_VT_ACCOUNT` and `SRO_VT_SHARD` SQL Server backup files included in the
obtained package. These are `.Bak` files (SQL Server's native backup format, page-based binary,
not plain SQL) — we haven't stood up a SQL Server to actually restore and query them yet, so what
follows comes from scanning the raw backup files for embedded identifier strings (table/column/
stored-procedure names are stored as plain UTF-16 text even in the binary backup format). This
gives us **names and rough domain groupings**, not full column definitions, types, or
relationships yet.

Caveat: this extraction method also picks up plenty of non-schema text that happens to live in
the same backup pages (item/NPC name strings, log message fragments, etc.) — some entries below
are almost certainly page-boundary-truncated fragments, not real identifiers. Treat this as a
rough map, not a verified schema.

## Account DB (`SRO_VT_ACCOUNT`)

Small, focused around login: `TB_User` (the main account table), `TB_Net2e`, plus stored
procedures following a `_VerbNoun` naming convention — `_CertifyUser` (login, see
`opcodes/login.md`), `_AddUser`, `_QueryCharOwnedUser`.

**Punishments (round 788).** The binaries name the account database's `_Punishment` table and its
procedures (READ, GlobalManager strings): `select * from _Punishment where UserJID = %d`,
`_RegisterPunishment` (13 arguments), `_UpdatePunishment`, `_QueryActivePunishmet` (sic),
`_RegisterAutomatedPunishment '<acct>',<type>,'<punisher>','<guide>','<description>',<minutes>`,
and the gateway's `_CertifyTB_User` / `_QueryBlockGuide <JID>`. The SMC's punishment plugin shows
the record's fields (SerialNo, Type, Executor, Shard, CharName, Additional Char Info, Position,
Guide For Web, Accident Description, Raised / Punish Begin / Punish End / Sentenced Time). The
procedures' bodies are in SRO_VT_ACCOUNT, which is not among the backups on the RE box (only
SRO_VT_SHARD is), so their logic is OPEN. OpenSRO's own table, `account_punishments`
(`server/internal/account/sqlstore.go`): serial, account_id, type (1-4), executor, guide,
description, raised_at, begin_at, end_at (NULL = no end). Details: `opcodes/login.md`,
"Punishments".

## Shard DB (`SRO_VT_SHARD`)

Much larger — this is the actual game-world data. Rough domain groupings from the identifiers
found (illustrative, not exhaustive):

- **Characters**: `_Char`, `_CharCOS` (companion/pet?), `_CharInstanceWorldData`, `_CharQuest`,
  `_CharSkill`, `_CharSkillMastery`, `_CharStorage`, `_CharTrijob`, `_CharNameList`,
  `_CharNickNameList`, `_DeletedChar`, `_TempConnectedChar`
- **Inventory/items**: `_Inventory`, `_InventoryForAvatar`, `_InvCOS`, `_Items`, `_ItemPool`,
  `_ItemQuotation` (market pricing?), `_LatestItemSerial`, `_Chest`, `_ChestInfo`
- **Guilds**: `_Guild`, `_GuildChest`, `_GuildMember`, `_GuildWar`, `_AlliedClans`,
  `_AssociationReputation`
- **Social**: `_Friend`
- **Siege/fortress warfare**: `_SiegeFortress`, `_SiegeFortressBattleRecord`,
  `_SiegeFortressItemForge`, `_SiegeFortressObject`, `_SiegeFortressRequest`,
  `_SiegeFortressStruct`
- **World/misc**: `_Building`, `_ClientConfig`, `_FlagWorld_EventParticipants`,
  `_FleaMarketNetwork`, `_TrainingCamp`, `_TimedJob`, `_TimedJobForPet`
- **Static/reference game data** (item stats, drop tables, etc. — over 100 distinct `_Ref*`
  identifiers found, e.g. `_RefDrop`, `_RefAbilityByItemOptLevel`, `_RefCharGen`, `_RefClimate`,
  `_RefConditionToBuyScrapItem` — these look like the static "game design data" tables rather than
  player state)
- **Logging**: `_ExploitLog`, `_Log_SEEK_N_DESTROY_ITEM_FAST` and similar per-event log tables

## Status / next steps

- [ ] Actually restore a `.Bak` into a SQL Server instance (or find/write a reader for the backup
      format directly) to get real column definitions, types, and keys — string-scanning only
      gives names
- [ ] Design an independent schema for the Go server informed by these domain groupings — not a
      1:1 port of the original table/column layout
- [ ] Cross-reference `_CertifyUser`'s parameters (see `opcodes/login.md`) against `TB_User`'s
      actual columns once real schema access exists
