# The fortress war

The largest system in `docs/SYSTEMS.md` by class count — 39 classes — and the
one with the richest refusal vocabulary in the whole protocol: **111 of the 609
codes in `docs/protocol/error_codes.md` are fortress codes.**

Implemented as a rule set in `server/internal/siege`. srrevamp has no fortress
war and is not about to grow one; the point of this page is that building one
later starts from the game's own numbers.

## How this was recovered, because the method generalises

Every requirement below came out of the same two-step move:

1. Find the server functions that return a fortress code —
   **69 of them** mention one.
2. Annotate each code with its client name from `error_codes.md`, then read the
   branch that produces it.

Step 2 is what makes the checks legible. A branch returning `0x280c` is not
"the fifth test in the registration path"; it is `TOOLESSGUILDLV`, and the
comparison right above it is therefore the minimum guild level. Nothing had to
be inferred from the shape of the arithmetic.

## Registering for a war — `FUN_00633910`

Read in the order the function tests, because the order is visible to players:
a guild failing two requirements is told about whichever comes first.

| # | check | refusal |
|---|---|---|
| 1 | the character is in a guild (`char[0x72f] != 0`) | `0x280b` `FORT_ETC_ERROR_NOTJOINGUILD` |
| 2 | neither the guild nor the fortress is already held | `0x2811` `FORT_ETC_ERROR_ALREADYPOSSESSFORT` |
| 3 | the alliance matches | `0x2812` `FORT_ETC_ERROR_WRONGALLIANCE` |
| 4 | the character is the guild master | `0x2807` `FORT_ETC_ERROR_ONLYGUILDMASTER_ACTION` |
| 5 | **guild level ≥ 3** | `0x280c` `FORT_ETC_ERROR_TOOLESSGUILDLV` |
| 6 | **guild members ≥ 7** | `0x280d` `FORT_ETC_ERROR_TOOLESSGUILDMB` |
| 7 | enough gold | `0x280f` `INTERACTION_FAIL_NOT_ENOUGH_MONEY` |
| 8 | not already applied | `0x2810` `FORT_OFFICIAL_FORTWAR_APPLY_ERROR_03` |

then `AQ_Siege__QUERY_SIEGE_REQUEST_ADD`, and the answer goes out on opcode
`0xb05e`.

The two numbers are literals:

	if (GuildLevel() < 3)                 -> 0x280c
	if (*(byte *)(guild + 0x24) < 7)      -> 0x280d

**`guild + 0x24` is the member count, and that is a cross-check rather than a
new reading.** `server/internal/guild` already treats that offset as the member
count, from a completely different function — the "is this guild full"
predicate at `0x005d0fb0`, which compares the per-level capacity table against
the same field. Two unrelated checks reading one offset the same way is what
makes it safe.

Note also what the level-1 capacity means here: a level-1 guild holds **15**
members (`guild.MaxMembersByLevel`), so the seven-member floor is not the
binding constraint — the level-3 requirement is.

## Tax — `FUN_0062f640`

The ratio is validated straight off the packet before anything else:

	62f68c  mov ebx,DWORD PTR [esp+0x10]   ; the ratio, 16-bit
	62f690  lea ecx,[ebx+0x14]             ; + 20
	62f693  cmp cx,0x28                    ; against 40
	62f697  ja  reject                     ; UNSIGNED above

so the accepted set is `(uint16)(ratio + 20) <= 40`, which as a signed value is
**−20 to +20 inclusive**. One unsigned comparison rather than two signed ones is
the usual compiler shape for a symmetric range, which is why it looks stranger
than it is. `server/internal/siege` reproduces the instruction, not the range,
and tests it across all 65,536 inputs.

Two further refusals:

- setting the ratio to the value it already holds → `0x2838`
  `FORT_MANAGER_TAX_ERROR_03` (the current value comes from
  `AQ_Siege::FUN_0061ca10`);
- anyone but the guild master → `0x2807`.

Accepted changes go to `AQ_Siege__QUERY_SIEGE_TAX_RATIO`, and the answer on
`0xb05e`.

**A negative tax is legal**, which is worth stating because it is the kind of
thing a reimplementation would clamp to zero without noticing.

**And the paying side agrees (round 321).** `Fortress_TaxRatioForActor`
(`0x004862a0`) -- the term a teleport fee gains at a fortress-controlled gate --
reads the ratio as a short at `fortress[4] + 0x20` and returns it unchanged when
it is below 1, so a negative ratio reaches the fee rather than being floored.
The setting side and the paying side were read from different functions on
different days and say the same thing.

