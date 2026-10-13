# A skill slot's re-use display (`skill_delay.ddj`, `skill_charge.ddj`)

The user (round 786, a GIF of the hotbar): the cooldown overlay showed as a 2 x 2 tiling inside the
slot -- four small sweeps, each over a quarter of the icon -- where it should be one sweep over the
whole icon. Then: the skill window showed no cooldown at all.

Built in round 785 (`SkillCooldowns`, the hotbar), corrected and put on the skill window in round
786 (`client/scripts/ui/skill_delay_overlay.gd`, `SkillDelayOverlay`). Every fact below is READ from
`sro_client.exe` (decomp dump `/var/tmp/decomp_client` and `objdump` of the binary on the render box)
or MEASURED from the archive; the choices of ours are marked OURS, the guesses INFERRED.

## 1. The art

| File (Media.pk2) | Size | Format | Grid | Cell | Frames |
|---|---|---|---|---|---|
| `interface\skill\skill_delay.ddj` | **256 x 256** | A8R8G8B8, no mips | 16 x 16 | 16 px | 240 (row 15 empty) |
| `interface\skill\skill_charge.ddj` | 64 x 64 | A8R8G8B8, no mips | 4 x 4 | 16 px | 16 |

MEASURED: the JMXVDDJ 1000 header (20 bytes) wraps a DDS whose header says 256 x 256 (64 x 64),
pixel-format flags 0x41, 32 bits, masks 0xff0000 / 0xff00 / 0xff / 0xff000000; the payload is
exactly 256 * 256 * 4 (64 * 64 * 4) bytes. The delay cells are black at alpha 185 where time is
left and clear (alpha 0) where it has passed; cell 0 is all dark, and the clear part grows
clockwise from 12 o'clock to nearly the whole cell at frame 239. (`skill_using.ddj`, beside them,
is 128 x 128; it is not drawn by this function.)

## 2. The draw (`UI_SILKMALL::FUN_0067cfb0`)

- **Who draws it.** `CIFSlotWithHelp::vslot_013` (`0x685e50`): the icon (`0x6550c0`), then
  `0x67cfb0` unless the slot's byte +0x64c is set (0 from the constructor `0x673c80`:
  `xor ebx,ebx` at `0x673cb2`, stored at `0x673e1d`), then the count (`0x67bd70`).
- **The textures.** `CIFSlotWithHelp::vslot_010` (`0x66b460`) loads `skill_delay.ddj` into
  +0x620 and `skill_charge.ddj` into +0x624.
- **Which slots.** The skill branch (`0x67d68d..0x67d6ad` the kind tests, `0x67d735` the sweep's `0x9bb9c0`, `0x67d965` the flash's `0x9bbb60`): the slot's kind (+0x36c,
  `0x666700`) is 0x49, or it is 0x0c (a quick slot) with sub-kind (+0x370, `0x666720`) 0x49, or
  the sub-kind is 0x19. The skill is +0x65c (`0x666730`); with it 0 nothing is drawn. It needs
  `0x9c0b90(id)` (learned), `0x9372b0(id)` or `0x93f5d0(id)` non-zero.
- **The sweep.** `r = SkillCoolTimeManager::FUN_009bb9c0(0x778bb0(id))` (left / total). When
  `r != 0`: `frame = ftol(239.0 - r * 239.0)` (239.0 the double at 0xda3760; `0xb42d10` is the
  ftol), `column = frame & 15`, `row = frame >> 4` (the signed-modulo idiom), and the quad's UVs
  are `u0 = column * 32.0 * 0.001953125`, `u1 = (column + 1) * 32.0 * 0.001953125`, the same for v
  with the row (32.0 the double at 0xd99a60, 0.001953125 = 1/512 at 0xda3768). The quad is the
  slot's own rectangle (+0x24c, copied to the vertex block).
