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

MEASURED with `client/tools/dump_visible_panels.gd`, v0.1.458 against v0.1.459:

- On the popup's inventory, character, skill, action, party and academy tabs,
  and on the warehouse and the exchange, exactly the nine `RegistryFrame` nodes
  went missing.
- The party and academy leader marks (Style 64 in their layouts) were hidden
  by the same rule, and that is correct.

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
  bag starts on page 0 (`0x6b6d16`). A tab click goes through `0x6b45b0`, which
  matches the clicked control's ID. An expansion re-selects `+0x3cc`
  (`0x6b75d3`).
- **Create** (`0x6b2440`) keeps control ID 10 (`GDR_INVENTORY_STA_MONEY`) at
  `+0x388` and ID 11 (the money button) at `+0x398`. The lattice is art only.

**OPEN: carrying an item across pages.** How the retail client does it (its
dragged-item model, `CIFDraggedStatic`) is not read. Ours (OURS) turns the page
when a drag passes over a tab.

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
- **Light** (`this + 0x510`, Create `0x6aca1c..0x6acae3`, SetLight(0) at
  `0x6ad9e8`):
  - directional, pointing (0, 0, 1);
  - diffuse 0.7 (`0xd82f04`), ambient 0.3 (`0xd82f00`), specular 1;
  - range 10000.
  - `D3DRS_AMBIENT` and `SPECULARENABLE` are inherited from earlier draws
    (OPEN).
- **Our key light's energy.** MEASURED with `client/tools/measure_doll_light.gd`
  in GL Compatibility on the box's RX 5700 XT. At energy 0.89, a 0.5-grey quad
  facing the camera renders 128 of 255, matching the client's
  0.5 × (0.3 + 0.7). With the light off it renders 34, against the client's 38.
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
- **Direction.** Which way a positive yaw turns on screen is INFERRED: it
  assumes vslot `0x30` is `D3DXMatrixRotationY(yaw)`, which turns the face
  toward the screen's left. The round-633 render matches that inference.
