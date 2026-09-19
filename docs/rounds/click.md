## Round: a click on a monster attacks, and the cursor is the client's own

The report was "clicking a monster opens the NPC talk window, and there is
no sword cursor over anything attackable". Both were measured before
anything was changed.

**The click, measured.** A new hook, `SRREVAMP_QA_CLICK="monster,npc,ground"`,
stands the player 40 units in front of the nearest target of each kind,
aims the camera, projects the target's middle to the screen and puts that
point through the real left-click path -- after first firing both click rays
at it side-effect-free and printing what each hit (collider path, layer
bits, the tag found walking up). Against the box's in-memory server and
against the public server (`192.168.5.25:15779`), the answer was the same:

```
QA CLICK monster: 'Yeoha' -> screen (480, 251)
   probe npc     layer 0b10000:  no hit
   probe monster layer 0b100000: .../OtherEntities/@Node3D@2686/ClickBody -> monster_id=20
   dispatched -> attack
QA CLICK npc: 'Storage-Keeper' -> probe npc: .../RealTerrain_97_168/Npc_2014_5/Body -> npc_name=...
   dispatched -> talk
QA CLICK ground: dispatched -> walk
```

So a monster's colliders are on the monster layer only (`0b100000`), carry a
`monster_id` and no `npc_name`, and the NPC-layer ray does not see them: the
talk window **cannot** open from a monster click in either environment. The
public server's Mangyangs report `54/54` HP -- the grounded characterdata
value -- so monster HP is not wrong either.

What was wrong in principle: the dispatcher ran `_try_talk_to_npc` first, on
`NPC_COLLISION_LAYER`, which is the navmesh **wall** layer, so an NPC body in
line behind a monster would have taken the click. The order is now monster,
NPC, walk (`_dispatch_left_click`, one function for the real click and the
hook), which is also how the client's own hover code treats the object under
the mouse -- it classifies what the pick returns, never wall-first. Read
honestly, the user's "it shows up as an NPC to talk to" is most likely the
**target window** opening on the click (its bar is broken -- another lane),
with no cursor change to say "attack" and, on a server with no item refdata,
placeholder 1-damage hits that leave the bar at 100%. That is an inference
from the measurement; the measurement itself is the fact.

**The cursors, from the client.** `Media.pk2` holds one cursor file
(`cursor\cursor_normal1.tga`); the other archives none. The client hides the
OS cursor (`SetCursor(NULL)`, three sites) and sets Win32 *resource* cursors
by id: `FUN_00ba6260` is `SetCursorResource(id)` --
`LoadCursorA(hInstance, MAKEINTRESOURCE(id))` -- fed by `FUN_00777ec0`
(`SetHoverCursor`) and `FUN_00777e70` (a forced cursor, -1 restores). The
mouse-move handler `CGInterface::vslot_005` (`0x00789820`) picks the object
under the mouse and switches on its class -- the classes recovered from the
type-id objects each class's `vslot_000` returns:

| class under the mouse | cursor id |
|---|---|
| nothing / friendly | `0x95` (arrow, hotspot 2,1) |
| `CICMonster`, `CICMonsterNPC`, `CICATStruct`; `CICUser` / `CICGuard` when the relation is `0xca`/`0xcc` | `0x97` attack |
| `CICNPC` | `0x98` talk (hotspot 2,26) |
| `CIItem` (on the ground) | `0x99` pick up (`0x9a` with a modifier) |
| `CITeleportGate` | `0xa1` |
| `CICUser` / `CICCos` with Alt held | `0xa0` |

`sro_client.exe` carries them as RT_GROUP_CURSOR groups over RT_CURSOR
images: 17 groups, ids `0x95..0xaf`, every one a 32x32 8-bit DIB plus AND
mask with a real hotspot (the first two WORDs of the RT_CURSOR data -- the
2220-byte size is exactly 4 + 40 + 1024 palette + 1024 XOR + 128 AND).

`client/scripts/ui/cursor_set.gd` reads them at runtime from the exe beside
the archives (`Data.pk2`'s folder holds `sro_client.exe` in every install):
PE header -> `.rsrc` -> the two resource types -> group -> image -> RGBA with
the AND bit as transparency. Nothing is extracted or shipped; a missing exe
leaves the system arrow and says so once. `World3D` classifies the hover with
the same two rays the click uses (monster -> attack, NPC -> talk, else
arrow), settled once a frame after GUI routing so a window always shows the
arrow (4.2 has no `gui_get_hovered_control`; the first draft used it, the
load check passed, and the call failed at runtime -- the project's own trap,
caught by the hook's log). The pick-up and gate kinds are wired to their ids
for the lanes that add ground items and gates.

**Verified.** `cursor_set_test.gd` decodes a hand-built 4x2 8-bit cursor
(palette, bottom-up rows, AND mask, hotspot) -- 14 checks pass. On the box,
`CursorSet: 16 cursor group(s) read from sro_client.exe` (the odd named
group is skipped), and the hook logs `kind=attack id=0x97 hotspot=(2, 1)` at
the monster click, `kind=talk id=0x98 hotspot=(2, 26)` at the NPC, `normal
0x95` at the ground. The frames show the decoded art as a QA swatch drawn at
the click point -- the golden sword over the Yeoha, the "..." bubble over
the storage keeper -- because offscreen frames never contain the OS cursor;
that is a swatch of the texture, not the cursor itself.

**Disclosed.** The hotspots are the files' own. The hover is throttled to
one classification per 50 ms (ours). The public-server run created a
`QaTester` character there. The box's `skills.csv` beside the archives did
not parse with the box's Sep-14 server binary ("wrong number of fields");
this lane ran with only `leveldata.csv` -- for the data lane.
