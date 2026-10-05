# Round 731 review: item tooltips, lane A

Reviewer: an independent adversarial pass over `dev..ca1708c3`, the bubble
(`ItemTooltipBubble`), its lines (`ItemTooltipLines`), `ItemTypeNames`,
`ItemTooltipInstance`, the new item columns in both readers, and the item sites.

Evidence came from four sources:
- the client decompile (`/var/tmp/decomp_client`) and its disassembly (`sro_client.asm`);
- the constants read out of `sro_client.exe`;
- the real itemdata rows on the box's `Media.pk2`, extracted to `/var/tmp/r731rev` and deleted afterwards;
- `XjjJyA5.png`.

No code was changed.

The lane's frames are no longer on the box or the workstation, and the notes name no path. So
none of the round's sharpness, stem or pitch numbers could be re-measured from its renders. The
pixel checks below are against the original only.

## Findings, most severe first

### 1. BUG: armour and shields miss their Phy./Mag. reinforce lines (cols 82-85 not read)

- **Where:**
  - `client/scripts/ui/hud/item_tooltip_lines.gd:286-300`;
  - `client/scripts/npc/item_table_reader.gd:129-165` (no column 82-85);
  - `native/src/core/tables.rs` `ITEM_EXT_*`;
  - `client/scripts/ui/hud/item_tooltip_instance.gd:105-115`.
- **Evidence:**
  - **The binary prints the single-value reinforce line for these items.** `0x66c5b0` prints `"%s %.1f %% (+%d%%)"` with `PARAM_PHYSICAL_SPECIALIZE` when the computed stat's weapon reinforce pair (`+0x34/+0x38`) is zero and `+0x44` is not. It rates that line against ref `+0x224/+0x228`, and does the same for `PARAM_MAGICAL_SPECIALIZE` with `+0x48` and ref `+0x22c/+0x230`.
  - **Those fields are columns 82-85.** The client's itemdata row parser is `GlobalDataManager::FUN_00975a10`, whose object is the ref plus 0x10. It stores columns 82, 83, 84 and 85, divided by 1000.0 (`0xd83268`), at parser `+0x234..+0x240`, which is ref `+0x224..+0x230`. That is PDStr_L/U and MDInt_L/U.
  - **The data has them on every armour and shield row.** All 6,309 rows of families 1, 2, 3, 4, 9, 10 and 11 have non-zero 82-85, for example ITEM_CH_M_CLOTHES_09_CA_C_RARE: 222 / 231 / 473 / 492.
  - **Neither reader reads them.** `ItemTooltipLines` only knows the weapon pair (105-112), so every armour and shield tooltip lacks "Phy. reinforce 22.2 % (+x%)" and "Mag. reinforce 47.3 % (+x%)". The shown value is the column / 1000 × 100 (`0xe1b7d8` = 100.0), so col/10.
  - **Lane B is ready for them.** `ItemQuality.GROUPS` already has armour and shield `phys_reinforce` / `mag_reinforce` (groups 1/2), so the instance path drops them too.
- **Fix:**
  - Read 82-85 in both readers and in `table_parity`.
  - In `_stats`, when the weapon pair is zero and the armour pair is not, print the single form from 82/83 (84/85 for magic), with the percent on [L, U].
  - Add the same pair to `ItemTooltipInstance`, using `float_stat` with no plus.

### 2. BUG: a store's goods show "Store purchasing price N", the wrong key and format

- **Where:** `client/scripts/ui/hud/item_tooltip_lines.gd:333-338`, and the store site `hud_panels.gd` `_fill_shop_grid`.
- **Evidence:**
  - **The key the lane used is the store's buying price.** In `0x6784a0`, `PARAM_STORE_PURCHASE_PRICE` "Store purchasing price" (`"%s %d"`, ref sell price `FUN_008ba460` × count) is printed only for slot kinds 0x46/0x47/0x21, and only while a store window is open (`FUN_00778a30`). That is the price the store pays for **your** item.
  - **The store's own slot prints a different line.** For slot kind 0x0f (the store, round 652's `0x6b5b80`), the branch at `0x678cf2` prints `"%s : %I64d%s"` with `UIIT_STT_PRICE` "Price" and `UIIT_STT_GOLD` "Gold", taking the goods record's price (`+8`, through `FUN_006fc910` when discounted).
  - Every store item now reads "Store purchasing price 40" where the original reads "Price : 40Gold".
