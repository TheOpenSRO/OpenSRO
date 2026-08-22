# Static game data (item/skill/drop reference tables)

Facts from actually restoring the `SRO_VT_SHARD` database backup included in the obtained
package (via a temporary local SQL Server instance, not anything persisted — see
`docs/PROGRESS.md`) and inspecting its schema. This goes further than `db_schema.md`'s
string-scan-only pass: real column definitions, not just table names.

No actual row data (item stats, skill values, drop rates) is committed anywhere in this repo —
only the schema/structure. See `server/internal/refdata` for the "bring your own data" importer
that populates a local database from a player-supplied export, the same pattern this repo already
uses for pk2 client assets.

## `_RefObjItem` (24,521 rows) — item stats

105 columns. No item names/descriptions live here — those are referenced by ID from elsewhere
(likely client-side localized text data, not this table), so this table is pure numeric
game-balance data. Columns fall into a few groups:

- **Identity/requirements**: `ID`, `MaxStack`, `ReqGender`, `ReqStr`, `ReqInt`, `ItemClass`,
  `SetID`, `TwoHanded`, `Range`, `SpeedClass`
- **Durability**: `Dur_L`/`Dur_U` (lower/upper bound, a recurring naming convention throughout —
  most stats are ranges, not fixed values, presumably rolled per-item-instance at drop/craft time)
- **Defense**: `PD_*` (physical defense), `ER_*`, `PAR_*`, `BR_*` (block/parry/balance-adjacent —
  exact semantics not yet decoded), `MD_*` (magic defense), `MAR_*`
- **Attack**: `PAttackMin_*`/`PAttackMax_*` (physical), `MAttackMin_*`/`MAttackMax_*` (magic),
  each split further by `*Str*`/`*Int*` variants (stat-scaling components)
- **Hit/crit**: `HR_*` (hit rate), `CHR_*` (critical hit rate)
- **Generic param slots**: `Param1`-`Param20` + matching `Desc1_128`-`Desc20_128` (varchar(128)
  each) — a flexible key/value extension mechanism, meaning not fixed per-column (probably
  item-class-dependent, e.g. a slot might mean "socket count" on one item class and something
  else on another)
- **Magic options**: `MaxMagicOptCount`, `ChildItemCount`, `Link`

`refdata.Item` (our own schema) keeps a curated subset of this — the combat-relevant stats — not
all 105 columns. Extend it as gameplay needs grow rather than mirroring everything up front.

## `_RefSkill` (36,144 rows) + `_RefSkill_Copy` (7,388 rows) — skill data

118 columns (not fully catalogued yet — this needs another pass). First 20 confirmed:
`Service`, `ID`, `GroupID`, `Basic_Code` (an internal symbolic identifier, not display text —
e.g. presumably something like a `SKILL_*` constant name, not a human-readable name),
`Basic_Name`, `Basic_Group`, `Basic_Original`, `Basic_Level`, `Basic_Activity`,
`Basic_ChainCode`, `Basic_RecycleCost`, then an `Action_*` group: `PreparingTime`, `CastingTime`,
`ActionDuration`, `ReuseDelay`, `CoolTime`, `FlyingSpeed`, `Interruptable`, `Overlap`,
`AutoAttackType`. Not yet imported into `refdata` — `_RefObjItem` was done first as the smaller,
more clearly-scoped example; skills are the natural next target using the same pattern.

## Drop tables (2026-08-22) — real schema pulled, three linked tables

Restored `SRO_VT_SHARD.Bak` into a temporary local SQL Server container again (same
not-persisted approach as the `_RefObjItem`/`_RefSkill` passes) and pulled real, complete column
schemas for all three real drop-related tables (row counts match the earlier string-scan-only
pass exactly: 8,966 / 378 / 3,108, confirming consistency):

- **`_RefMonster_AssignedItemRndDrop`** (3,108 rows) — the real per-monster drop assignment:
  `Service`, `RefMonsterID`, `RefItemGroupID`, `ItemGroupCodeName128` (varchar(128) — a real
  symbolic name, not display text), `Overlap`, `DropAmountMin`, `DropAmountMax`, `DropRatio`
  (real), `param1`, `param2` (both `int`, meaning unconfirmed). This is "which monster can drop
  from which item group, how many, and at what rate."
- **`_RefDropItemGroup`** (378 rows) — defines each item group as a named collection of items:
  `Service`, `RefItemGroupID`, `CodeName128` (varchar(129)), `RefItemID`, `SelectRatio` (real —
  the item's weight within its group), `RefMagicGroupID` (a link to a real magic-option table,
  not itself inspected yet). One row per (group, item) pair.
- **`_RefDropItemAssign`** (8,966 rows) — a real, simpler, separate table: `Service`, `RefItemID`,
  `Prob_Relative`, `Prob_Absolute`, `AssignedGroup`, `DropCount` (all `int`). Not yet confirmed how
  this relates to the two tables above -- plausibly a different drop path (e.g. quest/box rewards)
  rather than ordinary monster kills, since it has no `RefMonsterID` column at all.

`server/internal/combat.LootTables` is still this project's own small, invented drop-table
placeholder (see its own doc comment) -- these three real schemas are ready to inform a real
importer (`refdata.DropGroup`/`refdata.MonsterDrop`, following the `refdata.Item`/`refdata.Skill`
pattern) once one is built.

## Other reference tables found (not yet schema-inspected)

`_RefPricePolicyOfItem` (5,041), `_RefPackageItem` (3,130), `_RefSkillGroup` (933), and ~40 more
smaller tables — see `db_schema.md` for the fuller name-only list. Worth pulling schemas for as
each becomes relevant to actual gameplay systems being built, rather than front-loading all of it
now.

## Status / next steps

- [x] `_RefObjItem` schema confirmed, curated own-schema (`refdata.Item`) designed, CSV importer
      built and tested against the real 24,521-row export (data itself never committed)
- [x] `refdata.Skill` type + `LoadSkillsCSV` importer built, against the ~20 confirmed `_RefSkill`
      columns above (identity/timing/behavior only -- no damage/effect value, since no confirmed
      column encodes one). Not wired into `skill.Catalog` yet: that package's own `DamageBonus` is
      still an own-design number with no real column to source it from, so importing real skills
      would only replace their identity/cost/cooldown, not their actual combat behavior -- doing
      that half-replacement felt more confusing than useful without a real damage source, so
      `skill.Catalog` stays fully own-designed for now. `refdata.Skill` is ready to use once one
      exists.
- [ ] `_RefSkill` schema (remaining ~98 columns) + finding the real damage/effect source
- [x] `_RefDropItemAssign`/`_RefDropItemGroup`/`_RefMonster_AssignedItemRndDrop` schema confirmed
      (see the dedicated section above) — `refdata.DropGroup`/`refdata.MonsterDrop` Go types +
      importer not yet built
- [ ] Figure out where item/skill display names actually live (not in these tables) before any
      of this data is user-facing
