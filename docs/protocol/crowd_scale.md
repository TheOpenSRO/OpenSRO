# Crowd scale: 1000 other players on screen

Round 736. This is the spec for the user's target (2026-10-05): "we should be able to handle 1000+
players on the screen at any given moment and still be playable". It covers four things:

- what the original client and server do with many characters;
- what OpenSRO does for each other player today;
- where the frame goes at 20, 200 and 1000 (measured);
- the lanes that will build it.

Labels used throughout:

- **READ**: read in `sro_client.exe` / `SR_GameServer.exe` (decompiles and asm on the box), in our
  own code, or in Godot 4.2.2's source.
- **MEASURED**: a run on the box.
- **COMPUTED**: arithmetic on READ values.
- **INFERRED**, **OPEN** and **OURS** as usual.

The round's log, with the raw lines and the method, is `docs/rounds/r736.md`.

## 1. What the original does (READ unless marked)

### The client

**Retail never reduces other players.** It has no cap on visible characters and no per-frame
budget.

- **The per-frame update** (`FUN_00ba34e0`):
  - lists every object (`CEntityManager::vslot_011`);
  - calls each object's update (slot 9, `0x9c4180`);
  - advances each object's frame counter (+0x38) and time (+0x3c);
  - has no count limit and no time check.
- **The draw** (`FUN_00ba2570` -> slot 0x28, `0x9c4aa0`) draws every node. It skips an object
  only for:
  - its own hide flags (`+0x70 & 1`, `+0xd4 & 2`);
  - the frustum test.
- **The only count limit found:** the distance maps `CICPlayer::vslot_005` (`0x9d6c80`) builds
  every frame stop at **10,000 entries** (`9999 < DAT_00ec24d4`).
  - The maps are keyed by `(int)(distance x 10)`: one map to the player, one to the camera.
  - The ten-nearest shadow rule and the 300-unit name cut read these maps.

**A character is posed only if it was drawn in the previous frame.**

- The draw sets `+0xbc = 1` when the object passes the frustum test (`0x9c4bc4..0x9c4bd3`), and
  clears it when the object fails (`0x9c4bb1`).
- The update passes `vis = (+0xbc && !+0xbd)` down to `CCompChar::FUN_00c33230`:
  - `AniMixer::FUN_00c53e80(dt)` (the clip time) always runs;
  - `AniMixer::FUN_00c54200` (keyframes into bones) runs only when `vis` is set;
  - the particles and the dynamic block also run only when `vis` is set.
- So an off-screen character costs a time step and no pose.
- Sub-stepping: when dt > 20 ms the update is split into `ceil(dt/20)` steps, at most 3 (5 with
  `+0x48 & 1`). The middle steps pose only the bones with `+0x84 & 1`.

**Mesh LOD is always on.** Option 0x17 has no Video-tab row; its only setter,
`CPSTitle::vslot_011` (`0x864810`), sets it to 1.

- The object draw computes a factor `f = camera distance / 800.0` (the double at `0xd83080`).
- **For an object whose exact class is CICPlayer, the factor is 0: other players are always drawn
  at full detail.**
  - A unique monster (CICMonster with rarity 3 or 8) also gets 0.
  - Other characters with `+0x728` set get `clamp(f x (-0.09 S + 1.3), 0, 1)`, where `S` is
    `FUN_009c7740` (`0x503409`: -0.09 at `0xd82f80`, 1.3 at `0xd82f7c`).
  - Every other object keeps `f` as it is.
- `CCompChar::FUN_00c25620` turns the factor into a level: it clamps it to [0, 1] into `+0x7c`, and
  `iLOD = ftol(f x 4)` into `+0x80`, giving levels 0..4.
- COMPUTED level thresholds:
  - scenery: 200 / 400 / 600 / 800;
  - a monster with S = 1: about 165 / 331 / 496 / 661.
- `ResObject::FUN_00be3540` builds 4 extra index lists per mesh. A level with no source list copies
  the previous one.
