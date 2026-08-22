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

**All 118 columns now confirmed (2026-08-22)**, pulled the same way as the drop tables (temporary
SQL Server restore of `SRO_VT_SHARD.Bak`, not persisted). Real column groups, in real order:

- **Identity**: `Service`, `ID`, `GroupID`, `Basic_Code` (internal symbolic identifier, e.g.
  presumably a `SKILL_*` constant name, not confirmed display text), `Basic_Name`, `Basic_Group`
  (both `varchar(128)`, same ambiguity as `Basic_Code` -- not confirmed to be player-facing text),
  `Basic_Original`, `Basic_Level`, `Basic_Activity`, `Basic_ChainCode`, `Basic_RecycleCost`
- **Action/timing**: `Action_PreparingTime`, `CastingTime`, `ActionDuration`, `ReuseDelay`,
  `CoolTime`, `FlyingSpeed`, `Interruptable`, `Overlap`, `AutoAttackType`, `InTown`, `Range`
  (`smallint` -- a real skill range value)
- **Targeting**: `Target_Required`, `TargetType_Animal`/`Land`/`Building`, `TargetGroup_Self`/
  `Ally`/`Party`/`Enemy_M`/`Enemy_P`/`Neutral`/`DontCare`, `TargetEtc_SelectDeadBody` -- a real,
  fairly complete targeting-rule bitset
- **Requirements**: `ReqCommon_Mastery1`/`2`/`MasteryLevel1`/`2`/`Str`/`Int`, `ReqLearn_Skill1`/
  `2`/`3`/`SkillLevel1`/`2`/`3`/`SP` (a real SP cost to learn)/`Race`, `Req_Restriction1`/`2`,
  `ReqCast_Weapon1`/`2` (a real required-weapon-type-to-cast pair)
- **Resource cost**: `Consume_HP`/`MP`/`HPRatio`/`MPRatio`/`WHAN` -- real HP/MP costs, not
  previously known
- **UI**: `UI_SkillTab`/`Page`/`Column`/`Row`/`IconFile`/`SkillName`/`SkillToolTip`/
  `SkillToolTip_Desc`/`SkillStudy_Desc` (all but the tab/page/column/row ints are
  `varchar(128)`) -- `UI_SkillName` is a real, plausible candidate for where a skill's actual
  display name lives (distinct from the ambiguous `Basic_Name`/`Basic_Code`), though still not
  100% confirmed to hold literal text rather than another lookup key -- see the still-open
  "where do display names live" item below
- **AI**: `AI_AttackChance`, `AI_SkillType` (real monster-AI skill-use hints)
- **Extension**: `Param1`-`Param50` (all `int`, type-dependent meaning -- same generic-slot
  pattern `_RefObjItem`'s own `Param1`-`Param20` uses)

Still no column here is named anything like "Damage"/"AttackPower" -- consistent with this
project's earlier conclusion that a skill's actual combat-damage value doesn't live in
`_RefSkill` itself. `refdata.Skill` (Go) was extended with a few of the newly-confirmed
high-value real fields (`ConsumeHP`/`ConsumeMP`, `Range`, `ReqLevel`/`ReqSP`) -- not all 118
columns, same curation discipline as `refdata.Item`.

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
- [x] `_RefSkill` schema fully confirmed (all 118 columns, see the dedicated section above) --
      `refdata.Skill` extended with the newly-found high-value fields. Real damage/effect source
      still not found (still no column named for it) -- genuinely open, not this checklist item.
- [x] `_RefDropItemAssign`/`_RefDropItemGroup`/`_RefMonster_AssignedItemRndDrop` schema confirmed
      (see the dedicated section above) — `refdata.DropGroup`/`refdata.MonsterDrop` Go types +
      importer not yet built
- [ ] Figure out where item/skill display names actually live (not in these tables) before any
      of this data is user-facing
