# The buff bar: `CIFMagicStateBoard`

Round 618 records here how retail's buff bar works. The bar is the row of active-buff icons to the
right of the HP bar. srrevamp's version is `client/scripts/ui/hud/hud_buff_board.gd`, and it reads
skill rows through `skill_buff_catalog.gd`.

Every address is in `sro_client.exe`: the dump is `/var/tmp/decomp_client` and the disassembly is
`/var/tmp/sro_client.asm` on the RE box. The skills spec's section 3 did the first reading. This
round re-read every function it cites, and the rows marked **new** are ones the spec did not have.

The labels are:
- **READ**: read out of the binary.
- **MEASURED**: measured in the box's archives.
- **INFERRED**: a conclusion from something read or measured.
- **OURS**: a choice of this project.
- **OPEN**: not established.

## The window

| What | Value | Label |
|---|---|---|
| Registry entry | `GDR_MAGICSTATEBOARD:CIFMagicStateBoard`, ID 22, `Rect=220,10,160,40`, `resinfo\ginterface.txt` line 438 | MEASURED |
| Classes | `CIFMagicStateBoard` (vtable 0xdd0564), a `CIFStateSlot` per icon (0xdd068c), a `CIFGauge` per time bar (0xd9af64) | READ (RTTI) |
| Lists | The main list is at `+0x370`. The second list, at `+0x37c`, takes a skill with `bbuf` when the add's param_4 is 0. **New**: the 0xB0BD handler always passes 0 (asm 0x8a5cbc..0x8a5cc6: `push ebp` with ebp = 0), so every `bbuf` buff from the server goes to the second list. | READ |
| Order | Arrival order: 0x803ec0 inserts before the head sentinel. | READ |
| Zero duration | **New**: 0x7fda20 refuses the add when the skill has a `dura` whose first value is 0, so no icon appears. srrevamp maps this to a durationMs of 0. That mapping is INFERRED. | READ |
| Remaining time on add | **New**: the add's param_6 is the time left, and elapsed is set to total − param_6 (0x8048c0). 0xB0BD passes 0. The contract's `remainingMs` fills this slot. | READ |

## Layout (0x7ffc10)

- Main list: icon i sits at `((i % 8) * 23, (i / 8) * 27)`.
- Second list: icon i sits at `((i % 8) * 23, (i / 8 + rows1) * 27 + 2)`.
- A list's row count is `max(n − 1, 0) / 8 + 1`. **New**: an empty list still counts as one row.
- The board sizes itself to `184 × (rows1 + rows2) × 27`.
- **New**: each slot's gauge is shown only when that buff has a duration (asm 0x7ffd35..0x7ffd51: `ShowWindow(total != -1)`). The second gauge, for item-time entries, has the same rule. So **an untimed buff shows no bar at all**. The board's per-frame update still writes 1.0 into the hidden gauge. The spec's "full for untimed" was the value, not what is drawn.

## A slot (0x803cd0, 0x806d50)

- The icon is 20 × 20.
- The CIFGauge is created with rect `{0, 20, 20, 4}`:
  - The fill is `icon\stateodd\s_stateodd_time_gauge.ddj`. It is the gauge's own texture, set through the `+0x84` object's vslot `+0x34`.
  - The back is `icon\stateodd\s_stateodd_time.ddj`, set by 0x638540 at `+0x398`. 0x6387d0 draws it whole, before the fill.
  - Both files are 20 × 4 (MEASURED).
