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
| Reference-table catalogue | 85 tables | PARTIAL | docs/protocol/refdata_tables.md |  | 77 of 85 tables unread; read one when a value needs it |
| Teleport network | 3 tables | PARTIAL | docs/protocol/teleport_network.md |  | cols 3/8/9 of teleportlink (cost, level range) are inferred; read the `_REFTELELINK` consumer at `0x0082d770` |
| Berserk | 6 fns | PARTIAL | docs/protocol/param_registry.md | DamageNumerator, Duration, FillPerHit | the gauge fill rate; no probe known to exist (the magnitudes are DB rows) |
| Skills and masteries | 20 fns | PARTIAL | docs/protocol/skill_params.md |  | mastery cost `masteryUpCost` is own design; find its use-site |
| Item stats and tooltips | 128 CRef | PARTIAL | docs/protocol/ITEM_FORMAT.md | ReinforceDamage | durability and plus-level columns unread |
| Packet protocol | 11 | PARTIAL | docs/protocol/PACKET_FORMAT.md |  | opcode coverage vs the real space is unmeasured |
| Shops and the goods chain | 4 | PARTIAL | docs/protocol/refdata_schema.md |  | repair and item durability |
| Storage and warehouse | 39 | PARTIAL | docs/protocol/db_schema.md |  | per-account vs per-character scope |
| Monster profile and spawns | 36 | PARTIAL | docs/protocol/refdata_schema.md |  | AI behaviour, not stats -- see Monster AI |
| Siege and fortress war | 39 | OPEN | — |  | 39 classes; start at CRefSiegeFortress and the 11 _REFSIEGE* tables |
| Monster AI | 36 | OPEN | — |  | 36 classes under AI::; start at AI::CAIHive and CAISkill |
| Persistence / AsyncQuery | 28 | OPEN | — |  | 28 AQ_* classes; the 75 stored procedures are already enumerated |
| Guild | 27 | OPEN | — |  | 27 classes; CGuildManager and the guild tables |
| Pets and COS | 23 | OPEN | — |  | 23 classes; CGObjCOS and CGItemCOSSummoner |
| Alchemy and enchanting | 19 | OPEN | — |  | 19 classes; CEnchant_* and the _REFALCHEMYMERIT table |
| Battle arena | 16 | OPEN | — |  | 16 classes; CBattleArenaInfo* |
| Timed jobs | 16 | OPEN | — |  | 16 CTJ_* classes; CTimedJob::Create is already named |
| Party | 15 | OPEN | — |  | 15 classes; CParty and the party packet handlers |
| Academy and training camp | 11 | OPEN | — |  | 11 classes; CInstanceTrainingCamp* |
| Jobs, trade routes and market | 11 | OPEN | — |  | 11 classes; CInstanceCharTrijob and CFleaMarket |
| Durability and repair | ? | OPEN | — |  | itemdata durability columns are known; the repair path is not |

## How to read the count

**11 specified, 10 partial, 12 open, of 33.** That is the honest headline, and it
is not a percentage of the game — a specified system is one this project can
implement faithfully, not one it has implemented. What srrevamp actually ships is
a separate question, tracked in `docs/TODO.md`.

The open rows are ordered by class count, which is a rough proxy for effort, not
for value.

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
