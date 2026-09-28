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
- The slot is then sized to width × (20 + the gauge's height).
- Kind 3 (item time) entries use `s_stateodd_time02_gauge.ddj` and a second gauge. They are not built here.
- A skill with `lnks` gets a frame cut from `interface\ifcommon\window_all.ddj` at `{-2, -2, w+4, h+4+gauge}`, using the UV constants at 0xdd07a0..0xdd07b0. This is not drawn here: which constant is which corner is OPEN.

## The gauge (0x8056a0 per frame; 0x638310 and 0x6387d0)

- Each frame: `elapsed += frame ms`, clamped at total.
- The value is `(total − elapsed) / total`, written to both the value (`+0x380`) and the target (`+0x384`). The easing in 0x638310 therefore has nothing to ease.
- 0x653140 scales the right edge's x and its u by the value, which is a crop from the left. That it is a crop is INFERRED from the two products.
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

1. Only the main list is hit-tested.
2. A slot whose `+0x386` is 1 (already ending) does nothing.
3. The entry must be kind 1, a skill buff.
4. If the skill has `nbuf` and no `lnks`, nothing happens.
5. `0x93f5d0(skill)` must be non-null and must not be `0xc0000000`. What this lookup is, is OPEN, and srrevamp does not model it.
6. If the skill has `cbuf`, box 0x6ec5d0 opens instead, with type 0x20 and an empty text (`DAT_00e17460`). The box is 308 × 148 and centred.
7. Otherwise the client sends 0x7074 `01 05 u32 skill [u32 lnks word] 00` (0x81c5b0). srrevamp sends `OpBuffCancel` 0x00F7 through `NetClient.send_buff_cancel`.

What box type 0x20's OK does was not read. srrevamp's OK sends the cancel, which is INFERRED. The box's text is OPEN, so srrevamp's box is titled with the client's own `UIIT_STT_CONFIRM_BOX` ("Confirmation window") and has an empty body (OURS).

## The tooltip (0x800a10, kind 1)

The tooltip's lines are, in order:
1. `"%s %s %d"`: the name (`+0x128`, resolved), `UIIT_STT_LEVEL_LV`, and the level (`+0x60`).
   - A few mall and fortress skills show the name alone: `SN_SKILL_MALL_PRE_APRU_4W`, `SN_SKILL_ASSAULTING_SOILDER`, `SN_SKILL_CENTURION`, `SN_SKILL_MALL_PET_*` and others.
   - srrevamp compares these for equality. The binary's length-bounded compares were not fully read (INFERRED).
2. `"(%s)"` with `UIIT_TOOLTIP_OPERATION_STOP` ("Not affected"), in colour 0xffff4a4a, when the slot's `+0x36c` is set. What sets that byte is OPEN, so srrevamp does not draw this line.
3. The description (`+0x15c`, resolved).
4. `"%s : %s"`, which is `UIIT_STT_TARGETTING` ("Target ") and a name, when entry `+0x44` is non-zero. OPEN, not drawn.
5. When total ≠ −1, a time line, where r = total − elapsed in ms:
   - r < 60 000 (or negative): `"%s %d%s"`, which is `UIIT_STT_REMAIN_TIME`, r / 1000, `PARAM_SECOND`. For example "Remaining time 45Second".
   - r < 3 600 000: `"%s %d%s %d%s"`, which is REMAIN_TIME, r / 60000, `PARAM_MINUTE`, (r % 60000) / 1000, `PARAM_SECOND`.
   - Otherwise: `"%s: %d%s %d%s %d%s"`, which is REMAIN_TIME, r / 86400000, `PARAM_DAY`, (r % 86400000) / 3600000, `PARAM_HOUR`, (r % 86400000 % 3600000) / 60000, `PARAM_MINUTE`. Only this form has the colon.

Every key is in the box's `textuisystem.txt` (MEASURED). The English texts are "Lv", "Remaining time", "Day", "Hour", "Minute" and "Second". There is no space between a number and its unit, which is the format's own spelling.

## Where the flags come from (MEASURED, round 618)

- **The shards.** `server_dep\silkroad\textdata\skilldata.txt` lists 47 shards, `SkillData_1000` to `SkillData_47000`. Shard `k*1000` holds the ids `[(k−1)*1000, k*1000)`. This was checked on shards 1000, 2000, 3000, 31000 and 47000. The older 5000-wide files (`skilldata_5000.txt` and so on) overlap them; one per-level id range per 1000 is what the list names.
- **The walk.** The Param block starts at column 69 (0-based). It is walked with `skillparam.Run`, copied into the client and guarded by `server/internal/skillparam/client_table_test.go`.
- **The census.** Walking the 47 shards: 33,698 rows, and **every walk completes**. The tags occur in:
  - `cbuf`: 473 rows, the same as the spec.
  - `nbuf`: 285 rows. The spec had 284.
  - `lnks`: 308 rows. The spec had 294.
  - `bbuf`: 226 rows.
  The spec counted a different row set: the server's seven legacy shards, 33,632 rows.
- **Samples:**
  - Grass Walk A lv1 is id 113 (`lightning_gyeonggong_a.ddj`) and carries none of the four tags.
  - `cbuf`: id 93, `SN_SKILL_CH_COLD_GANGGI_A`.
  - `nbuf`: id 155, `SN_SKILL_CH_WATER_HARMONY_A`.
  - `bbuf`: id 157, `SN_SKILL_CH_WATER_CANCEL_A`.
  - `lnks`: id 34917, `SN_SKILL_CH_SWORD_DAMAGE_DIVIDE_A`.
