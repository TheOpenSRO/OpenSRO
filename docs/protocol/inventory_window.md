# The inventory window: bag pages, purse colour, equipment pane, preview

Round 633. Everything here is READ from `sro_client.exe` (the decompile in
`/var/tmp/decomp_client` and `/var/tmp/sro_client.asm` on the RE box) unless it
is labelled MEASURED, INFERRED, OPEN or OURS. The layouts are the archive's
`resinfo\ifinventory.txt`, `resinfo\ifequipment.txt` and `resinfo\ginterface.txt`.

## Registry windows and Style 0x40

The resinfo builder hides a control whose Style has bit 0x40 as it creates it
(`0x8b5710`: `push 0x40; call 0x652da0` tests the style, `vslot 0x5c`
ShowWindow(0) at `0x8b5726`). The test has no class condition. It hides:

- **92 controls in the layouts** (the party leader's mark, the minimap's dungeon
  ring, ...). Each window shows its own from code when it applies.
- **43 of `ginterface.txt`'s registry entries**, which are windows, not
  controls: `GDR_MAINPOPUP`, `GDR_STORAGEROOM`, `GDR_EXCHANGE`,
  `GDR_GAMEGUIDE`, `GDR_STORE`, `GDR_WORLDMAP` and more. CGInterface creates
  them hidden, and each window's own ShowWindow(1) shows it along with the
  frame it draws.

In this client a registry window is a `HudWindow`, and the frame is a child
drawn with it (`RegistryFrame`). Round 630 applied the bit to that child, and
nothing ever showed it again. Round 633 keeps the frame visible and leaves the
window's showing to HudPanels.

Which windows it reached: those this client frames from a registry entry
**and** whose entry carries Style 64 -- GDR_MAINPOPUP, GDR_STORAGEROOM,
GDR_EXCHANGE, GDR_GAMEGUIDE. GDR_COMMUNITY, GDR_STORE and GDR_ALCHEMYBOX carry
Style 64 too, but this client never builds them from the registry (the guild
and community are 2dt windows, the store is self-framed, the alchemy window is
CNIFEnchantWnd), so their windows were untouched.

MEASURED with `client/tools/dump_visible_panels.gd`, v0.1.458 against v0.1.459:

- On the popup's inventory, character, skill, action, party and academy tabs,
  and on the warehouse and the exchange, exactly the nine `RegistryFrame` nodes
  went missing.
