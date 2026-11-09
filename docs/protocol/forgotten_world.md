# The Forgotten World

Round 868, stage 1: the specification of the Forgotten World ("잊혀진 세계", the engine's `GOD`
worlds) -- how a party gets a Dimension hole, makes a gate, enters an instance, clears it and
leaves -- as the contract stage 2's lanes build from. It sits on the instanced-world foundation in
[game_worlds.md](game_worlds.md), which must be built first (its section 14). The build checklist for
the Forgotten World itself is section 11; stage 2's size is section 12.

Labels as in `game_worlds.md`: **READ** (`s:` SR_GameServer.exe, `m:` SR_ShardManager.exe, `c:`
sro_client.exe), **MEASURED** (observed in the running game, or counted in the reference tables and
the archives), **INFERRED**, **OURS**, **OPEN**. Texts are quoted from the client's English text table.

## 1. The 22 worlds

`INS_GOD_<theme>_<band>_LEVEL_<grade>` (MEASURED, `_RefGame_World` 63..84, all Type 1,
WorldMaxCount 50, duration 2 h, empty close 10 min; `game_worlds.md` 1):

| ids | theme (`UIIT_STT_GOD_*`) | band | grades (stars) | max players | map | start |
|---|---|---|---|---|---|---|
| 63, 64 | Togui village (`TOGUI`) | 35-50 | 1, 2 | 4 | 48 field regions 0x79E1..0x7EE8 | 0x7EE4 (1063, 693, 1125) |
| 65, 66 | Togui village | 51-60 | 1, 2 | 4 | the same | the same |
| 67, 68 | Togui village | 61-70 | 1, 2 | 4 | the same | the same |
| 69..72 | Flame Mountain (`FLAME`) | 71-80 | 1, 2, 3, 4 | 4, 4, 8, 8 | dungeon 0x8012 (`flame.dof`) | (10897, 165, -6110) |
| 73..76 | Flame Mountain | 81-90 | 1..4 | 4, 4, 8, 8 | the same | the same |
| 77, 78 | Wrecked Ship, inside (`WRECK_IN`) | 91-100 | 1, 2 | 4 | 224 field regions 0x68ED..0x75FC | 0x72F3 (264, -770, 1745) |
| 79, 80 | Wrecked Ship, outside (`WRECK_OUT`) | 91-100 | 3, 4 | 8 | 224 field regions 0x68DC..0x75EB | 0x6FE4 (1257, -247, 1771) |
| 81, 82 | Wrecked Ship, inside | 101-110 | 1, 2 | 4 | as 77 | as 77 |
| 83, 84 | Wrecked Ship, outside | 101-110 | 3, 4 | 8 | as 79 | as 79 |

Every world's config (MEASURED, rows 424..693): the level band (the Wreck 100_110 worlds start at
**101**), `JOB_CLOTHES_TAKE_OFF`, `RIDE_COS_NOT_RIDING`, `TRADE_COS_NOT_RIDING`,
`FRPVP_VOUCHER_TAKE_OFF` all ON, `PARTYMONSTER_SPAWN` OFF, `CONTROL_NOTIFY_SPAWN_UNIQUE_MONSTER_MSG`
ON, `GAMEWORLD_DISAPPEARANCE_TIME` 3,600,000 / 600,000 / 300,000, and (Togui only)
`MAX_SQUAD_MEMBER_COUNT` 30. All 22 are in world group 1, `GROUP_INS_GOD` (the 5-hour re-entry limit,
`game_worlds.md` 1.3). The client's `UIIT_STT_GOD_LV_EXTENT_1` reads "41~50 lv" although band 1 is
35-50 (MEASURED texts; the gate window prints the item's own numbers, section 4).

**Contents per world** (MEASURED, `Tab_RefHive.GameWorldID` -> nests):

| worlds | nests | monsters (sum of caps) | dormant nests | uniques / bosses (rarity 3, 8) | triggers |
|---|---|---|---|---|---|
| Togui (each) | 122 | 406 | 36 | 5 | 17 |
| Flame grades 1, 2, 3 | 76 | 274 | 21 | 5 | 18 |
| Flame grade 4 | 76 | 402 | 21 | 5 | 18 |
| Wreck inside | 41 | 213 | 15 | 4 | 13 |
| Wreck outside grade 3 | 61 | 357 | 17 | 6 | 13 |
| Wreck outside grade 4 | 61 | 459 | 17 | 6 | 13 |

Each world's monsters are its own codenames by grade (`MOB_GOD_TOGUI_*_A1` in world 63, `_A2` in 64,
`_B1` in 65, ...; `MOB_GOD_FLAME_*`, `MOB_GOD_GHOST_*` for the Wreck). The bosses of the
grade-1 worlds: Togui `TOGUIELDER` (rarity 3, 1,275,761 HP at A1) with `TOGUIGENERAL` and
`TOGUICAPTAIN` (rarity 8); Flame `COWKING` (3) with `ADJUTANT` and `CAPTAIN` (8); Wreck `UNDINE` (3)
with `BEAST` and `GLUTTONY` (8). Each world also has `ENVY` monsters (rarity 1, or 6 at grades 3/4),
two `TREASUREBOX` nests, two `NPC_INS_EXIT_TELEPORT` and three to five `NPC_FWORLD_RECALL_PARTY`
(all as nests in the world's hive; no `_RefGameWorldNPC` rows).

## 2. Getting a Dimension hole

**The items** (MEASURED, `_RefObjCommon` / `_RefObjItem`): `ITEM_ETC_TELEPORT_HOLE_<theme>_<band>_LEVEL_<grade>`,
ids **35883..35904** in the order of worlds 63..84, TypeID 3/3/12/7, icon `item\etc\teleprot_hole.ddj`,
stack 1, tradeable, sellable (1 gold), Service 1. `ITEM_ETC_TELEPORT_HOLE` (35577) is Service 0.
Params:

| param | value | READ / INFERRED |
|---|---|---|
| Param1 | 1..4 | the grade (stars); the client's tooltip and gate window read it (c:0x9e9eb0 via +0x2b4, INFERRED offset) |
| Desc2 | `INS_GOD_...` | the world codename |
| Param3 / Param4 | band min / max | level check at use (0x1851, READ) and the "Level : 35 - 50" lines |
| Param5 | 4 or 8 | the max players: READ c:0x66f400 prints UIIT_STT_PARTY_SUMMON "Number of Players Allowed: 1-%d" with ref +0x2c4 (Param5; round 869) |
| Param6 | 6 | the gate's access condition type (READ s:0x4865a0: 6 = only the creator's character, 7 = the creator's party); with 7 the user must also be the party master (READ s:0x4a0979, 0x184f). **Every row of the measured data is 6** (choice 1) |
| Param7 | 1 | INFERRED the min players (the tooltip's "1-" is the text's own, not Param7: READ c:0x66f400) |
| Desc8 | `INS_QUEST_TELEPORT` | the gate structure (RefObjID 19556, TypeID 4/1/2, `quest\ins_quest_teleport.bsr`) |
| Desc9 | `UIIT_STT_GOD_TOGUI` / `_FLAME` / `_WRECK` | the theme's name |
| Param10 / Desc10 | 18,000,000 / `COOLTIME:0x00000071` | the reuse cool time: 5 h, group 0x71 shared by every hole |

MEASURED tooltip (grade 2): "Dimension Hole (Togui Village-★★)", "Sort of item: Dimension Hole",
"Creates a teleport gate to the Forgotten World. Gates can only be created in a town. Hole items lose
their function in 24 hours. Once used, Dimension Hole items cannot be used again for a time.",
"Level : 35 - 50", "Grade : ★★", "Number of Players Allowed: 1-4", "Reuse time 16956Second"
(17 min 24 s after a use of a grade-1 hole: the group is shared). The "24 hours" expiry: how it is
applied is OPEN.

**Where holes come from** (MEASURED data; the mechanism INFERRED where marked):
1. **World 1 has seven triggers**, `TRI_GOD_PILLAR_35_50` .. `_101_110` (category
   `TRI_CATEGORY_GOD_PILLAR`, IsRepeat 1): on `MONSTER_KILL`, if the monster's rarity is 0, its level
   is inside the band and the killer's level is inside a wider band (35..57, 47..67, 57..77, 67..87,
   77..97, 77..107, 97..117), `MONSTER_LOAD_MONSTER` spawns **one** `MOB_GOD_PILLAR_<theme>_<band>`
   at the killer (`TARGET_PLAYER_EVENT_USER`, `FLOAT_INPUT` **0.001**: INFERRED a 0.1 % chance).
