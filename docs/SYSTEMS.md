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

**This file is checked by a test.** `internal/systems` parses it on every
`go test` run and fails if a row's spec document is missing, if a row claims
SPECIFIED without one, or if a row claims OPEN while a spec exists. Both of this
project's previous forward-looking summaries — the RE_COMPLETION work queue and
GROUNDING_AUDIT — rotted silently and had to be corrected on 2026-09-17; this
one cannot rot the same way without the build going red.

## Status

| System | Classes | Status | Spec | Anchors |
|---|---|---|---|---|
| Damage pipeline | ~156 fns | SPECIFIED | docs/protocol/damage_pipeline.md | MitigateDamage, ApplyFloorBand, ApplySkillPercent |
| Death penalty and death causes | 6 fns | SPECIFIED | docs/protocol/damage_pipeline.md | DeathCause, DeathPenaltyFactorFor, DeathPenaltyExp |
| Passive regeneration | 4 fns | SPECIFIED | docs/protocol/param_registry.md | RegenPerTick, RegenInterval |
| `_RefObjCommon` binary format | 3 parsers | SPECIFIED | docs/protocol/refobj_binary_format.md | ItemCSVColumnCount |
| Item requirements | 2 fns | SPECIFIED | docs/protocol/item_requirements.md | CheckRequirements, RequirementsOf |
| Item capability flags | 9 fns | SPECIFIED | docs/protocol/item_capability_flags.md | CanTrade, CanSell |
| Equipment slots | 4 fns | SPECIFIED | docs/protocol/EQUIP_SLOTS.md | SlotFor, MaxEquipSlots |
| ParamKeeper registry | 120 params | SPECIFIED | docs/protocol/param_registry.md | StrLevelDamageRatio, StrForMaxRatio |
| IGObj vtable | 208 slots | SPECIFIED | docs/protocol/igobj_vtable.md | |
| Magic-option vocabulary | 53 tags | SPECIFIED | docs/protocol/magic_options.md | ParamFor, PackTag |
| Levelling and EXP | 8 fns | SPECIFIED | docs/protocol/param_registry.md | DeathPenaltyMinLevel, StatPointsPerLevel |
| Quest scripting | 153 quests, 193 handlers | SPECIFIED | docs/protocol/quest_scripting.md | |
| Berserk | 6 fns | PARTIAL | docs/protocol/param_registry.md | DamageNumerator, Duration, FillPerHit |
| Skills and masteries | 20 fns | PARTIAL | docs/protocol/skill_params.md | |
| Item stats and tooltips | 128 CRef | PARTIAL | docs/protocol/ITEM_FORMAT.md | ReinforceDamage |
| Packet protocol | 11 | PARTIAL | docs/protocol/PACKET_FORMAT.md | |
| Shops and the goods chain | 4 | PARTIAL | docs/protocol/refdata_schema.md | |
| Storage and warehouse | 39 | PARTIAL | docs/protocol/db_schema.md | |
| Monster profile and spawns | 36 | PARTIAL | docs/protocol/refdata_schema.md | |
| Siege and fortress war | 39 | OPEN | — | |
| Monster AI | 36 | OPEN | — | |
| Persistence / AsyncQuery | 28 | OPEN | — | |
| Guild | 27 | OPEN | — | |
| Pets and COS | 23 | OPEN | — | |
| Alchemy and enchanting | 19 | OPEN | — | |
| Battle arena | 16 | OPEN | — | |
| Timed jobs | 16 | OPEN | — | |
| Party | 15 | OPEN | — | |
| Academy and training camp | 11 | OPEN | — | |
| Jobs, trade routes and market | 11 | OPEN | — | |
| Reference tables (the other 120) | 120 | OPEN | — | |
| Teleport network | ? | OPEN | — | |
| Durability and repair | ? | OPEN | — | |

## How to read the count

**12 specified, 7 partial, 14 open, of 33.** That is the honest headline, and it
is not a percentage of the game — a specified system is one this project can
implement faithfully, not one it has implemented. What srrevamp actually ships is
a separate question, tracked in `docs/TODO.md`.

The open rows are ordered by class count, which is a rough proxy for effort, not
for value.

Quest scripting was the first row taken, and it shows what "specified" buys: the
346 classes turned out to be 153 quests plus 193 nested handler classes over a
**15-event lifecycle** — not the three-handler triple the previous note
recorded — plus 12 named per-target kill hooks. Specifying the lifecycle covers
all 153 quests; specifying what any individual quest *does* is separate and is
not claimed.

## Adding a row

A system moves to SPECIFIED only when its spec exists and says what the engine
does in order, with citations. Half-knowledge belongs in PARTIAL with the gap
named, the way Berserk names the fill rate as the one number still ours.
