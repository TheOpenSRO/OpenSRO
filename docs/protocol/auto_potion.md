# The Auto potion (round 786)

Retail's "Auto potion" window (`CIFAutoPotion`, UIIT_PAG_MACROPOTION_TITLE) and the object behind
it (`CAutoPotion`, `AutoPotion.cpp`), read in `sro_client.exe`, with the server's side in
`SR_GameServer.exe`. Labels as everywhere: READ (the binary), MEASURED (the archive), INFERRED,
OURS, OPEN. Code: `client/scripts/world/auto_potion.gd` (the settings and the checks),
`client/scripts/ui/hud/auto_potion_window.gd` (the window), `server/internal/session/autopotion.go`
and `server/internal/character/autopotion.go` (the storage).

## The object

`CAutoPotion` is built once with the interface (CGInterface+0x6fc, constructor `0x82d010`): three
16-byte records at `this+4+16*row` (`0x82cd50`, which asserts `byType < AUTO_POTION_COUNT`), rows
0 HP, 1 MP, 2 abnormal status; then `+0x34` the delay box and `+0x38` the delay in ms (500 at
construction, `0x82d034`).

| record | what |
|---|---|
| +0 | enabled |
| +1 | the row's timer is armed |
| +2 | percent |
| +4 | threshold (HP/MP), `trunc(max x float32(percent / 100.0))` (`0x82cdb0`; the abnormal row's max is 1) |
| +8 | slot kind, 2 = a quick slot (`0x82ccf0`) |
| +0xc | quick slot, `belt x 10 + key + 1`, 1..40 (0x33 cap in `0x82ccf0`) |

The threshold is recomputed when Confirm changes the percent (`0x82d0b0`) and whenever the player's
maximum is set: `CICPlayer`'s max-HP and max-MP setters (`0x9d4b60` / `0x9d4b90`) tail-jump to
`0x82cdb0`.

## The wire (0x7158 type 2, and the character data)

`CAutoPotion::Send` (`0x82d2e0`), called by Confirm only when something changed, sends 0x7158:

    u8  2               (the type: 0 and 1 are the quick slots, CNIFUnderMenuBar's)
    u16 HP row          bit 15 enabled, bits 8..14 percent, bits 4..7 belt + 1, bits 0..3 key + 1
    u16 MP row            (a slot s: hi = s / 10, lo = s % 10; lo 0 -> lo 10, else hi + 1;
    u16 abnormal row       no slot -> both 0)
    u8  delay           bit 7 the box, bits 0..6 the delay / 100 (0x51eb851f, >> 5)

The game server's 0x7158 handler `GObjPC::FUN_00518c20` reads the type (from the tail when
`+0x1048` is 0) and gives type 2 to `FUN_00407ee0`, which stores the words in the character's
`_ClientConfig` record (`DB_Bind__ClientConfig` 0x85c590: CharID, ConfigType, SlotSeq, SlotType)
and marks it dirty; nothing is checked and nothing is answered. An unknown type logs "Unhandled
Client Config Data Msg Type was Detected!!!".

At entry the character data handler (`0x8ab0e0`) reads them back through `0x8a7bd0`: three u16 and
a u8 into `0xef1b70..0xef1b76`. **Defaults:** a zero delay byte (a character that never confirmed)
becomes HP `0x3211` (off, 50 %, F1 "1"), MP `0x3212` (off, 50 %, F1 "2"), abnormal `0x0013` (off,
F1 "3"), delay `0x8a` (on, 1.0 s); then an HP word whose low byte is 0 is replaced by `0x3211`.
`0x82cf60` decodes them: `slot = ((hi + 0xff) & 0xff) x 10 + lo`, capped at 40, and 0 when both
nibbles are 0; the delay is `(b & 0x7f) x 100` ms.

**OpenSRO** keeps the seven bytes per character (`characters.auto_potion`, BYTEA; OURS) and takes
0x7158 type 2 as retail sends it. Its character data is not retail's, so the client asks with
`0x0117` (OURS, empty) once it is in the world and the server answers `0x0116` (OURS) with the
seven bytes, zeros when none were saved (the client then applies the defaults above, as retail's
does). Types 0 and 1 are ignored: OpenSRO's quick-slot bar is kept on the client (round 639).

## The window

`CIFAutoPotion::Create` (`0x741980`) loads `resinfo\ifautopotion.txt`'s Create, AbnormalSlot and
PotionDelaySlot. Its children: 10/11 the HP and MP rows (`CIFAutoPotionSlot`, each built from
`resinfo\ifautopotionslot.txt` by `0x741f20`, the layout's ADDID 100 / 200 added to its ids), 15 the
abnormal check box, 18/20 its belt and quick-slot combos, 25 the delay check box, 27 the delay spin,
30 Confirm, 31 Cancel, 7 the description (CIFPML, UIIT_STT_MACROPOTION_CONTENTS).

- **Combos:** belt "F1".."F4" (`F%d`), quick slot "1".."9","0" (`%d` of i % 10). Slot from combos
  `belt x 10 + key + 1`, 40 at most (`0x741420`, `0x741d80`); combos from a slot `(s-1)/10`,
  `(s-1)%10`, left alone unless `s - 1 < 40` (`0x7413d0`, `0x741d30`).
- **A row** (`0x741f20`): its name (UIIT_STT_MACROPOTION_HP / _MP, vslot 45 `0x741ec0` on static
  2), the unit "%" (static 7), the percent (static 6, `%d`), the slider (15): range 1..100, step 1
  (`0x6599e0(1, 100, 1, 1)`), its min / centre / max statics "1" / "50" / "100" (17, 18, 19; `%d`
  of min, max / 2, max), arrows and thumb `com_qst_lefttarrow_button.ddj`,
  `com_qst_rightarrow_button.ddj`, `com_scroll_button.ddj` (`0x659da0`) at (0, 0), (312, 0),
  (20, 2) (`0x6596f0`), travel 276 (`0x659840`): `x = 20 + trunc((v - min) x 276 / (max - min))`
  (`0x6598a0`). Disabled (`0x6597d0`, from `0x741cc0` with the row's check box) the three children
  are hidden and the bar's art becomes `<art>_disable.ddj` (CIFSliderCtrl's texture setter,
  `0x65a18d..0x65a1d9`).
- **Events** (the map at `0xd6feaa..`): 101 / 201 (a row's check box, `0x741460`) enable the
  slider and, when the box comes on, put it back on the SAVED percent; 115 / 215 (a slider moved,
  `0x741540`) set the row's percent byte and static 6.
- **The spin** (`CIFVerticalSpinCtrl::vslot_010` `0x658740`): a black field with the
  `com_blacksquare_` frame over (0, 0, W-20, H), `ub_up_arrow.ddj` at (W-20, 1, 20, 12),
  `ub_down_arrow.ddj` at (W-20, H-12, 20, 12), the value at (6, 3, ...). The window sets the
  divisor 1000.0 (`.rdata 0xda95ec`) with one decimal (`%0.1f`, `0x6583f0`) and the range
  500..9500 step 500 (`0x6586c0`).
- **The check box** (`CIFCheckBox`, `resinfo\ifcheckbox.txt`): box `com_checkbutton_off.ddj`, mark
  `GDR_STATIC_SELECTED` (`com_checkbutton_on.ddj`) shown while checked; built checked (`0x656c78`);
  a left-button release toggles it (`0x656ce0`).
- **Open / close** (`0x79c750`): the window is built at every open and destroyed at every close, so
  an open always shows the saved settings (`0x741880`); Cancel (`0x7417c0`) and the close button
  just close. **Confirm** (`0x741590`): a row whose enabled / percent (HP, MP) / slot changed takes
  all of them (`0x82ccd0`, `0x82d0b0`, `0x82ccf0`, each clearing the row's armed flag -- the timer
  itself keeps running), the delay likewise, and only then is 0x7158 sent; the window closes.

## The checks

Two paths reach a row's check (`0x82d0e0` HP, `0x82d160` MP, `0x82d1d0` abnormal):

1. the 0x3057 update handler (`0x8aa0f0`), for this player only: flag 1 (HP) -> HP check, flag 2
   (MP) -> MP check, flag 4 (the state mask) -> abnormal check -- each only when its row is enabled
   (`0x82ce70`) and not armed (`0x82ce80`);
2. the interface timers 0xe / 0xf / 0x10 (`CGInterface::vslot_005`, `0x78a796..0x78a7bc`).

A check: disabled row -> nothing. Otherwise, when player+0x65c bit 0 is set (INFERRED "can act":
an action-state bit `0x9c9920` sets; the item use itself requires it, `0x796d37`) and
`HP <= threshold` (`cmp; ja` -- at the threshold it drinks) / `MP <= threshold` / the mask is
non-zero: the slot is used -- except HP while zombie (mask `0x20`, `0x82d106`) and the abnormal row
while stunned (`0x4000`, `0x82d1f5`) -- and the row's timer is armed, if not yet, for the delay when
the box is checked, else **500 ms** (`0x82d126`). Otherwise the flag is cleared and the timer killed.

The timers are the engine's own list (`0xb93320` adds -- a timer already there keeps its interval
--, `0xb93170` removes, `0xb933d0` fires every timer whose interval has passed since its stamp and
restamps it): periodic, so while a pool stays low the row drinks once per period.

**The use** (`0x82ce90`): for a quick-slot row, `0x60b1d0(slot)` -- the slot holds a bag item
(kind 0x46) whose TID is 3/3/1 (a recovery potion) or 3/3/2 (a cure) (`0x60ae50`) -- then
`0x60b850(slot)`, the same function a key press reaches. Which potion does not matter (an MP
potion in the HP row is drunk for HP). There is no client-side cooldown test; the server refuses a
use inside an item's reuse lock (0x185b).

## OpenSRO

- **READ, implemented:** everything above. The pools come from every message that sets this
  player's bars (the bars' `pool_set`), the mask from its OpObjectStatus, the timers from
  `_process` (wall clock); the use is `World3D._on_quickslot_activated(slot)`.
- **INFERRED:** player+0x65c bit 0 as "alive and not behind a loading screen".
- **OURS:** the storage (a column, not `_ClientConfig`), the load request/answer opcodes, the
  slider's drag (its mouse handling is not read), which arrow steps which way (by the art's names),
  the window kept and refilled rather than rebuilt, the PML's left alignment (the reference
  picture).
- **OPEN:** CIFPML's own alignment and scrolling; whether `+0x504` (`0x60b850`'s last test) is ever
  set for a player; the zombie's HP potion on the server (`0x49b912` hurts a zombie by the HP
  amount; OpenSRO's potion path does not read the bit yet).
