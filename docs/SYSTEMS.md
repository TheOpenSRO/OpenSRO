# Systems — the real completion tracker

**What this replaces.** "N% of functions named" measured the wrong thing: the
server has 34,113 functions and ~2,000 of them have ever needed reading, because
the rest are the CRT, template instantiations, and code no reimplementation
touches one function at a time. A name on `FUN_00712340` is not understanding.

**The unit here is a SYSTEM**, and a system is *specified* when it clears the
same bar `docs/protocol/damage_pipeline.md` clears:

1. its entry points are named,
2. its behaviour is written as an ordered spec, with addresses and constants
   cited,
3. every value it uses is either grounded or disclosed with a **proven** reason.

**The denominator is derived from the binary, not invented.** `SR_GameServer.exe`
carries 1,209 distinct RTTI type descriptors; 1,177 of them are game classes and
the rest are allocators, queues and other infrastructure. The "classes" column
below is that count per family — the surface area each system actually has.
Where a family is 346 instances of one pattern (the quest scripts) it is one
system, not 346.

**Every unfinished row carries its own next probe**, so a pivot leaves a
pointer rather than a loose end. A row that is not SPECIFIED must say what would
close it, or say that nothing is known to — and the test enforces that too.

**This file is checked by a test.** `internal/systems` parses it on every
`go test` run and fails if a row's spec document is missing, if a row claims
SPECIFIED without one, if a row claims OPEN while a spec exists, or if an
unfinished row records no next probe. Both of this
project's previous forward-looking summaries — the RE_COMPLETION work queue and
GROUNDING_AUDIT — rotted silently and had to be corrected on 2026-09-17; this
one cannot rot the same way without the build going red.

## Status