## Attacking a fortress structure — vtable slot 395

`CGObjSiegeStruct::vslot_395` (`0x0052c500`) and `CGObjSiegeObject::vslot_395`
(`0x0052c6a0`) both answer "may this attack proceed", returning 1 to permit or 0
with a code. `CGObjPC::vslot_395` (`0x0052bf90`) is the player's counterpart.

	if (!FortressWarPeriodActive())        -> 0x3043  CAN_ONLYPERIODFORT
	if (bodyMode(attacker) == 2            -> 0x3020  CANT_ATTACK_FORTRESS
	 || bodyMode(target) in {2, 3, 4})
	if (same guild || allied guild)        -> 0x303c  CANT_ATTACK_ALLYGUILD
	otherwise permit

**The war period is tested first, before the target is examined at all.**
Outside it a fortress structure cannot be attacked by anyone.

The body-mode byte is vtable slot 64 (`+0x100`), the same enum berserk rides on.
**Which three modes 2, 3 and 4 are is NOT recovered** — only that these are the
values this check rejects.

The related codes `CAN_ATTACK_ATTGUILD` and `CAN_ATTACK_DEFGUILD` appear in
`CGObjPC::vslot_395`, so attacker and defender are distinguished on the player
path; that function is 1,389 bytes and has not been read through.

## The dungeon — `FUN_00630450` (create), `FUN_00630760` (enter)

A fortress carries a dungeon with its own lifecycle, refused by:

| code | name | what it gates |
|---|---|---|
| `0x2842` | `FORTRESS_ERR_NOT_FOUND_DUNGEON` | no such dungeon |
| `0x2843` | `FORTRESS_ERR_CANT_CREATE_DUNGEON_BY_MAX_COUNT` | a cap on simultaneous dungeons |
| `0x2844` | `FORTRESS_ERR_ALREADY_CREATED_DUNGEON` | one already exists |
| `0x2845` | `FORTRESS_ERR_FAILED_CREATE_DUNGEON` | creation failed |
| `0x2847` | `FORTRESS_ERR_NOT_CREATED_DUNGEON` | entering one that does not exist |
| `0x2848` | `FORTRESS_ERR_IMPOSSIBLE_ENTRY_DUNGEON` | |
| `0x2849` | `FORTRESS_ERR_IMPOSSIBLE_ENTRY_DUNGEON_BY_FULL` | an occupancy cap |
| `0x284b` | `FORTRESS_ERR_NOT_CREATED_TIME_DUNGEON` | outside the creation window |

**Neither cap's number is recovered.** Both the max count and the occupancy
limit are read from a structure rather than compared against a literal, so there
is nothing to quote. That is the honest state: the *rules* are enumerated, the
*numbers* are not.

**The structure's fields are now named**, which narrows it. `_SiegeFortress`
introduces `CreatedDungeonCount` and `CreatedDungeonTime` to the binary's schema
pool (`docs/protocol/db_columns.md`), alongside `TaxRatio`, `Tax`, `NPCHired`,
`TempGuildID`, `Introduction` and `IntroductionModificationPermission`. So the
max-count check compares against a per-fortress **database column**, not a
constant — which is why no literal was found, and means the cap is server
configuration rather than a recoverable engine value.

Entry also charges — the path can refuse with `0x280e`
`ERROR_GUILD_LEVEL_UP_GP_DEFICIT` or `0x280f` `NOT_ENOUGH_MONEY`, so a dungeon
entry costs both guild points and gold.

## The rest of the surface, enumerated but unread

| area | functions | codes |
|---|---|---|
| structures: build, upgrade, repair | `0x00633ec0`, `0x00634020`, `0x006341b0`, `0x00634c90`, `0x00634350` | `STRUCTURE_ACTION_ERROR_01..06`, `ALREADY_BUILD`, `DELAYTIME`, `NOTBUILD`, `NOTDESTROYGUARD`, `BATTLEAIDE_REPAIR_FAIL`, `BATTLEAIDE_UPGRADE_FAIL..FAIL4` |
| the smith | `0x00632660`, `0x00632a50`, `0x00633170`, `0x006333c0` | `SMITH_PRODUCT_ERROR_01..06` |
| granting positions | `0x005c7bb0` | `POSITION_GRANT_FAIL_01..06` |
| item use inside a fortress | `0x0049cc80`, `0x0049dc80`, `0x0049e0b0`, `0x0049e620`, `0x0049eb10` | `ITEMUSE_ERR_NOTPORTAL`, `ITEMUSE_ERR_NUMLIMIT`, `NOT_USE_ITEM`, `PORTALSTONE_FAIL_02/04` |
| the big one | `AQ_Siege::FUN_006232c0`, **11,816 bytes** | most of the `FORTRESS_ERR_*` family |

