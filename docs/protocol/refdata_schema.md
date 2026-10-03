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

`refdata.Item` (our own schema) keeps a curated subset of this — the combat-relevant stats, and
since 2026-09-10 the classification and wearing-requirement columns (`TypeID1`-`4`, `Country`,
`ReqGender`, `ReqLevelType1`, `ReqLevel1`) that `equipment.Refusal` checks — not all 105 columns.
Extend it as gameplay needs grow rather than mirroring everything up front. The CSV importer's
column list appends the new eight after the original twenty, so an export made for the earlier
layout is a prefix of the current one. What each of those columns means, and how that was
established against the client's own tables, is in `ITEM_FORMAT.md`.

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

## Real magic-option (item random-stat) system — schema pulled, not yet implemented

While pulling the drop-table schema, followed `_RefDropItemGroup.RefMagicGroupID` to its real
linked tables (found via `INFORMATION_SCHEMA` search for `%Magic%`, same restore session):

- **`_RefMagicOpt`** (427 rows) — defines each real named magic option: `Service`, `ID`,
  `MOptName128` (varchar(129) -- an internal name, not confirmed display text), `AttrType`
  (varchar(8)), `MLevel`, `Prob` (real), `Weight`, `Param1`-`16`, `ExcFunc1`-`6`, and 10 real
  `AvailItemGroup*`/`ReqClass*` pairs (which real item groups/classes this option can roll on).
- **`_RefMagicOptGroup`** (115 rows) — `LinkID` (plausibly what `_RefDropItemGroup.RefMagicGroupID`
  points at), `MagicType`, `CodeName128`, `MOptID` (real FK into `_RefMagicOpt`), `MOptLevel`,
  `Value`, `Param1`/`2` + their own `_Desc` string columns.
- **`_RefMagicOptAssign`** (74 rows) — `Race`, `TID3`/`TID4`, and 25 real `AvailMOpt1`-`25`
  columns (which magic options are available per race/item-type).

This is the real system behind classic Silkroad "+N" magic-option item stats. **Not implemented in
`refdata` yet** -- nothing in this project's current gameplay systems needs random item magic
options, so per this file's own stated principle (pull schemas as they become relevant, don't
front-load), this is recorded as a real, confirmed schema for a future pass, not built out now.

## `_RefPricePolicyOfItem` (5,041 rows) — checked, real dead end for ordinary NPC vendor pricing

`server/internal/shop.Price()`'s own doc comment said the DB backups were "never fully
restored/mined for a real price table" -- now that restore access is proven working, checked
directly. Real schema: `Service`, `Country`, `RefPackageItemCodeName`, `PaymentDevice`,
`PreviousCost`, `Cost`, `Param1`-`4` (+ their own `_Desc128` columns). This is real, but it's the
**item-mall (cash shop) package pricing table**, not an ordinary NPC vendor's gold price for
regular weapons/armor -- `PaymentDevice`/`Country`/`RefPackageItemCodeName` are cash-shop-specific
concepts with no meaning for a plain vendor-bought sword. Also checked `_RefObjItem` itself for any
`Cost`/`Price`-named column -- none exists. **Real, confirmed conclusion**: no real per-item NPC
vendor gold price table exists anywhere in this database. This is consistent with (not just an
assumption) `shop.Price()`'s own existing formula-from-stats approach -- real Silkroad NPC prices
were plausibly always computed from item stats client/server-side too, not looked up from a static
table. Updated `shop.Price()`'s doc comment to state this as a checked fact, not an unexplored gap.

## `_RefObjChar` monsters: the species export (round 654)

`cmd/export-refdata -mode monsters` writes every client `characterdata_*.txt` row of TypeID
(1,2,1,x) as one CSV row; `server/internal/species` holds the column map, the exporter and the
loader, and `cmd/server -monsters-csv` loads it. Column numbers are 0-indexed (field 0 is the
service flag). How each is known:

| characterdata col | CSV column | meaning | how known |
|---|---|---|---|
| 1 | ID | row id, what npcpos places by | READ (_RefObjCommon prefix) |
| 2 | CodeName | code name, unique per row | READ |
| 4 | OrgCodeName / OrgID | OrgObjCodeName: the row it names, resolved over EVERY characterdata row | READ as a position (the deserialiser's third string read); what the client does with it is OPEN (round 655) |
| 5 | NameKey / Name | NameStrID; Name is textdata_object's English for it by the client's own rule (service-1 rows, first row wins, column 8 else the first Latin field) | READ position; resolution MEASURED on the ladder |
| 9-12 | (filter) / TypeID4 | TypeID; a monster is 1,2,1,x | READ position, MEASURED |
| 12 | TypeID4 | 1 field monsters (1,790), 2 and 3 the job-trade thieves and hunters (2,800 each), 4 structures and quest rows (213), 5 one event row | census MEASURED; its use is OPEN |
| 15 | Rarity | rank: 0 normal, 1 champion, 3/8 unique, 4 giant, 5 titan, 6 elite, 7 rank 7 | READ (FUN_0069b4c0, CGObjMob::PublishStats) |
| 46 / 47 | WalkSpeed / RunSpeed | Speed1/Speed2, units per second | READ, MEASURED (round 536) |
| 50 | BCRadius | collision radius | READ (round 247) |
| 52 | Model | own .bsr, or "xxx" | MEASURED |
| 57 | Level | level | READ (CRefObjChar+0x198) |
| 59 | MaxHP | MaxHP | READ (the m_dwMaxHP > 0 assert) |
| 71-78 | Col71..Col78 | ParamKeeper params 5..12: 71 flat physical absorption (READ), 73 physical percentage (READ), 72/74 their magical pair (INFERRED), 75 'era', 76 'bri' (block), 77 'hra', 78 'cri' (critical) -- tags READ | GObjMob_PublishStats |
| 83-92 | Skill1..Skill10 | attack-skill ids | READ (BindSkillsAndRanges) |
| -- | ModelFromOrg | 1 when col 52 is "xxx" and the Org row has a model, which Model then carries | OURS as a record; nothing draws by it this round |
| levelgold.txt | GoldMin / GoldMax | (level, min, max) at col 57 | rows READ; the join to the kill gold INFERRED (combat.RollGold), as the hand-typed roster already did |

Skill CSV column 89 is new with it: **AI_AttackChance, skilldata column 66** (CRefSkill+0x164), the
weight `AI::CAISkill_Basic::PickSkill` draws the attack list by (monster_ai.md). An export or a
database from before round 654 loads -1 (unknown), never 0.

**A retail archive, MEASURED (2026-09-30, Media.pk2 on the render box, parts fed in
characterdata.txt's order, last definition of an id kept):**

- 33,948 characterdata rows over the 63 listed parts (20 of them empty, a BOM only), 17,868 ids; 16,080 rows
  repeat an id, and every repeat differs from the earlier copy in WIDTH (104 against 105 fields,
  the 105th empty) -- only **2** differ in a value: MOB_SD_OSIRIS_3's rarity (8 in
  characterdata_39000, 3 in characterdata_40000, which is kept) and NPC_SOSUN's model.
- **7,604 monster species.** Rarity: 0 = 6,421, 1 = 85, 3 = 813, 4 = 2, 6 = 111, 7 = 91, 8 = 81.
  Levels 1..140; every level has a levelgold row. 7,509 name keys resolve (7,494 to Latin text).
- Models: 1,848 own; **156** "xxx" with an Org row that has one; 5,600 with neither (all the
  MOB_THIEF_NPC / MOB_HUNTER_NPC job-trade rows). 6,956 Org columns name a row, 33 name none.
- 7,412 species carry a col-83 skill; 7,394 of those resolve every skill id against the
  33,698-row skills export, 18 name 49 distinct ids it does not hold. 26,650 skills have a
  non-zero AI_AttackChance.
- npcpos names 589 ids; **355 are monster species in this table**, placed by 12,110 rows. 89 of
  the 355 (85 of them `_CLON`) have model "xxx" and all 89 have an Org row with a model; they
  are placed by 4,649 rows. (The round-654 plan counted 80 species and 4,554 rows by another
  de-duplication; these are the index-order, last-wins numbers the server loads.)
- The eleven roster species re-derive exactly: `TestSpeciesTableMatchesTheRealExport` with
  `OPENSRO_MONSTERS_CSV`/`OPENSRO_SKILLS_CSV` set reports overlaid 11, missing 0, changed 0,
  kept 0 -- names, gold and the full skill lists (chances included) as monsterSpecs types them.

## Other reference tables found (not yet schema-inspected)

`_RefPackageItem` (3,130), `_RefSkillGroup` (933), and ~40 more smaller tables — see
`db_schema.md` for the fuller name-only list. Worth pulling schemas for as each becomes relevant
to actual gameplay systems being built, rather than front-loading all of it now.

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