- The slot is then sized to width × (20 + the gauge's height), which is 20 × 24. That is the slot's rect for the right-click hit test.
- Kind 3 (item time) entries use `s_stateodd_time02_gauge.ddj` and a second gauge. They are not built here.
- A skill with `lnks` gets a frame cut from `interface\ifcommon\window_all.ddj` at `{-2, -2, w+4, h+4+gauge}`, using the UV constants at 0xdd07a0..0xdd07b0. This is not drawn here: which constant is which corner is OPEN.
- Round 638: the same CIFStateSlot is used by the target window's buff viewer (CIFBuffViewer),
  which passes 0 as 0x806d50's first argument, so that viewer's slots have no gauge. The flag at
  `+0x36c` is written by 0x806630 from an entry byte that 0x9d25e0 computes. See
  `target_window_buffs.md`.
- A kind-1 slot also loads `icon\stateodd\s_admittance_back.ddj` (string at 0xdd077c) and `icon\stateodd\s_admittance_icon.ddj` (0xdd0758) into `+0x390` and `+0x394`. CIFStateSlot's vslot_015 (0x8071c0) draws the two only while the slot's `+0x36c` is set. This is the same flag as the tooltip's red line. What sets it is OPEN, so neither sprite is drawn here.

## The icon's texture and sampling (round 624)

**Which file** (READ):
- 0x803cd0 builds the slot, then 0x7ff240 picks the icon's path by entry kind. For kind 1, a skill
  buff, it is the skill row's string at `+0x108` (0x93f250 → 0x95f4d0 = row + 0x774, + 0x108).
- 0x8068a0 hands the path to the icon child (`+0x378`, a 20 × 20 window at (0, 0), built in
  0x806d50) through its `+0x84` object's vslot `+0x34`. That is 0x655680, which loads the texture
  through 0x5008f0 → 0x500670.
- The skill window's slot (`IFSkillSlot` 0x6a15f0), the quick slot (`IFSlotWithHelp` 0x6809a0),
  0x66c3c0 and the practice box (`CIFSkillPracticeBox::vslot_052` 0x7063d0) load the same `+0x108`
  string the same way. So the buff icon is the skill window's file, skilldata col 61 under
  `icon\`. There is no separate state-icon table for skill buffs.
- The other kinds are these: kind 2 (abnormal states) `UI_PARAM::AbnormalState_IconAndLabelForMask`;
  kinds 6/7/8/9/11/12 fixed files (`icon\etc\icon_trade_timer.ddj`,
  `icon\skill\etc\tc_reserve_buff.ddj`, `vietnam_condition_*.ddj`, …); kinds 3/4/5 an item's
  `+0x15c` with `_off.ddj`; kinds 10/13/14 item or table strings. None of these is built here.

**The files** (MEASURED, Media.pk2 on the box; the DDS headers of all 622 `icon\skill\` files):

| Size | Format | Mips | Count |
|---|---|---|---|
| 32 × 32 | A8R8G8B8 | none | 441 |
| 32 × 32 | A8R8G8B8 | 6 | 4 |
| 32 × 32 | X8R8G8B8 (alpha mask 0) | none | 4 |
| 32 × 32 | A1R5G5B5 | none | 159 |
| 32 × 32 | A4R4G4B4 | none | 2 |
| 32 × 32 | DXT3 | 6 | 12 |

- The four A8R8G8B8 files with mips are `bow_balance_a`, `light_holy`, `spear_balance_a` and
  `sword_balance_a`. Their pixel-format flags are 0x41 (RGB | ALPHAPIXELS), with masks. The FourCC
  slot holds a stray 21, which is ignored because the FourCC flag is clear. Round 624 first read
  that 21 as the format, which was wrong (corrected in the review follow-up).
- `DdjReader` takes the mask path for them, as it does for every uncompressed file, so all 622
  decode.

- Every skill icon is 32 × 32. No `icon\small\`, `_s` or low-resolution twin exists. Data.pk2's
  41 paths containing `icon\` are sounds, and Map, Particles and Music have none.
- `icon\stateodd\` holds the four gauge strips (20 × 4), 24 abnormal-state icons (32 × 32 by their
  2196-byte size; `s_stun_icon`'s header was read),
  `s_goldtime_icon` and `s_silvertime_icon` (20 × 20, A1R5G5B5), and the two admittance sprites
  (20 × 20, A8R8G8B8).

**How a 32 × 32 file becomes 20 × 20 pixels** (READ):
- The icon child is a CIFStatic. Its draw is 0x64d940 → CIFWnd's 0x6550c0 → the `+0x84` object's
  vslot 2, 0x655d50 → vslot 11, 0x654c30. That draw sets FVF 0x104 (XYZRHW | TEX1) and the
  texture, then draws a two-triangle fan. **It sets no sampler state.**
- The quad's edges are the window's rect, each minus 0.5 (0x6529d0: `fsub` of the double 0.5 at
  0xe1b7d0; the far edges are `round(x + scale × w) − 0.5`). Its UVs are 0..1, set by the base window's constructor (0x654661..0x6546bf, before 0x653060 copies them into the vertices; 0x806d50's own UV call at 0x807036 is the `lnks` frame's, `+0x37c`). So
  screen pixel k of 20 samples u = (k + 0.5) / 20: D3D9's texel-to-pixel correction, which puts
  pixel k on texel coordinate (2k + 1) × 32 / 40.
- The UI pass (0x8408c0) sets ADDRESSU/V to CLAMP and MIPFILTER to NONE. The DDJ loader (0xb87f20)
  keeps the file's own mip count. So even the 16 files that carry mips draw from level 0.
- Stage-0 MIN and MAG are left as the previous draw set them. The sampler cache is 0x4784b0
  (`this` 0x1112428, cache at `+0x828 + (stage × 13 + state) × 4`: MAG 0x1112c64, MIN 0x1112c68).
  Some paths write that cache and the device inline.

**The draw order before the board** (READ, round 624's review):
- A window's children draw in list order (0xba0300).
- The interface file's windows reach the list in reverse file order: 0xb3e4d0 prepends each entry
  as it parses `ginterface.txt`, and 0xb90a80 then appends them in that order.
- `GDR_MAGICSTATEBOARD` is line 438 and `GDR_PLAYER_MINI_INFO` is line 457. So the board draws
  immediately after the whole `GDR_PLAYER_MINI_INFO` subtree.
- That subtree's labels are `TXT_ID`, `LEVEL`, `HP` and `MP`. Each is a CIFStatic, drawn by
  0x64d940, whose text goes through 0x8b48b0 → 0x8b2290.
- 0x8b46d0 sets a text board's scale (`+0x3c`) to 1.0. At |scale − 1.0| ≤ 0.1, 0x8b2290 sets MIN
  and MAG to **POINT** (`fcomp` against the double 0.1 at 0xe1b8c0, `test ah,0x41` at 0x8b2447).
- 0x8b48b0's tail (0x8b4d0b..0x8b4d77) restores the texture-stage states, not the filters.
- Nothing between that label and the icon sets a filter: the board and its slots (0x6550c0,
  `CIFStateSlot::vslot_015` 0x8071c0), the CIFGauge (0x6387d0, textless) and the icon's sprite draw.
- **So the icon is point-sampled (READ, for retail's default window order).**

**Every filter setter** (stage-0 MIN/MAG):

| Where | Leaves | What |
|---|---|---|
| 0x8b2290 (via 0x8b48b0) | POINT at scale 1.0, else LINEAR | CIFStatic label text; not restored |
| 0x493460 (via 0x476c80) | POINT at scale 1.0, else LINEAR | the CNIF text twin; not restored by its bare callers |
| 0x8b4d90 | LINEAR | wraps 0x8b48b0 and restores LINEAR; reached from 0x819040 and 0x62f910, among others |
| 0x4771a0 | LINEAR | wraps 0x476c80 and restores LINEAR |
| 0x49a7d0 | LINEAR at its tail | `CNIFStretchWnd` frames: POINT for its own draw, then LINEAR |
| 0x819d80 | LINEAR | a UI_SILKMALL draw |
| 0x4ffc50, 0x560c30/0x560db0, 0x6ad860, 0x7bff70, 0x7ee800 | **POINT** | the five 3D preview widgets (`CIFRenderStatic`, `CIFEquipment`, `CIFItemMall`, `CIFChangePlayerModel`, and 0x4ffc50). Each sets LINEAR for its model and **restores POINT** after it (0x4fffe7, 0x560de1, 0x6adb68, 0x7c02cd, 0x7eea84) |
| `CGame::vslot_015` | LINEAR | stages 0–2, the device's initial state |

The world passes (`SWorld`, `Map`, `CObjRendererVS`) set their own filters before the UI pass.

**Four assumptions remain:**
- (a) **No bring-to-front reorder.** The order above is the default, from the file. A window
  brought to the front, for example by a click, moves in the list. That is not modelled.
- (b) **No other text-scale writer.** Only 0x8b46d0's 1.0 was found for the HUD labels.
- (c) **State blocks and D3DX effects were not audited.** A stateblock `Apply` or an effect's
  `Begin`/`End` could set sampler state without going through the calls above.
- (d) **The labels have on-screen text.** A label with no text, or text clipped off-screen, draws
  no glyphs and sets nothing. The HUD's name, level, HP and MP always have text in game.

- The effect is that retail shows 20 of the 32 columns and rows, texels 0 2 4 5 7 8 10 12 13 15 16
  18 20 21 23 24 26 28 29 31, with no blending. That is the "lower resolution" look.

**srrevamp** (`HudBuffBoard.AUTHENTIC_ICONS`, a static var, on):
- The icon's Image is read with `UiBuilder.load_image`. `HudBuffBoard.retail_icon_image` samples it
  once, in integer arithmetic, to those 20 × 20 texels, and the result is drawn with
  `TEXTURE_FILTER_NEAREST`.
- At UI scale 1 this is retail's picture, pixel for pixel. At other scales it is those
  20 × 20 pixels enlarged. That choice is OURS: retail draws its UI 1:1 and has no scale.
- The four texels on an exact boundary (k = 2, 7, 12, 17) resolve by floor. That the GPU's float
  interpolation lands the same way is INFERRED.
- With `AUTHENTIC_ICONS` false, the board draws the 32 × 32 file with the canvas's default linear
  filter and no mipmaps, as rounds 618–623 did.
- The gauge (20 × 4) and the burst (a 50 × 52 cut) are drawn at their native size and are
  unchanged.

**The skill window and the hotbar** (READ): they draw the same 32 × 32 files through the same sprite
path, into 32 × 32 slots. So each pixel lands on a texel centre, and POINT and LINEAR give the same
picture. srrevamp's `hud_panels.gd` (`SKILL_CELL` 32) and `hud_underbar.gd` (32 × 32) already draw
them 1:1 with the canvas's linear filter, which matches at UI scale 1. They are unchanged.

## The gauge (0x8056a0 per frame; 0x638310 and 0x6387d0)

- Each frame: `elapsed += frame ms`, clamped at total.
- The value is `(total − elapsed) / total`, written to both the value (`+0x380`) and the target (`+0x384`). The easing in 0x638310 therefore has nothing to ease.
- 0x653140 scales the right edge's x and its u by the value, which is a crop from the left. That it is a crop is INFERRED from the two products.
- **A full gauge shows 18 coloured pixels, not 20, in retail too** (round 616-618 integration). The fill texture `s_stateodd_time_gauge.ddj` is opaque only in its first 18 columns and first 2 rows (`83e6ff` over `00cdff`); columns 18-19 and rows 2-3 are alpha 0 (MEASURED, every texel dumped). The back `s_stateodd_time.ddj` is black and opaque in rows 0-2, transparent in row 3. Since 0x653140 moves x and u together, value 1.0 draws the whole texture and the last two columns show the back. The live frames' 18 is therefore right, not a bug.
- There is no blink, threshold or colour change.
- For a normal buff the client never removes the icon by itself. When the time runs out it waits for the server's end, 0xB072 in retail and `OpBuffEnd` here. Only the special skill id `0xc0000000` removes itself.

## The end (0x804b30, then 0x8068f0, 0x8065d0 and the slot's timer 0x806790)

A main-list buff that ends goes through these steps:
1. Its token is zeroed.
2. The 50 × 52 overlay is placed at `((20 − 50) >> 1, (20 − 52) >> 1) = (−15, −16)` from the slot, which centres it on the icon. It shows frame 0 of `icon\buf_effect.ddj`, a sheet 512 × 64 in size (MEASURED). Frame i's UV is `(50i/512, 0)–(50(i+1)/512, 52/64)`.
3. Both gauges are hidden, and timer 1 starts at 100 ms.
4. `prim\snd\ui\buf_disappear.wav` plays at 1.0 (soundMgr vslot `+0x30`). The file is in Data.pk2.
5. On each tick the frame advances. After tick 3, the slot's own alpha (its `+0x84` object) drops by 0x55, and is set to 0 once it is below 0x56. So the alpha runs 255, 255, 255, 170, 85, 0, 0, 0.
6. At tick 9 (900 ms) the slot is flagged done (`+0x384 = 2`), and the next board update erases it and lays the grid out again.

INFERRED: the overlay is its own child window, so it does not fade with the icon.

**New**: a second-list buff that ends is erased and laid out at once, with no overlay and no sound. The second loop of 0x804b30 (0x804c60) calls only 0x7fda70, 0x803f20 and 0x7ffc10.

## Right-click (`vslot_033`, 0x800820, the WM_RBUTTONUP case)

1. Only the main list is hit-tested (0xb8f3d0 per slot), at the point where the button came **up**. A slot's rect is 20 × 24, the icon plus its gauge. srrevamp tests the release point against every main-list slot. Godot delivers the release to the slot the press was on, so a press on one icon and a release on another cancels the other, and a release off every icon does nothing.
2. A slot whose `+0x386` is 1 (already ending) does nothing.
3. The entry must be kind 1, a skill buff.
4. If the skill has `nbuf` and no `lnks`, nothing happens.
5. `0x93f5d0(skill)` must be non-null, on both paths. Its first dword must not be `0xc0000000`, but that test is on the **send path only**; the `cbuf` box opens regardless. What this lookup is, is OPEN, and srrevamp does not model it.
6. If the skill has `cbuf`, box 0x6ec5d0 opens instead, with type 0x20 and an empty text (`DAT_00e17460`). The box is 308 × 148 and centred.
7. Otherwise the client sends 0x7074 `01 05 u32 skill [u32 lnks word] 00` (0x81c5b0). srrevamp sends `OpBuffCancel` 0x00F7 through `NetClient.send_buff_cancel`.

What box type 0x20's OK does was not read. srrevamp's OK sends the cancel, which is INFERRED. The box's text is OPEN, so srrevamp's box is titled with the client's own `UIIT_STT_CONFIRM_BOX` ("Confirmation window") and has an empty body (OURS).

## The tooltip (0x800a10, kind 1)

The tooltip's lines are, in order:
1. `"%s %s %d"`: the name (`+0x128`, resolved), `UIIT_STT_LEVEL_LV`, and the level (`+0x60`).
   - A few mall and fortress skills show the name alone: `SN_SKILL_MALL_PRE_APRU_4W`, `SN_SKILL_ASSAULTING_SOILDER`, `SN_SKILL_CENTURION`, `SN_SKILL_MALL_PET_*` and others.
   - Each is compared at its full length (the first against 0x19 characters, the rest through 0x47ec20 / 0x47ea60 with their own lengths), which is equality (READ). srrevamp compares for equality.
2. `"(%s)"` with `UIIT_TOOLTIP_OPERATION_STOP` ("Not affected"), in colour 0xffff4a4a, when the slot's `+0x36c` is set. What sets that byte is OPEN, so srrevamp does not draw this line.
3. The description (`+0x15c`, resolved).
4. `"%s : %s"`, which is `UIIT_STT_TARGETTING` ("Target ") and a name, when entry `+0x44` is non-zero. OPEN, not drawn.
5. When total ≠ −1, a time line, where r = total − elapsed in ms:
   - r < 60 000 (or negative): `"%s %d%s"`, which is `UIIT_STT_REMAIN_TIME`, r / 1000, `PARAM_SECOND`. For example "Remaining time 45Second".
   - r < 3 600 000: `"%s %d%s %d%s"`, which is REMAIN_TIME, r / 60000, `PARAM_MINUTE`, (r % 60000) / 1000, `PARAM_SECOND`.
   - Otherwise: `"%s: %d%s %d%s %d%s"`, which is REMAIN_TIME, r / 86400000, `PARAM_DAY`, (r % 86400000) / 3600000, `PARAM_HOUR`, (r % 86400000 % 3600000) / 60000, `PARAM_MINUTE`. Only this form has the colon.

Every key is in the box's `textuisystem.txt` (MEASURED). The English texts are "Lv", "Remaining time", "Day", "Hour", "Minute" and "Second". There is no space between a number and its unit, which is the format's own spelling.

## Where the flags come from (READ and MEASURED; round 618 and its review)

**The files retail loads** (READ, `Client_LoadAllRefData` 0x844cd0): the list `textdata\skilldataenc.txt`, which names `SkillData_1000ENC.txt` to `SkillData_47000ENC.txt` in order.

**The encryption** (READ):
- The lazy loader 0x93ef10 reads a row at its recorded offset.
- If the file ends in `"\r\n//encrypt"` (UTF-16), it calls 0x4f5140(buffer, size, 0x8c1f, offset).
- For each byte at file position p, with k = 0x8c1f + p: `byte += T2[k % 0xa7] − T1[k % 0x1ef]`.
- T1 is 495 bytes at 0xeae758 and T2 is 167 bytes at 0xeae948, both in the executable's `.data`.
- Decrypting the box's 47 ENC shards this way gives the plain-text tables (MEASURED). The key tables are the executable's own and are not copied into the repo. The client reads the plain twins instead.

**The plain twins** (MEASURED on the box):
- Each ENC file has a twin, `skilldata_<n>.txt`: the list entry with `ENC` removed.
- The 47 files overlap:
  - `skilldata_5000` … `skilldata_30000` are 5000 wide, each repeating the five 1000-wide files below it;
  - `skilldata_35000` holds 30000–46422;
  - 38000–43000 are empty.
  - So id 40000 is only in 35000. The first build's "one 1000-wide shard per id" mapping missed every id that only a wide file holds, among them every id from 37000 to 44147.
- Duplicates:
  - 27,697 ids appear more than once in the plain files. Only one disagrees: 35958, where shard 35000 has no tags and shard 36000 has `nbuf`+`bbuf`.
  - In the decrypted ENC set, 27,714 ids appear more than once and none disagree. So retail's duplicate rule, which was not read, does not matter for retail's own data.
- srrevamp resolves a duplicate to the **first file in list order**. With that rule, every one of the ENC set's 33,632 ids gets exactly the ENC row's four tags, level, icon, name code and description code from the plain files: 0 missing, 0 differences, checked by the catalog itself on the box.
- The plain files also have 66 ids the ENC set lacks. They are harmless.

**The walk** (READ, the client's parser `GlobalDataManager::FUN_009bbca0`):
- The Param block starts at column 69 (0-based).
- The cursor starts at index 1 and stops past index 0x31, so at most 49 words. Real rows reach index 40 at most (MEASURED).
- `ssou` and `sstt` both end the block. A zero word is skipped. A code the parser has no branch for is never advanced past.
- The run table is the **client's**, 188 codes. It differs from the server's `skillparam.Run` in `bldr` (5 in the client, 4 in the server), in `fitp` (2, not 1), and in 19 codes the server lacks.
- `cbuf`, `nbuf` and `bbuf` are markers, run 1. **`lnks` is a run of 5.**
- `server/internal/skillparam/client_table_test.go` guards the copy in `skill_buff_catalog.gd`.
- Every one of the 61,395 plain rows walks to completion with this table.

**The census** over the ENC set's 33,632 ids:
- `cbuf`: 473
- `nbuf`: 284
- `bbuf`: 225
- `lnks`: 294

These match the spec. The first build counted the plain files with duplicates unresolved (285 / 226 / 308).

**When the index is built:** once per world entry.
- The 47 shards are read on the main thread in about 23 ms, or 90 ms counting the directory lookups.
- They are parsed on a WorkerThreadPool task in about 2.1 s. The longest frame measured while it ran was 7 ms.
- A buff that arrives before the index is ready is held, then placed with its wait taken off its time left (OURS).

**Samples:**
- Grass Walk A lv1 is id 113 (`lightning_gyeonggong_a.ddj`) and has none of the four tags.
- `cbuf`: id 93, `SN_SKILL_CH_COLD_GANGGI_A`.
- `nbuf`: id 155, `SN_SKILL_CH_WATER_HARMONY_A`.
- `bbuf`: id 157, `SN_SKILL_CH_WATER_CANCEL_A`.
- `lnks`: id 34917, `SN_SKILL_CH_SWORD_DAMAGE_DIVIDE_A`.

## Whose buff it is (round 618's review, with round 617's OpSelfId)

- A buff start is shown only when it is the player's own: the owner kind is 0 (a character), and the owner id is the one `World3D._sync_own_id` settles on. That is OpSelfId's id (`NetClient.own_character_id`) when the server sent one, otherwise the id the sit answer taught.
- With no id yet, no buff is shown. The first build's fallback, "neither another body nor a monster", is gone.
- An end is matched by token alone, since tokens are unique on the server.
- The board is cleared, with no bursts, on every successful `enter_world_result`, which covers re-entry and a character switch.