## The database surface

Nine stored procedures, with the argument counts read from their call literals:

	_SiegeFortressRequestSiege      4      _SiegeFortressTaxCollect       3
	_AddSiegeFortressObject        10      _SiegeFortressEngageBlessBuff  3
	_SiegeFortressHireNPC           5      _SiegeFortressEntryDungeon     2
	_UpdateSiegeFortressTaxRatio    2      _SiegeFortressFinished         1
	                                       _SiegeFortressTempFinished     1

Eleven reference tables — `_REFSIEGEBLESSBUFF`, `_REFSIEGEDUNGEON`,
`_REFSIEGEFORTRESS`, `_REFSIEGEFORTRESSBATTLERANK`, `_REFSIEGEFORTRESSGUARD`,
`_REFSIEGEFORTRESSITEMFORGE`, `_REFSIEGEFORTRESSREWARDS`,
`_REFSIEGELVLSUMMONMONSTER`, `_REFSIEGEQUEST`, `_REFSIEGEQUESTREWARD`,
`_REFSIEGESTRUCTUPGRADE` — and two runtime tables, `_SIEGEFORTRESSSTRUCT` and
`_LOGEVENTSIEGEFORTRESS`. **None has a column layout recovered**, which is the
same gap `docs/protocol/refdata_tables.md` records for 77 of the 85.

## The classes

| class | vtable | slots |
|---|---|---|
| `CGObjSiegeStruct` | `0x00af04fc` | 411 |
| `CGObjSiegeObject` | `0x00aefda4` | 408 |
| `CGameWorld_Siege` | `0x00b00fdc` | 62 |
| `CInstanceSiegeFortressStruct` | `0x00b0d1e4` | 20 |
| `CInstanceSiegeFortressObject` | `0x00b0d86c` | 18 |
| `CSiegeWorldContextController` | `0x00b01468` | 14 |

The two 400-slot classes are `IGObj` descendants — they share the object vtable
every world entity has, which is why a siege structure can be attacked, damaged
and killed through the same paths a monster is.

## What would close this row

The dungeon caps and the structure-upgrade costs are the two places where a real
number is being read from a structure this project has not mapped. Both lead to
the same place: **`AQ_Siege::FUN_006232c0`, 11,816 bytes**, which is where most
of the fortress logic lives and which no pass has read through.

## What a structure IS, and what a fortress weapon does (2026-09-18)

Recovered from the damage path rather than from `AQ_Siege`, and recorded here because this is the
page that will need it. Full evidence in `damage_pipeline.md`, "ONE of five damage kinds".

- **A fortress structure is TypeID (1,2,5,\*)** — `CGObj::IsFortressStructure`, slot 248. Real
  `characterdata` has 71: `STRUCTURE_FORT_STONE_*` (5,1), `STRUCTURE_GUARD_TOWER_*` /
  `STRUCTURE_LIGHTNING_TOWER_*` (5,2), `STRUCTURE_BIG_GATE_*` (5,3),
  `STRUCTURE_SMALL_DEFENSIVE_POSITION_*` (5,4), `STRUCTURE_HEADQUARTERS_*` (5,5),
  `STRUCTURE_BARRICADE_*` (5,6).
- **A fortress flag is TypeID (1,2,4,2)** — `CGObj::IsFortressFlag`, slot 244. Five rows:
  `STRUCTURE_AGGRESSIVE_FLAG`, `_DEFENSIVE_FLAG`, `_HEALING_FLAG` and two `_UP`. The rest of
  (1,2,4,\*) is NOT structures: (4,1) and (4,4) are `COS_GUARD_*` and (4,3) is `MOB_FW_*`, which is
  why slot 244 tests TypeID4 and slot 248 does not.
- **A PC's blow against either is damage kind 3**, computed by `FUN_0040f990` (736 bytes) after
  reading the attacker's weapon TID. **Unread** — it is the next probe for structure damage.
- **A fortress weapon (weapon-slot TypeID4 == 16) deals exactly 1 to anything that is not a
  structure or flag** — damage kind 4. Implemented as `combat.KindFortressWeapon`.