- OPEN: where the source lists come from, and the exact draw-time selector.

**Frame skip, only past 100 characters, and never for players.**

- `DAT_00ec4ce8` counts the live CICharactors. While it is above 99,
  `Map::FUN_00bbdb00(count > 99)` (`0x9d7078`) sets the effect manager's `+0x1e4`.
- With that set, `AniMixer::FUN_00c54200` skips every other pose for an object whose LOD level maps
  to 1 in the table at `0xeda308 = {0, 0, 0, 1, 1}`: levels 3 and 4, the far ones.
- Players are at level 0, so they are posed every frame they were drawn.

**Skinning is in the vertex shader.** `CObjRendererVS::FUN_00bf67c0` compiles `shader\vss0.c` /
`vss2.c` with `SKIN0` / `SKIN2`: 0 or 2 weights per vertex. A CPU `CPhysiqueModifier` also exists;
when it is used is OPEN.

**Dynamic Animation** (case 0xe):

- It runs a secondary simulation in 50 ms steps (`FUN_00c526e0`, `CCompChar::FUN_00c0d720`).
- It runs only for a visible character at LOD level 0 (`iLOD < +0x1a0`, which the constructor sets
  to 1).
- That this is cloth or hair motion is INFERRED from its tooltip.

**Names.** A name is skipped (`0x9d0a80`) when any of these holds:

- getter case 0x18 is set (a hidden "no names" switch; its setter was not found);
- the object's own hide bits are set;
- the object is not within 300.0 of the player (`0xd85224` against `+0x24c`), unless `+0xf0`, the
  hover flag the cursor pick sets, is set.

So a hovered name shows at any distance. `0xec4b58` is a GM console toggle (initial value 1),
INFERRED to be "ID".

**Shadows** (round 702, READ):

- Circle draws a circle under the ten nearest characters.
- Detail draws projected shadows for up to ten characters within 300 of the player, and no
  circles.

**Effects.**

- Effect Quality 1 shows a skill effect only when its owner object is exactly a CICMonster or
  exactly a CICPlayer (`IDecoSkill::FUN_00a50dc0`). Whether the owner is the caster or the target
  is OPEN.
- An equipment or model particle draws only while its `mod+0x3c` (0.9) is at least the host's LOD
  factor (`FUN_00c43780`):
  - **every other player's weapon particles draw at every distance** (factor 0);
  - scenery particles stop at 720 (COMPUTED);
  - a monster's particles stop at about 595 when S = 1 (COMPUTED).
- `CRTModParticle::FUN_00c81450` also needs the effect manager's `+0x1b0`.

**Character Sight Range (case 9) is very likely dead.**

- `SWorld::vslot_043` has no case 9. The shared tail (`0xa19c3e`) stores the value at
  `SWorld+0x2e74` (SWorld is the static at `0x1101950`) and posts message 0x809.
- Six probes found no reader:
  - no other `+0x2e74` access;
  - no absolute access to `0x11047c4`;
  - only the getter and the setter index the array;
  - no getter call with 9;
  - the record bytes are read only by the Option window;
  - no handler for message 0x809.
- INFERRED: stored and never read. The Large scale battle preset sets it to 4, the same as High. Its
  savings come from the other rows (shadow, reflection, water, metal, light, bloom, Dynamic
  Animation off, Effect Quality 1).

### The server

- **The interest area is the 3 x 3 message blocks of 320 units** (round 664; `CMsgBlock`). It
  applies to players as well as monsters.
- **Group spawn** (`FUN_00533e70`):
  - `0x3017` begins it: `[u8 kind (1 spawn / 2 despawn)][u16 count]`.
  - `0x3019` packets carry the data. `FUN_00430a20` cuts one serialized buffer into packets of
    (capacity - size - 0x20) bytes each.
  - `0x3018` ends it.
  - The builders (`FUN_00533910` / `FUN_00533b90`) write every object of the block into a static
    10,000,000-byte buffer.
  - The only cap is the u16 count. The packet capacity is OPEN.