2. The pillar (`quest\red_ins_quest_teleport.bsr`, level = band minimum, e.g. 35 / 1,940 HP; tactics
   43800.., aggression 0) has one skill, `MSKILL_GOD_PILLAR_<band>_ATTACK01`, whose params name
   `MOB_GOD_PILLAR_ENVY_DROP_<band>` (id 36048..36054): INFERRED the pillar summons that monster.
3. `MOB_GOD_PILLAR_ENVY_DROP_<band>` (`mob\god\elemental.bsr`) is the only Forgotten World monster
   with assigned drops (MEASURED 22 rows of `_RefMonster_AssignedItemDrop`): the band's holes, grade 1
   at **0.3**, grade 2 at **0.2**, grade 3 at 0.2, grade 4 at 0.1, one each.
   `MOB_GOD_PILLAR_ENVY_<band>` (rarity 1) has no drops. Neither has a nest anywhere.
4. Holes can be traded. The mall's free entrance ticket is section 9.

## 3. Making the gate (using the hole)

**Client** (READ): a TypeID 3/3/12/7 item (type word 0x3E6C, c:0x666f80) used from the bag
(c:0x677006) opens message box 0x2e **at once, with no local check**: "Will you create the gate to the
Forgotten World?" (`UIIT_MSG_USE_MAGIC_HOLE_CREATE_GATE`, c:0x6479b9). OK sends the plain item use
**0x704C {u8 slot, u16 0x3E6C}** (c:0x79865d -> c:0x797660). Success plays
`prim\snd\ui\gacha_change_2.wav` (c:0x87b47c). A hole whose cool time is running is refused by the
client itself with the system line "Still have time to reuse the item." and **no packet** (MEASURED).

READ in round 869 (stage 2): box 0x2e is CMessageBoxManager's (UI_SILKMALL 0x644c90, case at c:0x6478c2):
title UIIT_STT_CONFIRM_BOX, the box resized to 0x1f4 x 0x90, the line at (0x14, 0x37) 0x1cc x 0xf, OK moved
right by 0x50 and Cancel by 0x64 from the MsgBoxINIF layout's 72 / 152 (MEASURED: Yes from x 640, No from x
739, the box from x 487 at 1280 x 1024). The client's re-use refusal is not in the bag use but in the send
path SendItem_HandleUseItem (c:0x7972aa..0x7972f5), so it comes **after** the box's Yes: the item's
COOLTIME group's time left (ref +0x53c != 0, 0x9ba5c0) or else its own id's (0x9ba6e0) ->
FUN_00778190(1, 0x185b, ...), UIIT_MSG_STRGERR_WAIT_FOR_REUSE_DELAY, nothing sent. The success sound is
played by path (0xdda9d8) through the sound manager at the player's +0x90 (c:0x87b485..0x87b4bf) after
Item_OnUseItemResult's success for type word 0x3E6C. The tooltip (c:0x66f400, from the generic builder
0x6860a0 at c:0x686aa3): "Level : %s" with "%d - %d" of Param3 / Param4, "Grade : %s" by Param1 (a
Param1 outside 1..4 prints the level's text again: the switch's default leaves the buffer), "Number of
Players Allowed: 1-%d" with Param5, "%s %d%s" UIIT_STT_ITEM_FORMAT_COOLTIME with the re-use time left / 1000
or the item's own cool time / 1000, all white, after the description's blank.

