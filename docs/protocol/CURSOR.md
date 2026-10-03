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
While the camera turns (right drag) the manager hides the cursor and puts it back at the press
point (`CGInterface::vslot_012 0x77b140`: `0xba61e0(0)` + `SetCursorPos`).

## The hover (READ: CGInterface::vslot_005 case 1, 0x789820)

`vslot_005` is CGInterface's **timer** handler; timer 1 runs every **250 ms**
(`push 0xfa; push 1; call 0xb93320` at 0x787294). Each tick: the window under the mouse must be
the interface itself (`FUN_00b9dc00() == this`), else 0x95; the pick (`FUN_0078ee20(x, y, 0)`:
the nearest object of any class, never the player) must find something, else 0x95; then the
object's runtime class, by exact match (vslot 0 returns the class descriptor):

| Descriptor | Class | Cursor |
|---|---|---|
| 0xef1c28 | CIItem | 0x99, 0x9a with the left button held |
| 0xef1dac | CITeleportGate | 0xa1 |
| 0xef1bc0 | CICUser | outside the party (`0x992940`) and its IsHostile(Alt) (vslot 0xa8, `0x9de780`) -> 0xa0; else stalling -> 0xa3; else 0x95. Then in a siege-fortress zone (`0x939a60` on the player's REF_SIEGE_FORTRESS): a party member 0x95, else guild relation `0x998280` 0xca / 0xcc -> 0x97, 0xc9 / 0xcb -> 0x95. Then, while the player's team byte +0x81d != 0xff: another team 0x97, the same 0x95 |
| 0xef1a84 | CICMonster | 0x97 when its vslot 0xdc (always 1, `0x9d3160`) and the interface's set +0x500 holds key 5 (`0x784ed0`; INFERRED "attack allowed") -- unless the player's vslot 0xac is 4 (INFERRED no job) and the monster is TypeID 1/2/1/2 or 1/2/1/3 (`0x779dd0` / `0x779e20`, on +0x220: the thief and hunter NPC monsters); else 0x95 |
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

- **Where the exe is found** (round 697): `SRREVAMP_CLIENT_EXE` (OURS, dev) first; then, for
  `sro_client.exe` and the vSRO package's `sro_client_NODLL.exe` (the same 16 numbered cursors,
  MEASURED), the folder of Data.pk2, its parent, and the folder of our own executable. The launcher
  `silkroad.exe` is not accepted (15 1-bit system-style cursors, MEASURED). The log says
  `GameCursor: 16 cursor(s) from <path>`, or `GameCursor: no sro_client.exe found -- ... Tried: ...`.
  Before round 697 only `$SRREVAMP_PK2_PATH`'s folder was tried, and a player's build resolves the
  `pk2` folder without that variable -- so a player never got the cursors.
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
  have; the ground pick shows the system cross (OURS, round 617; retail shows its hover cursor);
  the cursor is not hidden while the camera turns.

## Size (MEASURED / OURS)

The resource cursors are 32x32 (0x96 34x34, 0x9a 32x31; 0x99 also carries a 36x34 image after its
32x32 one -- Windows picks the 32x32 for the default cursor size). Retail passes no size:
`LoadCursorA` gives the system cursor size (INFERRED from the Win32 contract). **OURS, the user's
decision (2026-10-03):** the cursor is scaled by the UI scale (`content_scale_factor`),
nearest-neighbour, size `round(32 x k)` clamped to Godot's 256, hotspot `floor((h + 0.5) x k)`
(inside its own pixel's block). Godot 4.2.2 does not rescale again: on Windows
`DisplayServerWindows::cursor_set_custom_image` builds the HCURSOR from a DIB at the texture's own
pixel size (`CreateIconIndirect`) in a DPI-aware process. So at 4K with UI scale 2.0 the cursor is
64 x 64 screen pixels -- the same share of the screen as retail's 32 x 32 at 1920 x 1080 -- drawn
with doubled pixels. (A native macOS build would double again, because NSImage sizes are points:
not this user's case -- the Mac runs the Windows build under CrossOver, whose mapping is not
measured.)
