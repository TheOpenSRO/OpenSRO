# When a monster appears, and when an attack registers (round 786)

The user's report (2026-10-13): "the mobs appear to pop up way later than they should and
sometimes my attacks take awhile to register." This page is what was read, what was measured,
and what changed. Labels: READ (from the retail binaries on the render box), MEASURED, INFERRED,
OURS, OPEN. The round's log entry is `docs/WORLD_ISSUES.md`, "Round 786 (part): Monsters appear
on time, and attacks register promptly".

## The view window: OpenSRO's is retail's (READ, re-read this round)

`SR_GameServer.exe` (`/var/tmp/SR_GameServer.exe`, objdump `/var/tmp/gs_full.asm`):

| What | Where | Value |
|---|---|---|
| The block of a region-local position | `CRgnTerrain::vslot_006` 0x53ad30 | asserts 0 <= x, z < 1920.0 (double 0xb45ad0), divides each by the double 0xb45ae8 = **320.0** (`fdiv` 0x53ad90), truncates (0x9fbb40), asserts 0..5 (0x53ada2..0x53adb0), block `(x + z * 6) * 0x98 + 0x2c` (0x53adb7..0x53adc5) |
| Each block's 8 neighbours | the table 0xc64090 | (-1,-1) (0,-1) (1,-1) (-1,0) (1,0) (-1,1) (0,1) (1,1) |
| An object entering a block | `CMsgBlock` slot 2 0x534340 | for each neighbour (the list at block+0x10, loop 0x5343b8..0x534402) and then the block itself (0x534407..0x534419): `FUN_00533e70(1)` (the block's objects to a player: the group spawn) and `FUN_00533f70` (the object's 0x3015 to the block's players) |

So a player holds the objects of the 3 x 3 blocks of 320 around its own: a monster comes into
view 320 to 640 units ahead on the axis it walks (round 664 read the same). OpenSRO:
`combat.CellSpan` 320, `session.AOIRadius` 1.

`sro_client.exe` has no rule of its own that holds an object back or drops one by distance:
the 0x3015 handler creates the object and runs its body reader at once (`FUN_008a6ca0` ->
`FUN_008a6bd0`, round 676, READ); the only removals are the server's 0x3016 (or a group
despawn) and the world reset (`FUN_009c2c20`); the draw tests the frustum and picks a mesh LOD
by distance / **800.0** (double 0xd83080, re-read) but never skips an object for distance
(round 664). Every spawned character fades in over **2.0 s** (float 0xd86ecc, re-read;
`CIDecoAppear`, round 676) and out over **1.5 s** (0xd819ec). OpenSRO draws both
(`AppearFade`). So the original also shows a monster first 320-640 units off, fading in:
**the distance was never the bug.**

## What each step costs (MEASURED, round 786)

Method: the server from this branch with the Mac mini's flags (`-full-map`, the six monster
switches; 67,266 monsters alive) and the prod data, on the render box; a QA client against it in
real time (`QA_SHOT_REALTIME=1`, Forward+, 1280x720, 144 fps cap) with `OPENSRO_QA_LATENCY=1`
(`LatencyProbe`, below); and `partybot -mode latency` for the server alone. Scripts:
`/var/tmp/latency/live.sh`, `ab.sh`, `mab.sh`; logs `/var/tmp/latency/run/<run>/`.

### The server

- **Enter timing.** `partybot -mode latency -walk 30s` (a straight run at 105 units/s through
  the bandit fields at (-21000, 12500)): 25-40 enters a run, each 320-621 units ahead of the bot
  (p50 420-483), **27-96 ms after the bot's block crossing** (p50 47-71 ms): one area-of-interest
  tick (`AOITick`, 100 ms, OURS; retail answers the block change in the move itself). At 105
  units/s that is under 10 units of run. Not a cause.