- **Movement 0xB021** (`GObjPC::FUN_004b0ea0`):
  - it is built once per accepted move request (one per click, not a position stream);
  - `CMsgBlockObject::FUN_00534150` walks the neighbour blocks and adds each player as a target;
  - one message goes to each AgentServer, carrying its list of sessions (up to 0x800).
  - There is no throttle or per-tick budget in the GameServer. Any batching in the AgentServer is
    OPEN.

### What this means

Retail's tricks are:

- no pose for an object that was not drawn;
- names within 300;
- shadows for the ten nearest only;
- mesh LOD and an every-other-frame pose skip, for far non-player characters only;
- the 3 x 3-block interest area and paged group spawns on the server.

**Retail itself would pose and fully draw 1000 players in view every frame.** Holding 1000 on
screen at 60 fps therefore needs OURS techniques on top of the READ limits. Each one is labelled in
section 5.

## 2. What OpenSRO does for each other player (READ, our code)

### The client: one other player's body

These counts are MEASURED by `QaCrowdProbe`'s census and are the same at 20, 200 and 1000.

| What | Per body | Notes |
|---|---|---|
| Nodes | 28 | `Node3D` holder → `Skeleton3D` (+ item skeletons), meshes, `Label3D`, `StaticBody3D` + shape |
| Skeleton3D | 3 (49 bones in all) | body skeleton plus item skeletons (`CharacterAppearance.build`) |
| MeshInstance3D | 14, all skinned, 14 surfaces; **8 visible** | The body parts under armour are hidden, not removed. One draw call per visible mesh (MEASURED: 7,994 visible at 1000; 7,900 draw calls) |
| Skins | **14 distinct**, hidden meshes' included | `CharacterAppearance._own_skins` copies every skin per body, for Volume. A hidden mesh's skin stays registered: `MeshInstance3D` registers it on entering the tree, whatever its visibility (Godot 4.2.2 `mesh_instance_3d.cpp:167-180, 330`, READ) |
| Materials | shared | across bodies (723 distinct for 13,500 meshes at 1000); `CharacterLight` swaps between shared per-level copies |
| Shadow casting | 8 of 14 meshes | Only drawn under Detail, into the sun's shadow map out to 400 |
| Name plate | 1 `Label3D` | Drawn by `OverlayView`'s second viewport; shown within 300 (READ rule, `NamePlates.Sweep`) |
| Click body | 1 `StaticBody3D` + capsule | Layer `OTHER_PLAYER_COLLISION_LAYER`, mask 0 |
| Circle shadow | registered in `CharacterBlobs` | Ten nearest, reselected every 6 frames over the group |
| Equipment particles | `EquipFx` hosts | The 64 nearest in view within 800 shown (OURS, round 734) |

**Per-frame work for each other player:**

1. **Posed every frame, unconditionally.**
   - `_tick_idle_animations` asks `MonsterCrowd.CullCache.info(skeleton)`. A player skeleton has no
     `MonsterDraw.META_CULL`, so it gets `NONE`: no frustum test, no range test, no animation LOD
     (`monster_crowd.gd:69-89`).
   - So every other player is posed (`MonsterCrowd.pose_at`, GDScript) every rendered frame,
     on-screen or not, near or far. Retail poses only the drawn ones.
   - The pose then costs the engine `Skeleton3D`'s update. In Godot 4.2.2,
     `NOTIFICATION_UPDATE_SKELETON` calls `skeleton_bone_set_transform` once per bind of **every
     registered Skin** (`scene/3d/skeleton_3d.cpp:245-297`, READ), hidden meshes' skins included.
     It costs the renderer as well: each visible skinned instance is skinned again.
   - With 14 skins per body, every pose writes about 14 RenderingServer skeletons where one would
     do.
