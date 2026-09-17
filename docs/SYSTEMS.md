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
| Damage pipeline | ~156 fns | SPECIFIED | docs/protocol/damage_pipeline.md | MitigateDamage, ApplyFloorBand, ApplySkillPercent | stages 17+ run to 0x40e819 and are unread; nothing needs them |
| Death penalty and death causes | 6 fns | SPECIFIED | docs/protocol/damage_pipeline.md | DeathCause, DeathPenaltyFactorFor, DeathPenaltyExp | — |
| Passive regeneration | 4 fns | SPECIFIED | docs/protocol/param_registry.md | RegenPerTick, RegenInterval | the curHP*0.5 bound at 0x004e2c00 is read but its comparison is not |
| `_RefObjCommon` binary format | 3 parsers | SPECIFIED | docs/protocol/refobj_binary_format.md | ItemCSVColumnCount | — |
| Item requirements | 2 fns | SPECIFIED | docs/protocol/item_requirements.md | CheckRequirements, RequirementsOf | — |
| Item capability flags | 9 fns | SPECIFIED | docs/protocol/item_capability_flags.md | CanTrade, CanSell | — |
| Equipment slots | 4 fns | SPECIFIED | docs/protocol/EQUIP_SLOTS.md | SlotFor, MaxEquipSlots | — |
| ParamKeeper registry | 120 params | SPECIFIED | docs/protocol/param_registry.md | StrLevelDamageRatio, StrForMaxRatio | — |
| IGObj vtable | 208 slots | SPECIFIED | docs/protocol/igobj_vtable.md |  | — |
| Magic-option vocabulary | 53 tags | SPECIFIED | docs/protocol/magic_options.md | ParamFor, PackTag | — |
| Levelling and EXP | 8 fns | SPECIFIED | docs/protocol/param_registry.md | DeathPenaltyMinLevel, StatPointsPerLevel | — |
| Quest scripting | 696 quests, 153 compiled | PARTIAL | docs/protocol/quest_scripting.md |  | **BLOCKED**: how the 543 classless quests attach. CQuestBase's slot-55 default is not reachable via the dump's slot tags; needs the vtable read directly in Ghidra |
| Reference-table catalogue | 85 tables | PARTIAL | docs/protocol/refdata_tables.md | ReferenceTables, ClientTextdata | the count is PROVEN complete, and **51 of the 85 are readable right now** from `Media.pk2` -- the mapping is `persistence.ClientTextdata`. The other 34 are server-only, 17 of them the loot tables, which is measured rather than assumed. Read a readable one when a value needs it |
| Teleport network | 3 tables | PARTIAL | docs/protocol/teleport_network.md |  | cols 3/8/9 of teleportlink (cost, level range) are inferred; read the `_REFTELELINK` consumer at `0x0082d770` |
| Berserk | 6 fns | PARTIAL | docs/protocol/param_registry.md | DamageNumerator, Duration, FillPerHit | the gauge fill rate; no probe known to exist (the magnitudes are DB rows) |
| Skills and masteries | 20 fns | PARTIAL | docs/protocol/skill_params.md | MasteryUpCost, MasteryLevelCap | **the mastery-cost probe is DONE** (2026-09-17): `masteryUpCost` is real, from leveldata column 2, with its use-site at `FUN_0059c4e0` -- only the no-table fallback is own design. What remains is skill damage: `DisclosedSkillDamagePerLevel` is still own design |
| Item stats and tooltips | 128 CRef | PARTIAL | docs/protocol/ITEM_FORMAT.md | ReinforceDamage | durability and plus-level columns unread |
| Packet protocol | 11 | PARTIAL | docs/protocol/PACKET_FORMAT.md |  | opcode coverage vs the real space is unmeasured |
| Shops and the goods chain | 4 | PARTIAL | docs/protocol/refdata_schema.md |  | repair and item durability |
| Storage and warehouse | 39 | PARTIAL | docs/protocol/db_schema.md |  | per-account vs per-character scope |
| Monster profile and spawns | 36 | PARTIAL | docs/protocol/refdata_schema.md |  | AI behaviour, not stats -- see Monster AI |
| Monster AI | 36 | PARTIAL | docs/protocol/monster_ai.md | StateBattle, FallbackState, DwellExtension | the machine is whole; the four DB tables that configure it (`TAB_REFTACTICS`, `_REFNEST`, `_REFHIVE`, `_REFAISKILL`) have no column layout. Read `CRefTactics`' parse method -- the loader at `0x008334e0` only installs the class |
| Siege and fortress war | 39 | PARTIAL | docs/protocol/siege.md | MinGuildLevel, ValidTaxRatio, CanAttack | registration, tax and the attack rules are grounded; the dungeon caps and structure-upgrade costs are read from a structure, not compared against literals. Read `AQ_Siege::FUN_006232c0` (11,816 bytes), where most of the fortress logic lives |
| Persistence / AsyncQuery | 28 | PARTIAL | docs/protocol/persistence.md | Procs, SlotDoWork, ReferenceTables | the interface and the 39 procedures are whole; no procedure's PARAMETERS are read, and none of the 35 runtime tables has a column layout. Read AQ_CharDataSaver's argument set-up first |
| Guild | 27 | PARTIAL | docs/protocol/guild.md | MaxLevel, LevelUpCost, ValidName | size, level and the level-up costs are grounded; the alliance rules (`FUN_005c6550`), guild war (`FUN_005c6b60`) and where guild points come from are unread |
| Pets and COS | 23 | PARTIAL | docs/protocol/pets.md | MinOwnerLevel, CheckSummon, PetRequiredLevelOffset | the summon, level and naming rules are grounded; the five switch cases in `GObjPC::FUN_004fcef0` are not mapped to COS kinds, and the hunger gauge (`HGPFULL_NODRINK`) is named but unread |
| Alchemy and enchanting | 19 | PARTIAL | docs/protocol/alchemy.md | ClampRate, LuckyBonus, SuccessBonusParam | the reinforce rate is whole; the base rate's ref-record offset `(tier+21)*32` is not mapped to a column -- count fields through `RefObjItem::ExtractData` (`0x006a3d50`). The other seven operations' slot 6/7 pairs are unread |
| Battle arena | 16 | PARTIAL | docs/protocol/battle_arena.md | Modes, Scorings, ArenaCoinItemKind | the STRUCTURE is grounded and essentially none of the behaviour is -- the mode classes' slots are all unnamed. Read `CGame_BattleArenaSchedule` for how a match starts |
| Timed jobs | 16 | PARTIAL | docs/protocol/timed_jobs.md | Kinds, GetterSlotFor, PetFieldCount | the mechanism, the twelve kinds and the record's arity are grounded; what the thirteen non-timestamp columns hold needs the twelve kinds' getters read, and how a job fires is unread |
| Party | 15 | PARTIAL | docs/protocol/party.md | MaxSize, MinCreatorLevel, CanCreate | size and the creator level are grounded; the invite and expulsion flows are only enumerated, and party flag bit 2 has no probe known to name it |
| Academy and training camp | 11 | PARTIAL | docs/protocol/academy.md | MinFounderLevel, FoundingGold, ReopenCooldownDays | founding is grounded; which of the two membership levels (41/61) is the master role is unread, and the three 24-hour windows are named by the client but not confirmed server-side |
| Jobs, trade routes and market | 11 | PARTIAL | docs/protocol/jobs.md | MinJobLevel, FleaMarketSlots, CheckJoin | the level floor, the three kinds and the market size are grounded; which kind is trader/hunter/thief is unread, and every other limit (distance, wear limits, reward rates) sits behind a helper rather than a literal |
| Durability and repair | 5 fns | PARTIAL | docs/protocol/durability.md | UnitPrice, MaxUnitsPerRepair, Estimate | the repair cost model is whole; what CONSUMES durability is entirely unread, and `refRecord[0xa4]` has no column mapping -- which needs `RefObjItem::ExtractData` counted through, the same function alchemy is blocked on |

## How to read the count

**11 specified, 22 partial, 0 open, of 33.** That is the honest headline, and it
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