| System | Classes | Status | Spec | Anchors | Next probe |
|---|---|---|---|---|---|
| Damage pipeline | ~156 fns | SPECIFIED | docs/protocol/damage_pipeline.md | MitigateDamage, ApplyFloorBand, ApplySkillPercent | stages 17+ run to 0x40e819 and are unread; nothing needs them; the attack-DISTANCE rule is read (round 247, `combat.ApproachBand`): reach = both BCRadius + range (skill Range or weapon Range col 94 = param 33), +2 slack, the server walks the attacker to a banded stop distance -- data wired, behaviour not yet |
| Death penalty and death causes | 6 fns | SPECIFIED | docs/protocol/damage_pipeline.md | DeathCause, DeathPenaltyFactorFor, DeathPenaltyExp | — |
| Passive regeneration | 4 fns | SPECIFIED | docs/protocol/param_registry.md | RegenPerTick, RegenInterval, RegenHalfCapDivisor | — |
| `_RefObjCommon` binary format | 3 parsers | SPECIFIED | docs/protocol/refobj_binary_format.md | ItemCSVColumnCount | — |
| Item requirements | 2 fns | SPECIFIED | docs/protocol/item_requirements.md | CheckRequirements, RequirementsOf | — |
| Item capability flags | 9 fns | SPECIFIED | docs/protocol/item_capability_flags.md | CanTrade, CanSell | — |
| Equipment slots | 4 fns | SPECIFIED | docs/protocol/EQUIP_SLOTS.md | SlotFor, MaxEquipSlots | — |
| ParamKeeper registry | 120 params | SPECIFIED | docs/protocol/param_registry.md | StrLevelDamageRatio, StrForMaxRatio | — |
| IGObj vtable | 208 slots | SPECIFIED | docs/protocol/igobj_vtable.md |  | — |
| Magic-option vocabulary | 53 tags | SPECIFIED | docs/protocol/magic_options.md | ParamFor, PackTag | — |
| Levelling and EXP | 8 fns | SPECIFIED | docs/protocol/param_registry.md | DeathPenaltyMinLevel, StatPointsPerLevel | — |
| Quest scripting | 696 quests, 153 compiled | PARTIAL | docs/protocol/quest_scripting.md |  | **BLOCKED**: how the 543 classless quests attach. CQuestBase's slot-55 default is not reachable via the dump's slot tags; needs the vtable read directly in Ghidra |
| Reference-table catalogue | 124 tables | PARTIAL | docs/protocol/refdata_tables.md | ReferenceTables, ClientTextdata | the count was CORRECTED from 85 to 124 in round 242 (the census's two probes shared an upper-case regex and both missed the 10 `TAB_REF*` and 29 mixed-case `_Ref*` names); **51 are readable right now** from `Media.pk2` -- the mapping is `persistence.ClientTextdata`. The other 73 are server-only, 17 of them the loot tables, which is measured rather than assumed. The server's own row parsers are catalogued (round 240: 66 positional parsers with widths, record sizes, inserters and list loaders; 19 named to their table, the shop/package families by their inserters' case numbers). Read a readable one when a value needs it; settle a blank parser row by an assert string, a family case or a use-site, never by column count |
| Teleport network | 3 tables | PARTIAL | docs/protocol/teleport_network.md |  | col 3 is the FEE, read at its use-site (2026-09-19): the teleport-use handler `FUN_00513590` compares the link's second word to the character's gold (inv+0x78/+0x7c) and refuses 0x1c07; waived below level 21; a gate flag adds a surcharge (`FUN_00486390`, unread). Cols 8/9: NO consumer found in either binary's ordinary-gate paths (2026-09-19, second pass): the client builds the list from its OWN link records (`UI_TELEPORT::FUN_006fd3e0`), reads only the fee word (+0x10 -- agreeing with the server that col 3 is the fee), and its one per-destination gate is the `STORE_TOMB_GATE_IN` special case, a per-player byte the server sends in the talk reply (`0x88b200` -> player+0x20ff); the level range the gate object shows (`UIIT_STT_GOD_LV_EXTENT`) comes from the structure's own object record. Next: the server pass that fills a `CRefTeleport`'s link vector from `CRefTeleLink` rows. |
| Berserk | 10 fns | PARTIAL | docs/protocol/param_registry.md | DamageNumerator, Duration, EarnOnKill, GainChance | THE EARN IS READ (2026-09-19, `internal/berserk`, round in docs/rounds/zerk.md): there is no per-hit gauge -- the only state is RemainHwanCount (charData+0x86), whole orbs earned on the KILLING blow by chance: 8% base (.rdata 0xb45e14), decaying 0.25%/level past a five-level gap to a 0.25% floor for a victim more than three levels below (FUN_0040fe60 class 2), x5 giant, x2 elite, all five orbs certain for a unique (FUN_00410880's table at 0x4109e8), scaled by param 184 when set; no gain while berserk; spend is -5 on activation. Still PARTIAL: the party share (FUN_005bcf30 -- every alive member in the killer's region, only for a party-support monster in an exp-sharing party) is unwired because srrevamp has no party-support monsters; the count is not persisted (the engine's is a DB column); a skill's own hwan cost (EngageSkill: `-skill_ref+0x18`, the Consume_WHAN-style byte) is unwired; param 184's tag and writers are unread. Next: persist RemainHwanCount with the character and read the Consume_WHAN column index to spend it on cast. The duration's UNIT is READ (round 223): the countdown runs in the PC's 1-second timer job (`docs/protocol/character_state.md`), so 60.0 is 60 s. |
| Skills and masteries | 20 fns | PARTIAL | docs/protocol/skill_params.md | MasteryUpCost, MasteryLevelCap | **the mastery-cost probe is DONE** (2026-09-17): `masteryUpCost` is real, from leveldata column 2, with its use-site at `FUN_0059c4e0` -- only the no-table fallback is own design. **Skill damage is DONE for the ordinary damage kind** (2026-09-18): every one of the 33,632 real skill rows falls in exactly one grounded class -- computed (29,619), floor blow of 1 (446), zero (3,567) -- and `DisclosedSkillDamagePerLevel` reaches none of them on a fresh export. **The four other damage kinds are identified** (same day; `damage_pipeline.md`): monster transform, event monster, fortress structure, fortress weapon -- kinds 2 and 4 implemented, none reachable with today's content. What remains is what a NON-damaging skill does instead: of 209 recovered parameters the server reads four, and there is no buff, heal or status system. The heal case is now specified (`docs/protocol/heal.md`): the HP/MP formula, `'nmh'` percent mode and the 170/171 buff scalings, from `Skill_ApplyHealToObject` (`0x005a0850`). What remains is the buff/status write path -- start with `'efr'`, carried by 10,403 skills and read nowhere -- `ApplySkillParamsToChar` (`0x00594ac0`) reads its field `0x28c` |
| Item stats and tooltips | 128 CRef | PARTIAL | docs/protocol/ITEM_FORMAT.md | ReinforceDamage | the durability columns are 63/64 (`Dur_L/Dur_U`) and the plus level is not a column but the instance byte at record+0x2c (2026-09-19, CInstanceItem::CopyFrom); the white-stat percentage a tooltip shows is variance group k / 31 per stat triple (`refobj_binary_format.md`). Unread: the tooltip's own rendering of those in the client, and which of the 12 groups each displayed stat maps to beyond the first nine triples; **a worn piece's defence is its instance's white stat (round 243, v0.1.396)**: `PD_L + q*(PD_U-PD_L)` with `q` from variance group 3 (armour) / 4 (shield) -- `defenderArmor` no longer sums `PhysDefenseMax`; the group-to-stat map is the block order of `Char_BuildAggregateStats`, not the triple index; **a worn weapon's damage and reinforce read the instance too (round 244, v0.1.397)**: the weapon branch interpolates the damage pairs by group 4/5 and the reinforce pairs by group 1/2 between lo/hi columns the export now carries (96/98, 101/103, 106/108, 110/112); **the shield's block rate too (round 245, v0.1.398)**: `BR_L + q*(BR_U-BR_L)` by the shield branch's group 3 (`0x4967b0` -> item+0x1a4, param 10 'bri'). The shield's own PD/MD count too (round 246, v0.1.399): `RefreshEquipParamEntryForPC` walks all 13 equipment slots and `Char_PublishCombatStats(item, pc)` publishes each item's block keyed by the item -- the equip summation site, read |
| Packet protocol | 11 | PARTIAL | docs/protocol/PACKET_FORMAT.md |  | opcode coverage vs the real space is unmeasured |
| Shops and the goods chain | 4 | PARTIAL | docs/protocol/refdata_schema.md |  | repair and item durability |
| Storage and warehouse | 39 | PARTIAL | docs/protocol/server_sql.md | DefaultCapacity | scope AND capacity model are read (2026-09-19, v0.1.390/391): the warehouse and its gold are the ACCOUNT's; the capacity is a per-user row `_ChestInfo.ChestSize` (binder 0x8586e0) loaded at 0x43d980 into char+0x110 with NO in-binary default (a missing row fails the load), ceiling 0x70 from the expander; the client pages it by 30 (CIFStorageRoom::Create builds 0x1e slots, 0x6cd350 addresses cell+page*0x1e). `storage.DefaultCapacity` (50) is DISCLOSED: the starting size is written by the database's user-creation procedure, held in no archive. Next: the storage-expansion item's slot increment (itemdata param) and its `_STRG_ADD_LINKED_STORAGE`/expander path |
| Monster profile and spawns | 36 | PARTIAL | docs/protocol/refdata_schema.md |, RarityHPPercent | the rank HP scale is read and wired (2026-09-19, `CGObjMob::PublishStats`: champion x2, elite x4, giant x20, rank 7 x30, titan x100 as a percent in the 'hp' param; uniques unscaled; a slot-192 mode starts from x10, disclosed as likely 'party monster'); every spawned species is rank 0 today; the real spawn model (per-nest alive cap, uniform respawn window in seconds from the first death out of a full nest, champion/giant roll) is read in Monster AI round 239 and `respawnDelay = 10 s` is disclosed against it; every roster species stands at its real `npcpos` placements (round 253) and strikes no more often than its attack skill's ReuseDelay (round 254: Mangyang 3000 ms, Gyo 2000, Yeoha 2500 -- `combat.Hub.CounterattackReady`), though still only when struck |
| Monster AI | 36 | PARTIAL | docs/protocol/monster_ai.md | StateBattle, FallbackState, DwellExtension | the machine is whole, and all four of its tables are read off their positional parsers -- `_RefTactics` (round 238, 43 columns), `_RefNest` (239, 17), `_RefAISkill` and `_RefHive` (241, 5 and 9): aggression mode/percent, give-up distance, roam-radius rule and 200-unit fallback, the flag word; the nest's alive cap, respawn flag, uniform hatch-delay window in seconds, champion percent (with the engine's `GiantMonster_SpawnRatio`, default 14), the hatch scheduler; the hive's population scaling of the hatch rate (rate x round(sample/divisor), capped). A monster's AI skills are skilldata rows bound by `Basic_Code` through `m_RefSkillByCodename`. Column NAMES are not in the binary. WANDER's leg and every state's dwell are read (round 251: 85+-39 units at a 45..135 degree turn, 30-unit blocked-probe reversal; IDLE 2-6 s, WANDER 5-6 s, FLEE 3-5 s, HOMING 50 s -- `ai.DwellRange`). Next: the BATTLE skill choice (`AI::CAISkill` slots) and HOMING's path |
| Siege and fortress war | 39 | PARTIAL | docs/protocol/siege.md | MinGuildLevel, ValidTaxRatio, CanAttack | registration, tax and the attack rules are grounded; the dungeon caps and structure-upgrade costs are read from a structure, not compared against literals. Read `AQ_Siege::FUN_006232c0` (11,816 bytes), where most of the fortress logic lives |
| Persistence / AsyncQuery | 28 | PARTIAL | docs/protocol/persistence.md | Procs, SlotDoWork, ReferenceTables | the interface and the 71 procedures are whole; no procedure's PARAMETERS are read, and none of the 54 runtime tables has a column layout. Read AQ_CharDataSaver's argument set-up first |
| Guild | 27 | PARTIAL | docs/protocol/guild.md | MaxLevel, LevelUpCost, ValidName | size, level and the level-up costs are grounded; where guild points come from are unread |
| Pets and COS | 23 | PARTIAL | docs/protocol/pets.md | MinOwnerLevel, CheckSummon, PetRequiredLevelOffset | the summon, level and naming rules are grounded; the five switch cases in `GObjPC::FUN_004fcef0` are not mapped to COS kinds, and the hunger gauge (`HGPFULL_NODRINK`) is named but unread |
| Alchemy and enchanting | 19 | PARTIAL | docs/protocol/alchemy.md | ClampRate, LuckyBonus, SuccessBonusParam | the reinforce rate is whole; the base rate's ref-record offset `(tier+21)*32` is not mapped to a column -- count fields through `RefObjItem::ExtractData` (`0x006a3d50`). The other seven operations' slot 6/7 pairs are unread |
| Battle arena | 16 | PARTIAL | docs/protocol/battle_arena.md | Modes, Scorings, ArenaCoinItemKind | the STRUCTURE is grounded and essentially none of the behaviour is -- the mode classes' slots are all unnamed. Read `CGame_BattleArenaSchedule` for how a match starts |
| Timed jobs | 16 | PARTIAL | docs/protocol/timed_jobs.md | Kinds, GetterSlotFor, PetFieldCount | the mechanism, the twelve kinds and the record's arity are grounded; what the thirteen non-timestamp columns hold needs the twelve kinds' getters read, and how a job fires is unread |
| Party | 15 | PARTIAL | docs/protocol/party.md | MaxSize, MinCreatorLevel, CanCreate | size and the creator level are grounded; the invite and expulsion flows are only enumerated, and party flag bit 2 has no probe known to name it |
| Academy and training camp | 11 | PARTIAL | docs/protocol/academy.md | MinFounderLevel, FoundingGold, ReopenCooldownDays | founding is grounded; which of the two membership levels (41/61) is the master role is unread, and the three 24-hour windows are named by the client but not confirmed server-side |
| Jobs, trade routes and market | 11 | PARTIAL | docs/protocol/jobs.md | MinJobLevel, FleaMarketSlots, CheckJoin | the level floor, the three kinds and the market size are grounded; which kind is trader/hunter/thief is unread, and every other limit (distance, wear limits, reward rates) sits behind a helper rather than a literal |
| Durability and repair | 11 fns | SPECIFIED | docs/protocol/durability.md | UnitPrice, MaxUnitsPerRepair, Estimate | BUILT end to end (2026-09-19, docs/rounds/dura.md): per-instance Variance+Durability rolled at creation and carried on every transfer, persisted (mem+SQL migrations); worn/weapon wear in performAttack via RollDurabilityLoss, broken gear inert; OpRepair (0x007a) charges repair.Estimate and the store's authored buttons are wired; additive durability block on the inventory/equipment/move/repair wire; client tooltip shows cur/max and dims a broken icon. Every constant cited to durability.md. Disclosed: warehouse-list block, per-slot repair selection, the broken-icon grey |
| Status effects | 22 appliers | PARTIAL | docs/protocol/status_effects.md | ReachSlack | the VOCABULARY is read (round 248): 25 abnormal-state bits named by the client's icon switch, aligned one-to-one with the server's applier table at pc+0xe0c, and the params thirteen of the appliers write (Myopia -> 183 the range cut, Burn -> parry, Blunting/Frostbite -> speed, Decay/Weakness -> flat defence, Dark -> attack rate, Panic/Combustion -> MaxHP/MaxMP ...). the application is read for the six elemental states (round 249): chance = (100-resist%)/100*base - flat, resist pairs 27..32/145..150 settled per state, kind = icon bit + 1, tick = 'puls' or 2000 ms. srrevamp has no status-effect system. Next: the non-elemental blocks' chance path and the 0xc63c94 duration table |

## How to read the count

**12 specified, 22 partial, 0 open, of 34.** That is the honest headline, and it
is not a percentage of the game — a specified system is one this project can
implement faithfully, not one it has implemented. What srrevamp actually ships is
a separate question, tracked in `docs/TODO.md`.

**No row is OPEN any more**, as of 2026-09-17, and that is a smaller claim than
it sounds. PARTIAL means a spec exists and the gap is named; it does not mean
the system is nearly done. Battle arena is the honest floor — its structure is
grounded and essentially none of its behaviour is — and the distance between
that row and, say, Monster AI is larger than the distance between OPEN and
PARTIAL ever was.

What the sweep bought is that **every system now has a spec document and a named
next probe**, so no row is a question mark, and the remaining work is legible
rather than merely unstarted.

Two probes recur across several rows and are the highest-value targets left:

- **`RefObjItem::ExtractData` (`0x006a3d50`, 7,052 bytes)** is a sequential
  field-by-field deserializer, and mapping its offsets to columns would unblock
  the packed reinforce rates in `alchemy.md` *and* the repair price basis in
  `durability.md`. One function, two rows. `client/tools/re/fields.py` reads
  these deserializers mechanically and is **validated** as of 2026-09-17 — it
  returns exactly the 58 fields known for `_RefObjCommon`, with three anchors
  landing — and gives `RefObjItem` 153 fields, 79 offsets resolved. The offsets
  those two rows need are in the unresolved gap (`0x2a0..0x520`, written through
  walking pointers), and `+0xa4` is written by two different `ExtractData`
  functions, so which record it belongs to must be settled first.
- **`AQ_Siege::FUN_006232c0` (11,816 bytes)** holds most of the fortress logic,
  including the dungeon caps and the structure-upgrade costs.

Quest scripting was the first row taken, and it went SPECIFIED then straight
back to PARTIAL within the same session — which is the tracker working. The
lifecycle is recovered in full (15 events, 12 per-target kill hooks, the
`CEVENTHandler` slot-1 dispatch). What the first pass got wrong was the
denominator: there are **696 quests**, not 153. 153 is the count of *compiled*
ones. The other **543 have no compiled class and no objective row in either data
file**, and until that is explained the system is not specified.

## Adding a row

A system moves to SPECIFIED only when its spec exists and says what the engine
does in order, with citations. Half-knowledge belongs in PARTIAL with the gap
named, the way Berserk names the fill rate as the one number still ours.