- **Fix:**
  - Store goods: `"%s : %d%s"` with `UIIT_STT_PRICE` / `UIIT_STT_GOLD`.
  - Re-read whether that branch writes a blank before the line. None was seen between `0x678cf2` and the `0x776d20` call.
  - Keep `PARAM_STORE_PURCHASE_PRICE` for bag items while a shop is open: the ref price × quantity. It is not built (OPEN).

### 3. BUG: European equipment shows no requirement lines

- **Where:** `client/scripts/ui/hud/item_tooltip_lines.gd:309-331` (`_requirements`) and `item_table_reader.gd:318` (`required_character_level`).
- **Evidence:**
  - **The binary prints a line for every requirement pair.** `0x67eec0` loops the four `ReqLevelType/ReqLevel` pairs (ref `+0xd0/+0xe0`):
    - type 1 → `PARAM_REQ_LV`;
    - types 2/3/4 → job grade;
    - 0x101..0x114 and 0x201..0x206 → `"%s: %s %s %d"` with `PARAM_MASTERY_LEVEL`, the mastery name (`UIIT_STT_WARRIOR`, `_ROG`…) and `PARAM_MASTERY`.
  - **All the loop's lines share one colour:** white when any of them is met (`cStack_585`), else red (`0x67fe..`).
  - **The data has them.** 2,910 European equipment rows have mastery pairs and no level pair, for example ITEM_EU_W_LIGHT_01_HA_A: 513/1, 515/1, 518/1.
  - **We print none of them.** `_requirements` only prints the character-level pair, so these items show no requirement line at all. The notes and the spec do not disclose the omission.
- **Fix:**
  - Walk all four pairs as `0x67eec0` does: level, job grade and mastery. Use one colour for the loop's lines.
  - Do it at least for the mastery types the archive uses (0x201-0x206). Label the job-grade types OPEN if they are not built.

### 4. BUG (carried over): an emptied storage cell keeps the old item's tooltip