- The party and academy leader marks (Style 64 in their layouts) were hidden
  by the same rule, and that is correct: the client hides them at creation too.
  It then shows them from code:
  - **party** (built, round 633's review): CIFParty::Create keeps
    GDR_PTY_PARTY_LEADER (ID 14) at `+0x3a8` and
    GDR_PTY_PARTY_LEADER_RACE_MARK (ID 15) at `+0x3ac`
    (`0x6d70b6..0x6d70e0`). The refresh `IFParty::FUN_006d6640` asks the party
    manager (`0xeeebd8`, `0x987070`: its state's byte `+0xe`) whether the
    player is in a party, and shows both (`0x6d6676..0x6d6687`) or hides both
    (`0x6d6cdc..0x6d6ced`). In a party the race mark gets the leader's race art
    (`0x6d67fb..0x6d682c`: race byte `+0x9c` into `0x98caa0(.., race, 1)`,
    `com_kindred_china16.ddj` / `com_kindred_europe16.ddj`);
  - **academy** (OPEN): CIFApprenticeShip keeps the rank mark (ID 15) at
    `+0x390` (fetched at `0x6e98cb` with the ID in ebp). `0x6e9de3..0x6e9e6f`
    sets its texture from a path formatted with the member's rank byte
    (`[ebp+0x34]`, format `0xdaabb0`) and shows it. `0x6e8cdc` hides it. No
    fetch of ID 14 was found in the module. This client keeps no academy data,
    so neither is built.

## The bag's pages

- **Size.** The character-data handler reads the inventory size byte and takes
  13 off it (`0x9d9aee sub dl,0xd`), storing the bag's size at `+0x2048`. It
  passes that to `IFInventory 0x6b6620(size, goldLo, goldHi)` (the call is at
  `0x9d9c0f`). The size-change packet handler (`0x8a759c`) does the same
  subtraction before calling `0x6b7020`.
- **Pages.** `((size - 1) >> 5) + 1`, so a size of 0 or 1 is one page. The
  code asserts at most 3 pages (`IFInventory.cpp` line `0xa7`), so the bag
  shows at most 96 slots.
- **Tabs.** Each is a `CIFSelectableArea` (class `0xee96c0`), created in code
  with a rect relative to the pane:

  | ID | Rect | Art | Text |
  |---|---|---|---|
  | `0x50` | 4,-23,60,24 | `interface\ifcommon\com_tab_on.ddj` / `_off.ddj` | `UIIT_CTL_BELOINGING` |
  | `0x51` | 64,-23,56,24 | `com_short_tab_on.ddj` / `_off.ddj` | `UIIT_STT_INVENTORY_EXTENSION_TEB` |
  | `0x52` | 118,-23,57,24 | `com_short_tab_on.ddj` / `_off.ddj` | `UIIT_STT_INVENTORY_EXTENSION_TEB2` |

  All three have ClientRect 0, font index 0 (`0xba5460(0)`), and centred text
  (HAlign/VAlign 1). The text colour is never set, so it is the text board's
  default (INFERRED white).
- **Selecting a tab.** `0x64ce30` stores its first texture as the selected one
  (`+0x380`) and its second as the unselected one (`+0x384`). SetSelected
  (`0x64cc30`) swaps between them. A selected tab also sets text flag 2
  (`0x8b44b0(0,2)`), which switches the glyph mode in `0x8b39e0`. What that
  mode draws is OPEN.
- **Slots.** There are `pages * 32` `CIFSlotWithHelp` (`0xee9b18`), ID
  `100 + i`, each 32x32 at `(18 + 36*(i%4), 13 + 36*((i%32)/4))`. That is the
  top-left of the lattice cell each one sits on, since `GDR_INVENTORY_LATTICE`
  is at 18,13 with 36-pixel cells. A slot at or past the size shows
  `interface\pet\pt_block.ddj` and is disabled (`0xb8f540(0)`).
- **Showing a page.** `0x6b3d00(page)` selects the tab, keeps the page at
  `+0x3cc`, and shows that page's 32 slots while hiding every other slot. The
  bag starts on page 0 (`0x6b6d16`). A tab click goes through `0x6b45b0`,
  which matches the clicked control by its handle (`+0x2c`, read through
  `0xb8f4d0` against the event's `0xb9dc30`). An expansion re-selects
  `+0x3cc` (`0x6b75d3`). A tab acts on the **press**: CIFSelectableArea's
  `0x64cb80` answers message `0x201` (WM_LBUTTONDOWN).
- **Create** (`0x6b2440`) keeps control ID 10 (`GDR_INVENTORY_STA_MONEY`) at
  `+0x388` and ID 11 (the money button) at `+0x398`. The lattice is art only.

**OPEN: carrying an item across pages.** The two IFInventory handlers that
name "DraggedTab", "DraggedPage" and "DraggedItemIndex" do not define it
(round 633's review):

- `0x6b4610` (message `0x8074`) is the confirm box's answer after an item was
  dragged between windows. It reads those keys back from the box and sends
  the move, addressing a store slot as `index + (page + tab*8)*0x1e` and a
  warehouse slot as `index + page*0x1e`.
- `0x6b62d0` (message `0x8076`) is the split box's OK. It moves the chosen
  quantity from the slot at `+0x384` into the first empty bag slot
  (`0x6b6280`).

Neither turns a page, and the tab (CIFSelectableArea) answers only a press
(`0x64cb80`) and hover (`vslot_019`: messages `0x4009`/`0x400a`). So how
retail carries an item to another page is still not read. Ours (OURS) turns
the page when a drag passes over a tab.

**Held slots are never stranded** (OURS, round 633's review, tightened by the
rounds 633-635 integration review). An item held past a lowered size stays
REACHABLE -- listed (the list's size is the highest held slot + 1), moved or
merged out, removed, its durability written -- but nothing new is placed past
the size: AddItem's stacking and free-slot search, a move's target, a swap
into the held slot and the trade's space check all keep to the configured
size (`inventory.SetKeepHeld`, logged once per character and size). So the
size falls to the configured one as the player empties those slots, and
nothing refills them; an expansion item grows the configured size, not the
reach. The original has no such case: its size only grows.

**Starting size.** The retail starting size is not in either executable: it is
the `_CHAR.InventorySize` database default. The engine's own growth caps are
bag + 13 ≤ 77, or ≤ 99 with the expansion quest (`inventory.go`). So retail's
third page is never full by the engine's means: at most 86 slots.

## The purse colour

`0x5d3df0(lo, hi)` picks the colour by the amount's size:

| Amount below | Colour |
|---|---|
| 10^4 | `FFFFFFFF` |
| 10^5 | `FFFFFA85` |
| 10^6 | `FFFFD348` |
| 10^7 | `FFFFAD5C` |
| 10^8 | `FFFF9AA1` |
| 10^9 | `FFEBA1FF` |
| 10^10 | `FFB8BBFF` |
| 10^11 | `FF95DEFF` |
| otherwise | `FF8BFFE5` |

Each caller applies it to the number's own static with `0x8b2b70`:

- the bag, `GDR_INVENTORY_STA_MONEY` (`0x6b045b`);
- the warehouse, `GDR_STORAGE_STA_MONEY` (`0x6cc535`);
- the exchange's `_MYMONEY` / `_OTHERMONEY` (`0x7b23be` / `0x7b236e`). Both
  start at 0 (`0x7b2941`, `0x7b294c`).

The "Gold" captions keep their layout colour.

These do **not** use it:

- store prices and totals;
- the gold input box: CIFEdit colouring needs flag `0x400`, which nothing sets;
- item tooltips.

It is also used for stall prices, the guild-war wager and the Open Market, none
of which this client builds.

## The equipment pane

`CIFEquipment::vslot_013` (`0x6ad860`) draws in this order: the frame (ID 4)
and tile (ID 5), then the 3D model, then the slot backdrops, then the children.

- **Worn backdrops** (`0x6adc02..0x6adf35`). The textures are `+0x594 + 4i`,
  from Create `0x6ac51a..0x6ac8f2`, named
  `interface\equipment\equip_slot_{helm, mail, shoulderguard, gauntlet, pants,
  boots, weapon, shield, specialdress, earring, necklace, l_ring, r_ring}`.
  Positions come from the table at `0xda6e20`:

  | i | Position | i | Position |
  |---|---|---|---|
  | 0 | (1,82) | 7 | (122,0) |
  | 1 | (1,125) | 8 | (137,304) |
  | 2 | (137,82) | 9 | (1,211) |
  | 3 | (137,125) | 10 | (137,211) |
  | 4 | (1,168) | 11 | (1,254) |
  | 5 | (137,168) | 12 | (137,254) |
  | 6 | (0,0) | | |

  Each is 40 square, except 6 and 7 at 56. They are drawn whether the slot is
  filled or not. In avatar mode only i = 8 is drawn.
- **Avatar backdrops** (`0x6adf3b..0x6ae191`, table `0xda6df8`), avatar mode
  only, each 40 square:

  | Texture | Position |
  |---|---|
  | helm | (1,82) |
  | cloth | (1,125) |
  | pandernt | (137,125) |
  | plag | (137,82) |
  | extraneous01 | (1,169) |

- **Texture sizes.** MEASURED from their headers: 40x40, except the weapon's
  and shield's at 56x56.
- **Button tooltips.** Button 13 gets `UIIT_STT_AVATAR_VIEW_AVATARSLOT` and
  button 14 gets `UIIT_STT_AVATAR_VIEW_EQUIPSLOT` (`0x653dc0`).

## The preview

- **Viewport.** The pane's rect grown by (+2, +15, -2, -37)
  (`0x6ad8ca..0x6ad8d3`), which is (2, 15, 176, 318). It clears Z only.
- **Camera** (`0xbae0a0`, then the draw sets it):
  - perspective, vertical field of view 30 (`0xd82ef0`);
  - near 1, far 500000 (`0xe09630`);
  - looks at (0, 9, 0) (`0xd82ef8`) from 40 (`0xd82ef4`) in front, with no
    pitch or roll: eye (0, 9, -40), through `LookAtLH` `0xaa4bad`;
  - aspect is the viewport's own;
  - nothing depends on the model's size.
- **Light: the zone's** (round 633's review). The draw does fill a D3DLIGHT9
  at `this + 0x510` (Create `0x6aca1c..0x6acae3`: directional (0,0,1),
  diffuse 0.7, ambient 0.3). But it hands it to the device's SetLight
  (`0x6ad9e8`), which is fixed-function state no draw reads:
  - the model is drawn by CObjRendererVS (`vslot_038` `0xbf5830`) through a
    vertex shader;
  - that shader's light constants (`0x1112e18` / `0x1112e28`) are written only
    by `vslot_025` (`0xbeecc0`), which only the world draw calls.

  So the preview is lit exactly as round 635's portrait is
  (`docs/protocol/player_mini_info.md`):
  - diffuse = environment channel 2, clamped, × 0.6;
  - ambient = channel 3;
  - to-light (0.707, 0.707, 0) in the file's coordinates;
  - `oD0 = object colour 0.6 × ambient + max(0, n·l) × material colour ×
    diffuse`;
  - stage 0 MODULATE2X.

  PaperDoll reuses PlayerPortrait's materials. Round 633's first version
  (a 0.7/0.3 Godot light with its energy calibrated to 0.89) is gone.
- **Pose.** Animation type 0, stand (`0xa5b550(group, 0, ...)` at
  `0x8a94b2..0x8a9545`).

## Turning the preview

| Button | ID | Rect | Handler |
|---|---|---|---|
| `GDR_EQ_BTN_ROTATE_LEFT` | 10 | 54,327,28,16 | `0x6ab920`: yaw -= frame_ms × 0.0015 |
| `GDR_EQ_BTN_ROTATE_RIGHT` | 11 | 96,327,28,16 | `0x6ab960`: yaw += frame_ms × 0.0015 |
| `GDR_EQ_BTN_ROTATE_RESET` | 12 | 81,327,16,16 | `0x6ab9a0`: yaw = 0 |

- 0.0015 is the double at `0xda6fa8`.
- `frame_ms` is the int at `0x110f7f8`, clamped to at most 3000 (`0xba4101`).
- The yaw lives at `+0x578` (the model's `+0x20c`) and is applied through
  `0xa5a8c0` → the model's vslot `0x30`.
- The yaw starts at 0 (`0x6ab555`) and is not reset when the window is shown.
- **Held arrows.** Both arrows carry CIFButton flag `0x20` (`0x6ac341`,
  `0x6ac34e`):
  - press: one command at once, then a 1000 ms timer;
  - when that timer fires, a 50 ms repeat takes over (`0x655f40`);
  - release: no click;
  - moving off the button pauses the repeat (`0xb93290` / `0xb93240`).
- **Reset** fires on release, like any plain button.
- **srrevamp's step is 36 degrees (OURS, round 639).** The user found retail's step (one
  frame's worth, about 1.4 degrees at 60 fps) too slow and asked for 36 degrees a click, ten
  clicks to a full turn. A held arrow repeats the same 36 degrees after retail's 1000 ms and
  then every 250 ms (OURS, round 639's review: retail's 50 ms made 720 degrees a second, too fast
  to aim; 250 ms is 144 degrees a second). The yaw is kept in [0, 360) and the reset still sets
  0. MEASURED on the box: ten real clicks on the right arrow logged 36, 72, ... 324 and 0.
- **Direction and handedness** (round 633's review, READ). The yaw setter
  `CCompChar::FUN_00c26e70` builds the row-vector matrix
  `[[c,0,s],[0,1,0],[-s,0,c]]`, so the model's forward is (sin, 0, -cos). At
  yaw 0 it faces the camera (at -z), and a growing yaw (the right arrow,
  `0x6ab960`) turns the face toward +x, which is the screen's right in the
  client's left-handed view.
  - The client is left-handed and the assembled body is in the file's own
    coordinates. So the model hangs under a (1, 1, -1) node and the camera
    stands at the mirrored eye (0, 9, 40), as the portrait does.
  - Without that node the picture was retail's mirror image, the one-handed
    weapon in the wrong hand.
  - Under the mirror the setter's matrix is a Godot rotation by -yaw.
  - MEASURED in the review's real-input run (`World3D: doll pose`):
    - at yaw 0 the right hand is drawn at x 55 and the left at x 133 of 176:
      the character's right hand on the screen's left, facing the camera;
    - with the right arrow held, a point in front of the face moves
      +1.2 … +23.1 px right as the yaw grows 0.024 … 0.510.
