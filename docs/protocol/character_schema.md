# What the engine thinks a character is

`_CHAR` is one of the 54 runtime tables whose column names `SR_GameServer.exe`
declares in its schema pool (`docs/protocol/db_columns.md`). It introduces **42
column names**, and that is the fullest available statement of what the game
considers a character to be.

srrevamp's `Character` has **twelve** fields. This page is the map between them,
and `server/internal/character/schema.go` holds it in code with tests that fail
if a field is added without an entry or if the column list drifts from the
extracted pool.

## The 42 columns

	Deleted  RefObjID  CharName16  NickName16  Scale
	CurLevel  MaxLevel  ExpOffset  SExpOffset
	Strength  Intellect  RemainGold
	RemainSkillPoint  RemainStatPoint  RemainHwanCount  GatheredExpPoint
	HP  MP
	LatestRegion  PosX  PosY  PosZ
	AppointedTeleport  AutoInvestExp  InventorySize
	DailyPK  TotalPK  PKPenaltyPoint
	GuildID  LastLogout
	TelRegion  TelPosX  TelPosY  TelPosZ
	DiedRegion  DiedPosX  DiedPosY  DiedPosZ
	WorldID  TelWorldID  DiedWorldID  HwanLevel

## What srrevamp has, and what the engine calls it

| srrevamp | `_CHAR` | |
|---|---|---|
| `Name` | `CharName16` | |
| `Gold` | `RemainGold` | |
| `HP` | `HP` | |
| `Level` | `CurLevel` | the engine also keeps `MaxLevel` |
| `Exp` | `ExpOffset` | the engine also keeps `SExpOffset` and `GatheredExpPoint` |
| `StatPoints` | `RemainStatPoint` | |
| `Str` | **`Strength`** | |
| `Int` | **`Intellect`** | |
| `ID` | — | the engine's key is `CharID` |
| `AccountID` | — | the engine links to `_USER` rather than storing an id on the row |
| `Gender` | — | **divergence, below** |
| `StorageGold` | — | **divergence, below** |

**`Strength` and `Intellect` are naming confirmations.** srrevamp guessed at
`Str`/`Int` and the engine spells them out — a small thing, but it is the
difference between a convention and a citation.

## Two divergences worth naming

**`Gender` is not a column.** A character's race and sex follow from
`RefObjID`, the reference object it is built from. srrevamp stores a string
(`china_man` / `china_woman`) because it selects asset paths directly. That is a
reasonable shortcut and it is a shortcut.

**`StorageGold` is not on the character.** Warehouse gold lives in the separate
`_CHEST` table. srrevamp hangs it off `Character`.

## The engine persists MP, and srrevamp does not

`_CHAR` carries **`MP`** immediately beside **`HP`**.

`server/internal/mana` did not persist current mana, and argued that "being
topped up on mana should not be worth reconnecting for, because the pool refills
anyway" — which reads as though the design followed the game. **It does not.**
The real server saves current mana, so relogging does not refill it there.

The choice can stand on its own merits — srrevamp has no cross-session
consequence that turns on a mana total — but it is **own design**, and it is now
recorded as one, with a test that keeps it stated rather than assumed.

This is the third time this project has found a claim about the engine resting
on a plausible assumption rather than a reading, and the pattern is the same
each time: the design was fine, the justification was not.

## What the engine keeps that srrevamp models nowhere

| columns | what they are |
|---|---|
| `LatestRegion`, `PosX/Y/Z`, `WorldID` | position on the row — srrevamp keeps it in the live world only |
| `TelRegion`, `TelPosX/Y/Z`, `TelWorldID` | the bound return point, five columns |
| `DiedRegion`, `DiedPosX/Y/Z`, `DiedWorldID` | where the character last died, five columns |
| `DailyPK`, `TotalPK`, `PKPenaltyPoint` | the PK economy |
| `HwanLevel`, `RemainHwanCount` | the berserk economy, **persisted** |
| `RemainSkillPoint` | srrevamp keeps SP in `internal/skill`'s own store |
| `SExpOffset`, `GatheredExpPoint` | skill experience and a lifetime total |
| `InventorySize` | per-character inventory width; srrevamp's is fixed |
| `AutoInvestExp` | automatic stat investment |
| `AppointedTeleport` | a bound teleport |
| `NickName16`, `Scale`, `Deleted`, `GuildID`, `LastLogout`, `MaxLevel`, `RefObjID` | |

**Five columns for the return point and five for the death point** is the detail
most likely to matter to srrevamp later: the engine treats "where you go back
to" and "where you died" as first-class persisted state, each with its own
region, three coordinates and world id.

`HwanLevel` being persisted is worth noting against
`docs/protocol/param_registry.md`'s berserk work — the gauge is transient but the
*level* is not.

## What this is not

A persistence design. srrevamp does not use this schema and nothing here says it
should. The value is that every field on `Character` is now either matched to
the engine's own name or recorded as a deliberate divergence, and a test makes
the next field added answer the same question.