- **Where:** `client/scripts/ui/hud/hud_panels.gd:2709-2717` (`_fill_storage_grid`'s clear loop).
- **Evidence:**
  - **The cell is cleared but not disarmed.** The loop sets `icon0.texture = null` and drops the `wh_*` metas. It neither calls `_set_item_tip(icon0, -1)` nor resets `mouse_filter`, which the filled path set to STOP.
  - **So the bubble comes back.** Hovering a cell whose item was withdrawn, or a cell on a page that is now empty, shows the previous item's bubble.
  - **It is not new, but it is now visible.** `dev` never cleared the storage `tooltip_text` either. The round claims every site is wired.
- **Fix:** in the clear loop, `_set_item_tip(icon0, -1)` and `icon0.mouse_filter = Control.MOUSE_FILTER_IGNORE`.

### 5. WRONG-LABEL: "Sort of item"'s source is not read, and the one reference contradicts it for Europe

- **Where:**
  - `client/scripts/ui/hud/item_type_names.gd:7-15`;
  - `docs/protocol/item_tooltip.md` "Round 731 (lane A) additions";
  - `docs/rounds/r731.md` "ItemTypeNames".
- **Evidence:**
  - **How the builders look the name up.** They call `FUN_00941240(out, TypeID word, ref+8)`, which tries two maps in turn:
    - first `FUN_009411d0`, a map keyed by the ref's string at `+8`, at owner `+0x6b8`;
    - then `FUN_0093acb0`, a map keyed by `TypeID & 0xfffe` whose node holds a **string** at `+0x10`, at owner `+0x6a8`.
  - **The round did not read that map.** What fills `+0x6a8` is unread. `RefParse_fmntidgroupmapdata` (`0x6d5570`) stores a group number, not a string. The fmn join is a measured 1:1 join, not the binary's lookup.
  - **The reference screenshot disagrees.** `XjjJyA5.png` prints "Sort of item: Twohand staff". That is `UIIT_CTL_WNETWORK_EU_TSTAFF`'s text in this archive's `textuisystem.txt`. The fmn join gives `UIIT_CTL_WK_EU_WEAPON_TSTAFF` = "Staff". Esro is a modified client, so this is a contradiction to settle, not proof.
  - **The label is wrong.** The code comment says the client "packs the four TypeIDs into the item type word the tooltip looks the name up by", but no read connects fmntidgroupmapdata to the tooltip.
- **Fix:**
  - Label the type name INFERRED (fmn join) and add it to OPEN.
  - Find the writer of the `+0x6a8` map (an insert of a ushort key with a wstring value) and of the `+0x6b8` code-name map before treating the name as settled.
  - Until then, add a test-free note that the European names may be the WNETWORK set ("Onehand sword", "Light staff", "Twohand staff", "Heavy armor").

### 6. LAYOUT / WRONG-LABEL: the Tahoma-less offset is waved off with a false premise

- **Where:**
  - `docs/rounds/r731.md` "Differences": "Not tuned: the user's Windows client has Tahoma";
  - `client/scripts/ui/hud/item_tooltip_bubble.gd:179`.
- **Evidence:**
  - **The user is not on Windows.** The user plays the native Linux build at UI DPI 2.0, so their client most likely has no Tahoma either. `UiBuilder._load_fonts_uncached` then serves the disclosed Arial fallback (`vplus\vfont.ttf`), as on the box.
  - **So the measured offset is the user's offset.** The notes measured the fallback's glyphs 1-2 px higher in the line than the original's (cap top +1 against +3). At 2.0 that is 2-4 px.
  - **Nothing in the bubble depends on Tahoma's metrics otherwise.** The indent is computed from the loaded face's space, the line pitch is the binary's 18, and the width is measured. The only face-dependent thing is the label's top.
- **Fix:** place each label by baseline, not top. The original's baseline sits 12 px below the line's top (cap top 3 + 9-row cap). So `label.position.y = line_top + 12 - font.get_ascent(size)` (rounded), whichever face is loaded. Correct the notes' premise.

### 7. MINOR: "Max. no. of magic options" is hidden at 0; the binary prints it always

- **Where:** `client/scripts/ui/hud/item_tooltip_lines.gd:190`.
- **Evidence:** all four builders (`0x6827c0`, `0x683040`, `0x682ba0`, `0x682df0`) call `0x66e030` unconditionally, and it formats `"%s: %d%s"` from ref `+0x534` with no test. Fourteen weapons (the ITEM_FORT_FORTRESS_HAMMER/AXE rows) have 0 and would read "Max. no. of magic options: 0Unit".
- **Fix:** drop the `> 0` test.

### 8. MINOR: the reinforce form is chosen by equal ends, not by the binary's test

- **Where:** `client/scripts/ui/hud/item_tooltip_lines.gd:296`.
- **Evidence:** the binary uses the range form whenever the weapon pair `+0x34/+0x38` is non-zero, even when the two ends are equal. 215 weapons have equal phys-reinforce lower ends (cols 105 = 107). On those, ours prints "Phy. reinforce X %" where the binary prints "X % ~ X %".
- **Fix:** range form for the weapon columns, single form for 82-85 (finding 1).

### 9. MINOR: stale or open labels

- **`item_tooltip_lines.gd:8`** still says blank entries are "the group breaks the bubble draws as rules". The round corrected that.
- **The spec's §5 gap 1** ("no frame, icon or rules") and **OPEN 2** ("the rule drawing") are not updated to the correction.
- **`0x66f850` (r731 OPEN 2, spec row 6) can be closed.**
  - It prints the ref's string at `+0x7c`, column 6 (`DescStrID128`), through the object text table (`FUN_008c9bb0`), in white, then a blank, when it resolves.
  - Only 14 four-family rows resolve to text (the fortress weapons' `SN_ITEM_FORT_FORTRESS_*_TT_DESC`), so it is cheap to add.
- **The reference path adds `roundi(inc × plus)` (`_stats:232-238`).** Lane B read `trunc` (`0x8bdb75`). It is only reachable through `item_instance_lookup` with a plus and no stats, but it should match.

## What was verified (holds)

- **The order (USER DECISION, binary order) matches the builders.**
  - The weapon, armour, accessory and shield builders all run the same sequence: `0x67a570` name (with a blank when printed), `0x66fa60` seal/set, Sort of item (beige), the armour position (armour only, 6 keys), `0x66f0c0` degree, a blank, `0x66f850` with a blank when present, `0x66c5b0` stats, `0x67eec0` requirements, `0x66e030`, `0x6780c0`, `0x66fd60`, `0x6784a0`.
  - In `0x66fa60` the seal line comes before the set line, and the extra blank before the set line comes only when there was no seal.
- **The colours and keys hold.**
  - **Name.** Gold is `-0x26ad` = `0xffffd953`; pink is `0xffff9c9f - 0x26ad` = `0xffff75f2` under `0x8bd660`; cyan is `-0xff1501` = `0xff00eaff`, under `0x8ba5d0`, the instance's `+0xa4`.
  - **Seal.** `0x8ba600` tests ref `+0xa0` for 2 or 6, and the parser puts column 15 at byte `+0xa0`. The tier is `0x8ba6e0`, ItemClass mod 3. The `cmp byte [esi+0x1d0],0x1f; jb` picks `PARAM_RARE_FIRST2` (`0xda217c`) from 31.
  - **Set.** `0x8ba620` returns rarity, `> 2`; the line is green `0xff6ce675` with font 3.
  - **Beige.** `0xffefdaa4`.
  - **Requirements.** The red/white expression `(c - 1 & 0xb5b5) - 0xb5b6` gives `0xffff4a4a` or `0xffffffff`.
  - **Advanced elixir.** "Able to use Advanced elixir." is `0xffc8c8c8` with font 3; "used" is white with font 3 (`0x66fd60`).
- **The stat block holds.**
  - The order and formats are `0x66c5b0`'s: PA, MA, PD, MD, PR, MR, Dur, Range, HR, ER, CR, BR, PS, MS.
  - Durability is red `0xffff4a4a` at 0.
  - The range is divided by 10.0 (`0xe1b840`) and the reinforce is shown × 100.0 (`0xe1b7d8`) after the parse's / 1000.0.
- **The Int slip is real.**
  - Both the decompile and the instructions show it. At `0x680019`, `mov ecx,[eax+0x1c8]` feeds the `PARAM_INT` line's `"%s %d"`. The colour compares the player's `+0x87e` with ref `+0x1cc` (`0x680087`).
  - It can never show on this archive: ReqStr and ReqInt are 0 on all 11,351 equipment rows.
- **Gender and race hold.** The gender line comes before race, as in `0x67eec0`. `+0x1c4` 0 is `UIO_NEWCHAR_CTL_FEMALE` and 1 is `_MALE`, which matches `REQ_GENDER_WOMAN = 0`.
- **Every new column holds against the client's own row parser.** `FUN_00975a10` reads after `FUN_00972910`, and its object is the ref plus 0x10 (anchors: ref `+0x254` = col 94, the range the tooltip reads; ref `+0x1d4` = SetID, used for the set visual; ref `+0x534` = `0x66e030`'s byte).
  - **Requirements and class:** 58 gender, 59 Str (`+0x1c8`), 60 Int (`+0x1cc`), 61 ItemClass (byte `+0x1d0`), 62 SetID (`+0x1d4`).
  - **The (L, U, Inc) block:** 63/64 durability; 65-67 PD and its Inc; 68/69 ER and 70 its Inc; 71-73 PAR; 74/75 BR; 76-78 MD; 79-81 MAR.
  - **Attack:** 95-98 phys attack and 99 its Inc; 100-103 mag attack and 104 its Inc; 105-112 reinforce.
  - **Hit and critical:** 113/114 HR and 115 its Inc; 116/117 CHR.
  - **Then** a 20 × (int, string) loop, and 158 MaxMagicOptCount at parser `+0x544`.
  - Rarity 15 is at `+0xa0` in `FUN_00972910`.
- **The real rows hold.**
  - **4116 Reaper Soul Spear:** rarity 2, class 31, PA 1729/1831 and 2059/2180 with Inc 56.6, crit 5-17, range 18, max options 9.
  - **5832 Pearl Necklace seal:** absorptions 17.4/18.0, Inc 0.3.
  - **25425 the set spear:** rarity 3, set 39.
  - **Coverage:** every four-family TypeID combination has an fmn key (0 missing).
- **The lane-B adapter is sound.**
  - **It matches lane B's API by name and arity** (from `r732.md` and lane B's files): `ItemQuality.GROUPS` kinds and stat names, `int_stat`, `float_stat`, `range_int_pct`, `range_float_pct`, `single_pct`, `durability_pct` and `group_for`; `MagicOptionTable.shared`, `shared_text`, `row`, `blue_pct` and `format_line`; `ItemInstance.effective_plus()`, `adv_elixir`, `variance_group(k)`, `durability` and `option_*`.
  - **The plus goes where lane B read it.** It comes off the percent only for PD/MD/PR/MR. Hit, parry, critical and block get none.
  - **The lists line up.** NetClient's `last_inventory_instances` / `last_equipment_instances` / `last_storage_instances` are keyed by the same container slots as the durability blocks.
  - **The merge is clean.** `git merge-tree ca1708c3 worktree-agent-a1dbdde02d381b76d` has no conflict, including `item_tooltip.md` and `World3D.gd`.
  - **It is robust.** On a tree without lane B it returns `{}` and the reference path stands. The probe is cached once (`_looked`), which is fine because the files cannot appear at runtime.