- **The AI tick at 67k monsters**, sleep on: p50 0.007-0.08 ms, p99 under 0.3 ms, max 0.3 ms
  (`OPENSRO_AI_TICK_STATS`). The attack handler runs on the session's reader goroutine and
  answers at once (sub-millisecond request->result on loopback, partybot, 40 attacks; with 300
  more bots moving around the probe, `-crowd 300`: p50 0.8 ms, max 1.1 ms, the AI tick p50
  0.13-0.17 ms, max 0.65 ms); its locks (the AI's `noteStruck`, the AOI's) wait at most one such
  tick. With Nagle on and that crowd's traffic flowing, the server's ACKs ride its sends: p50 2.3
  ms, max 12 ms.
- **Prod's own send accounting** for the user's address (192.168.10.137, every session since
  2026-10-12): send queue peak at most 8,363 bytes, send debt at most 246 us. Nothing queues on
  the server side.

### The client

1. **The body build waited for the render thread.** A pushed monster (0x007E, the enter) was
   built in its dispatch, and `MonsterDraw.instance_of` made it with `duplicate()`. With the
   separate render thread (`project.godot` `thread_model=2`), `duplicate()` reads each node's
   property list, and a `GeometryInstance3D`'s asks the rendering server for its instance shader
   parameters -- a call that waits for the render thread, which mid-frame is drawing the last
   frame (INFERRED from Godot's source as remembered: `GeometryInstance3D::_get_property_list`
   -> `instance_geometry_get_shader_parameter_list`, a synchronous command; the timing below is
   MEASURED). The first `duplicate()` of a frame took **12-25 ms** and the next ones in the same
   frame 0.3 ms (`QA LAT dup`: duplicate(0) first 24.9 ms, then duplicate() 0.38 ms; headless,
   with no render thread, round 655's probe gives 0.25 ms for every one). Every pushed body took
   **21-25 ms** (instance p50 22.2 ms, n = 600). Removing the `duplicate()` only moved the wait:
   the name plate's look (`_monster_name_look`: the name box sprite and its fit), the lighting's material copy and the fade's twins wait
   the same way, whichever comes first in the frame (`QA LAT build` laps).
2. **The network's read budget counted that wait as work.** `NetClient` dispatches packets until
   `NET_FRAME_BUDGET_USEC` (8 ms, OURS) is spent, at least one a frame. A 22 ms build spent it, so
   a burst of N monsters entering together was read one a frame: **N frames**, and every packet
   behind them -- an attack's result -- waited those N frames too. Before: bursts of 19, 7, 8, 6
   bodies took 12, 10, 8, 6 frames (255, 228, 207, 126 ms first body to last, fight run `fightA4`);
   9 took 4 frames, 120 ms (`walkA4`).
3. **Nagle's algorithm.** `StreamPeerTCP` leaves it on (MEASURED: `tools/nagle_probe.gd`, a stop
   frame and an attack frame written back to back to a listener that answers only the second:
   **40.9 ms** p50 with Nagle on against **0.3 ms** with `set_no_delay(true)`, 200 rounds each,
   over the LAN and on loopback; the 40 ms is the Linux receiver's delayed ACK). The walk into
   reach ends exactly that way: `_flush_position` sends the stop report (OpMove with the stop flag,
   which the server relays to the watchers and does not answer) and then `_send_attack`. Against
   the box's Linux server the real client's request->result was **47-52 ms for 97 of 120 attacks**
   (`fight_base`). Against the Mac mini it is mostly not paid: in prod's own log the attack (0x0060
   or 0x0072) followed the stop report (0x0022) by **0-5 ms in 607 of 643 cases** since
   2026-10-06 (macOS acknowledged at once), 5-60 ms in 29, 120-1000 ms in 7.
4. **The first monster of a species waits for its model** (round 661): 98-178 ms on the box
   (`template` waits); retail loads it in the spawn handler (INFERRED: the body reader runs at
   once). Kept: the alternative is a frame of that length.
5. **A click inside the base attack's re-use delay** is answered when the delay ends (round 785,
   READ: the engine's action queue waits on the cooldown gate): 578-1,184 ms after the click in
   the fight runs, when the next monster was clicked right after a kill. Retail's.

## What changed