2. **Clip sounds advanced every frame.** `audible` stays true for `NONE` (the 600-unit hearing cut
   of round 664 is never applied to players).
3. **Interpolation, in every physics step.** `_physics_step` walks `_other_body_targets` (a lerp, and
   `_set_other_gait`) in every physics step, not once a rendered frame. At 5 fps a frame runs the
   capped 8 steps (MEASURED), and the loop runs 8 times.
4. **Turns** (`_step_remote_turns`), the minimap fill (`_minimap_fill_positions`, once a frame over
   every body), `CharacterLight` (12 bodies a frame), `CharacterBlobs` (every 6 frames over the
   group), the plate sweep (a sixth a frame), and `EquipFx` (every 10 frames: a sort over every
   host).
5. **Network.**
   - Each `OpEntityMoved` (0x0024, 26 B framed) is decoded in GDScript and sets a target and a turn
     (`_on_entity_moved`).
   - `_other_by_uid` (0x3038/0x3039) scans every body.
   - `NetClient._process` drains every buffered packet every frame, with no budget.
6. **Arrival.**
   - `_spawn_or_update_other` builds the dressed body at once, about 10 ms a body (MEASURED: 1000
     bodies in 10.3 s, one frame).
   - Monsters have a per-frame build pump (`_pump_monster_builds`); players do not.

### The server (READ; the details are in r736.md, from `crowd736_bench_test.go`'s investigation)

- **Players have no interest area.**
  - `aoi.go`'s 3 x 3 blocks cover monsters (and NPCs). A player sees every player in its hub bucket
    (`world.Entity.Zone`), which under `-full-map` is the whole world.
  - Player opcodes are OURS: `OpEntityEntered` 0x0023, `OpEntityMoved` 0x0024 and
    `OpEntityLeft` 0x0025. Retail's 0x3015..0x3019 are used only for NPCs.
- **Move:**
  - `handleMove` takes the hub's exclusive lock and copies the bucket (`othersInZoneLocked`);
  - it then **re-encodes the message for every recipient** (`world.go:1774-1775`);
  - it runs per event, with no tick batching.
- **Arrival** (`enterOwned`):
  - two store reads per player already present;
  - **one** `EnterWorldResult` frame holding every other player. It fits 166 full-kit others
    (MaxPayload 32,767). **With 167 or more present, the arriving session is closed** (MEASURED at
    200 and 1000).
- **Every other broadcast** (sit, chat, equipment, body mode, status, buffs) copies the whole
  bucket. Some lookups are O(n) scans of every session (`EntityByCharacterID`, `FindByName`).
- **Sends:** one writer goroutine per session and a 2 MB queue. **The writer makes one syscall per
  frame** (`gateway.go:505-512`).
- **The client's move rate is 20 a second while walking** (`MIN_SEND_INTERVAL` = 0.05 s,
  `World3D.gd:842`, OURS). Retail sends a destination per click.

## 3. Measured

### The client (`QaCrowdProbe`)

**Setup.**

- The box: RX 7600 (RADV NAVI33), Forward+ through `xwl_run.sh`, 1920 x 1080, vsync off. Middle
  preset (the default): Circle shadows.