- **The sites are all wired.** No item `tooltip_text` is left: the store, buy back, storage, bag and equipment all go through `_set_item_tip`, and the bag and equipment clears clear the tip. Every remaining `tooltip_text` belongs to a non-item control (skills, mastery, underbar, chat, options and so on) and is untouched. The removed `Item.tooltip_lines`, `WEAPON_SORT`, `_item_tooltip`, `_shop_tooltip` and `_fmt` have no callers left.
- **The "no rules" correction is right.** In `XjjJyA5.png` the bright rows inside the bubble (y 550-552, 574-576, 585-588, 596-598) have matching bright rows outside it, left (x 300-340) and right (x 600-715), at the same y. They are the stall window's edges seen through the 0.78-alpha fill. Away from them the fill is a flat 31.0.
- **The shadow is right.** Of the original's text pixels whose (+1,+1) neighbour is not text, 4,507 of 4,507 have that neighbour black (≤ 8).
- **The bubble mechanics hold.**
  - The frame turns correctly: the edge rotated clockwise puts column 0 (the outside) on row 0, the bottom is that flipped, the right is the edge flipped.
  - The alpha is applied through `self_modulate`, so the labels and the icon stay opaque.
  - z 4000 is under the held icon's 4096.
  - Font 3's embolden 1.4 also widens the advance, and `text_width` measures with the same face.

## Tests (this review, `RENDER_DIR=/opt/opensro-client-r731rev`, own lock)

- `cargo test --release` (workstation toolchain): **45 passed**. `native/build.sh` built the library that shipped with the box run.
- Box `check`: **630 scripts, 9 scenes, ALL LOAD**.
- Box `tests`: **240 suites, 0 failing**. This includes `item_tooltip_lines_test.gd`, whose cases encode findings 1-3's omissions as expected output, so they pass.
- `table_parity` (native vs GDScript on `/opt/sro-files/client`, with this head's library): **TABLE PARITY PASS**. Items merged 7 parts, 11,772 entries. The run reported 260 fallbacks (130 files handed back). The ones listed are empty `ref*scrapitem` / `*packageitem` tables. A per-file check that no `itemdata` part hit the new "tooltip float" fallback was not completed, because the listing was truncated.
- Frames: none to measure. The lane's renders are gone and the notes name no path. Per the brief, `qa_shot.sh` was not run.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
