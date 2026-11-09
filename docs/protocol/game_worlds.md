# Game worlds and instances (the foundation)

Round 868, stage 1: the specification of the original's **game worlds** -- the open world, the
fixed special worlds and the instanced ones -- and of what OpenSRO has to build before any
instanced content (the Forgotten World, `forgotten_world.md`) can run. Stage 2 builds from it in
parallel lanes; the build checklist is section 14.

Labels: **READ** (from a binary, with the address: `s:` SR_GameServer.exe, `m:` SR_ShardManager.exe,
`c:` sro_client.exe; decomp dumps `/var/tmp/decomp_server`, `/var/tmp/decomp_client`, asm
`/var/tmp/srgs.asm`, `/var/tmp/sro_client.asm` on the render box), **MEASURED** (observed in the
running game, or counted in the reference tables / the archives), **INFERRED**, **OURS** (an OpenSRO
choice), **OPEN** (not known; do not guess). Table names are the shard database's; the counts are of
its rows.

Much of the server side was read from the assembly because the decompiler drops the world
manager's and the trigger engine's bodies; the addresses below are the asm's.

## 1. What a game world is

Every object in the original lives in a **game world**: a row of `_RefGame_World` (client copy
`gameworlddata.txt`, parsed by `RefParse_gameworlddata` c:0x753400: u16 id, str codename, u8 type,
u16, u16, str config group -- READ; the client has no consumer of it for the Forgotten World).

MEASURED (94 rows):

| ids | codenames | Type | WorldMaxCount | WorldMaxUserCount | Duration / EmptyRemain (ms) |
|---|---|---|---|---|---|
| 1 | `INS_DEFAULT` (the open world) | 0 | 1 | 0 | 0 / 0 |
| 2..9 | `INS_FORT_*` (eight fortresses) | 0 | 1 | 200..300 | 0 / 0 |
| 10..13, 16..39 | `INS_QNO_*` quest instances, `INS_EVENT_RANDOMMATCH` | 1 | 100 (400) | 1..16 | 0 / 0 |
| 14, 15 | `INS_QINSHI_FLOOR_5/6` | 1 | 5 | 500 | 0 / 0 |
| 40, 41 | `INS_ROC_TOP`, `INS_ROC_FRONT` | 1 | 5 | 150 / 8 | 17,640,000 / 17,640,000; 14,400,000 / 7,200,000 |
| 42..50, 62 | `INS_ARENA_*` | 1 | 200 (100) | 30..100 | 0 / 0 |
| 51..56 | `INS_TEMPLE_*` | 1 | 5 | 500 (32) | 5,400,000 / 5,400,000 |
| 57..59 | `INS_PHARAOH_NOVICE/EXPERT/MASTER` | 1 | 200 | 8 | 7,200,000 / 300,000 |
| 60, 90, 91, 92 | `INS_TEMPLE_DEFAULT`, `INS_JUPITER_FIELD`, `INS_PRISON`, `INS_GM_EVENT` | 0 | 1 | 0 | 0 / 0 |
| 61 | `INS_SIEGE_DUNGEON` | 1 | 8 | 30 | 1,200,000 / 1,200,000 |
| **63..84** | **`INS_GOD_*` (the Forgotten World, 22 worlds)** | **1** | **50** | **4 or 8** | **7,200,000 / 600,000** |
| 85 | `INS_EVENT_GHOST` | 1 | 100 | 40 | 0 / 0 |
| 86..89, 93, 94 | `INS_JUPITER_*` | 1 | 200 / 300 | 8 | 10,800,000 / 600,000 |

- **Type** 0 is a single, always-present world; **1** an instanced world, of which up to
  `WorldMaxCount` copies (**layers**) exist at once (READ: the layer table, section 3).
- `WorldEntryType`, `WorldEntranceType`, `WorldLeaveType` are 0 on every row except Roc front
  (6/1/1) and the siege dungeon (8/4/0). READ: an EntryType of 6 switches on the party rule of the
  instance-creating link path (s:0x4f3583); the other values' meanings are OPEN.
- **The server's class per row** (READ, factory s:0x5f5b60): `INS_DEFAULT`, the fortresses, the
  Qin-Shi floors 5/6, Roc and the arenas get hard-coded `CGameWorld_*` classes; every other row reads
  its `GAME_WORLD_NORMALIZE_TYPE` config, and `GAME_WORLD_NORMALIZE_TYPE_A` builds a
  `CGameWorld_Normalize_A` (a `CDataDrivenGameWorld`, vtable s:0xb01dcc, controller
  `CDataDrivenWCC_NormalizeA`); a row without it is a plain `CGameWorld`. All 22 `INS_GOD_*` worlds
  are `_A` (MEASURED: their config rows 424..445).
- **Maps load once per world, at start-up** (READ s:0x530720, s:0x53b4b0), and every layer of the
  world shares them: an instance owns objects, not terrain.

### 1.1 Which regions belong to a world

`_RefInstance_World_Region` {WorldID, RegionID} (MEASURED 4,754 rows). World 1 lists 2,385
regions and **includes every Forgotten World region**; each instanced world lists its own set. A game
server loads only the regions whose `ContinentName` is bound to it in `_RefRegionBindAssocServer`
(READ, section 5 item 7). In the measured data the Forgotten World continents are `GOD_TOGUI`,
`GOD_FLAME`, `GOD_WRECK_IN` and `GOD_WRECK_OUT`.

