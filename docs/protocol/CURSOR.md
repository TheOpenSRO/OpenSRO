# The mouse cursor (round 697)

What sro_client.exe shows under the mouse, read from the decompile (`/var/tmp/decomp_client`) and
the asm (`/var/tmp/sro_client.asm`) on the RE box. Labels: **READ** (the binary), **MEASURED**,
**INFERRED**, **OURS**. Code: `client/scripts/ui/cursor_set.gd` (the exe's cursors),
`client/scripts/ui/game_cursor.gd` (shown on every screen, at the UI scale),
`World3D._hover_kind_at` (which one, over the world).

## The manager (READ)

| Address | What |
|---|---|
| `0x00ba6260` | **SetCursor(id)**: `LoadCursorA(hInstance, MAKEINTRESOURCE(id & 0xffff))`, stores id at +0x24 and the handle at +0x28, and calls `SetCursor` while the show flag +0x20 is set |
| `0x00ba61e0` | show / hide: +0x20 = flag, `SetCursor(+0x28)` or `SetCursor(NULL)` |
| `0x00ba6960` | the manager's constructor: +0x20 = 1 (shown), +0x24 = -1, the button bytes +0x258..+0x25a = 0 |
| `0x00ba6f10` case 0x20 | WM_SETCURSOR: `SetCursor(+0x28)` (or NULL while hidden) -- every window, every control |
| `0x00ba7240` | input: WM_LBUTTONDOWN / UP set / clear +0x258, RBUTTON +0x25a, MBUTTON +0x259 (jump table 0xba75cc) |
| `0x00777ec0` | **SetHoverCursor(id)** (CGInterface): stores id at +0x510; calls the manager only when no forced cursor is up (+0x50c == -1) and the id changed |
| `0x00777e70` | **ForceCursor(id)**: id -1 restores the stored hover id and clears +0x50c; any other id is set and kept at +0x50c |
| `0x0086d150` | `CPSVersionCheck::vslot_011`: the first process state sets **0x95**, before the login screen |

So the default cursor is a Win32 resource cursor on every screen from the version check on --
login, server list, character select and create included. `Media.pk2`'s `cursor\cursor_normal1.tga`
(32x32, 32-bit with alpha, a glowing golden hand -- MEASURED) is named nowhere in the exe (ASCII and
UTF-16 searched) and in no archive text (raw grep of Media.pk2 and Data.pk2: 0 hits): it is never
drawn. The "golden cursor" is resource 0x95.

## Every id the client sets (READ)

All direct callers: the manager x4, SetHoverCursor x16, ForceCursor x20 (asm `call` sites; the
decompile's argument-less calls resolved from the pushes before them).

| Id | Art (MEASURED) | Set when | Where |
|---|---|---|---|
| 0x95 | gold arrow with a square gem, hotspot (2, 1) | default; nothing picked; a window (not the interface) under the mouse; a friendly character; after a window toggle / Escape / logout cancel | `0x86d150`, `0x789820` many, `0x652b70`, `0x79d620`, `0x79dbd0`, `0x788180` |
| 0x96 | hammer, 34x34, hotspot (11, 10) | NPC store's repair button: forced | `CIFStore 0x6cea60`, package store `0x6d28d0` |
| 0x97 | sword with a red edge, (2, 1) | attackable monster; enemy in fortress war; another team | `0x789820` |
| 0x98 | white speech bubble "...", (2, 26) | a CICNPC | `0x789c58` |
| 0x99 | open glove, (9, 6) | a CIItem on the ground | `0x789953` |
| 0x9a | closed glove, 32x31, (9, 4) | the same with the left button held (+0x258) | `0x789962` |
| 0xa0 | sword with a bright red edge, (2, 1) | a hostile player / another's COS (below) | `0x7899db`, `0x789bc5` |
| 0xa1 | blue disc, (0, 0) | a CITeleportGate | `0x789980` |
| 0xa3 | pouch, (15, 15) | a stalling player (+0x471 == 4) | `0x7899e2..0x7899f2` (`0x95 + 14` by `sbb`) |
| 0xa6 | bright gold arrow, (0, 0) | an inventory item applied to another slot: forced | `0x6769fa` |
| 0xae / 0xaf | funnel / anvil, (3, 22) / (2, 1) | the socket window's modes 1 / 2: forced | `0x592c19`, `0x592c9f` |

**Never set:** 0x9d (gold hammer), 0x9e, 0x9f (arrows with a target) and 0xa2 (a hand): no push
of them reaches any of the three entry points. **No cursor for a ground-targeted skill**: none of
the forced cursors belongs to a skill. A forced cursor ends on a right press over the world
(`CGInterface::vslot_017` WM_RBUTTONDOWN, `0x77c72e..0x77c737`) and on Escape (`0x79d620`).
**The camera turn leaves the cursor alone by default** (round 697's review, READ): the hide and
`SetCursorPos` back to the press point in `CGInterface::vslot_012 0x77b140` run only while +0x82d is
set, and `vslot_017 0x77c260` sets +0x82d only when the option byte settings+0x1c is non-zero
(`0x77c535`, `0x77c6c1`). That byte is the Option window's camera-rotate choice
(UIIT_CTL_CAMERA_ROTATE_METHOD1 / METHOD2, `0x5fcf40`), 0 by default (`0x7776c0`). So under the
default method 1 the cursor stays visible and free while the camera turns -- as here; method 2
(hidden, put back at the press point) is an Option this client has not built.

## The hover (READ: CGInterface::vslot_005 case 1, 0x789820)

`vslot_005` is CGInterface's **timer** handler; timer 1 runs every **250 ms**
(`push 0xfa; push 1; call 0xb93320` at 0x787294). Each tick: the window under the mouse must be
the interface itself (`FUN_00b9dc00() == this`), else 0x95; the pick (`FUN_0078ee20(x, y, 0)`:
the nearest object of any class, never the player, passing over a character whose +0x65c bit 0
-- alive -- is clear) must find something, else 0x95; then the
object's runtime class, by exact match (vslot 0 returns the class descriptor):

| Descriptor | Class | Cursor |
|---|---|---|
| 0xef1c28 | CIItem | 0x99, 0x9a with the left button held |
| 0xef1dac | CITeleportGate | 0xa1 |
| 0xef1bc0 | CICUser | outside the party (`0x992940`) and its IsHostile(Alt) (vslot 0xa8, `0x9de780`) -> 0xa0; else stalling -> 0xa3; else 0x95. Then in a siege-fortress zone (`0x939a60` on the player's REF_SIEGE_FORTRESS): a party member 0x95, else guild relation `0x998280` 0xca / 0xcc -> 0x97, 0xc9 / 0xcb -> 0x95. Then, while the player's team byte +0x81d != 0xff: another team 0x97, the same 0x95 |
| 0xef1a84 | CICMonster | 0x97 when its vslot 0xdc (`0x9d3160`: 0 for a player in job mode 1 over a TypeID4 3 monster, mode 2 over one `0x779dd0` matches, mode 3 over one `0x779e20` matches, else 1 -- so 1 for a jobless player; round 697's review corrected "always 1") and the interface's set +0x500 holds key 5 (`0x784ed0`; INFERRED "attack allowed") -- unless the player's vslot 0xac is 4 (INFERRED no job) and the monster is TypeID 1/2/1/2 or 1/2/1/3 (`0x779dd0` / `0x779e20`, on +0x220: the thief and hunter NPC monsters); else 0x95 |
| 0xee77ac | CICMonsterNPC | 0x97 when vslot 0xdc (`!(+0x7c8 & 2)`, `0x534740`) and key 5; else 0x95 |
| 0xeef6f0 | CICCos | the player's own (`0x9a0b80` on the player's +0x20d4): 0x95; another's with IsHostile(Alt) -> 0xa0, else 0x95; then its owner by the fortress relation as a CICUser |
| 0xef1ac4 | CICNPC | 0x98 |
| 0xee774c | CICATStruct | fortress structures: relation-based 0x97 / 0x95 |
| 0xeef710 | CICGuard | in a siege-fortress zone with a guild: relation 0xca / 0xcc -> 0x97, else 0x95; elsewhere 0x95 |
| anything else | | 0x95 |

The hover also flags the picked object (+0xf0 = 1) and clears the previous one's flag.

### Hostility, exactly (READ, `CICUser` vslot 0xa8 = `0x9de780`, `param_2` = Alt held)

In order, the first that decides:
1. the player's team byte +0x81d is not 0xff: hostile iff the target's differs;
2. the base `CICharactor` test (`0x9d02c0`): job modes (vslot 0xac: 1 and 3 against 2 hostile,
   INFERRED trader / hunter against thief), the murder state `0x9c7a40`, guild checks;
3. in a siege-fortress zone with a guild: relation 0xca / 0xcc hostile, 0xc9 / 0xcb friendly;
4. both job bytes +0x824 set (not -1 or 0): hostile if they differ or the target's is 5;
5. otherwise: both wearing job suits (equipment item 3/1/7/1..3, `0x666e60`) friendly; else
   **Alt held: hostile**; else the PK flag bytes (`0x9dd8f0`: 0x80 fortress zone, 0x40 a job, 0x20
   a job mode, 0x10 `0x9dd8a0`) and the list `0x992a90` reads (unread).

This client has no teams, fortress war, job modes, murder state or that list, so only the Alt
branch can be true: **Alt over another player shows 0xa0** (INFERRED: each other branch tests a
state that never reaches this client). The duel window (`net/duel.gd`) is our own extension, not a
retail state, and does not mark its opponent hostile.

## In this client

- **Where the exe is found** (round 697): `OPENSRO_CLIENT_EXE` (OURS, dev) first; then, for
  `sro_client.exe` and the vSRO package's `sro_client_NODLL.exe` (the same 16 numbered cursors,
  MEASURED), the folder of Data.pk2, its parent, and the folder of our own executable. The launcher
  `silkroad.exe` is not accepted (15 1-bit system-style cursors, MEASURED). The log says
  `GameCursor: 16 cursor(s) from <path>`, or `GameCursor: no sro_client.exe found -- ... Tried: ...`.
  Before round 697 only `$OPENSRO_PK2_PATH`'s folder was tried, and a player's build resolves the
  `pk2` folder without that variable -- so a player never got the cursors.
- **On Windows** (round 700, MEASURED under Wine 10.0 on the box, docs/RENDER_BOX.md "Wine"): the
  v0.1.483 Windows release, its `pk2\` holding the five archives and `sro_client.exe`, logs
  `GameCursor: 16 cursor(s) from Z:/.../pk2/sro_client.exe` and the X server's cursor over its window
  is 0x95 (32 x 32, hotspot (2, 1), 359 opaque pixels, mean (130, 126, 93)) under Compatibility
  (llvmpipe) and under Forward+ (the RX 7600 through Wine's Vulkan); outside the window the root
  cursor, back inside 0x95 again. Without the exe the log says `no sro_client.exe found -- ... Tried:`
  the four paths and the cursor is the system arrow. Godot 4.2.2's Windows path, read: the
  HCURSOR is built from the texture's image (`cursor_set_custom_image`: 32-bit DIB with alpha,
  at most 256 x 256, `CreateIconIndirect`), set at once when the shape is current, re-set on every
  mouse enter (`WM_MOUSEMOVE`'s `window_mouseover_id` change) and after a hidden mode; the window
  class has no cursor (`wc.hCursor = nullptr`), so `DefWindowProc` never puts the arrow back. The
  tester's "system cursor on Windows / CrossOver" was the missing exe: the user had not put
  sro_client.exe beside the pk2s, and with it there the cursors load on Windows (the user,
  2026-10-03).
- **Saying so on screen** (round 700): without the cursors the login screen's status line and the
  world's system messages say `No game cursor: copy sro_client.exe from your Silkroad folder into
  <the pk2 folder> (beside Data.pk2).` (`GameCursor.missing_hint`), not only the log.
- **A renamed client** (round 700): when no candidate name is there, every `*.exe` in the same
  folders (OPENSRO_CLIENT_EXE's, the pk2 folder, its parent, our exe's; at most 64 a folder, our
  own exe skipped) is probed for cursor group 0x95 -- the PE headers (4 KB) and the head of `.rsrc`
  (256 KB at most) only, never the whole file -- and the first that decodes is used
  (`CursorSet.scan_for_client`; the log says `found by its cursors`). A private server's
  `SRO_Client_VTX.exe` carries the same cursor groups (MEASURED: the group directory at the same
  offsets, ids 0x95..0xaf).
- **Every screen**: Boot shows 0x95 before the login screen; the world chooses the hover kind;
  leaving the world puts 0x95 back. Godot's own shape changes (a text field's I-beam, a link's hand)
  get 0x95 too, as retail's WM_SETCURSOR shows the one cursor everywhere.
- **The hover**: retail's 250 ms timer (`World3D._hover_tick` from the physics step). Over a window
  (motion consumed by the GUI) 0x95. Over the world, in the click dispatch's order (round 207: the
  item ray first, because an item at a monster's feet is inside the monster's capsule; retail takes
  the nearest object of any class): item 0x99 / 0x9a, the nearest monster or player (0x97, or 0x95
  for a thief / hunter NPC monster; 0xa0 for a player with Alt held), a gate 0xa1, an NPC 0x98,
  else 0x95. The job-monster test reads the code name: every 1/2/1/2 and 1/2/1/3 row in the box's
  archive is a `MOB_..THIEF_NPC..` / `MOB_..HUNTER_NPC..` and no other row is (11,195 rows,
  MEASURED). **Stall (0xa3) is wired but unreachable**: no other player's stall state reaches this
  client yet (TODO in `GameCursor.KIND_IDS`).
- **Not here**: the forced cursors (repair, item use, socket) belong to windows this client does not
  have; the camera-rotate method 2 Option (above).
- **The ground pick's cross is OURS until the ground-pick decal is built** (round 617): retail sets
  no cursor for it and shows a ring decal instead (`select_02` in range, `select_04` out of range,
  `FUN_00629fa0`, read by lane 698). Without the decal the cross is the only cue, so it stays; it
  goes when the decal comes.
- **Dying monsters** are passed over by the hover's ray, which goes on to what is behind them, as
  retail's pick skips characters whose alive bit is clear (round 697's review).
- **The window frame and resize borders** show the OS's shapes: retail answers WM_SETCURSOR with its
  own cursor there too (no HTCLIENT test), but Godot gives the non-client area to the OS.

## How far the hover reaches (READ, round 700)

The user (2026-10-03): the gate disc shows "super far away when the game only shows it when you can
actually teleport"; swords and speech bubbles likewise. What the code does:

- **No class has a distance test.** `CGInterface::vslot_005` case 1 (`0x789820`) switches on the
  picked object's class and state only: CIItem -> 0x99 / 0x9a, CITeleportGate -> 0xa1 (nothing
  else is tested), CICUser, CICMonster, CICMonsterNPC, CICCos, CICNPC -> 0x98 (nothing else),
  CICATStruct, CICGuard. No talk, teleport or attack range is read in the hover.
- **The pick** (`FUN_0078ee20`): 3 x 3 rays around the mouse (`FUN_00a5ade0` per ray, offsets
  (i - 1) x a step from the doubles at `0xdb9820` / `0xed7cc4`), over the entity list
  `DAT_00ec4ae4`, skipping objects with +0x70 bit 0 set (`FUN_009c4150`; set by
  `FUN_009c4130`, called only from the UI preview code at `0x5611e9` / `0x5618cd`), the player
  (and the object `FUN_009ce930` returns, not read), and dead characters (+0x65c bit 0); the nearest hit wins from **1e38** (the float at
  `0xe1b85c`), a centre-ray hit beats an outer one. Each ray is a **segment**: `FUN_00a5ade0` ends
  it at the camera plus the view-space direction (x, y, 1) times **5000.0** (the double at
  `0xde5188`, `fld` at `0xa5aecc`) -- 5000 units of view depth. The object's slot 33 (0x84) tests
  it: for a gate `CITeleportGate::vslot_033` (`0x9e9b60`) puts its position in the box's matrix and
  calls `FUN_00a5b000` (a sphere test, then the box's 12 triangles through `FUN_00a5af20` ->
  `FUN_0045c750`, whose plane test `FUN_0045c9a0` needs the segment's ends on opposite sides) --
  the box is teleportbuilding's BCRadius / BCHeight (round 690).
- **So the bound is what the client holds.** The server gives a player the objects of the **3 x 3
  message blocks of 320 units** around its own block (SR_GameServer `CMsgBlock` slot 2 `0x534340`,
  `CRgnTerrain::vslot_006` `0x53ad30`; READ in round 664, docs/protocol/monster_ai.md): 320 to 640
  units each way, a square. Out of that window an NPC, gate, monster, item or player does not exist
  in the original client, so it has no cursor. NPCs are field objects in those blocks (READ, round
  664), and a gate is a server-sent object like them (READ, round 700's review: CITeleportGate is
  created only by the spawn parser -- `FUN_008a6bd0`, `FUN_009c1fa0`, NetProcessInObject -- so a
  gate exists in the client only inside the view window).
- **Here:** OpenSRO's server applies the window to monsters (`session.AOIRadius` = 1), but this
  client builds NPCs and gate pick boxes itself for all 5 x 5 loaded regions, and other players
  and drops arrive zone-wide. The hover now applies the window to every class
  (`GameCursor.in_view_window`: `floor((v + 960) / 320)` on x and z within 1 of the player's, the
  server's `combat.CellOf`): out of it the object is passed over and the cursor stays 0x95. The
  log line names the target, its distance and its block offset: `CURSOR: gate (0xa1) at (x, y) --
  gate STORE_CH_GATE at 210 units (blocks 0, 1)`, or `... -- outside the view window, not held`.
  The hover's rays stay 2000 units long (OURS; the window's farthest corner is about 905 units from
  the player and the camera at most 90 behind, so retail's 5000 never binds first).
- **For the click side (round 701):** the hover reads no range; the walk-then-talk / teleport
  distance is the server's `GObjPC::IsWithinInteractionRange` (round 642), and the click should
  pass over what the window does not hold, as the hover does. Not changed here.

## Size (MEASURED / OURS)

The resource cursors are 32x32 (0x96 34x34, 0x9a 32x31; 0x99 also carries a 36x34 image after its
32x32 one -- Windows picks the 32x32 for the default cursor size). Retail passes no size:
`LoadCursorA` gives the system cursor size (INFERRED from the Win32 contract). **OURS, the user's
decision (2026-10-03):** the cursor is scaled by the UI scale (`content_scale_factor`),
nearest-neighbour -- also the user's choice, 2026-10-03: "pixel-sharp is gonna be more clear"
(round 672's UI art is drawn linear; the cursor is not) -- size `round(32 x k)` clamped to Godot's 256, hotspot `floor((h + 0.5) x k)`
(inside its own pixel's block). Godot 4.2.2 does not rescale again: on Windows
`DisplayServerWindows::cursor_set_custom_image` builds the HCURSOR from a DIB at the texture's own
pixel size (`CreateIconIndirect`) in a DPI-aware process. So at 4K with UI scale 2.0 the cursor is
64 x 64 screen pixels -- the same share of the screen as retail's 32 x 32 at 1920 x 1080 -- drawn
with doubled pixels. (A native macOS build would double again, because NSImage sizes are points:
not this user's case -- the Mac runs the Windows build under CrossOver, whose mapping is not
measured.)