**Server checks, in order** (READ, item use for TypeID 3/3/12/7 -> `GObjPC::FUN_004a08e0`):
1. outside a safe zone (town) -> **0x184b**; the client has no text case for it (READ: default);
2. level outside Param3..Param4 -> **0x1851** (`UIIT_MGS_ERR_GOD_LEVEL`, "Required level is not
   reached for entering.");
3. only when Param6 = 7: not in a party or not its master -> **0x184f**
   (`PARTYMATCH_RECORD_ERROR_PARTYLEADER`);
4. the world job (`game_worlds.md` 4): no free layer -> **0x1852**; any other failure -> 0x183e.
The item cool time (group 0x71) and the item are spent.

MEASURED (level 39 in band 35-50):
- In the field: `0xB04C {02, 0x184b}`; nothing spawned, item kept.
- In Jangan, **alone, not in a party** -- success: `0xB04C {01, u8 slot, 00 00, u16 0x3E6C}`,
  `0x305C {u32 user, u32 35883}` (the item-use effect, to the user and the watchers), `0xB034 {01, 0x0F,
  u8 slot, 02}` (the bag slot emptied), then the gate's spawn `0x3015` (section 4), ~110 ms after the
  request. So with Param6 = 6 **no party is needed to make a gate**, and a party member who is not its
  master made one too (MEASURED).
- `_CharInstanceWorldData` stayed empty (nobody entered); `_TimedJob` gained the item cool time row.

Texts the client has but never shows (READ: no reference in the exe, c: scan): `UIIT_MSG_ERR_MAGIC_HOLE_TOWN`,
`_LIMIT_DUNGEON`, `UIIT_MGS_ERR_GOD_PERSONNEL_MAX_COUNT`, `_JOB_STATE`, `_CART_STATE`, `_TRADE_STATE`,
`_MOVE_QUEST_STATE`, `UIIT_MSG_GOD_GATE_MOVE`, `UIIT_STT_GOD_EXTINCTION_TIME`, every
`DUNGEON_FREE_TICKET` text. `UIIT_MSG_FLAGWAR_GAME_ENTERD_ERORR` (which names the Forgotten World) is
used only by the capture-the-flag handler (c:0x4f8fe5), not here.

## 4. The gate

**Spawn record** (MEASURED bytes, READ order c:0x8a6bd0 -> c:0x9c3a70 -> `CIRuntimeStruct::vslot_025`
c:0x56dfa0), single (0x3015) and in group spawns (0x3019):

| field | measured | READ meaning |
|---|---|---|
| u32 RefObjID | 19556 | `INS_QUEST_TELEPORT` |
| u32 unique id | | |
| u16 region, f32 x, y, z | the creator's town region | INFERRED at the creator's position |
| u16 angle | varies | READ s:0x5f8aa0: a random yaw, rand()/32767 x 360 deg |
| u8 (+0x260) | 1 | OPEN |
| u8 (+0x261) | 0 | a state byte |
| u8 (+0x254) | 1 | INFERRED: owner-restricted |
| u8 (+0x255) | **6** | the access type: 6 = a named owner, 7 = a party |
| type 6: str (u16 len + ANSI); type 7: u32 | the creator's name | type 7: the party id (+0x258) |
| u32 (+0x25c) | 35883 | the Dimension hole's RefObjID |
| (0x3015 only) u8 | 1 | the single-spawn trailer |

There is **no lifetime field**. **The gate lives exactly as long as its layer** (READ): 10 minutes
when nobody enters (MEASURED 601.0 s and 604.9 s to its 0x3016), otherwise until the layer closes.

**Who sees it** (MEASURED): the creator sees the crystal and can click it; another member of the
same party received the gate's spawn record but the gate was **not drawn** for it (four camera
directions, 5 units away). READ (`CITeleportGate::vslot_025` c:0x9e9eb0), with +0x254 = 1: for type 7
the client compares +0x258 with its own party id (c:0x9e9f1a..0x9e9f2d, `FUN_00986f50()+0x5c`); for
type 6 it compares the name at +0x264 with its own character's name (c:0x9e9fbb..0x9e9ff1:
`FUN_009d6580`, the own name, through `CIFDropDownButton::FUN_00657290`, which returns "not equal").
On a mismatch it returns before the model, the pick box and the talk lines -- so a type-6 gate is
drawn and picked only by the character named in it (round 869, lane C1). On a match it keeps the
**talk window's lines** on the gate (not plate lines: the asm stores them at +0x2e4, +0x31c and
+0x338, c:0x9e9faa, 0x9ea0be, 0x9ea1e8, and `FUN_009ea880` reads them back when the window opens):
`UIIT_STT_GOD_PARTY_MASTER` ("Party master : %s", the party leader's name; type 7 only),
`UIIT_STT_GOD_LV_EXTENT` ("Level : %s" with "%d - %d" from the hole's +0x2bc / +0x2c0, Param3 /
Param4) and `UIIT_STT_GOD_CLASS` ("Grade : %s" with `UIIT_STT_GOD_CLASS_1..4` by the hole's +0x2b4,
Param1). Its pick box is min (-r, -h, -r) max (r, h, r) with r = the row's +0x118 and h = +0x114.

**Its model** (MEASURED, our archive): `teleportbuilding.txt` row 19556 `INS_QUEST_TELEPORT` (TypeID
4/1/2) names `Bldg\North Africa\Alexandria\alex_raid_portal.bsr` (column 52), bounding height 16 and
radius 10 (columns 49 / 50); the server's database row names `quest\ins_quest_teleport.bsr`. The client
draws its own archive's model. Its name `SN_INS_QUEST_TELEPORT` is "Gap of Dimensions"
(textdata_object) and its greeting is npcchat's `SN_INS_QUEST_TELEPORT_BS` (textquest_speechname).

**Which class** (READ, round 869): `IGIDObject::FUN_009c1fa0` (c:0x9c1fa0) creates a not-bionic
TypeID 4/1 object as a `CITeleportGate` (c:0x9c1ca0) and a not-bionic TypeID 4/2 object as a
`CIEventRuntimeObj` (c:0x9c1cc0); the only 4/2 row in teleportbuilding is 36513
`STORE_EVENTZONE_DEFAULT` (MEASURED), so the trigger doors travel as that object (section 6).

**Selecting it** (MEASURED): `0x7045 {u32 gate}` -> `0xB045 {01, u32 gate, 01, 1c, 01, 02, u16 0x7EE4,
i32 1063, i32 693, i32 1125}`: interaction 0x1c (a teleport), one destination of kind 2 = {region,
position} -- the world's start position. READ (round 869): `NetProcessInInterface::FUN_0088b200`'s
branch for class 0xef1dac reads the reply as {u8 1, u32 gate, u8 n, n ids, [u16 when 0x1f is among
them]} (it has no NPC flag byte; three service-country reads c:0x88b4e1..0x88b5ec and a u16 gated by
the ref's +0x120 at c:0x88b716 were absent from the measured bytes), then opens the window:
`FUN_006fb530` puts the greeting and a "  " line, and with 0x1c among the ids `FUN_006fac20` reads
the destinations -- u8 count, each a u8 kind: 0 nothing more (`SN_TALK_COMMON_INS_WADDUNGOT`), 1 a
u16-length text key, 2 a u16 region and three i32 -- after the gate's own lines (`FUN_009ea880`:
`UIIT_STT_GOD_TELTOPRT_GATE_1`, a blank, the three kept lines above when not empty, a blank, `_2`; all
white style 1 but `_2`, 0xffd6ff7e style 2) and a "  " line; each destination is "%d. " +
`UIIT_CTL_TELEPORT_FREE_RESULT` with the place (kind 2: the text keyed by the region id in decimal,
textzonename), line kind 0x2a in 0xffefdaa4 / 0xffff8a00; `FUN_007001a0` adds the numbered end line.
Clicking a kind-0x2a line (c:0x7035d2..0x7036c4) sends the end 0x704B (c:0x78fc20) and then 0x705A
{u32 gate, u8 3, u8 the line's +0xc}. The window, titled "Gap of Dimensions" (MEASURED):

> You can use the Dimensional Rift to return to your original location or to another location
> connected to here.
>
> The currently generated dimension is the Forgotten World.
>
> Level : 35 - 50
> Grade : ★
>
> **Please note that you must defeat a certain monster or all monsters in order to generate the
> special monsters to progress the plot or open up a blocked passageway.** (yellow-green, bold)
>
> 1. Teleport to [Togui Village]area.
> 2. End conversation.

(MEASURED screen text; the destination line is `UIIT_CTL_TELEPORT_FREE_RESULT` with the region's
name.)

## 5. Entering

**Request**: clicking line 1 sends `0x704B {u32 gate}` (answered `0xB04B {02, 0x1c0d}`, MEASURED) and
**`0x705A {u32 gate, u8 3, u8 0}`** (kind 3 = portal, destination index 0; READ c:0x7035f8..0x703690).

**Replies** (READ `game_worlds.md` 5): `0xB05A {02, 0x0001}` = accepted, then `0xB05A {01}` and the
teleport sequence into the layer's random start position; or `{02, code}`:

| code | text (error category 0xd, READ c:0x7bbaac) |
|---|---|
| 0x1c0b | `INTERACTION_FAIL_IM_BUSY` |
| 0x1c10 | `CANT_USE_TELEPORT_WITH_TRADECART` |
| 0x1c25 | `OUT_OF_REQUIRED_NUMBER_FOR_TELEPORT` ("Max number is reached") |
| 0x1c28 | (party rule: not the master's layer) -- `EGYPT_TOMB_ENTRANCE_CONDITION_ERROR_02` ("Party master has not move or difficulty does not match party masters choice. Therefore unable to move."; READ round 869, table 0x7bbaac) |
| 0x1c29 | `INSTANCEDUNGEON_ERROR_MSG_01` ("Unable to create instance dungeon now") |
| 0x1c2a | party condition -- `EGYPT_TOMB_ENTRANCE_CONDITION_ERROR_05` ("Party over 2 members are able to enter.") |
| 0x1c2b | job suit or voucher -- `FLAGWAR_GAME_JOB_NOT_ENTER` ("Cannot enter while in Free PvP mode or wearing Job outfit."; MEASURED round 869 with a job suit worn) |
| 0x1c2c | level -- `EGYPT_SHRINE_ENTRANCE_CONDITION_ERROR_01` ("Unable to move. Level requirement does not match.") |
| 0x1c2f | portal access refused -- `EGYPT_SHRINE_ENTRANCE_CONDITION_ERROR_02` ("Has no right to move on.") |
| 0x1c30 | `CANT_USE_TELEPORT_WITH_RIDE` |
| 0x1c31 | `INSTANCEDUNGEON_ERROR_MSG_02` ("already inside of instance dungeon") |
| 0x1c32 | `UIIT_MGS_ERR_GOD_LIMIT_TIME` ("Unable to enter instance dungeon, because re-entering time limit is not over.") |
| 0x1c33 | `UIIT_MGS_ERR_GOD_TELEPORT_HOLE_NOT_PARTY` ("Dimensions Holes can only be used in a party.") |
| 0x1c34 | `PARTYMATCH_RECORD_ERROR_PARTYLEADER` ("Only party leader has this option") |
| 0x1c35 | `UIIT_MGS_ERR_GOD_INS_WORLD` ("You already belong to another instance dungeon and cannot enter.") |
| 0x1c36 | `UIIT_MGS_ERR_GOD_DEADSTATE` |
| 0x1c37 | `UIIT_MGS_ERR_GOD_TELEPORT_HOLE_NOT_TOWN` ("Dimension Holes cannot be used outside of a town.") |
| 0x1c38 | `UIIT_MGS_ERR_GOD_BATTLE_STATE` ("Unable to enter during battle.") |
| 0x1c39 | `UIIT_MGS_ERR_GOD_GUILD` ("You cannot enter dungeon during guild or fortress war.") |
| 2, 3, 1 | no text (category 0xd's default) |

The checks and their order are `game_worlds.md` 5 (the warp handler's portal checks, then CanEnter).

**MEASURED**: the creator (alone, and again in a party of two, levels 39 and 40,
in band) clicked the destination and got `0xB05A {02, 0x0001}` then `0xB05A {02, 0x0003}` -- accepted,
then refused with 3 and no text; nobody entered. Round 869 found the cause (below): the game server
had none of the Forgotten World's regions loaded. So the inside (sections 6-8) is READ from the
binaries and the data, **not measured**.

**Why every entry was refused with 3** (round 869):

- **READ: a game server keeps only the regions whose area is bound to it.** The `_RefRegion` row
  reader (s:0x6a2e40) drops the row's own `AssocServer`. It looks up the row's `ContinentName` in
  `_RefRegionBindAssocServer` {AreaName, AssocServer} (s:0x5fba80, a case-insensitive name lookup
  over the list the shard manager hands over in `CGameServer::LoadReferenceData` case 2, s:0x6bd920)
  and stores that value at the region's +0x10. A **0**, or an area missing from the list, makes the
  reader return 0, and the loader (s:0x6e33b0) then **drops the region** with no log line.
- READ: the bound value is a 1-based index of the shard's `SR_GameServer` nodes. s:0x412360 lists
  them from the certification node data, s:0x412530 gives the running server its own index (kept by
  `InitializeGame`, s:0x412c20), and s:0x412590 turns an index back into a node id. So with one game
  server the index is 1, and 0 matches no server.
- READ: an instance world's regions are its `_RefInstance_World_Region` rows that this server kept
  (s:0x530f40 with s:0x533030). A world left with none still opens: s:0x53b4b0 prints "There is no
  assigned region!!! check out _RefRegion Table !!!" at console level and carries on. So the hole
  still makes a layer and a gate, and selecting the gate still works. The warp to the start region
  then fails in `CGObjPC::vslot_222` (s:0x4df5a7..0x4df5d8: the region is not in the table), which
  the warp handler (s:0x4f365c -> s:0x4f369a) answers with **`0xB05A {02, 0x0003}`**.
- READ: arena worlds are bound the same way when they are created (s:0x5f5b60 looks up `ARENA_SCORE`
  and `ARENA_FLAG` and compares them with the running server's index).
- **MEASURED** (the data the entries were measured against):
  - `_RefRegionBindAssocServer` binds `GOD_TOGUI`, `GOD_FLAME`, `GOD_WRECK_IN` and `GOD_WRECK_OUT` to
    **0**. The same goes for every `ARENA_*`, `FORT_*_AREA`, `PRISON`, `GM_EVENT`, `JUPITER`,
    `SIEGE_DUNGEON` and `EVENT_GHOST` area.
  - The open-world areas and Egypt (`TEMPLE`, `KingsValley`, `Pharaoh`, `SD`, `DELTA`) are bound to
    **1**.
  - Every `_RefRegion` row's own `AssocServer` is 0; the binding replaces it.
  - All Forgotten World regions are present in `_RefRegion` and `_RefInstance_World_Region`: 48
    Togui (continent `GOD_TOGUI`), the Flame dungeon 0x8012 (`GOD_FLAME`) and 224 + 224 Wreck. The
    server's own map data has every one of their navmeshes (`nv_<region>.nvm`, `ainavdata_32786.dat`,
    `flame.dof`), and its `mapinfo.mfo` sets their bits. **The binding is the only thing missing.**
- **MEASURED again in round 869** (level 41, alone, band 35-50, a new grade-1 hole in Jangan):
  1. `B04C {01, slot, 00 00, 3E6C}`, then the gate's `3015` 41 ms later (the same record as
     section 4: access 6, the creator's name, 35883).
  2. Selecting the gate: `B045` with the same one destination (0x7EE4, 1063, 693, 1125).
  3. Clicking line 1: `B04B {02, 0x1c0d}`, then `B05A {02, 0x0001}`, then `B05A {02, 0x0003}` 38 ms
     later. No text appears and nothing else is sent.
- **Inference:** every band and theme is refused the same way, because all four `GOD_*` areas are
  bound to 0.
- **To measure the inside** on data like this, the four `GOD_*` areas must be bound to the game
  server's index, and the shard manager and the game server restarted (the binding is loaded at
  start).
- **OpenSRO** has no per-area server binding: one process serves every region of a world's
  `_RefInstance_World_Region` list (OURS: `game_worlds.md` 12 places whole instances, not areas).
  Stage 2 needs no change for this; the instanced worlds' regions must simply be loaded.

**MEASURED with the four `GOD_*` areas bound to the game server** (round 869, world 67 = Togui
61-70 grade 1, the creator level 70 alone, then a party of two, levels 70 and 65):

- **A worn job suit refuses entry**: `B04B {02, 0x1c0d}`, `B05A {02, 0x0001}`, then
  **`B05A {02, 0x1c2b}`** 25 ms later (the CanEnter job-suit check, `game_worlds.md` 5); the system line (yellow) reads "Cannot enter
  while in Free PvP mode or wearing Job outfit."
- **Entry** (no suit, no party), byte for byte:
  1. C `704B {gate}` -> S `B04B {02, 0x1c0d}`; C `705A {gate, 03, 00}` -> S `B05A {02, 0x0001}`.
  2. 77 ms later: `3019` group-despawns of the town objects around the player, **`B05A {01}`**, then
     `34B5 {u16 0x61A8}` 26 ms later. The client answers `34B6`.
  3. `34A5`, `3013` (the character data, as on any teleport), `34A6`, `3020`; the client sends
     `3012` 457 ms later.
  4. At once after the `3012` (same burst, < 50 ms): the group spawn of the layer's NPCs near the
     start; **`300C {0x0C1C, 01, "UIIT_MGS_GOD_TRIGGER_NOTICE_COMMON_MONSTER_KILL"}`** and the same with
     kind **02**; then the usual arrival state; **`320C {0x0C, u32 1, u32 18000}`** (the re-entry
     icon: group 1, 18,000 s) -- sent twice in the burst; `B50E {01 00}`.
  - So the entry notice is **not** 20 s after entry: it comes with the arrival, to the entering
    player, on every entry (re-entry and a summoned member too). The banner and the system line both
    show "In the dungeons of the Forgotten World, all monsters must be eliminated before the next
    passageway opens and the players can go on." (frames).
  - The arrival point is the world's start (0x7EE4 (1063, 693, 1125); the minimap reads X 17962,
    Y 6640, the open world's coordinate formula). The area name is "Togui Village".
- **The loading screen** is the ordinary one (a town picture and the "loading" bar); the first
  frame inside came 2.5 s after the click (frames 0.7 s apart).
- **Minimap and maps inside**: the minimap draws Togui's own tiles with the area name "Togui
  Village" and X/Y in open-world coordinates. The area map (M) is titled "Regional map - Togui
  village" with the label "Camp No. 1". The world map ("Entire map") shows no Forgotten World page.
- **NPCs**: the world's NPC hive spawns with the layer: "Dungeon Exit" (`NPC_INS_EXIT_TELEPORT`, a
  blue crystal with lightning) 160 units west of the start and "Pillar of Party Member Recall"
  (`NPC_FWORLD_RECALL_PARTY`, a dark stone pillar with red light) 200 units south-east of it.
  - Selecting the exit NPC: `B045 {01, u32 npc, 00, 01, 29, 00}` (9 bytes: the flag byte 0, one
    interaction 0x29, the CICNPC's u8 0); the talk window "Dungeon Exit": "1. Exit Dungeon", "2. End
    conversation."
  - Selecting the recall pillar: `B045 {01, u32 npc, 00, 01, 27, 00}` (0x27); "Pillar of Party Member
    Recall": "1. Summon Party member", "2. End conversation."
  - Round 870: the raw payload is `01 4e090000 00 01 29 00` (and `01 4d090000 00 01 27 00`); round
    869's "00 00 00 01 29 00" counted the npc id's two high zero bytes twice. It is exactly the order
    READ in c:0x88b200's CICharactor branch (u8 1, u32 id, u8 flag, u32 when its bit 0 is set, u8 n, n
    ids, u16 when 0x1f is among them, the CICNPC's u8 (`FUN_00b94b70(0xef1ac4)`), u16 when 0x21 is, u16
    when the ref's +0x120 is set) and what OpenSRO's shared encoder (`npctalk.EncodeSelectNPC`) sends.
- **Monsters: none appeared.** In this layer none of world 67's 116 monster nests (hives 838..854)
  spawned anything -- no monster spawn reached either player at the start, at the camp-1 nest
  (0x7EE3 (1066, 820, 512)) or at camp 2, over 35 minutes; the area map's monster option showed
  none. The NPC hive (837) did spawn. Why is OPEN (the nest data has normal values: btType 0 for the
  86 always-on nests, Service 1 monsters). So the trigger chain, the doors (0x351E), the Envy, the
  boss, the treasure boxes and the rewards are **still not measured**.
- **Exit NPC**: C `751D {npc}` -> S `3019` (the layer's objects despawn), **`B51D {01}`**, `34B5
  {0x61A8}`, then the ordinary teleport. The player is back **at the gate's spot in Jangan** (the
  return point; X 6435, Y 1055), with the gate still standing. The `320C` icon stays (remaining
  16,719 s).
- **Re-entry**: selecting the same gate again and clicking line 1 puts the player back in **the
  same layer** (`B05A {01}`); `320C` carries the remaining time (17,004 s after 996 s), not 18,000.
- **Logout inside** (System > Restart): `_CharInstanceWorldData` stayed empty and `_Char`
  kept `LatestRegion` 0x61A8 / `WorldID` 1; the next login put the character **at the return point
  in Jangan**, with the `320C` icon (tooltip "Forgotten World - Re-entry Time Limit", "Once the
  instance dungeon re-entry time limit expires, players can enter a different instance dungeon.",
  "Remaining time: 4Hour 44Minute 59Second"). The gate was still there and led back in.
- **The re-entry job in the database**: `_TimedJob` category 12, JobID 1 (the world group),
  TimeToKeep = the entry time + 18,000 s (Unix seconds), Data1 14 (the same for both players of the
  layer; INFERRED the layer id).
- **The party recall** (the master inside at the pillar, the member in Jangan):
  1. C `7519 {npc}` -> S **`B519 {01, 01, u32 0x597, 02, 0x41, u16 0}`** 113 ms later, **with no
     wait**: per member {u32 member id, u8 state (2 = possible), **u8 the member's level** (65),
     u16 minutes}. The window "Summon Party member" has the columns "Party Member Name",
     "Eligibility", "Level", "Time Limit for Entry" and the row "<member> | Possible (green) | 65 |
     0 Minutes", and a "Summon" button.
  2. Selecting the row and Summon: C **`751A {u32 member id}`**. The member gets **`751A {u32
     0x1F5, u32 0x596, u32 5, str master's name}`** and the box "<master> is summoning you. Do you
     wish to accept the summon?" Yes / No. Nothing came back to the master.
  3. Yes: C **`751C {u32 0x1F5, u32 member id, 01}`** -> S `30BF {member uid, 0B 01}`, **`B51C {01}`**.
  4. **5.4 s later** the member is teleported into the master's layer (`34B5`, the ordinary
     sequence) at the world's start, gets the same `300C` notice pair and its own `320C {0C, 1,
     18000}`, and its own category-12 job. The master sees the member's party row move to region
     0x7EE4 (`3864`, `3C80`). INFERRED: the u32 5 in the member's `751A` is that 5-second delay.
- **The 60-minute warning**: **`300C {u16 0x0C1A, u8 60}`** (3 bytes) reached both players in the
  layer 3,609.9 s after the hole was used (the layer's creation), at the same millisecond; the
  system line read "After 60 minute, instance dungeon will vanish. When it vanish, user will move to
  saved return place." (with the banner).
- **The 10- and 5-minute warnings and the close** (both players kept inside, no party):
  `300C {1A 0C 0A}` at 6,609.9 s and `300C {1A 0C 05}` at 6,909.9 s.
  - **The close** came at **7,209.9 s** (2 h + 9.9 s after the hole was used), to both players in
    the same millisecond, **with no text**: `3019` despawns of the layer's objects, then `34B5
    {0x61A8}` and the ordinary teleport.
  - Each player landed **at their own return point**: the creator at the gate's spot, and the
    summoned member where it had accepted the summon.
  - `320C` came back with the remaining limit (12,903 s): the re-entry limit outlives the layer.
- **Leaving the party inside**: the master banished the only member (C `7063 {member id}`; both got
  `3864 {01, 0x0B}`, "The party is dismissed."). **Nobody was moved**: the former member stayed in
  the layer, and was still there minutes later.

**The party** (READ): a type-6 gate admits only its creator; the rest of the party comes in through
the recall NPC inside (section 8). With Param6 = 7 a party gate would admit the creator's party
(choice 1). The layer pick's party rule: the master gets a new layer, members follow the master's
(s:0x60a740).

**The re-entry limit** (`game_worlds.md` 5): from the entry, 5 h (database; choice 1 of
`game_worlds.md`), the buff-bar icon with "Forgotten World - Re-entry Time Limit" /
"Once the instance dungeon re-entry time limit expires, players can enter a different instance
dungeon." While it runs, the same instance can be re-entered; another is refused 0x1c32.

## 6. Inside: the trigger scripts

Every world: on entry, after **20 s**, the entering player (`TARGET_PLAYER_EVENT_USER`) gets the
banner, and at once the system line (MEASURED in the data: the banner's action has Delay 20,000 and the
system line's 0 -- read per action, round 869's engine sends the system line at the entry and the banner
20 s later; the cumulative reading of this sentence is OPEN, `game_worlds.md` 14 notes), "In the dungeons of the Forgotten World, all monsters must be
eliminated before the next passageway opens and the players can go on."
(`UIIT_MGS_GOD_TRIGGER_NOTICE_COMMON_MONSTER_KILL`; IsRepeat 1, the only repeating trigger). Every
other notice goes to all players in the layer, as banner **and** system line. MEASURED (round 869):
this notice arrives with the arrival itself (right after the client's `3012`), not 20 s later, on
every entry -- section 5.

**Togui, world 63** (MEASURED, `_RefTrigger*`; worlds 64..68 are the same script with their own hives
and nests). "Kill hive N" = every monster of hive N dead (`MONSTER_HIVE_KILL`):

| trigger | when | then |
|---|---|---|
| NOMAL_MONSTER_1 | hive 675 (the field's 38 normal nests) killed | wake nest 30121 (`TOGUI_ENVY_A1`); "Envy has appeared in Camp No. 1." |
| NOMAL_MONSTER_2 | hive 676 (8 nests) | wake 30177 (Envy); "Envy has appeared in Camp No. 2." |
| NOMAL_MONSTER_3 | hive 678 (10 nests: soldiers, magic, dolls, the `GENERAL` and a `CAPTAIN`) | wake 30192 (Envy); "Envy has appeared in Camp No. 3." |
| NOMAL_MONSTER_4 | hive 677 (22 nests) | open `BIG_GATE_TOGUI_3`; "The blocked door has been opened." |
| A_AREA_1 | hive 679 (the camp-1 Envy) | wake nests 30115..30120 (soldiers, strong) |
| A_AREA_2 | hive 680 (those six) | wake 30122..30125 (4 x 9 `TOGUI`); open `SMALL_GATE_TOGUI_A_1..4` |
| A_AREA_3 | hive 683 (those) | wake 30126 (`TOGUIGENERAL`, rarity 8) |
| A_AREA_4 | hive 684 (the general) | open `BIG_GATE_TOGUI_1`; "The blocked door has been opened." |
| B_AREA_1..4 | hives 685, 686, 687, 688 | the same pattern: camp-2 Envy -> 6 nests -> 4 x 9 and `SMALL_GATE_TOGUI_B_1..4` -> `TOGUICAPTAIN` -> `BIG_GATE_TOGUI_2` + notice |
| C_AREA_1 | hive 689 (camp-3 Envy) | wake 30194..30199 |
| C_AREA_2 | hive 690 | wake 30201..30204 (4 x 9); open `SMALL_GATE_TOGUI_C_1..4` |
| C_AREA_3 | hive 691 | wake 30207 (`TOGUIELDER`, rarity 3, the boss); "The boss monster has appeared." |
| AREA_BOSS_KILL | hive 692 (the elder) | "The boss monster has been defeated.  You can use the dungeon exit object to leave the instance dungeon." |

Hive 674 holds the NPCs (two exits, four recalls); hive 710 the two treasure boxes
(`TOGUI_TREASUREBOX_A1`, active from the start). 36 of the 122 nests are dormant (btType 1); every
nest has respawn 0, caps 1, 3 or 9.

**Flame, world 69** (worlds 70..76 alike): four `NOMAL_MONSTER` triggers each wake one Envy ("Envy has
appeared in Area No. 1..4."); areas A, B, C, D each have three steps: two steps each wake two nests and
open two `SMALL_GATE_FLAME_<area>_n` blocks (`flame_event_block.bsr` / `flame_event_break.bsr`), the
third opens `BIG_GATE_FLAME_1..3` with the door notice; D's third step wakes the boss (`COWKING`,
"The boss monster has appeared."), whose hive kill gives the defeat notice.

**Wreck inside, world 77** (78, 81, 82 alike): three `NOMAL_MONSTER` triggers each wake two nests,
"Monsters have appeared in Shipwreck No. 1..3."; areas A, B, C: Envy ("Envy has appeared in Shipwreck
No. n."), then two nests, then a door (`BIG_GATE_WRECK_B1_1`, `_B1_2`); A's door step also
`MONSTER_LOAD_MONSTER` `MOB_GOD_GHOST_CURSE_A1` (count 1, `FLOAT_INPUT` 1, `TARGET_PLAYER_RANDOM`).
C's second step wakes the boss; the defeat notice fires on `MONSTER_KILL` of `MOB_GOD_GHOST_UNDINE_A1`
(a codename condition, not a hive).

**Wreck outside, world 79** (80, 83, 84 alike): the first trigger opens
`BIG_GATE_WRECK_1F_PURPLE_1` and loads `MOB_GOD_GHOST_CURSE_A3` at the event user (`NUM_INPUT_1` 6);
A and B areas open `SMALL_GATE_WRECK_1F_A_*` / `_B_*`, then `BIG_GATE_WRECK_1F_ORANGE_1..3` and
`_BLUE_1, 2, 3, 5`; the last step wakes the boss with "The boss monster has appeared on the island in
the middle of the dungeon." (`..._WRECK_OUT_BOSS`); the `UNDINE_A3` kill gives the defeat notice.

The doors are event zones (`game_worlds.md` 8): `STRUCTURE_GOD_*` (TypeID 1/2/1/4; 3 big and 12
small Togui doors, 3 big and 16 small Flame blocks, Wreck doors) drawn while closed, removed on 0x351E
state 1 (INFERRED: "ON" opens). READ (round 869): those characterdata rows are the doors' **models**,
not the object on the wire -- the object is a not-bionic TypeID 4/2 structure (`CIEventRuntimeObj`,
MEASURED: teleportbuilding's only 4/2 row is 36513 `STORE_EVENTZONE_DEFAULT`) whose record names the
event zone (+0x280); `CIEventRuntimeObj::FUN_00535750` (c:0x535750) at state 0 builds the zone's
object's .bsr (eventzonedata column 9 -> characterdata, e.g. zone 251 -> `STRUCTURE_GOD_BIG_GATE_FLAME_1`
-> `Dun\Property\flame\Com\flame_lroom_door.bsr`), at state 1 removes it (`FUN_009c4160(2)`), and
leaves it as it is for any other value. Note for the server: SWITCH_EVENTZONE's zone states are 2
(ON) and 1 (OFF) (`game_worlds.md` 8); what value goes into 0x351E's state byte for each is OPEN
(the client opens on 1 and closes on 0).

## 7. Notices (MEASURED texts)

| key | text |
|---|---|
| `UIIT_MGS_GOD_TRIGGER_NOTICE_COMMON_MONSTER_KILL` | In the dungeons of the Forgotten World, all monsters must be eliminated before the next passageway opens and the players can go on. |
| `..._COMMON_OPEN_DOOR` | The blocked door has been opened. |
| `..._COMMON_BOSS` | The boss monster has appeared. |
| `..._WRECK_OUT_BOSS` | The boss monster has appeared on the island in the middle of the dungeon. |
| `..._COMMON_BOSS_KILL` | The boss monster has been defeated.  You can use the dungeon exit object to leave the instance dungeon. |
| `..._COMMON_ENVY_TOGUI_1..3` | Envy has appeared in Camp No. 1..3. |
| `..._COMMON_ENVY_FLAME_1..4` | Envy has appeared in Area No. 1..4. |
| `..._COMMON_MONSTER_WRECK_IN_1..3` | Monsters have appeared in Shipwreck No. 1..3. |
| `..._COMMON_ENVY_WRECK_1..3` | Envy has appeared in Shipwreck No. 1..3. |
| `UIIT_MSG_EGYPT_DUNGEON_DESTROY_ALARM` (0x0C1A, 60 / 10 / 5 min) | After %d minute, instance dungeon will vanish. When it vanish, user will move to saved return place. |

All on **0x300C {u16 0x0C1C, u8 1 | 2, str key}** (1 = banner, 2 = system line), except the alarm
(0x0C1A, both) -- `game_worlds.md` 7.

## 8. Leaving, and the party recall

- **The exit NPC** (`NPC_INS_EXIT_TELEPORT`, `quest\ins_quest_teleport.bsr`, interaction 0x29): the
  talk line "Exit Dungeon" (`UIIT_STT_DUNGEON_EXIT`, c:0x7014bb: id 0x29 -> line type 0x3e) sends
  **0x751D {u32 npc}** (CIF_NPCTalk::FUN_008234f0, case 0x3e; the talk window stays); the player goes back
  to the return point (where they used the gate). `game_worlds.md` 5. 0xB51D's refusals go to category 1,
  whose switch (0x7b8c82) has a text only for 3, 0x1807 and 0x180b..0x18ff: the exit's own refusals
  (0x1c36, 0x1c10, 2) show **nothing** (READ round 869).
- **The recall NPC** (`NPC_FWORLD_RECALL_PARTY`, `Dun\Property\com\property_recall.bsr`, interaction
  0x27; one beside the start, others along the way), READ both sides:
  1. The talk line "Summon Party member" (`UIIT_PAG_PARTY_SUMMON`, c:0x70144a: id 0x27 -> line type
     0x3d) sends **0x7519 {u32 npc}** (c:0x823290; CIF_NPCTalk::FUN_007020c0 case 0x3d, which leaves the
     talk window open). Server (s:0x51bb70): not in a party 0x1c33, not the master 0x1c34, fewer
     than 2 members 2; otherwise a 15.0 s job (0x7d1b, s:0xb45f08).
  2. **0xB519** (c:0x89a590): {u8 1, u8 n, n x {u32 char id, u8 state, u8 level, u16 minutes}} or
     {u8 != 1, u16 code} (category 0xd); the window's list is cleared before the result is tested. The u8
     printed "%d" sits under the `PARAM_LV` header (MEASURED in the .2dt; INFERRED the member's level).
     It fills the summon window `CNIFSummonPartyUserWnd` (window 0xd6, built from
     **`res_ui\nifsummonpartyuserwnd.2dt`** -- MEASURED in Media.pk2, 51 records; READ c:0x787119..0x787154
     loads it at game start, string 0xdb90bc -- 496 x 320, caption `UIIT_PAG_PARTY_SUMMON`, eight
     `CNIFSummonPartyUserSlot` rows (ids 13..48, statics 14 name / 15 state / 16 level / 17 minutes), the
     Summon button 7; a row is selected with the left button (c:0x609a80) and the button is enabled only
     for a selected row in state 2 that is not waiting (c:0x6096e0, c:0x607730)):
     each member's name, state (1 "Completed" `UIIT_STT_FORT_SMITH_COMPLETE`, 2
     `UIIT_CTL_PARTY_SUMMON_POSSILBE`, 3 `..._IMPOSSILBE` with its tooltip), "%d" and "%d Minutes".
  3. The window's Summon (button 7, c:0x607c80) sends **0x751A {u32 char id}** of the selected row
     (c:0x823350; server s:0x51bd60, master only 0x1c34); that row then waits 20,000 ms (timer 100,
     c:0x607c20; its end re-enables the button for the selected row, c:0x607c50). A refusal comes on
     0xB51A {u8 != 1, u16 code} in **category 0x23** (READ round 869, index bytes 0x7bc118, targets
     0x7bc0f0): 0x1c0b `INTERACTION_FAIL_IM_BUSY`, 0x1c25 `_IMPOSSILBE_2`, 0x1c2b `_4`, 0x1c2c `_3`,
     0x1c30 `_6`, 0x1c36 `_8`, 0x1c37 `_1`, 0x1c39 `_7` (`UIIT_STT_PARTY_SUMMON_IMPOSSILBE_n`), 0x1c3a
     `UIIT_STT_PARTY_SUMMON_WAIT_ERR`; any other code no text.
  4. The member gets the push **0x751A {u32 requester, u32, u32, str name}** (c:0x89f010 ->
     c:0x608a60) and a confirm box "%s is summoning you. Do you wish to accept the summon?"
     (`UIIT_STT_GNGWC_PARTY_MEMBER_CALL`) with a 20,000 ms timer; the timer closes it silently.
  5. The answer **0x751C {u32 requester, u32 own id, u8 1 | 0}** (c:0x823410; server s:0x51bf10): the
     requester is the push's first u32 (+0x7c8), the own id the party's own JID (the party object's +0x18,
     which 0xB060 writes, c:0x880059; READ c:0x6076d3..0x607702); the push's second u32 (+0x7cc) is
     never sent. The box is a MsgBoxSimple (GInterface::FUN_007884e0, 360 x 151, style 1 Yes / No,
     `UIIT_STT_CONFIRM_BOX`); a push while one is up keeps its text and restarts the timer.
     Reply 0xB51C {u8 1} or {u8 2, u16 code} (category 0xd); the master gets 0xB51A.
  MEASURED (round 869, section 5): the member is warped from the town into the master's layer 5.4 s
  after its Yes, at the world's start; `B519`'s per-member u8 is the member's **level**; the window
  opened at once (no 15 s wait was seen); the master got no `B51A` for an accepted summon.
- **Time-out**: the warnings, then everyone to their return point (`game_worlds.md` 4).
- MEASURED (round 869, section 5): logout inside -> the next login is at the return point, the
  gate leads back into the same layer; the party dismissed inside -> nobody is moved. OPEN: death
  inside (no monster spawned in the measured layer); a disconnect (not a clean logout) inside.

## 9. The free entrance ticket

`ITEM_MALL_DUNGEON_FREE_TICKET_FORGOTTEN_WORLD` (36781) and `ITEM_PRE_MALL_...` (38295): TypeID
3/3/13/23, stack 50, Param1 / Desc1 = 1 / `GROUP_INS_GOD`, **Service 0** in the measured data. The
texts exist ("If you use the Dungeon entrance ticket, dungeon cooltime will  disappear. Do you want to
use the entrance ticket?", "Cannot enter because you don't have an entrance ticket.", "Entrance ticket
was not used because the Entrance Dungeon is currently off-limits.") but **neither binary references
them** and the server's item-use switch has no case for TypeID4 23 (READ s:0x49c2b0). INFERRED: the
ticket clears the group cool time (`GROUP_INS_GOD`) and belongs to a later client than ours. Choice 3.

## 10. What other players see

- The gate: its spawn reaches those around (MEASURED, a party member); a type-6 gate is drawn only for
  its creator, a type-7 one only for the creator's party (READ, section 4).
- The item-use effect 0x305C is broadcast (MEASURED).
- Inside: players of the same layer only (`game_worlds.md` 3).
- The gate's removal 0x3016 goes to everyone who had it (MEASURED).

## 11. Build checklist (stage 2, after the foundation of `game_worlds.md` 14)

### SERVER
1. **FGW reference data** -- the hole items' params, the 22 worlds' configs, the world group, the
   PILLAR triggers of world 1, the 22 worlds' trigger sets, hives and nests (from the export of
   `game_worlds.md` checklist 1). Test: `gameworld/fgw_test.go` -- 22 worlds, item 35883 -> world 63,
   band 35..50, grade 1, Param6 6, cool time group 0x71 18,000,000 ms.
2. **The Dimension hole** -- `internal/session/useitem.go`: an `isDimensionHole` branch (TypeID
   3/3/12/7): safe zone 0x184b, band 0x1851, Param6 = 7 party master 0x184f, open a layer through the
   world manager (no slot 0x1852, other 0x183e); spend the item and its cool time; 0xB04C, 0x305C,
   0xB034 in the measured order; the gate structure (19556) at the user's position with a random yaw
   and the access type of Param6. Test: `session/fgw_hole_test.go`, each refusal and the success bytes.
3. **The gate** -- spawn record (section 4) in single and group spawns; 0x7045 / 0xB045 with the one
   kind-2 destination; 0x705A kind 3 through the foundation's entry path; the gate removed with its
   layer. Test: the measured 0xB045 and spawn bytes; a type-6 gate refused to a non-creator (0x1c2f).
4. **The scripts** -- the trigger sets of section 6 on the foundation's engine; the entry notice
   20 s after entry to the event user; doors via 0x351E; boss notices. Test: run world 63's script
   on a fake layer by killing hives in order; assert every nest woken, every door opened and every
   0x300C in order.
5. **Recall** -- 0x7519 / 0xB519 / 0x751A (both ways) / 0x751C / 0xB51C / 0xB51A, the 15 s job, the
   20 s summon wait, the member's warp into the master's layer with CanEnter. Test: master and two
   members; each refusal.
6. **The hole sources** -- the PILLAR triggers in world 1 (rarity 0, both level bands, 0.001), the
   pillar's summon of the ENVY_DROP pillar, its drop table. Test with a seeded random source.
7. **The re-entry limit** -- the 5-hour group timed job at entry; 0x320C; the 0x1c32 refusal; same
   instance allowed. Test.
8. **GM aids (OURS, for QA)** -- `/fgw <world>` opens a layer and warps the GM; `/fgwtime <duration>`
   moves an instance's clock. Not in the original's console.

**Stage 2 notes (round 869, lane W3; the server as built -- the client lane reads the same):**
- **The hole's replies** ride OpenSRO's own use reply (OpUseItemResult, OURS opcode, its `Code`
  the refusal: 0x184b, 0x1851, 0x184f, 0x1852, 0x183e, and 0x185b for a use in the cool time, which
  the client refuses first). On success the order is the MEASURED one: the use reply, `0x305C {u32
  user, u32 hole}` to the user and everyone in view, **`0xB034 {01, 0x0F, u8 bag slot + 13, 02}`**
  (type 0x0F, a consumed slot -- new on OpenSRO's wire), then the gate's `0x3015`. The measured gap
  to the `0x3015` (41 ms and 111 ms) is the shard manager's round trip (INFERRED); OpenSRO opens the
  layer in process and sends it at once.
- **The band** is the item's Param3 / Param4 (the item table's RestoreMP / RestoreMPPct columns:
  Param1..Param4 are columns 118/120/122/124). MEASURED: they equal the world's ENTER_LIMIT band on
  every row, the Wreck 100_110 holes included (101).
- **The hole's cool time** is kept as a timed job of category 6 (MEASURED `_TimedJob` row: the
  item's id, 18,000,000) and re-armed at every world entry.
- **The gate** is a structure in the open world at the user's point, uids 0x7d400000.. (OURS
  range), sent to every player whose window holds it (the NPCs' window) and taken down (`0x3016`)
  with its layer. Its select answers the MEASURED `0xB045` and sets no interaction state; anything
  but the owner's character through a type-6 gate is 0x1c2f (READ); a type-7 gate admits the owner's
  party.
- **The entry notice** comes with the arrival (MEASURED): the trigger engine runs every action at
  once -- the `Delay` column is not a wait (its only non-zero value, the banner's 20,000, MEASURED
  not to delay it); a notice or 0x320C for a character still held by the arrival guard goes out
  right after its `0x3012` (the notices) and after the arrival state (the 0x320C, sent twice as
  MEASURED). In the data, world 69 binds its system line before its banner and world 72 has two
  banners: sent as bound.
- **The recall** answers 0x7519 at once (MEASURED 113 ms; the READ 15 s is the original's job
  limit), rows {u32 char, u8 state, u8 level, u16 minutes} for every member but the master: state 1
  in the master's layer, 2 possible, 3 not (INFERRED: in an instance 0x1c35, dead 0x1c36, outside a
  town 0x1c37, a stall or an exchange 0x1c0b, then CanEnter's codes); the minutes are the member's
  own re-entry limit (INFERRED; MEASURED 0 for a member with none). A summon sends nothing to the
  master and the push `{u32 master uid, u32 master char, u32 5, str name}` to the member; a refusal
  is `0xB51A {02, code}`; a second summon within 20 s is 0x1c3a. The Yes: `0x30BF {member, 0x0B,
  1}`, `0xB51C {01}`, and 5 s later the ordinary entry at the world's start. A No answers `{01}` and
  tells the master nothing (OPEN).
- **The pillars**: world 1's triggers load the pillar at the killer (the engine's LOAD_MONSTER,
  0.001). The pillar's skill is an `'ssou'` summon with AI_AttackChance 0 and AI_SkillType `'D'`;
  READ s:0x5614d0 files a `'D'` skill apart from the attack list (the selector's +0x34) and
  s:0x593738 runs the minion executor on any cast of a summon skill -- INFERRED: the pillar summons
  at its death (the reader of +0x34 is OPEN). The 35-50 pillar's block is {36048, class 1, 4..6} and
  {36048, class 1, 1..1}: 5-7 ENVY_DROP champions around it.
- **The holes' drop** is the ENVY_DROP's `_RefMonster_AssignedItemDrop` rows (the game-world export
  now carries the table; served for MOB_GOD_* monsters only, OURS scope). READ s:0x724a00: a row's
  attempts are `rand % (max - min + 1) + min`, each at the ratio, so the 0..1 rows give a grade-1
  hole on **15 %** of the kills, grades 2 and 3 on 10 %, grade 4 on 5 % -- not the rows' 30 / 20 /
  20 / 10.
- **Rewards**: MEASURED `_RefMonster_AssignedItemRndDrop` gives the talisman groups
  (`ITEM_TALISMAN_TOGUI_DROPGROUP` and the Wreck's) to the treasure boxes and the bosses (e.g.
  `TOGUIELDER_A1` 0.15, `TREASUREBOX_A1` 0.15, `_A2` 2 x 1.0, `_C2` 2 x 1.0); they drop through the
  ordinary drop path when the operator's drop tables are loaded. What else a box gives is OPEN.
- **Death inside**: the return-point revive takes the character to its designated return point in
  the open world, which counts it out of the layer (OURS; the original's place is OPEN).
- **GM aids (OURS)**: `/fgw <world>` opens a layer and stands its gate at the GM (no item, no
  checks; the entry is the gate's own); `/fgwtime <duration>` ages the GM's layer (or its newest
  gate's); `/fgwtime limit <duration>` moves the GM's re-entry limit and hole cool time;
  `/fgwkill [n]` kills the layer's live monsters as the GM's kills (the triggers hear them; no
  exp, gold or drops); `/fgwpillar [band]` loads a pillar at the GM in the open world.

### CLIENT
1. **Hole use** -- `UI` item use for type word 0x3E6C opens box 0x2e with
   `UIIT_MSG_USE_MAGIC_HOLE_CREATE_GATE`, sends 0x704C on OK, plays `gacha_change_2.wav` on success;
   the local cool-time refusal line. Test: `fgw_hole_test.gd`.
2. **Item tooltip** -- "Level : a - b", "Grade : ★..", "Number of Players Allowed: 1-n", the reuse
   time (`UIIT_STT_GOD_LV_EXTENT` / `_CLASS`, c:0x66f400). Test.
3. **The gate** -- a `CITeleportGate`-like structure (model of 19556 with its ambient effects), the
   type-6 / type-7 visibility rule, the talk lines it keeps (section 4), its pick box; select -> the talk window
   "Gap of Dimensions" with the texts of section 4; line 1 sends 0x704B + 0x705A {gate, 3, index}. Test:
   the window text from the measured 0xB045; a non-owner draws nothing.
4. **Entry replies** -- 0xB05A {2, 1} then {1}: the teleport; {2, code}: the category-0xd texts of
   section 5 (`client/scripts/net/error_text.gd`). Test: code -> text table.
5. **Inside** -- the 0x300C notices (both kinds), the doors (0x351E), the destroy alarm. Test with
   recorded bytes.
6. **Exit and recall talk lines** -- interaction 0x29 / 0x27 lines; the summon window
   (`CNIFSummonPartyUserWnd`, `res_ui\nifsummonpartyuserwnd.2dt`), the 20 s per-slot wait, the member's confirm box
   with its 20 s timer, 0x751C. Test: window rows from a recorded 0xB519.
7. **Re-entry icon** -- the buff-bar icon (foundation client 5) with this group's texts. Test.
8. **QA** -- real clicks against the lane server: make a gate, enter, kill a hive, see the door open,
   recall a member, exit (`partybot` as the second member).

**Stage 3 notes (round 870, lane FQ: OpenSRO's server and two real clients together; the step table
is the round's WORLD_ISSUES entry):**
- **The doors stand at `objectstring.ifo`'s named positions** (READ, `game_worlds.md` 14 stage 3
  notes): all 52 `POS_STRUCTURE_GOD_*` zones have an entry; none is near a start (the nearest Togui
  door is 1,000+ units from 0x7EE4), so a door reaches a client when it walks into the door's window.
  In this client archive eventzonedata has no Togui zone (round 869), so a Togui door's record arrives
  and draws nothing; the Flame and Wreck doors draw their models.
- **The recall pillar draws** (`NPC_FWORLD_RECALL_PARTY`'s `Dun\Property\com\property_recall.bsr` is a
  type-2 object with no skeleton; MEASURED the original shows "a dark stone pillar with red light"):
  the client builds an NPC whose model is a static object through the scenery templates, with its
  ambient effect, collider and plate (`World3D._place_static_npc`). Before, it was not placed and
  could not be selected.
- **The exit and recall selects**: `{01, u32 npc, 00, 01, 29 | 27, 00}` MEASURED (section 5's raw
  bytes), sent so.
- **0x320C**: twice for a new limit (after the notice pair and in the arrival state), once on a
  re-entry, once on each arrival back in town and once after the 0x3012 of a login (MEASURED; before,
  OpenSRO sent it at the login's world entry, before the client's world existed, and the icon was
  missing after a login inside the limit).
- **Every NPC select inside Togui after a walk was refused** (0xB045 {02, 4}): the client sent its
  frame-anchored scene heights (Togui's anchor 834); the wire carries region-local heights now
  (`game_worlds.md` 14 stage 3 notes).
- **A gate vanished from a client at a zone change within its frame** (a GM's `/tp`, a return to the
  same town): its record was kept but its holder, under the old terrain group, was taken for standing
  (`StructureWorld._standing` now reads the parents, as the NPCs' `npc_holder_standing` does).
- **The data's own quirk**, sent as bound: one Togui world's camp-2 system-line action (row 2027,
  `TRIGGER_ACTION_MESSAGE_SYSTEM_WINDOW_1228`) names `..._ENVY_TOGUI_1`, so its banner says "Camp No. 2"
  and its line "Camp No. 1" (MEASURED in the data).
- **The recall's warp** waits 5.0 s after the Yes (W3's); MEASURED 5.32 s from `B51C` to the first
  despawn, INFERRED the push's u32 5 plus the original's job tick. Kept at 5 s.
- **The warnings** come at their thresholds exactly (60 / 10 / 5 minutes before the end); MEASURED
  each 9.9 s past them in the original (3,609.9 s, 6,609.9 s, 6,909.9 s, 7,209.9 s after the hole),
  and the empty closes 601.0 s and 604.9 s: INFERRED the shard manager's tick phase, not a rule;
  not copied.

## 12. Stage 2: size (estimate)

The foundation is the larger half. Suggested lanes (each with its own tests; the scaling work can
start in parallel with the world unit because it only needs the interfaces):

| lane | scope | size |
|---|---|---|
| **W1 server: world unit** | `game_worlds.md` server 1-8: reference export, `gameworld.World` / `Manager`, session plumbing out of the global hub, warps between worlds, lifecycle, entry rules, persistence, exit NPC | **large** -- the biggest refactor since the hub (224 handler signatures, 45 runtime singletons, a dozen per-character maps); 2-3 sessions |
| **W2 server: scaling** | `game_worlds.md` server 11: registry (memory + PostgreSQL), bus (memory + LISTEN/NOTIFY), roles, the front's relay and re-route, heartbeat / reaper / drain, loopback multi-host tests | **large**; 2 sessions; depends on W1's interfaces only |
| **W3 server: triggers + FGW** | `game_worlds.md` server 9-10, this page's server 1-8 | **medium-large**; 1-2 sessions after W1's world unit exists |
| **C1 client: instances + FGW** | `game_worlds.md` client 1-6, this page's client 1-8 | **medium**; 1-2 sessions; perf gate for the world loading |
| **Stage 3** | QA (the inside was not measured: check against the READ behaviour) and the load test of `game_worlds.md` 12.7 | medium |

## 13. OPEN, and choices for the user

**Choices, decided (2026-11-09, before stage 2):**
1. Gate access: follow the data, the access type read per hole item (every hole today is type 6: only the
   creator enters by the gate; the party follows through the recall NPC inside).
2. Re-entry limit: 300 minutes on the server (the database and the item's cooldown); the client keeps reading
   its own text.
3. The free entrance ticket: not built (switched off in the data, referenced by neither binary).
4. The inside: built from what was READ; measured in stage 3 if entry can be made to work. The refusal's cause
   was found in round 869: the `GOD_*` areas are not bound to a game server (`forgotten_world.md` 5).
5. Instances on several processes: built and load-tested now, single process stays the default; prod runs one
   process until the user says otherwise.

OPEN (the refusal's cause, the type-6 gate's client test and the category-0xd texts are settled in
round 869, sections 4-5 and 8): why no monster spawned in the measured layer (section 5) and, with it,
everything the monsters drive: the trigger notices after the first, the doors (0x351E), the Envy, the
boss, the treasure boxes and rewards; death inside; the gate record's +0x260 (1 in every record
measured); the hole's "24
hours" expiry; how the talismans (`ITEM_TALISMAN_TOGUI_*`, `_FLAME_*`, `_WRECK_A_*` / `_B_*`) and
other rewards drop (no assigned drops on any FGW monster but the ENVY_DROP pillars; the drop groups
were not read); the treasure boxes' contents; what the 0x751A push's second and third u32 mean; everything in
`game_worlds.md` 13.

**Choices:**
1. **Gate access: creator only (6) or party (7).** The data we have sets Param6 = 6 on every hole:
   only the creator enters by the gate, the party follows by the recall NPC inside, and anyone (not
   only the master) may make a gate -- as MEASURED (section 3). With 7 the gate admits the
   creator's party directly and only the party master may make one. Recommend: follow the data (6),
   reading Param6 per item so a 7 in someone's data works too.
2. **The re-entry limit's length** (`game_worlds.md` choice 1): 300 minutes (database) or 480 (our
   client archive). Recommend 300 on the server.
3. **The free entrance ticket.** It is off in the data and unreferenced by both binaries. Recommend:
   leave it unbuilt (not served), or, if the user wants it, build it as OURS: using it clears the
   GROUP_INS_GOD cool time after the confirm box with its existing text.
4. **The inside was not measured** (every measured entry was refused, section 5: the `GOD_*` areas
   were bound to no game server, so their regions were never loaded). Recommend: build from the READ
   behaviour and the data, and measure the inside in stage 3 before calling it done.