- **`MonsterDraw.clone_tree`** builds a body from its template node by node (the skeleton's
  bones and poses, the pieces' meshes, skins, materials and draw settings, the bone attachments,
  the metas; resources shared as `duplicate()` shared them), reading no property list. Pinned
  against `duplicate()` field by field (`scripts/world/monster_spawn786_test.gd`; on the archive's
  own templates `tools/clone_parity.gd`: 120 models, 683 nodes, 0 differences). Instance
  **21.2-22.2 ms -> 0.14-0.17 ms** (p50; p95 23.3-23.8 -> 0.27-0.34 ms).
- **`RenderSync.wait_once()`** waits for the render thread once, at the start of the first body
  build of a frame, and hands the time to `NetClient.credit_render_sync` and the build pump, whose
  budgets then count only their own work. The wait is the one the build's first call would have
  made anyway; the frame's other bodies then cost 0.1-0.7 ms each. **A burst is now built in the
  frame it arrives**: 37 of 42 bursts of 3-27 pushed bodies in one frame, 1-6 ms first body to
  last; the rest 2-5 frames, at most 112 ms for 27 bodies (`mfightB1`; before, `mfightA1`: 21, 10,
  12, 8, 14 bodies over 3, 13, 12, 8, 14 frames, 98-326 ms).
- **An attack's request->result** against the box's server: p50 50-51 ms before (114 of 140
  between 20 and 60 ms), p50 2 ms after (71 of 87 under 20 ms); what is left over 200 ms is the
  re-use delay's deferral (retail's).
- **TCP_NODELAY** on the game socket (`NetClient.no_delay_wanted`, `OPENSRO_NAGLE=1` restores
  Nagle). OURS: neither retail binary sets it -- `sro_client.exe`'s six `setsockopt` calls
  (IAT 0xd80624, WS2_32 #21; at 0x4b0586, 0x4b2640, 0x4c0731, 0x4c077e, 0x4c0801, 0x4c352d) and
  `SR_GameServer.exe`'s three (IAT 0xad942c; 0x965665, 0x9679c0, 0x969c2d) are all level
  `SOL_SOCKET` 0xffff (`SO_LINGER` 0x80, `SO_REUSEADDR` 4, `SO_SNDBUF` 0x1001, and a buffer-size loop at 0x4c0770 halving its caller's option down to 0x5b4) --
  but retail sends one request for the whole action (0x7074; the server walks the player into
  reach, round 256), so nothing of its waits behind an unanswered packet. OpenSRO's client sends
  two, so it turns Nagle off.

## The QA probe

`OPENSRO_QA_LATENCY=1` (`scripts/world/latency_probe.gd`):

- `QA LAT mob <id> via push|list wait <ms> (<none|template|region|queue>) dist at recv <u> at
  body <u> at <clock> frame <n>`: a monster from the moment its list or push is dispatched to its
  body.
- `QA LAT atk <id> click->send <ms> send->result <ms> total <ms>`: a click or a cast, the walk into
  reach, and the server's answer as dispatched.
- `QA LAT build <id> us: render_sync .., height .., instance .., ...`: where a body's build time
  went.
- A/B switches in one build: `OPENSRO_QA_DUPLICATE=1` (bodies by `duplicate()`),
  `OPENSRO_QA_NO_RENDER_SYNC=1`, `OPENSRO_NAGLE=1`.
- `partybot -mode latency` (server only): `-walk` times the enters against the bot's own block
  crossings; `-attacks` times OpAttack request->result after the stop report, `-nodelay=false` with
  Nagle on.

## OPEN

- macOS's delayed-ACK timer (100 ms in XNU, INFERRED) was not measured against the Mac mini: its
  game server is not touched, and prod's log shows it acknowledging at once anyway.
- The other render-thread waits in the body build (the name plate's look, the light, the fade) are now one
  per frame, not removed; the twins and the light copy materials, which a property-list-free copy
  could avoid too.
- The area-of-interest tick (100 ms) against retail's immediate block change.
- Other players' and NPC bodies are still made by `duplicate()` (not part of this report).