- **The flash.** Otherwise `f = FUN_009bbb60(...)` (the 500 ms tail / 500). When `f != 0`:
  `frame = ftol(15.0 - f * 15.0)` (0xd878a0), `column = frame & 3`, `row = frame >> 2`, UVs
  `column * 16.0 * 0.015625` (16.0 at 0xe1b8e0, 1/64 at 0xda3758), with the +0x624 texture.
- **The cell is a fraction of the sheet.** The UVs are 32/512 = 1/16 (16/64 = 1/4) per cell,
  whatever the sheet's pixel size; the 512 is not the sheet's size (that is 256, §1). One cell
  covers the slot's whole quad: a 16-pixel cell stretched over the 32-pixel icon.
- **The time left as a number.** Quick slots only (kind 0x0c, sub-kind 0x49 or 0x19):
  `0x67c920(SkillCoolTimeManager::FUN_009bba90(...))` draws the time left -- seconds under 61,
  minutes (`/ 0x3c`, colour 0xffe1e700) under 3601, another draw beyond (not read). OPEN: not
  built.

## 3. The skill window draws it too

- `resinfo\ifskill_slot.txt` (MEASURED, the file): ID 1 is `GDR_STMS_SLOT_SKILL:CIFSlotWithHelp`,
  ID 2 the button `GDR_STMS_BTN_LEVELUP`, IDs 3..6 the level statics.
- `CIFSkillSlot::Create` (`0x6a0980`): `0x8b51f0(1, 1)` -> +0x3ac (the slot), `0x8b51f0(2, 1)` ->
  +0x3a8 (the button), then `mov ecx,[esi+0x3ac]; push 0x49; call 0x6666f0` (`0x6a09df..0x6a09ed`):
  the slot's kind is 0x49.
- `IFSkillSlot::FUN_006a15f0` (SetSkill): `mov ecx,[esi+0x3ac]; push edi; call 0x66c3c0`
  (`0x6a1794..0x6a179b`), which stores the skill id at +0x65c.
- So the skill window's slot is drawn by the same `0x685e50` -> `0x67cfb0` branch as the bar's,
  sweep and flash alike (not the number: its kind is 0x49, not 0x0c).

## 4. Other slots `0x67cfb0` gives a sweep (OPEN, not built here)

The same function draws the same +0x620 sheet, at the same 1/16 cells, for item slots: kinds 0x46,
0x47, 0x33, 0x45, 0x13, 0x91, 0x21, 0x1a and quick slots of sub-kind 0x46 / 0x47 (or 0x8c with
0x46), from the item cool-time functions `0x9b94d0` / `0x9ba560` / `0x9ba680` keyed by the item's
type (`0x67dac0..0x67de4a`; the slot must hold an item, +0x390 with +0x28 set); and kind 0x0c sub-kind 0x4a when +0x658 is 100 and +0x65c is 0x3f7,
from `IFMainPopup` `0x6a2b70` / `0x6a2b60`. OpenSRO draws no item re-use display anywhere.

## 5. OpenSRO

- `SkillDelayOverlay.cell_region(sheet_size, grid, frame)`: the cell as a fraction of the loaded
  sheet (1/16, 1/4), so the measured 256 x 256 gives 16-pixel cells. `apply` puts one
  `AtlasTexture` cell over the icon.
- `HudUnderbar.set_slot_cooldown` (the bar) and `SkillBoard.set_cooldowns` (the skill window's
  learned slots) both use it; World3D's `_tick_skill_cooldowns` feeds both from one
  `SkillCooldowns`, every frame while a record runs and once more when the last goes.
- INFERRED: in the skill window the overlay is over the icon and under the level badge and the
  button; the slot child's draw order against the other children of `ifskill_slot.txt` was not
  traced.
- Round 785's mistake: it read `32 * 1/512` as "a 512 x 512 sheet of 32-pixel cells" and cut
  32-pixel regions; on the real 256 x 256 sheet that is 2 x 2 cells.