- A boot another lane's Godot overlapped was repeated (r736.md has which).
- Bodies: the 52 creatable Figures cycled, each with its race's catalogue weapon in rotation (a
  shield with one-handed weapons), the kit armour, weapon and shield at +13 (glow, and particles
  where the item's rows have them).
- Layout: rows of 40, 8 apart, 10 between rows, from 40 ahead of the player at the Jangan spawn.
- Camera at distance 90 (the zoom maximum), pitch -15: 988 of 1000 in view.
- Each step runs 6 s; its first 1.5 s are not measured. `frame_ms` is the wall time per rendered
  frame.

**Frame time (ms), with one part switched off for every lineup body.**

Each value is the median of the clean boots: `m1`..`m4`, the logs in r736.md. A boot another lane's
Godot overlapped was repeated, and its steps were taken from the repeat. `pose_ms` is the check for
contention: it holds at 15.0-16.1 at 200 and 63.3-67.6 at 1000 in every value used.

| Step | n = 20 | n = 200 | n = 1000 | What it changes |
|---|---|---|---|---|
| **base** | 4.2 | **42.2-45.3** | **194.7-197.0** | nothing (11 boots' base steps) |
| pose off | 3.4 | **9.2** | **70.9-71.3** | posing: the GDScript, the Skeleton3D update, the re-skin |
| **away** (camera turned 180°) | 3.4 | **33.5-34.2** (26 in view) | **168.4-172.3** (26 in view) | the crowd off screen: **still posed** |
| mesh off | 4.5 | 35.4-36.8 | 174.2-179.5 | the body meshes' draw and skinning (still posed) |
| nodraw | 3.5 | 26.8 | 162.4 | mesh, labels, fx, blobs and overlay together |
| fx off | 3.4 | **34.2** | 187.4 (`TIME_PROCESS` 57 -> 42) | `EquipFx` (driver and holders) |
| sound off | 4.1 | 41.7 | 195.6 | clip sound tracks (5.2 ms of GDScript at 1000) |
| labels off | 4.2 | 45.3 | 191.6 | the name plates |
| collide off | 4.2 | 43.8 | 188.6 | the click bodies |
| shadow-cast off (Circle) | 4.1 | 42.3 | 200.6 | nothing: no shadow map under Circle |
| blobs off | 4.2 | 41.7 | 196.1 | the circle shadows' reselection |
| overlay off | 4.0 | 41.3 | 193.9 | the plates' second viewport |
| run (in place) | 4.2 | 42.2 | 201.1 | (adds) a different clip |
| **move** (all walking) | 4.3 | 46.6 | **235.2 (p95 354)** | (adds) interpolation, gait, turns, moved transforms |
| **net** (1 packet a body a second) | 4.4 | **51.3-51.6** | **257.4-259.0** | (adds) the real `OpEntityMoved` path, and the walk it starts |
| **net20** (the client's walking rate) | -- | **74.8** | -- | (adds) 20 packets a body a second |
| **gone** (out of the tree) | 3.0 | 3.4 | 8.4 | the bodies themselves |

The spread between base runs is about 3 ms at 200 and 2-3 ms at 1000. **Labels, collide,
shadow-cast (Circle), blobs, overlay and run are within the spread at every n.**

**Network.** `NetClient._dispatch` takes 7-10 µs a packet: 0.93-0.98 ms a frame at 1000 x 1/s,
1.9 ms at 200 x 20/s. **The packets are cheap; the walk they start is not.** At 1000, one move a
body a second costs +62 ms, nearly all of it in the per-physics-step interpolation and turns
(`physics_ms` 99 -> 123).

**Where the frame goes at n = 1000** (the probe's split; `TIME_PROCESS` is Godot's process time
outside physics: the `Skeleton3D` updates, `EquipFx`, the other `_process` work):

| | base | pose off | away | mesh off | nodraw | gone |
|---|---|---|---|---|---|---|
| frame ms | 194.7-197.0 | 70.9 | 168.4 | 179.5 | 162.4 | 8.4 |
| GDScript pose (`pose_ms`) | 63.4-64.2 | 0 | 63.7 | 63.5 | 66.0 | 0.1 |
| GDScript clip sounds | 5.2 | 4.2 | 5.2 | 5.3 | 5.3 | 0 |
| `TIME_PROCESS` | 56.7-58.1 | 37.3 | 29.6 | 34.5 | 17.5 | 5.8 |
| render CPU | 24.6-24.9 | 19.2 | 4.4 | 4.4 | 3.8 | 2.9 |
| render GPU | 5.0-5.2 | 6.9 | 2.7 | 3.0 | 2.9 | 2.3 |
| physics steps a frame | **8.0 (the cap)** | 4.3 | 8.0 | 8.0 | 8.0 | 0.5 |
| draw calls | 8,553 | 8,554 | 728 | 632 | 635 | 634 |

Readings:

- **The frame is CPU-bound at every n.** The GPU takes about 5 ms at 1080p for 1000 bodies.
- **Posing is about 65% of the frame** (-125 ms at 1000, -34 at 200). It is three costs:
  - the GDScript pose: 63 µs a body;
  - the engine's `Skeleton3D` update over 14 skins a body: about 20 ms at 1000 (the drop in
    `TIME_PROCESS`);
  - the re-skinning in the renderer: about 5 ms at 1000 (render CPU);
  - plus the step spiral the slow frame causes: 8 physics steps a frame against 4.3.
- **An off-screen crowd costs 86% of an on-screen one** (away: 168 against 196 ms; 26 in view).
  It is posed anyway (A1).
- **Drawing** (mesh off): render CPU 24.7 -> 4.4. That is 7,900 draw calls for 1000 bodies: about 8
  visible meshes a body, one call each. Skinned meshes are not instanced.
- **A walking crowd adds 40 ms at 1000** (p95 354). Every per-step cost is paid 8 times a frame.
- **`EquipFx` costs about 9 ms at 200 and about 8 ms at 1000** (`TIME_PROCESS` -15 ms).
- **Cost per body:** (base - gone) / n = 0.20 ms at 200 and 0.19 ms at 1000. It is linear. 60 fps
  with 1000 bodies needs about 0.01 ms (10 µs) a body: **about 20 times less**.
- **Arrival:** building costs about 10 ms a body. The lineup's 1000 took 10.3 s in one frame, and
  200 took 5.3 s.

**Under Detail shadows** (`OPENSRO_QA_VIDEO=shadow_detail=2`, n = 1000):

- base 204.6 / 208.3 ms; every body's cast shadow off: 195.2 ms;
- render CPU 37 -> 25 ms; draws 24,682 -> 8,638.
- At n = 200: 45.3 / 45.7 against 42.0 ms; draws 5,909 -> 2,239.
- So the sun's shadow map costs about 10 ms at 1000 and 3.5 at 200. Retail draws only ten projected
  shadows.

### The server (`server/internal/session/crowd736_bench_test.go`)

**Setup.** The real `gateway.Server` on loopback, the real `handleMove`, `enterOwned` and leave.
The clients are a child process that only counts, so the CPU figure is the server's alone. Each
player moves once a second (OURS model). Measured on the workstation (5950X).

| N in one bucket | handler ns / move | server CPU ms per s | per client pkts/s, KB/s | total MB/s | arrival |
|---|---|---|---|---|---|
| 20 | 12,000 | 2.2 | 19, 0.49 | 0.010 | 4,028 B; 0.14-0.27 ms |
| 200 | 125,000 | 240-289 | 199, 5.17 | 1.04 | **refused**: result 34,066 B > 32,767 |
| 1000 | 595,000-614,000 | 5,870-6,580 | 999, 25.97 | 25.97 | **refused**: 170,066 B |

- At N = 1000, 79% of the CPU is `write` syscalls under `gateway.writeFrames`.
- The hub lock is held 1.3 / 12 / 59 µs per move; at 1000 each move allocates 293 KB.
- A town layout and a 10 x 10-block field measure the same: there is no player interest area.
- **INFERRED, the client's real 20 moves a second:** x20, about 120 CPU-seconds a second at 1000
  and 520 KB/s per client. The queues would pass 2 MB and close sessions.

## 4. The target and the proxy

**Proposed target (OURS: the user has not chosen the numbers).**

- 1000 other players in view, at 1920 x 1080, Forward+, the Middle preset;
- standing crowd: **p50 at most 16.7 ms** (60 fps);
- walking crowd: p95 at most 33 ms (never under 30 fps);
- arrival of a full crowd: no single frame over 100 ms (the gate's hitch line).

**The proxy is the box at 1920 x 1080.** It has the same GPU family and driver as the user's Steam
Machine (RADV NAVI33: an RX 7600 here). The frame is CPU-bound by a wide margin, so the CPU is what
transfers.

- The box's 5950X runs GDScript on one thread. The device's CPU was not measured, so its
  single-thread speed against the box is OPEN.
- **The device check:** the probe is in every build and needs no server. The same environment as
  section 3 on the device gives the real number:

  ```
  OPENSRO_QA_LINEUP=all OPENSRO_QA_LINEUP_COUNT=1000 OPENSRO_QA_LINEUP_PLUS=13 OPENSRO_QA_LINEUP_COLUMNS=40
  OPENSRO_QA_LINEUP_SPACING=8,10 OPENSRO_QA_LINEUP_PHASE=100000 OPENSRO_QA_CROWD_STEPS=base,pose,away,mesh,base
  OPENSRO_QA_CROWD_QUIT=1 OPENSRO_QA_DIST=90 OPENSRO_QA_PITCH=-15 OPENSRO_QA_AT=1002,1020 OPENSRO_MAPM_PATH='97\168.m'
  ```

  The `QA CROWD step` lines are the numbers.
- The user's own log shows 3840 x 2004 (round 729). The GPU share grows with pixels, so a 4K target
  needs its own GPU budget. INFERRED: about 4 x 5-7 ms at 1000, if it scales with pixels.

## 5. The plan

Expected savings come from section 3's measurements at n = 1000 unless marked. Retail-matching
limits come first. **They do not reach the target on their own:** retail fully poses and draws
players.

### Lane A: client animation and skinning

Files: `world/monster_crowd.gd` or a new `world/crowd_anim.gd`, `ui/character_appearance.gd`,
`assets/skeleton3d_builder.gd`, and in World3D only `_tick_idle_animations`.

| # | Item | Label | Expected saving |
|---|---|---|---|
| A1 | **Pose a player only if it was drawn** (in the frustum) the previous frame. The clip time always advances (READ, `0x9c4180` / `FUN_00c33230`). This gives player skeletons the cull metadata monsters have, without the range hide. | READ | Proportional to the share off screen. MEASURED today: with the crowd behind the camera (26 of 1000 in view) the frame is still 168 ms against 196, because all 1000 are posed. With A1, most of the pose's -125 ms goes for an off-screen crowd (INFERRED); about 0 with all 988 in view |
| A2 | **One Skin per body**: merge a body's 14 skins into one bind list (same skeleton, same bind poses per bone) and remap each mesh's bone indices at template time. Volume stays per body. | OURS | Most of the engine's `Skeleton3D` update (about 20 ms of `TIME_PROCESS` at 1000), including the 6 hidden meshes' skins a body, which can simply leave the tree. INFERRED from Godot's per-Skin write loop; measure first |
| A3 | **Shared poses**: bodies playing the same clip at the same quantised frame share one computed bone set. A standing crowd plays few (clip, frame) pairs. | OURS | Most of the GDScript pose (63 ms -> a few ms) |
| A4 | **Animation LOD for players by distance**: every 2nd / 4th frame beyond 300 / 900, as `MonsterCrowd.pose_interval`. Retail skips only far non-players past 100 characters. | OURS (retail: READ, non-players only) | Up to half to three quarters of the remaining pose and re-skin for far bodies |
| A5 | **GPU crowd for far bodies**: bake each clip's bone matrices into a texture; draw far bodies as `MultiMesh` instances per (mesh part, material) with a per-instance clip and time; keep full skeletons for the nearest ~50. Removes `Skeleton3D`, skin and per-body draw calls for the far crowd. | OURS | The pose (-125) and draw (render CPU -20) shares for far bodies. The largest single item, and the largest build |

### Lane B: client per-body systems, arrival and network

Files: in World3D, `_physics_step`'s others loop, `_spawn_or_update_other`, `_on_entity_moved`,
`_other_by_uid`; plus `assets/equip_fx.gd`, `world/character_blobs.gd` and the shadow code.

| # | Item | Label | Expected saving |
|---|---|---|---|
| B1 | **Others' interpolation once a rendered frame** (as the clip tick's `TickGate`), and the step spiral's other per-step loops. | OURS | Most of the walking crowd's +40 ms (move) and +62 ms (net) at 1000, and the p95 tail. Every per-step cost is x8 at 5 fps |
| B2 | **Detail shadows for the ten nearest within 300 only** (READ). Today every body casts into the sun's map. | READ | About 10 ms at 1000 under Detail (MEASURED); 0 under Circle |
| B3 | **Clip sounds within 600 for players too** (READ: 600, `0xda98fc`; round 664's monster rule). | READ | About 5 ms GDScript at 1000 (MEASURED `sound_ms`; the frame change is within the spread) |
| B4 | **Arrival through a build pump**: a few bodies a frame, as `_pump_monster_builds`; the template caches already make a body about 10 ms. | OURS | The 10.3 s single-frame freeze for 1000, down to under 100 ms a frame |
| B5 | **Merge each body's meshes into one draw per material** at build (one skinned mesh per body). | OURS | Draw calls 8 -> about 3-5 per body; part of render CPU's 20 ms |
| B6 | `EquipFx`: replace the sort over every host every 10 frames with a grid or partial select. Keep the 64 budget (OURS). Retail draws players' particles at every distance (READ), so the budget is a disclosed difference. | OURS | About 9 ms at 200 and 8 ms at 1000 (`TIME_PROCESS` -15 ms) |
| B7 | `_other_by_uid` from a map. `NetClient._dispatch` itself is 7-10 µs a packet (MEASURED), about 1 ms a frame at 1000 x 1/s. | OURS | Small |

### Lane C: server interest management (server only)

| # | Item | Label | Expected saving |
|---|---|---|---|
| C1 | **Players in the 3 x 3-block interest area**, as monsters already are; arrivals as **paged group spawns** (0x3017 / 0x3019 / 0x3018); a cell index instead of bucket copies. | READ | Fixes the refused arrival at 167+ present; makes the cost of a town independent of world size |
| C2 | **Encode once per event; one write per queue drain** (writev). Round 663's client reader takes split frames, so the 662 workaround can go (live check needed). | OURS | Most of the 79% of CPU spent in syscalls: about 6 s -> well under 1 s of CPU per second at 1000 (INFERRED) |
| C3 | **Destination moves** (retail 0xB021 per click, `docs/protocol/opcodes/movement.md`) instead of 20 positions a second; observers walk the path. | READ | Traffic and server CPU / 20 for walkers (INFERRED from the per-move cost) |
| C4 | The hub lock: recipients from the cell index under a read lock; O(1) maps for `EntityByCharacterID` and `FindByName`. | OURS | 59 µs per move under the write lock at 1000 |

### Order and gates

1. **A1 + B1 + B2 + B3 + C1 first.** These are the READ rules and the step-spiral fix: cheap, and
   they keep the original's look.
2. **Then A2 and A3**, each measured with the probe, A/B on the same boot.
3. **A5 is the big one.** It gets its own spec round (impostor look against the full body, the
   switch distance, the glow on instances).

Every lane:

- runs `perf_gate.sh` (the jangan site);
- runs the probe at 200 and 1000 (`docs/rounds/r736.md`, "How to rerun");
- puts the before and after `QA CROWD step` lines in its round.

## 6. OPEN

- The LOD index lists' source, and the selector at draw time (`ResObject::FUN_00be3540`).
- Effect Quality 1's owner: caster or target.
- The packet capacity for 0x3019, and any batching in the AgentServer.
- When the CPU `CPhysiqueModifier` is used.
- The device's single-thread speed against the box.
- Our client at 4K (3840 x 2004, the user's resolution).