| worlds | regions | MEASURED |
|---|---|---|
| 63..68 (Togui) | 48 field regions, rows 121..126 (0x79..0x7E), columns 225..232 (0xE1..0xE8): 0x79E1..0x7EE8 | `.m`/`.o`/`.o2`/`.t` in Map.pk2, `nv_*.nvm` in Data.pk2 and a `minimap\<x>x<y>.ddj` tile for all 48 |
| 69..76 (Flame) | one dungeon region, **0x8012** = `dungeoninfo.txt` row 18, `Dungeon\Property\flame\flame.dof` | 210 `minimap_d\flame_dungeon\` tiles |
| 77, 78, 81, 82 (Wreck, inside) | 224 field regions 0x68ED..0x75FC | `.m`, navmesh and minimap tile for each |
| 79, 80, 83, 84 (Wreck, outside) | 224 field regions 0x68DC..0x75EB | the same |

**All six Togui worlds share the same 48 region ids, and two layers of one world share every
coordinate** (MEASURED from the table): an instance is never identified by its regions. Map.pk2 also
holds 14-19 regions beside each set that the set does not list (e.g. 122/234): whether the original
draws them is OPEN.

`_RefInstance_World_Start_Pos` {WorldID, RegionID, PosX/Y/Z (int), Param} (MEASURED 55 rows): the
arrival points. READ s:0x6029e0: an entry picks a **random** row of the world's start positions.
Forgotten World rows (one each): Togui 0x7EE4 (1063, 693, 1125); Flame 0x8012 (10897, 165, -6110);
Wreck inside 0x72F3 (264, -770, 1745); Wreck outside 0x6FE4 (1257, -247, 1771).

### 1.2 What lives in a world

- **Monsters:** `Tab_RefHive.GameWorldID` puts a hive (and its nests) in a world. A layer hatches
  its own copy of every hive of its world (READ, layer Init s:0x5f28f0). `Tab_RefNest.btType` 1 is a
  **dormant** nest that hatches only when a trigger activates it (READ s:0x682fb0 sets the layer
  copy's +0x14 = 1); `btRespawn` 0 means a killed monster is not replaced.
- **NPCs:** `_RefGameWorldNPC` (340 rows, none for `INS_GOD_*`) places NPCs per world; the Forgotten
  World places its NPCs as nests instead (`forgotten_world.md` 6).
- **Triggers:** `_RefGameWorldBindTriggerCategory` binds trigger categories to a world (130 rows):
  section 9.

### 1.3 Configuration

`_RefGame_World_Config` {Group, Key, Value, Type} (MEASURED 824 rows) is read per world by
`vslot_055` (READ s:0x608630) into fields of the world object. The keys the instanced worlds use:

| key | field (READ) | what it does |
|---|---|---|
| `GAME_WORLD_NORMALIZE_TYPE` | factory | `_A` = the data-driven class |
| `ENTER_LIMIT_CONDITION_LEVEL_MINIMUM_NUM` / `_MAXIMUM_NUM` | +0x90/+0x91, +0x92/+0x93 | the level band, checked at entry (0x1c2c) |
| `ENTER_LIMIT_CONDITION_JOB_CLOTHES_TAKE_OFF` | +0x88/+0x8c | no job suit at entry (0x1c2b) |
| `ENTER_LIMIT_CONDITION_RIDE_COS_NOT_RIDING` | +0x98/+0x9c | not riding (0x1c30) |
| `ENTER_LIMIT_CONDITION_TRADE_COS_NOT_RIDING` | +0xa0/+0xa4 | no trade transport out (0x1c10) |
| `ENTER_LIMIT_CONDITION_FRPVP_VOUCHER_TAKE_OFF` | +0xa8/+0xac | no free-PvP voucher worn (0x1c2b) |
| `PARTYMONSTER_SPAWN` | +0x58 | party-monster spawning; OFF in every FGW world |
| `MAX_SQUAD_MEMBER_COUNT` | +0x60 (default 6) | 30 in the Togui worlds; consumer not traced (OPEN) |
| `CONTROL_NOTIFY_SPAWN_UNIQUE_MONSTER_MSG` | +0x108 | ON in every FGW world; consumer not traced (OPEN) |
| `GAMEWORLD_DISAPPEARANCE_TIME` | -- (the shard manager's) | three rows per world, 3,600,000 / 600,000 / 300,000: **warning thresholds** (section 4) |
| (entry untouchable time) | +0x5c, default 6.0 s | the arrival protection (`arrival_guard.md`) |

**World groups.** `_RefGameWorldGroup` has one row, `GROUP_INS_GOD` ("잊혀진 세계 토귀 월드 그룹",
config `GROUP_CONFIG_INS_GOD`); `_RefGameWorldBindGameWorldGroup` puts worlds 63..84 in it.
`_RefGameWorldGroup_Config` (MEASURED):

| key | value | type | READ |
|---|---|---|---|
| `ENTER_WORLD_GROUP_COOL_TIME` | 300 | INT32 | x 60 s into +0xdc (group id at +0xd4): **18,000 s = 5 h** re-entry limit |
| `TIMEDJOB_COOL_TIME_FORCLIENT` | 300 | CLIENT_DATA | the client's copy (minutes) |
| `TIMEDJOB_ICONURL_FORCLIENT` | `icon\item\etc\teleprot_hole.ddj` | CLIENT_DATA | the buff-bar icon |
| `TIMEDJOB_EXPANATION_FORCLIENT` | `UIIT_STT_PARTY_LOST_WOLRD_EXPANATION` | CLIENT_DATA | tooltip text |
| `TIMEDJOB_SUBJECT_FORCLIENT` | `UIIT_STT_PARTY_LOST_WOLRD_SUBJECT` | CLIENT_DATA | tooltip title |

The client reads its own copy, `groupworld_config_forclient.txt`, in `Client_LoadRefDataFile`
(READ c:0x958a13..0x958bad: a 0x58-byte record keyed by group id, +0x00 = the cool time x 60 s,
+0x04 subject, +0x20 explanation, +0x3c icon; it never reads `ENTER_WORLD_GROUP_COOL_TIME`).
**MEASURED discrepancy:** our archive's file says **480** for group 1 (both keys), the database
**300**. Choice 1 (section 13).

## 2. The managers

READ: `CGameWorldMgr` (singleton s:0xd6a9a4; `GameWorldMgr_FindByID` s:0x5f6b80) holds one world
object per row; `CPublicInstanceWorldMgr` (s:0xd6a9a8; add s:0x606c80, remove s:0x606d30)
registers each live layer. Both are server singletons, not client ones (READ: the client has
neither).

**The shard manager owns the registry of instances.** The game server only runs layers; the shard
manager allocates layer slots, counts users in each layer and runs every instance timer (READ, the
`m:` addresses in sections 3 and 4). This split -- one registry, many layer runners -- is the
original's own, and it is what section 12 keeps.

## 3. An instance: identity and layers

- **An instance is a u32 = {u16 world id, u16 layer}** (READ `CGObj::EnterWorld` s:0x485360); the
  open world is world 1, layer 1. Every object keeps the word at +0x78 and pointers to its world and
  layer.
- **Layers are slots.** Each world keeps a vector of layer slots, slot 0 unused (READ); at most
  `WorldMaxCount` (50 for each FGW world). No free slot: the Dimension hole is refused (0x1852,
  `forgotten_world.md` 3).
- **Visibility is per layer, regions are shared**: each region block keeps per-layer object maps
  (READ), so the same region id in two layers never mixes their objects (`pc_spawn.md`: "players of
  the receiver's layer first").
- **A layer object** (`CGameWorldLayer`, Init s:0x5f28f0): world id, layer number, owner, a copy of
  the creating job, and an **instance key at +0x70**. Init hatches the layer's hives, starts its wave
  and portal spawners and its message sender, and loads its trigger set. Layer numbers are reused,
  so the key tells incarnations apart (INFERRED: the key is `_CharInstanceWorldData.DungeonKeyID`;
  s:0x5f30d0 compares the two).

## 4. Lifecycle: creation, timers, close

**Creation is a job through the shard manager** (READ):
1. The game server queues a world job (type 9) and s:0x5f82d0 sends **GS->SM 0x7C14** {u8 kind
   (1 = open, 3 = release), requester, job record}.
2. The shard manager allocates the first free slot (m:0x658b50), stamps "empty since" = now
   (m:0x6582d0, +0x54) and answers **SM->GS 0x3C15** {u8 kind, u16 world, u16 layer}.
3. The game server's dispatcher s:0x5f7b50: kind 1 "opened" (s:0x5f7bd0) builds the layer, registers
   it and (Forgotten World) creates the gate; kind 3 is the close (s:0x5f80b0).

For the Forgotten World the layer is created **when the Dimension hole is used**, not when someone
first enters (READ; MEASURED: the gate, which lives exactly as long as its layer, appeared at the
item use).

**Timers, all in the shard manager** (READ, world tick m:0x658810):
- **End** = open time + `WorldDurationTime` (2 h for `INS_GOD_*`).
- **Empty close**: the user count is tracked in and out (m:0x658e30, m:0x658f10; "empty since"
  re-stamped at 0 users); a layer with 0 users for `WorldEmptyRemainTime` (10 min) closes.
  MEASURED: two Forgotten World layers that nobody entered were removed (their gates despawned,
  0x3016) **601.0 s and 604.9 s** after creation; the excess over 600 s is INFERRED to be the shard
  manager's tick.
- **Warnings**: each `GAMEWORLD_DISAPPEARANCE_TIME` value is a threshold before the end; as each one
  passes, SM->GS 0x3CE8 makes the game server send everyone in the layer **0x300C {u16 0x0C1A, u8
  minutes}** -- 60, 10 and 5 minutes. The client (READ c:0x8764da) formats
  `UIIT_MSG_EGYPT_DUNGEON_DESTROY_ALARM` ("After %d minute, instance dungeon will vanish. When it
  vanish, user will move to saved return place.") and shows it as the blue notice banner (c:0x77b580)
  and as a system line (c:0x7781b0). The game server never reads the key; only the shard manager.
  MEASURED (round 869): `300C {1A 0C 3C}` to every player in the layer 3,609.9 s after its creation
  (the 60-minute threshold of a 2-hour world, plus the tick); `{1A 0C 0A}` at 6,609.9 s, `{1A 0C 05}`
  at 6,909.9 s.
  MEASURED close at 7,209.9 s: no text. The players in the layer get the despawns and an ordinary
  teleport (`34B5 {0x61A8}`, `34A5`, `3013`, `34A6`), each to its own return point (a summoned
  member: where it accepted). `320C` keeps running.

**Close** (READ s:0x5f80b0): every player still inside is warped to the return point on the
character (`_Char` LatestRegion/Pos/WorldID, which the warp in did not overwrite: s:0x4df666..0x4df68f
writes the destination only when s:0x5f85a0 returns 1); with nobody left the game server acks SM
0x7C14 {3, world, layer}; the layer, its monsters and its gate are removed (MEASURED: 0x3016 of the
gate to everyone who saw it). OPEN: the two kind bytes that tell a time-out close from an empty
close (the decompiler drops them).

## 5. Entering and leaving

**Entering is a teleport** (READ, `teleport_network.md` for the field form):
- Request **0x705A {u32 object, u8 kind, ...}** (s:0x513590). Kind 3 is a portal object: u8
  destination index. The reply is **0xB05A {u8 2, u16 1}** = "accepted, warp queued" (the handler
  always ends at s:0x513a33 through s:0x4e7250, which writes {2, code}; 1 is the accept), and then
  the warp handler (`CMainProcess::FUN_004f2b50`, internal message 0x7CE6) answers **0xB05A {u8 1}**
  on success (s:0x4f2cae..0x4f2cfe) or **{u8 2, u16 code}** on a refusal (s:0x4f300e..0x4f3024).
  MEASURED: the accept {2, 0x0001} followed by a refusal {2, 0x0003} (`forgotten_world.md` 5).
- **The warp handler's portal checks, in order** (READ, table s:0x4f37dc -> s:0x4f3347):
  1. a set on the player (+0x130, s:0x484df0) holding the gate's interaction id 0x1c -> 3 (what
     fills the set is OPEN);
  2. player flag 0x40000 -> 0x1c17;
  3. trade transport out -> 0x1c10;
  4. the portal's access rule (s:0x486a10 -> s:0x4865a0) -> 0x1c2f;
  5. the destination (s:0x486a40 -> s:0x4864e0); a miss -> 2;
  6. the world's **CanEnter** (below); its codes 2 and 6 map to 3 (s:0x5f9950);
  7. then by the gate's teleport-ref links: a link with byte +9 = 1 takes the create-instance job
     path (s:0x4f34bb..0x4f3657); otherwise a direct warp, `CGObjPC::vslot_222` (s:0x4df590), whose
     0 -> 3. It returns 0 for region 0, **layer 0** (s:0x4df5a7), a region not in the server's region
     table (s:0x4df5d8) or a region whose map is not loaded (s:0x4df607).
     READ (round 869): the region table holds only the regions whose area is bound to this server in
     `_RefRegionBindAssocServer`. The `_RefRegion` row reader (s:0x6a2e40) takes the area's value by
     `ContinentName` (s:0x5fba80), and the loader (s:0x6e33b0) drops a row whose value is 0. The value
     is the 1-based index of the shard's `SR_GameServer` node (s:0x412360, s:0x412530). s:0x4df607
     tests a region's index against the running server (s:0x412590, s:0x411780). This is the
     original's static sharding of areas over game servers. MEASURED: the Forgotten World refusals
     were this check, because the four `GOD_*` areas were bound to 0 (`forgotten_world.md` 5).
- **CanEnter** (READ s:0x609c30, base s:0x5ec5b0; world codes -> reply codes by s:0x5f9950):

| order | check | reply |
|---|---|---|
| 1 | the layer is full (`WorldMaxUserCount`; GMs exempt) | 0x1c25 |
| 2 | the party condition: no party or fewer than 2 members | 0x1c2a |
| 3 | job suit worn | 0x1c2b |
| 4 | level outside the band | 0x1c2c |
| 5 | riding a transport | 0x1c30 |
| 6 | trade transport out | 0x1c10 |
| 7 | free-PvP voucher worn | 0x1c2b |
| 8 | the group cool time runs for **another** instance | 0x1c32 |
| 9 | stall / trading | 2 |
| -- | the layer does not exist (`GetWorldLayer` null) | 2 -> 3 |

  OPEN: when the party condition (2) applies to an FGW world (its EntryType is 0).
- **Which layer** (READ s:0x60a5b0): the character's own recorded instance if its key matches; with
  `GAME_WORLD_ASSIGNED` set, refused 0x1c31; otherwise the party rule (s:0x60a740): the master gets a
  new layer, members follow the master's layer, else 0x1c28.
- **Arrival**: a random start position of the world (s:0x6029e0), through the ordinary teleport
  sequence (`arrival_guard.md`: 0x34B5 {u16 region}, 0x34A5, the character data, 0x34A6, the
  client's 0x3012, protection for the world's +0x5c seconds). **No world or layer id reaches the
  client** (READ: the spawn head c:0x9c3a70 and 0x34B5 carry none; OPEN: a full audit of 0x3013's
  tail for one).
- **The re-entry limit starts at entry** (READ s:0x60a070): a timed job of category 0xC
  (`CTJ_EnterWorldGroupKeeper`, `timed_jobs.md`) holding the instance key, for the group's cool time
  (5 h). While it runs the character may go back into **the same** instance and is refused any other
  (0x1c32). The client is told by **0x320C {u8 0x0C, u32 group id, u32 remaining seconds}** (READ
  c:0x88dad0 -> c:0x778f90 -> c:0x777f20(0xe) -> c:0x805a40 case 0xe): a buff-bar icon of kind 0xE
  with the group's icon; its tooltip shows the subject, the explanation and
  "`UIIT_STT_REMAIN_TIME`: %d`PARAM_HOUR` %d`PARAM_MINUTE` %d`PARAM_SECOND`" (c:0x8035d0..); the
  client computes elapsed = cool time x 60,000 - remaining x 1,000.

**Leaving** (READ):
- **The exit NPC**: **0x751D {u32 npc}** (s:0x51c050; the NPC offers interaction 0x29). Refusals:
  dead 0x1c36, trade transport 0x1c10, busy 2. Otherwise the warp to the return point; reply
  **0xB51D {u8 1}**, or {u8 != 1, u16 code} in error category 1 (c:0x89a760) -- whose switch has no text
  for 0x1c36, 0x1c10 or 2, so a refused exit shows nothing (READ round 869: 0x7b8c82 sends every code
  outside 3, 0x1807 and 0x180b..0x18ff to the default 0x7b913a).
- **The layer closes** (section 4): everyone to the return point.
- MEASURED (round 869, `forgotten_world.md` 5): the exit NPC's `751D` -> `B51D {01}` puts the player
  at the return point (where the gate was used). A **logout inside** writes nothing to
  `_CharInstanceWorldData` and leaves `_Char`'s region and world at the return point, so the next
  login is at the return point; while the layer lives, its gate takes the player back into **the
  same layer**, and `320C` then carries the remaining time. A member dismissed from the party inside
  stays in the layer. The arrival in a layer sends the same `34B5`/`34A5`/`3013`/`34A6` sequence
  as any teleport; `34B5`'s u16 was 0x61A8 (the return-point region) on the way in and on the way
  out. OPEN: where a player revives after dying inside; a disconnect inside.

## 6. Persistence

- **`_CharInstanceWorldData`** {CharID, DungeonKeyID, WorldID, LayerID, OpenedTime, RegionID,
  PosX/Y/Z (int), IsActivated (u8), EnterCount, LastEnterTime} (MEASURED columns). Written by
  `AQ_GameWorld` (READ s:0x441b40) through `{?=CALL _CharInstanceWorldDataUpdate(%d,%d,%d,%d,
  '%s',%d,%d,%d,%d,%d,%d,'%s')}` and `_CharInstanceWorldDataMarkUpLastWorld(%d,%d,%d,%d)`; deleted by
  `CWicket` with `delete _CharInstanceWorldData where CharID = %d and WorldID = %d` (s:0x602d50).
- **The return point stays in `_Char`** (section 4, Close).
- **The re-entry limit is a timed job** (`_TimedJob`, category 0xC; `timed_jobs.md`'s persisted
  record).
- **The Dimension hole's own reuse cooldown** is the item's cool-time group (0x71, 18,000,000 ms),
  MEASURED persisted as a `_TimedJob` row (category 6, the item's id, 18,000,000) for the character
  that used one.

## 7. The client

- **No world id on the wire** (section 5): the client draws what the region id and position name.
  Togui and Wreck are ordinary field regions (terrain, objects, navmesh, minimap); Flame is a
  dungeon (`dungeon.md`). INFERRED: the client needs nothing from the server beyond region and
  position.
- **World map**: `worldmap_instanceinfo.txt` has `Worldmap_FLAME_DUNGEON` (18 / 128) and **no row for
  Togui or Wreck** (MEASURED); what M shows there is OPEN.
- **Structures and event objects**: the gate is a `CITeleportGate` (any TypeID 4/1/x structure;
  vtable c:0xde46b4, factory c:0x9ea810) and a trigger door a `CIEventRuntimeObj` (c:0x535750). Both
  arrive in the spawn records' structure form (`forgotten_world.md` 4 has the gate's bytes; a door's
  record is the structure record plus u32 event-zone key (+0x280) and u8 (+0x284), c:0x535980).
  READ (round 869): the class is the object's type word's -- not bionic, TypeID 4/1 a
  `CITeleportGate` (c:0x9c1ca0), 4/2 a `CIEventRuntimeObj` (c:0x9c1cc0), both chosen by
  `IGIDObject::FUN_009c1fa0`; the structure record (`CIRuntimeStruct::vslot_025` c:0x56dfa0) is the
  CIGIDObject head (`FUN_009c3a70`: u32 uid, u16 region, f32 x, y, z, u16 angle), u8 +0x260, u8 +0x261
  (the state), u8 +0x254, u8 +0x255 (the access type), type 6 a u16-length ANSI name else u32 +0x258,
  then u32 +0x25c; a 0x3015 ends with one more u8 (slot 26, c:0x9c2180). A door's object is 36513
  `STORE_EVENTZONE_DEFAULT` (MEASURED: the only 4/2 row); its model is its event zone's object's
  (`forgotten_world.md` 6). Not drawn: a 0x351E state other than 0 or 1 leaves the object as it is
  (c:0x535750). **So a door's record carries the whole structure record too** -- `CIEventRuntimeObj::
  vslot_025` (c:0x535980) calls `CIRuntimeStruct::vslot_025` first, which reads +0x254, +0x255, the
  name or u32 +0x258 and u32 +0x25c for every runtime structure -- and only then u32 +0x280 (the
  event zone, eventzonedata.txt column 1) and u8 +0x284: {head, u8 +0x260, u8 state, u8 0, u8 0,
  u32 0, u32 0, u32 zone, u8 0} for a door with no owner rule (round 869, lane C1). And the name
  follows +0x255 only for type 6; any other type has the u32 (c:0x56dfa0).
- **Instance regions in the client** (MEASURED, round 869): the four start positions load as any
  field region or dungeon does -- Togui 126/228, Wreck inside 114/243 and outside 111/228 (terrain,
  objects, navmesh and minimap tiles from the archives), Flame as dungeon 0x8012 -- see the round's
  WORLD_ISSUES entry for the frames and the floor checks.
- **Event-zone switch**: **0x351E {u32 object id, u8 0x10, u8 state}** (READ c:0x89a7b0 ->
  c:0x5359c0; server s:0x52f120): sets +0x261 and redraws: state 0 builds the model (the bsr of the
  event-zone row's object), state 1 removes it. INFERRED: a door is drawn while closed and removed
  when its zone is switched ON.
- **Trigger notices**: **0x300C {u16 0x0C1C, u8 kind, str textKey}** (READ c:0x87657d..0x876670):
  kind 1 the blue banner only (c:0x77b580, `notice_banner.md`), kind 2 a type-0 system line only, in colour
  0xffdbc99b (c:0x7781b0); the key is looked up in the text table (c:0x8c9bb0).
- **The loading screen**: the ordinary teleport loading (`arrival_guard.md`); which backdrop the
  client shows for an instance region is OPEN.

## 8. Event zones

`eventzonedata.txt` (Media.pk2) rows of kind OBJECT name the trigger doors:
37 `POS_STRUCTURE_GOD_*` rows point at the `STRUCTURE_GOD_*` objects (MEASURED). READ: a
trigger's SWITCH_EVENTZONE (s:0x683d90) finds the layer's `CGObjEventZone` linked to the zone, sets
state 2 for ON and 1 for OFF, and on a change broadcasts 0x351E (section 7); the state is also in the
zone object's spawn record. What blocks movement at a closed door on the server is OPEN (no
navigation-mesh switch was found; INFERRED: the door structure's collision).

## 9. The trigger engine

Per layer (READ: a layer loads its trigger set at Init). The data (MEASURED):

| table | rows | what |
|---|---|---|
| `_RefTriggerCommon` | 32 | the vocabulary: 5 events, 12 conditions, 15 actions (TID1 = 1 event / 2 condition / 3 action) |
| `_RefTriggerCategory`, `_RefTriggerCategoryBindTrigger` | 130, 468 | categories and their triggers |
| `_RefGameWorldBindTriggerCategory` | 130 | categories per world |
| `_RefTrigger` | 468 | {CodeName, IsActive, IsRepeat, IndexNumber} |
| `_RefTriggerEvent` / `BindEvent` | 468 / 468 | one event per trigger |
| `_RefTriggerCondition` / `BindCondition` / `ConditionParam` | 470 / 470 / 499 | {OnTrue, OnFalse, Sequence, param group} |
| `_RefTriggerAction` / `BindAction` / `ActionParam` | 2,219 / 2,219 / 3,243 | {Delay (ms), param group} |
| `_RefTriggerVariable` | 0 | |

Vocabulary (MEASURED codenames; semantics READ where marked, else INFERRED from the names and the
data):

- **Events**: `WORLD_CREATE`, `WORLD_ENTRANCE` (a player enters the layer), `SELECT_TALK_WINDOW`,
  `SELECT_NPC`, `POSITION_EVENTZONE`, `MONSTER_KILL`.
- **Conditions**: `POSITION_EVENTZONE_IN/OUT`, `MONSTER_KILL` (param `MONSTER_SELECT` codename),
  **`MONSTER_HIVE_KILL`** (param `HIVE_MONSTER_SELECT`; READ s:0x690a70: counts the kills of that
  hive's monsters in the layer and is true when the count reaches the sum of the hive's nests'
  `dwMaxTotalCount` (s:0x55e9b0) -- with no respawn, "every monster of the hive killed"),
  `MONSTER_RARITY_KILL` (`NUM_INPUT`), `MONSTER_LEVEL`, `MONSTER_LEVEL_KILL` and `USER_LEVEL`
  (`SIGN_SELECT` `SIGN_LEFT_BIG_EQUAL` / `SIGN_RIGHT_BIG_EQUAL` + `NUM_INPUT`), `VARIABLE_SINGLE`,
  `USER_ITEM`, `USER_QUEST`, `NPC_CODENAME`. A trigger's conditions run in `Sequence` order; `OnTrue`
  / `OnFalse` are `NEXT`, `RETURN_TRUE` or `RETURN_FALSE` (MEASURED values; the chain rule is
  INFERRED, OPEN in the binary).
- **Actions**: **`MONSTER_ACTIVE_NEST`** (`NEST_MONSTER_SELECT` nest id; READ s:0x682fb0 wakes the
  layer's copy), **`MONSTER_LOAD_MONSTER`** (`NUM_INPUT_1`, `MONSTER_SELECT`, `FLOAT_INPUT`,
  `TARGET_PLAYER_INS_SELECT`, `NUM_INPUT_2`; INFERRED: `FLOAT_INPUT` the chance, `NUM_INPUT_2` the
  count, the target the player it spawns at; `NUM_INPUT_1` OPEN), `CREATEOBJECT_STRUCT`,
  `CREATEOBJECT_TELEPORT`, **`SWITCH_EVENTZONE`** (`EVENT_ZONE_SELECT`, `ON_OFF_SWITCH`; section 8),
  `SWITCH_TRIGGER`, `SWITCH_TELEPORT`, **`MESSAGE_NOTIFY_WINDOW` / `MESSAGE_SYSTEM_WINDOW`**
  (`STRING_INPUT` text key, `TARGET_PLAYER_INS_SELECT`; READ s:0x5f9450 sends 0x300C {0x0C1C, 1 | 2,
  key}; targets READ s:0x5f9750: `TARGET_PLAYER_ALL` 1, `_PARTY_MASTER` 2, `_RANDOM` 3,
  `_EVENT_USER` 4), `VARIABLE_VALUE/ADDITION/SUBTRACTION`, `NPC_LOAD`, `SCRIPT_CINEMA`.
- `Delay` (ms) on an action: MEASURED values 0 and 20,000 (the FGW entry notice); READ semantics
  OPEN (INFERRED: the action runs that long after the trigger fires). `IsRepeat` 1 = the trigger can
  fire more than once (INFERRED: the entry notice is the only repeating FGW trigger, once per
  entering player).
- **World 1 has triggers too** (7, the Forgotten World's pillars: `forgotten_world.md` 2), so the
  engine must run in the open world as well as in instances.

## 10. OpenSRO today (round 868, before stage 2)

MEASURED in the code (base `60b40fca`):
- **One process, one world.** `server/cmd/server/main.go` builds one `world.Hub`
  (`internal/world/world.go`: one `sync.RWMutex` over `byZone`, `bySession`, `byChar`, `byName`,
  `byCell`, `moving`), one `combat.Hub`, one `grounditem.Hub`, one `party.Hub` (in memory), one nest
  scheduler, and process-wide loops (`RunMonsterAI`, `RunMonsterAOI`, `hub.AdvanceMovers`, the nest
  pass, regen, buffs, status effects, COS, ground items). 224 session parameters take the `*world.Hub`
  and 32 the `*combat.Hub`; 45 `atomic.Pointer` runtime singletons in `internal/session` and about a
  dozen per-character maps behind package mutexes (`motions`, `buffBooks`, `itemCooldowns`,
  `statusFX`, ...).
- **Visibility is per zone label**: `combat.Cell{Zone, x, z}` (320-unit blocks) and `InView` requires
  the same zone, so a different bucket string already isolates who sees whom. Hazard: under
  `-single-frame`, `ZoneBucket` (`session/world.go`) merges every `"x/y"` label into `"world"` -- an
  instance region label such as `126/228` would join the open world.
- **Other worlds are refused**: `inOpenWorld` (`session/teleport.go`, OURS round 642,
  `teleport.MainWorld = 1`) and `placeArrival` (`session/scroll.go`) refuse every world but 1; the nest
  join drops every hive whose `GameWorldID` is not `nest.FieldWorldID = 1` (`internal/nest/join.go`).
  Dungeons reachable from world 1 (0x8001..0x8007) are each one shared bucket (`dungeon.md` 5).
- **Warps** go through `warpVia` (`session/world.go`): change zone (held), save, `holdArrival`,
  `OpChangeZoneResult` (OURS, in place of 0x34B5/0x34A6), release on 0x3012.
- **Persistence**: PostgreSQL through pgx (`txn.OpenNamedPool`, pools of 32 + 8 per process); the
  character keeps a zone label, frame and point; no world or instance column; `internal/timedjob`
  persists timed jobs. **No registry, no pub/sub, no cross-process mechanism exists.**
- **Players are found in process**: whispers and friends (`hub.FindByName`), world chat and unique
  notices (`hub.AllEntities`), parties (`party.Hub`), guild plates.
- **Client**: a zone change (`World3D._on_change_zone_result`) shows the loading screen and reloads by
  zone label; `"x/y"` streams field regions within 2 of the player (no check against a world's region
  set); `dungeon/<rid>` loads any `.dof` (0x8012's minimap folder is already mapped). **The spawn
  reader refuses the structure record forms** (`npc_spawn.gd`, ref id 0xFFFFFFFF/0xFFFFFFFE), so
  neither a gate nor a door can spawn today.
- **Data**: the client archives ship `gameworlddata.txt`, `gameworldconfigdata.txt`,
  `groupworld_config_forclient.txt` and `worldmap_instanceinfo.txt`; the region and start-position
  tables, world groups, every `_RefTrigger*` table and the hive/nest/tactics tables are server-only
  and must come from the operator's database export (as `-nest-db-dir` does today).

## 11. What OpenSRO has to change

1. **A world unit** (`internal/gameworld`): the reference tables of section 1 and 9, a `World`
   (ref, layer, key, created, expires, empty-since) that owns its hub, monsters, ground items, nest
   scheduler, AI / visibility / mover runtimes, trigger engine and timers, and one goroutine. The open
   world becomes world 1, layer 1, built the same way.
2. **Session handlers find the character's world** instead of a captured global hub; the per-world
   singletons move into the world unit; per-character state (motion, buffs, cooldowns, status, pets)
   moves onto a per-character runtime that travels with the character.
3. **Warps take a target world**: `warpVia` / `placeArrival` move a character between world units
   (leave one, `EnterHeld` in the other); the client still gets `OpChangeZoneResult` with the region
   label (`126/228`, `dungeon/32786`), never a world id. `ZoneBucket` never merges an instance label.
4. **`inOpenWorld` and the `MainWorld` callers** accept the instance world the character is in; the
   nest join routes other-world hives to their worlds instead of dropping them.
5. **Persistence**: an instance position is never saved as the home position (the return point stays
   on the character); a table with `_CharInstanceWorldData`'s columns; a timed-job type for the group
   cool time; at login, an instance that is no longer open lands the character at its return point.
6. **Triggers and event zones** (section 9, 8), **structure spawns** (gate, doors) on both sides,
   0x351E, 0x300C 0x0C1A / 0x0C1C, 0x320C 0x0C.
7. **The server navmesh** for instance regions: `export-navmesh` already copies every `nv_*.nvm`
   (MEASURED: the 48 Togui and 448 Wreck files are in Data.pk2), so `-navmesh-dir` covers Togui and
   Wreck; Flame (a dungeon) has no server navmesh, as no dungeon does today (`dungeon.md` 5).
   **The Wrecked Ship's decks are compounds** (MEASURED, round 869: `wreck_bship_in_01`,
   `wreck_sship_in_01/02/09`, `wreck_sship_out_07` ... are `.cpd` objects in the regions' `.nvm` object
   lists; until round 869 neither reader gave a compound a navigation mesh, so the Wreck-inside start
   (114/243 at 264, 1745) had no walkable surface above the -1800 terrain). READ (round 869,
   `MapLoader::FUN_0042bc00`, the object index's 'd' case): a compound's navigation mesh is the one of
   the `.bsr` named by a length-prefixed string at the file offset in its header word 0x0C
   (`wreck_sship_in_01.cpd`: offset 73, `res\dun\property\wreck\ship\wreck_sship_in_01.bsr`); the
   client's `NavObjectSource` and the server's `navmesh.CollisionPath` now both read it.

## 12. OURS: instances that scale horizontally

The user's requirement, verbatim: "make sure instanced worlds are virtually infinitely horizontally
scalable". This section is OpenSRO's own architecture (**OURS**); the wire and what players see stay
the original's exactly. It keeps the original's own split -- one registry of instances (the shard
manager's role) and many layer runners -- and makes the runners independent processes.

### 12.1 The instance unit
- Each instance (`gameworld.World`, world id + layer) has **its own** entity hub and visibility
  index, monsters, nests, ground items, trigger engine, timers, clock and **one goroutine** (its tick
  loop). It shares **no lock and no mutable map** with the open world or with any other instance;
  reference data (refdata, navmesh, skill and item tables) is immutable and shared read-only.
- **No per-tick iteration over all instances.** Creating an instance starts its goroutine; closing
  it cancels its context. Timers (duration, empty close, warnings) are the instance's own
  `time.Timer`s, not a scan. An empty instance stops ticking its monsters and keeps only its timers.
- Per-character state that today lives in package-level maps moves onto a per-character runtime
  attached to the character's world entity, so a character can move between instances -- and
  between processes -- by serialising that runtime.

### 12.2 Where instances run
- **Process roles**, one binary, a `-role` flag: `all` (today's single process, **the default for dev
  and QA**), `front` (client connections, framing, login, routing), `home` (the open world and the
  social services) and `instance` (instance worlds only). Adding an `instance` process or host adds
  capacity with no other change.
- **Routing is a proxy, not a redirect** (the client protocol is unchanged). Neither client can be
  moved to another server mid-session: the retail agent redirect (0xA102) exists only at login, the
  original's agent server relays game traffic to its game servers, and OpenSRO's own client stays on
  its one connection (`client/scripts/net/login_ack.gd`). So the **front** keeps the client's TCP
  connection and opens an internal stream to the process that owns the character; the stream carries
  the already-decoded frames behind a small header (session token, account, character). On the host
  the stream is an ordinary `gateway.Session` from an internal listener, so the session handlers do
  not change.
- **Entering an instance on another process**: (1) the source saves the character and its carried
  runtime and removes it from its world; (2) it asks the front to re-route the character to the
  target host and instance with a one-time token; (3) the front buffers the client's packets, opens
  the stream to the target and closes the old one; (4) the target loads the character and runtime,
  enters it held into the instance and sends the ordinary zone change; (5) the client shows its normal
  loading screen and sends 0x3012, which releases the hold. This is the same shape as the original's
  re-login on every teleport (`arrival_guard.md`). In `-role all` the re-route is a local world swap.
- **Placement by load**: each host reports {players, instances, a CPU score} to the registry every
  2 s; creating an instance picks the least-loaded live host (`FOR UPDATE SKIP LOCKED`), inserts the
  instance row and notifies that host, which opens the layer and answers like the shard manager's
  0x3C15.

### 12.3 What is shared: PostgreSQL first
- Character persistence is already shared PostgreSQL. The **instance registry** goes there too: it
  is small, transactional (a slot allocation, a membership change and a cool time must commit
  together), gives leases through `FOR UPDATE` and advisory locks, and adds no new dependency or
  failure mode. Tables (OURS): `world_hosts` {host id, address, version, state active|draining|dead,
  heartbeat, players, instances, load}; `instances` {world, layer, key, host, party, owner, gate
  object, created, expires, state creating|open|closing|lost}; `instance_members` {instance,
  character, entered at, return point}; `char_instance_world` (`_CharInstanceWorldData`'s columns);
  `presence` {character, front, host, session token}. Cool times and expiries use the database's
  `now()`, not each host's clock.
- **The bus** for everything that must reach a player wherever they are -- chat (all channels),
  whispers, party, guild, academy, friends, notices, GM look-ups: an interface `bus.Bus`
  {`Publish(channel, msg)`, `Subscribe(channel)`} with three implementations: **in-process** (the
  default), **PostgreSQL LISTEN/NOTIFY** (one channel per front and host plus a broadcast channel;
  one dedicated pgx connection per process; payloads over 8,000 bytes go in a row and travel by id),
  and **NATS** if measured traffic outgrows LISTEN/NOTIFY (an embeddable server, subject routing, no
  size limit; a new dependency, so not first). Delivering to a character looks up its front in
  `presence` (cached) and publishes there; the front writes to the socket. The social services
  (party, guild, academy, friends) stay authoritative on the home role and talk to the members'
  hosts through the bus.

### 12.4 Failure and deploys
- **A host dies**: it misses its heartbeat lease for 10 s; the reaper (whichever process holds the
  reaper advisory lock) marks it dead and its instances **lost**; each member's place is reset to its
  return point; the fronts warp those players to the home role with the normal loading screen, so
  nobody is disconnected or left stuck. Every login falls back to the return point when the recorded
  instance is not open.
- **A front dies**: its sessions drop; hosts see closed streams as ordinary disconnects (a re-login
  returns to an instance that is still open, as the original's table allows).
- **Graceful drain**: a draining host gets no new instances; its instances run to their end or to a
  deadline, then the members go to their return points with a notice, then it exits. A rolling deploy
  starts new hosts, then drains the old ones; placement prefers same-version hosts and the relay
  checks a protocol version.

### 12.5 Single process stays the default
`-role all` runs the in-memory registry and bus behind the same interfaces, so stage 2 builds and
tests on one box; several processes are a deployment choice. Every stage-2 test runs in this mode;
the multi-process mode gets its own tests (two hosts in one test binary on loopback).

### 12.6 What prod needs to run more than one process
Prod is one compose stack on one machine (one PostgreSQL container, one server container). To run
more than one process: role flags and separate compose services (one front, one home, N instance
hosts) on an internal network, players still connecting only to the one public port; smaller pools
per process or a higher `max_connections` (each process opens 32 + 8 against a limit of 100, so about
two processes fit today; PgBouncer's transaction pooling breaks LISTEN, so the bus connection must
bypass it); the same data mounts on every host (navmesh, refdata, nests, the world/trigger export); a
metrics port per process in the scrape configuration; an update script that drains and rolls instead
of restarting the stack. Across machines: PostgreSQL reachable on the LAN, and authentication on the
relay and the bus (a shared secret or mutual TLS).

### 12.7 Proof (stage 3): the load test
`cmd/swarm` gains a Forgotten World mode: parties of 4 (bots already accept invites), the leader
given a Dimension hole through the database, the gate made, the party in, bots walking and fighting
with real blows (as `partybot -kill`). Runs at 50, 200, 500 and 2,000 parties against 1, 2, 4 and 8
instance hosts, first on one machine on separate ports, then across machines. Measured: per-instance
tick cost (a histogram per world type), instances and players per host, host CPU and memory, instance
creation time, entry time from re-route to 0x3012, the relay's added latency (the swarm probe inside
an instance against the open world), bus messages per second and their delay. **Pass**: capacity
grows linearly with hosts at a fixed per-host tick budget, and no shared part (PostgreSQL
connections, notify throughput, the front's CPU) saturates. Fault drills: `kill -9` a host (all its
players back in the open world in under 15 s) and a drain under load.

### 12.8 As built (round 869, lane W2)

What stage 2 built of 12.1-12.7 (all OURS; the measurements are in `docs/WORLD_ISSUES.md`, "Eight-hundred-and-
sixty-ninth round, lane W2"). Where it differs from the design above, this is what runs:

- **Roles**: `-role all` (the default: one process, exactly as before), `-role front`, and `-role world` with
  `-world-layers open | instances | both` in place of 12.2's `home` and `instance` (a host running the open world
  is 12.2's home: logins and the social services' authority). A host without the open world serves no client
  listener of its own.
- **The front frames and routes; it does not log in.** Every client stream opens on the open world's host, where
  the login, the character list and the world entry run as in one process. The front reads OpenSRO's own framing
  (no security, as every production session) and never forwards the internal control range 0xFE00..0xFE0F
  (`relay.OpHello` with the shared secret and the player's address; `OpBind`, who is in the world on the
  stream; `OpReroute`, the move with the hand-off). The retail listeners (round 788) stay on `-role all`.
- **The move** (`session/handoff.go`): the source asks the session to end (`gateway.Session.RequestEnd`), its
  disconnect bookkeeping runs in hand-off form (the watchers drop the character as at a warp; no offline line to
  the guild, the academy or the friends; the party keeps it; the login stays held), its carried runtime is taken
  first and the re-route sent last; the front opens a stream to the target with the hand-off in the hello and
  replays the client frames the source had not handled (`Reroute.Consumed`); the target enters the character
  held, as `warpAcross` does, and sends the ordinary `OpChangeZoneResult`. Carried: the buff book whole (records,
  tokens, starts, state bits, speed and wall holders, the GM /speed factor; `buff.BookState`), the item and
  cool-time groups, the live MP, the return point. Not carried (OPEN): the abnormal states (they end, as at a
  death), a `lnks` link to another character; the COS are put away and called out again as at a login.
- **Tables** (12.3's names, prefixed): `world_hosts`, `world_instances` (a lost layer keeps its row a day; the
  slot index covers only open and closing rows), `world_instance_members`, `world_presence`, `world_returns`
  (the return point the recovery uses), `bus_spill`; `char_instance_world` is lane W1's. The game clock of every
  host follows the open world's host's start (`world_hosts.started`), so a move shows no jump.
- **Parties** are not kept on the home role alone: every process keeps every party, each change is broadcast as
  the party's whole state with a sequence (`party.Snapshot`), a member elsewhere is held with a remote session,
  and only the member's own process samples its 0x3864 kind 6 updates. Party ids carry the forming host's range.
- **Delivery**: `session.reachOf` (local hub, any world of this process, then the directory) for the guild,
  academy and union lines and updates, the friends' pushes, party members; `findByNameCluster` for a whisper, a
  friend request, a GM kick; a global and a notice go to every other process in one message
  (`sendEverywhere`); a crest change is replayed on each process (its plate cache too); a friend request's answer
  goes to the asker's process. Per-host outboxes batch the deliveries (1 ms) and send identical frames once.
- **Failure**: the front recovers a character whose stream broke at once (MEASURED 10 ms in the four-process
  test), before the reaper's 10 s lease; a host the reaper declared dead is fenced (its next beat is refused and
  it exits). **Drain**: SIGTERM; the close warning 0x0C1A with the deadline's minutes (OURS reuse); at the
  deadline the layers close and their players go home; moving a live layer to another host is not built (OPEN).
- **NATS** (12.3's third bus) is not built: LISTEN/NOTIFY carried the load test without strain.

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

OPEN (not read, not measured): the close messages' kind bytes (the close itself: MEASURED, section 4); where a player revives after dying
inside (re-login and a member leaving the party inside: MEASURED, section 5); the trigger chain
rule (OnTrue/OnFalse), Delay and IsRepeat in the binary; `NUM_INPUT_1` of LOAD_MONSTER; the door's
server-side block; the loading backdrop and world map inside
Wreck (Togui: the ordinary loading screen, no world-map page -- MEASURED, `forgotten_world.md` 5); whether neighbouring unlisted regions are drawn; `MAX_SQUAD_MEMBER_COUNT` and
`CONTROL_NOTIFY_SPAWN_UNIQUE_MONSTER_MSG`'s consumers; a full 0x3013 audit for a world field.

Choices:
1. **The re-entry limit: 300 or 480 minutes.** The database (and the item's own cool time,
   18,000,000 ms) say 300; our client archive's `groupworld_config_forclient.txt` says 480, and the
   client draws its icon's bar from its own file. Recommend: the server enforces the database's 300
   and the client reads its archive (as the original does); the bar then runs on a 480-minute scale
   with a correct remaining time.
2. **Multi-process from the start or later.** Recommend: build the instance unit, the registry and
   bus interfaces and the proxy now (single-process default), and turn on multi-process in prod only
   after the stage-3 load test.

## 14. Build checklist (stage 2, the foundation -- before any FGW content)

The wire is the original's (`PROTOCOL_DECISION.md`); OpenSRO's own zone-change message stays.

**Stage 2 notes (round 869, lane W1; the server side as built -- the client lanes read the same):**
- **The 0x300C payloads ride OpenSRO's notice opcode 0x0110** (`session.OpUniqueNotice`, round 657's
  convention: the client's `UniqueNoticeNet` / `notice_word` path already carries 0x300C's 0x0C05 /
  0x0C06 / 0x0C01 payloads there). So the close warning is 0x0110 {u16 0x0C1A, u8 minutes} and a
  trigger notice 0x0110 {u16 0x0C1C, u8 1 | 2, u16 len, key}. 0x351E, 0x320C, 0x705A / 0xB05A and
  0x751D / 0xB51D are on their retail opcodes (`proto.OpEventZoneState`, `OpTimedJobPush`,
  `OpTeleportUse` / `Ack`, `OpInstanceExit` / `Ack`).
- **0x351E's state byte** (INFERRED): the server's ON (2) is the wire's 1 (the door removed), OFF (1)
  the wire's 0 (built). The door's spawn tail is {u32 event-zone key = the `_RefEventZone` ID, u8 0}
  after the structure fields (INFERRED order; section 7). Where the doors stand is OPEN (no table, nest
  or map list found names their positions), so no door is spawned or blocks yet; a placement fed to
  `gameworld.Manager.SetZonePlaces` makes one block the server's move (OURS, 40 units).
- **Action Delay** (INFERRED, OPEN in the binary): each action runs its own Delay after the trigger
  fires. MEASURED in the data: the FGW entry notice's banner action has Delay 20,000 and its system line
  0, so with this reading the system line comes at once and the banner 20 s later
  (`forgotten_world.md` 6 read it as both after 20 s: the cumulative reading). Which is right is OPEN.
  **Round 869 lane W3: neither** -- MEASURED, the banner and the system line both arrive with the
  arrival (right after the client's 0x3012), banner first; the engine now runs every action at once,
  in binding order, and holds a message for a character still behind the arrival guard until its
  0x3012 (`forgotten_world.md` 11, stage 2 notes). What the column means stays OPEN.
- **The party condition** (CanEnter's 2) is applied only to a world whose EntryType is 6 (INFERRED: the
  type READ to switch the party rule on; every FGW world's is 0, and a solo entry MEASURED was refused 3,
  not 0x1c2a).
- **The event user of MONSTER_KILL** is the kill credit, the biggest hitter (INFERRED).
- **A warp from an instance** to a place outside the instance's regions lands in the open world; to a
  place inside, it stays (OURS rule: `session.warpTarget`). A re-login lands at the return point (the
  instance position is never saved: READ s:0x4df666); re-entering a still-open instance at login is not
  built (OPEN, section 13).

### SERVER
1. **Reference data** -- `server/cmd/export-refdata` (new `-mode gameworlds`) writes the world,
   world-config, group, group-config, group-bind, region, start-position and every `_RefTrigger*`
   table and the event zones to CSV; `server/internal/gameworld/refdata.go` loads them (from the
   client's `gameworlddata.txt` / `gameworldconfigdata.txt` where they exist). Test:
   `gameworld/refdata_test.go` (22 GOD worlds, 48 Togui regions, start position 0x7EE4, group cool
   time 300 -> 18,000 s, three warning thresholds).
2. **The world unit** -- `internal/gameworld/world.go`: `World` {ref, layer, key, created, expires,
   emptySince}, its hub, combat hub, ground items, nest scheduler built from its hives (dormant nests
   kept, respawn 0), its runtimes and one goroutine; `Manager` (slots 1..WorldMaxCount, open, find,
   close). The open world is world 1 layer 1. Test: two layers of world 63 see none of each other's
   entities in the same region; no shared lock (a race test running both).
3. **Session plumbing** -- `internal/session`: handlers resolve `worldOf(sess)`; move the per-world
   singletons into the unit and the per-character maps onto a carried runtime. Test: the existing
   suite green in `-role all`; a character carried between two units keeps buffs and cooldowns.
4. **Warps between worlds** -- `warpVia` / `placeArrival` take a target world; `ZoneBucket` never
   merges an instance label; `inOpenWorld` / `MainWorld` callers accept the current instance;
   `nest/join.go` routes other-world hives. Test: warp into a layer and back; the return point
   untouched.
5. **Lifecycle** -- duration end, empty close (10 min), warnings 0x300C {0x0C1A, u8 minutes} at
   60/10/5 min, close warps everyone to the return point, gate and monsters removed. Test with a fake
   clock: 600 s empty -> closed; 2 h -> closed with members moved; the three warnings' bytes.
6. **Entry rules** -- CanEnter's order and codes (section 5), the layer pick, a random start
   position, protection; 0x705A kind 3 with the {2, 1} accept then {1} / {2, code}. Test: one case
   per refusal in order; the two-reply success.
7. **Persistence** -- `internal/persistence/schema.go`: `char_instance_world`; the group cool time as
   a timed job (category 0xC) with 0x320C {0x0C, group, remaining s} at entry and world entry; the
   login fallback to the return point. Test: re-entry to the same instance allowed, another refused
   0x1c32; restart keeps the cool time.
8. **Exit NPC** -- 0x751D / 0xB51D with its refusals. Test.
9. **Event zones and structures** -- `CGObjEventZone` per layer; SWITCH_EVENTZONE state and 0x351E;
   structure spawn records (gate, door). Test: the bytes; a closed door blocks the server's move
   check (OURS mechanism, section 13 OPEN for the original's).
10. **Trigger engine** -- `internal/trigger`: events, conditions (with MONSTER_HIVE_KILL's sum rule),
    actions (ACTIVE_NEST, LOAD_MONSTER, SWITCH_EVENTZONE, both MESSAGE kinds with targets, Delay),
    per layer and in world 1. Test: the Togui script of `forgotten_world.md` 6 run on a fake layer.
11. **OURS scaling** -- `internal/registry` (memory + PostgreSQL), `internal/bus` (memory +
    LISTEN/NOTIFY), `-role all|front|home|instance`, the front's relay and re-route, heartbeats,
    reaper, drain. Test: two hosts in one test binary on loopback: placement, a re-route mid-session,
    a host killed (players at their return points), a drain.
    **Built (round 869, lane W2; 12.8):** `-role all|front|world` with `-world-layers`; `internal/registry`
    (Memory + Postgres, `cluster.go`), `internal/bus` (Memory + Postgres), `internal/cluster` (the node),
    `internal/relay` (the front, the host codec), `session/handoff.go` and the `cluster*.go` files. Tests: the
    registry, the bus, the node and the relay with several hosts in one binary (in memory, and on PostgreSQL);
    `cmd/server/cluster_test.go`, four processes on loopback (placement, the hand-off in and out, a whisper and a
    party line across processes, a host killed, a drain); the load test `cmd/loadworld/run.sh`.

### CLIENT
1. **Structure spawns** -- `client/scripts/net/npc_spawn.gd` (and the group-spawn reader): accept the
   structure record forms; build `CITeleportGate`-like gates and event doors. Test: the measured gate
   record of `forgotten_world.md` 4 decodes.
2. **Instance regions** -- `World3D` zone change into an instance label loads Togui / Wreck as field
   regions and Flame as dungeon 0x8012, with the loading screen; minimap tiles. Test: a QA shot at
   each start position (`qa_shot.sh`), perf gate `--sites jangan` (world loading changes).
3. **0x351E** -- the door object built at state 0, removed at state 1. Test.
4. **0x300C 0x0C1A and 0x0C1C** -- banner and system line (`hud_system_message.gd`,
   `notice_banner.md`). Test: the bytes to the texts.
5. **0x320C kind 0x0C** -- the buff-bar icon of kind 0xE from `groupworld_config_forclient.txt`, its
   tooltip and bar. Test.
6. **Exit NPC talk line** -- interaction 0x29 adds "Exit Dungeon" (`UIIT_STT_DUNGEON_EXIT`), sends
   0x751D; 0xB51D's error in category 1. Test.

Size: section 12 of `forgotten_world.md` estimates stage 2.
