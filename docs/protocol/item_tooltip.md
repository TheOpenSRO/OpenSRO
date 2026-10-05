# Item tooltips (round 730, spec)

The user (2026-10-05): "now let's work on item descriptions … The yellow/golden name means it's a Seal
item otherwise it's white or blue if there are blue stats on it … Text is hard to read and nowhere
like the original on design. My DPI is 2.0 btw. Also not all items have full descriptions when they
should." Screenshots in `/root/opensro-handoff/tooltip_refs/`: `XjjJyA5.png` (the ORIGINAL, a stall
item, Esro client), `YOoS7Lx.png` and `ijubQ8Z.png` (OURS: a spear, and a necklace with only its name,
level and country).

Labels: **READ** (sro_client.exe, address given), **MEASURED** (archive data or the screenshots,
counted), **INFERRED**, **OPEN**, **OURS**. Text keys are the stock English rows of
`textuisystem.txt` (the user's decision of 2026-10-05). No game data is in this file.

## 1. The window

| Fact | Value | Label |
|---|---|---|
| Class | `CNIFHelperBubbleWindow : CNIFStretchWnd` (RTTI), Create `vslot_010` `0x496910`, constructor `0x4967d0` (0x7c8 bytes) | READ |
| Layout | `resinfo\ifhelpbubblewindow.txt`: `GDR_HELP:CIFTextBox` (ID 10, Color 255,74,16,238), `GDR_ITEMNAME_L` / `_R` (IDs 11/12, `interface\ifcommon\com_itemsign.ddj`, 12x12, tints 255,117,111,3 and 255,47,158,106), `GDR_ITEMNAME_DIA` (ID 13, `com_diamond.ddj`, 12x12) | MEASURED (layout) and READ (`0x496955..0x4969df` creates IDs 10-13) |
| Frame | `interface\ifcommon\com_tooltip_corner.ddj` (8x8) and `com_tooltip_edge.ddj` (8x4), all eight border widths set to 8 (`+0x760..+0x79c = 8`) | READ (`0x496b0f..0x496bc4`) |
| Frame colours | A1R5G5B5 texels, outside in: transparent, black `0x8000`, light blue (107,132,206), navy fill (25,33,66), two dark inner lines (0,8,33) and (8,16,49) | MEASURED (decoded texels) |
| Window alpha | drawn with the byte at `+0x131` (`vslot_013` `0x496c00` → `0x49a7d0`); 0.77–0.78 measured on three texels of `XjjJyA5.png`, drawn as 200/255 (round 731); the byte itself | MEASURED / OPEN |
| Line height | 18 px when the box holds more than one line, 14 for one (`+0x374 = (lines != 1) * 4 + 14`) | READ (`0x496c90`) |
| Size | width = the widest line (each line's `+0x50`); height = lines x line height; the 8-px frame outside | READ (`0x496c90`) |
| Width hint | the item builders end with the textbox's slot `0x54(200, 1)` | READ (`0x685f20`); meaning (max width 200?) INFERRED |
| Name icon | the name line is written with the indent flag, which shows the sign statics (`+0x7e0` / `+0x7e8` slot `0x5c`) and pads the line with spaces to the icon's width | READ (`0x776d20`) |
| Placement on screen | right of the hovered slot, top aligned (one screenshot); text pen 8 px in, every glyph pixel with a black (+1,+1) shadow | MEASURED (round 731) |

**Why ours is blurry at DPI 2.0 (INFERRED, not measured):** every OpenSRO item tooltip is Godot's
built-in `Control.tooltip_text` (`hud_panels.gd` `_item_tooltip` / `_shop_tooltip`). Godot shows that
text in its own popup window, an embedded sub-window with its own viewport and the default theme font.
Round 672's crisp-text path is the root window's font oversampling, which only applies to the root's
own canvas. The popup's text is rasterised at 1x and then scaled up by the root's content scale, here
2.0. It is also the wrong font, grey, with no border. **The fix is to never use `tooltip_text` for
items**: build the bubble as a Control in the HUD layer, from the layout above, through `UiBuilder` and
the game font, so it inherits round 672's handling.

## 2. Line composition

`UI_SILKMALL::FUN_006860a0` and the item path `FUN_00685f20` dispatch on the item's TypeID3, i.e.
`(type & 0x780) >> 7` for an equipment item (TypeID1 3, TypeID2 1). READ, `0x685f20`:

| TypeID3 | Kind | Builder |
|---|---|---|
| 1, 2, 3, 9, 10, 11 | China/Europe garment, protector, armour | `0x6827c0` |
| 4 (TypeID4 1 or 2) | shield | `0x683040` |
| 5, 12 | China/Europe accessory | `0x682ba0` |
| 6 | weapon | `0x682df0` |
| 7 | job suit | `0x6821f0` |
| 13 | avatar | `0x682410` |
| 14 | devil spirit | `0x67b460` |

Pets and COS go to `0x684740` / `0x685b80`; other items (consumables, alchemy and the rest) go through
the other branches of `0x6860a0`, which are not walked this round (OPEN). The rent and expiry block
`0x672990` and the socket block `0x672740` follow for any item.

**The four equipment builders (armour, shield, accessory, weapon) share one skeleton (READ,
`0x6827c0`, `0x683040`, `0x682ba0`, `0x682df0`).** Each line is appended through
`FUN_00776d20(text, 0, colour, indent, font)`, whose argument order is read at `0x66fca5..0x66fcb4`.
A blank entry has colour 0.

| # | Line | Format and key | Colour (ARGB) | Font arg | Source |
|---|---|---|---|---|---|
| 1 | Name | `"%s (+%d)"` (plus = opt level) or the plain name; name from the ref's name key (`+0x60`) | see §3 | 3, indented | `0x67a570` |
| — | blank | — | 0 | 1 | after a printed name |
| 2 | Seal | `PARAM_RARE_FIRST` "Seal of Star" (`PARAM_RARE_FIRST2` "Seal of Nova" when ItemClass ≥ 31), `PARAM_RARE_SECOND` (Moon), `PARAM_RARE_THIRD` (Sun); the tier is `(ItemClass − 1) mod 3` | gold `0xffffd953`, or pink `0xffff75f2` when `0x8bd660` holds | 3 | `0x66fa60`, only for Rarity 2 or 6 (`0x8ba600`) |
| 3 | Set name | text at `+0x3c` of the set table entry for ref `+0x1d4` (table `0xeedf08`) | green `0xff6ce675` | 3 | `0x66fa60`, when Rarity > 2 (preceded by a blank if there was no seal line) |
| 4 | Sort of item | `"%s: %s"` `UIIT_STT_ITEM_TYPE` "Sort of item" + the type's name | beige `0xffefdaa4` | 1 | every builder |
| 4a | Armour position (armour only) | `"%s: %s"` `UIIT_STT_ARMOR_POSITION` + `_HEAD/_SHOULDER/_BREAST/_LEG/_HAND/_FOOT` by TypeID4 | beige | 1 | `0x6827c0` |
| 5 | Degree | `UIIT_TOOLTIP_EQUIPMENT_CLASS` "Degree: %d degrees", degree = (ItemClass − 1) / 3 + 1, only when ItemClass ≠ 0 | beige | 1 | `0x66f0c0` (`0x66f13b..0x66f15b`) |
| — | blank | | 0 | 1 | |
| 6 | Description (when it resolves) | `0x66f850`: the ref's column 6 key (`DescStrID128`, `+0x7c`) through the object text table, then a blank (round 731's review) | white | 1 | READ |
| 7 | Stats | see the stat table below | white (durability: its own colour) | 1 | `0x66c5b0` |
| 8 | Requirements | blank, then: `PARAM_REQ_LV` "Required level %d"; job grade (`UIIT_STT_CHAR_JOBGRADE` + `UIIT_STT_CLASS_*_%d`); guild level (`UIIT_STT_GUILD_REQUIRE_LEVEL`); mastery (`PARAM_MASTERY`: name `PARAM_MASTERY_LEVEL` %d); `PARAM_STR` / `PARAM_INT` %d; race `UIO_NEWCHAR_CTL_CHINESE` "Chinese" / `_EUROPEAN` "European" / `_ARABIAN`; gender `UIO_NEWCHAR_CTL_MALE` / `_FEMALE`; fortress use rules | white when met, **red `0xffff4a4a` when not** | 1 | `IFSlotWithHelp::0x67eec0` |
| 9 | Max. no. of magic options | `"%s: %d%s"` `UIIT_STT_AVATAR_MAGICOPTION_MAXCOUNT` + count + `UIIT_STT_UNIT` "Unit" | beige | 1 | `0x66e030` |
| 10 | Magic options (blue stats) | blank (except job suits), then one line per magic param through `0x670dd0` | cyan `0xff00eaff` | ? | `0x6780c0`; the per-option formats ("Steady(1Time/times)", "%s %d%% Increase"…) are in `0x670dd0`, OPEN |
| 11 | Advanced elixir | `UIIT_STT_SOCKET_TIP_UPPER_REINFOREC_UNUSE` "Able to use Advanced elixir." when the count is 0, else `_USED` with the count | grey `0xffc8c8c8` unused, white used (round 731) | 3 | `UI_SOCKET::0x66fd60` |
| 12 | Prices | store buy/sell, make price, GP, period, repair charge, market condition (`PARAM_STORE_PURCHASE_PRICE`, `UIIT_STT_PRICE`…) | white | 1 | `0x6784a0` |

**The stat block, in order (READ, `0x66c5b0`).** Each line shows only when its value is non-zero.

| Line | Key | Format |
|---|---|---|
| Phy. atk (fortress weapons use `UIIT_STT_ITEM_FORMAT_FORT_ATTACKP`) | `PARAM_PA` | `"%s %d ~ %d (+%d%%)"` |
| Mag. atk | `PARAM_MA` | `"%s %d ~ %d (+%d%%)"` |
| Phy. def | `PARAM_PD` | `"%s %.1f (+%d%%)"` |
| Mag. def | `PARAM_MD` | `"%s %.1f (+%d%%)"` |
| Phy. absorption | `PARAM_PR` | `"%s %.1f (+%d%%)"` |
| Mag. absorption | `PARAM_MR` | `"%s %.1f (+%d%%)"` |
| Durability | `PARAM_DUR` | `"%s %d/%d (+%d%%)"`, with its own colour |
| Attack distance | `PARAM_RANGE` | `"%s %.1f m"` (ref `+0x254`) |
| Attack rate | `PARAM_HR` | `"%s %d (+%d%%)"` |
| Parry rate | `PARAM_ER` | `"%s %d (+%d%%)"` |
| Critical | `PARAM_CRITICAL` | `"%s %d (+%d%%)"` |
| Blocking rate | `PARAM_BLOCKING` | `"%s %d (+%d%%)"` |
| Phy. reinforce | `PARAM_PHYSICAL_SPECIALIZE` | `"%s %.1f %% (+%d%%)"`, or `"%s %.1f %% ~ %.1f %% (+%d%%)"` for a range |
| Mag. reinforce | `PARAM_MAGICAL_SPECIALIZE` | as Phy. reinforce |

**The "(+x%)" white-stat quality (READ, the shape; `0x66c5b0` lines 60-125).**
1. Take the instance's computed stat (`FUN_008ba4b0`, built from the variance).
2. Subtract the plus bonus: `ROUND(ref per-plus increment (e.g. +0x268) × (opt level + advanced-elixir plus))`.
3. Normalise against the ref's [lower, upper] range: f = (base − lower) / (upper − lower), or 1.0 when the range is empty.
4. The percentage is f × 100, truncated (`_ftol2`).

**Settled in round 732 (READ, the x87 code):** both ends are used — the percent is trunc((f_lo + f_hi) × 0.5 × 100) — and the plus bonus in step 2 is TRUNCATED, not rounded (the fistp runs with the rounding control set to chop). Single-value lines, the durability line (`trunc(q / 0.31)`, so 31 shows 99%), the stat builder and the blue-option percent are in `docs/rounds/r732.md`; the code is `client/scripts/items/item_quality.gd` and `server/internal/durability/quality.go`.

The accessory lines our necklace lacks are Phy./Mag. absorption (`PARAM_PR` / `PARAM_MR`), plus
anything else in the stat block that is non-zero, the requirements and race lines, and Max. no. of
magic options.

## 3. Colours (READ unless marked)

- **The name** (`0x67a570`, `0x67a8d7..`):
  - gold `0xffffd953` for a seal item (Rarity 2 or 6), or pink `0xffff75f2` when `0x8bd660` holds;
  - else cyan-blue `0xff00eaff` when the item has magic options (`0x8ba5d0`);
  - else white `0xffffffff`.
  
  This confirms the user's rule (golden = Seal, blue = blue stats, white otherwise).
- **Beige `0xffefdaa4`:** Sort of item, armour position, degree, max magic options.
- **White `0xffffffff`:** the stats and requirements that are met.
- **Red `0xffff4a4a`:** an unmet requirement (level, race, gender, mastery).
- **Green `0xff6ce675`:** the set line. "Power" in the user's screenshot is that line (INFERRED: the item is a Nova seal item and Nova sets carry a set id).
- **Cyan `0xff00eaff`:** the magic options ("Steady(1Time/times)", "Lucky(1Time/times)").
- **Font:** the last argument is 3 for the name, the seal, the set and "Advanced elixir used", 1 for body lines and 2 for rent headings. That 3 is the bold face is INFERRED from the screenshot, where exactly those lines are bold.
- **Blank lines:** entries with colour 0 are the group breaks. **Corrected in round 731: there is no rule.** The full-width dark rows in `XjjJyA5.png` continue outside the bubble on both sides: they are the stall window behind it.

**Order (settled: USER DECISION 2026-10-05, the binary's order; round 731 re-read `0x776d20` → `0x64f8a0`: lines append at the end, the font argument only selects the face — nothing re-orders):** was: in this binary the seal and set lines come right
after the name (`0x66fa60` is called before "Sort of item"). In the user's screenshot, from the Esro
client, they come after the requirements and "Max. no. of magic options". Either the font-3 lines go
to a later section through a path not yet read, or the user's client differs from this vSRO build.
Lane A reads `0x776d20`'s flag semantics first. If the binary really puts the seal near the top, ask
the user which to follow, as was done for party matching.

## 4. Data each line needs, and what OpenSRO has

| Need | Source | OpenSRO today |
|---|---|---|
| ItemClass (degree, seal tier) | itemdata (ref `+0x1d0`) | not read by `ItemTableReader` |
| Rarity (seal), set id (`+0x1d4`) | itemdata | rarity not read on the client; set table not read |
| Absorption PR/MR, parry ER, blocking, per-plus increments | itemdata (ref floats) | not read (only phys/mag atk and def, block, rate, critical, reinforce, range) |
| Max magic options count | itemdata | not read |
| Opt level (plus), variance (white stats), magic params (count + list), advanced-elixir count | item **instance**, sent by the server | the client gets only per-slot durability; the server stores `variance` and `durability` (`inventory.Slot`), but no opt level, magic params or advanced-elixir count |
| The player's level, race, gender and masteries (red requirement lines) | client state | available |

## 5. Gap list (OpenSRO today)

1. **The window:** Godot's `tooltip_text`. It is blurry at DPI 2.0, uses the wrong font, a grey box, and has no frame or icon. (Fixed in round 731.)
2. **The text:** hard-coded English ("Phy. atk. pwr.", "China", "Man only") instead of the text table's keys ("Chinese", the gender keys). There is no degree line, no "(+x%)", no armour position, no requirement colours and no "Max. no. of magic options".
3. **Missing stat lines:** absorption, parry, blocking and range-format lines are missing, so accessories show almost nothing (the user's necklace).
4. **Colours:** the name is always white (no gold, pink or blue), and there are no seal, set or magic-option lines.
5. **Server and instance:** no opt level, magic params or advanced-elixir count on the wire or in storage. Variance is stored but not sent, so neither "(+x%)" nor the true stats can be shown.

## OPEN

1. The window alpha byte (`+0x131`) itself; the clamping (OURS).
2. ~~The rule drawing~~: there is none (round 731).
3. The seal and set order (see §3).
4. `0x670dd0`'s per-option formats — the main ones read in round 732 (`MagicOptionTable.FORMATS`); the reinforce-timer, 3rd-job, avatar and Nasrun ones remain.
5. The non-equipment builders.
6. ~~`0x66f850`'s line~~: the description, column 6 (round 731's review).
10. **"Sort of item"'s source** (round 731's review): `FUN_00941240` tries a code-name map (`+0x6b8`, `FUN_009411d0`) then a TypeID & 0xfffe -> string map (`+0x6a8`, `FUN_0093acb0`); their writers are not read. OpenSRO's fmn join is INFERRED, and `XjjJyA5.png` reads "Twohand staff" (`UIIT_CTL_WNETWORK_EU_TSTAFF`) where the join gives "Staff".
11. The job-grade requirement types 2/3/4, and `PARAM_STORE_PURCHASE_PRICE` (the store's offer for a bag item while a shop is open).
7. What `0x8bd660` tests (the pink seal colour).
8. ~~Which range end the "(+x%)" uses.~~ Both, averaged (round 732).
9. ~~The retail item-instance wire layout.~~ Read in round 732 and its review: u32 rent block (0, or bit 0/bit 1 branches, c:0x8bb130), u32 RefItemID, u8 OptLevel, u64 Variance, u32 Durability (the period word active<<31|seconds for TypeID3 14), u8 MagParamNum ≤ 12, N × u64 (low u16 id, high u32 value), two binding blocks, type 1 then type 2, each entry u8 nSlot and a u64 (low nOptID|nOptLvl<<16, high the value; gs:0x825a40). See `docs/rounds/r732.md` and `server/internal/session/iteminfo.go`.

## Implementation lanes

**Lane A (client): the bubble window and text.** Files: a new `client/scripts/ui/hud/item_tooltip.gd`
(the bubble) and `item_tooltip_lines.gd` (the composition); `item_table_reader.gd` (and the native
`tables.rs` with `table_parity`) for ItemClass, Rarity, set id, absorption, parry, blocking, per-plus
increments and max magic options; the call sites in `hud_panels.gd` that set `tooltip_text` for items.
1. Read the OPEN items 1–4 and 6–7 first.
2. Build the bubble from `ifhelpbubblewindow.txt` and the frame textures, through `UiBuilder` and the game font, so it is crisp at any UI scale.
3. Compose the lines per §2 and §3, with stock keys, and replace every item `tooltip_text`.
4. With no instance data yet, show "(+0%)" only where the original would with an unknown instance, or leave it out and label that.

Acceptance:
- GD tests of the line tables per type, the colours, and the degree and seal maths;
- renders at UI scale 1.0 and 2.0, measured: glyph edge sharpness, frame texels, line height 18;
- the user's spear and necklace cases;
- no perf gate (UI only).

**Lane B (server + client): instance data.**
1. Read the retail item-instance layout (opt level, variance, magic params, advanced elixir) from the client's inventory parser.
2. Store opt level, magic params and advanced elixir per item on the server (schema plus migration).
3. Send them, on retail layouts where OpenSRO's inventory messages already follow retail, otherwise as an extension labelled OURS.
4. Give the client the computed stats and "(+x%)" (`FUN_008ba4b0`'s maths, READ in this lane).

Acceptance: Go tests; a live check of an item with variance showing the "(+x%)" values.

Lane A first. Lane B can run in parallel; A consumes B's fields when they land.

## Round 731 (lane A) additions

- "Sort of item" is taken from `fmntidgroupmapdata.txt` (TypeID1-4 -> group) joined to `fmncategorytreedata.txt`'s key by group (the join MEASURED 1:1; that the client uses it INFERRED, OPEN 10); the set name's key resolves in `textdata_equip&skill.txt` (listed by `textdataname.txt` with `textdata_object.txt`), SN_ITEM_11_SET_A_WEAPON = "Power".
- The Int requirement line prints the Str requirement's value (READ, `0x67eec0`, PARAM_INT with ref `+0x1c8`); OpenSRO reproduces it.
- Font arg 3 is the same face bold (same 9-row cap height, 2-px stems, MEASURED), not FontIndex 3.
- Implementation and measurements: `docs/rounds/r731.md`.
- Round 731's review fixes: armour/shield reinforce from columns 82-85 (single-value line when the weapon pair is zero); a store's goods print `"%s : %I64d%s"` (`UIIT_STT_PRICE`, `UIIT_STT_GOLD`, no blank before, `0x678cf2`); all four requirement pairs (level, masteries 0x101-0x114 / 0x201-0x206 as `"%s: %s %s %d"`) in one colour, white if any is met; the mastery names resolve in `textdata_equip&skill.txt`; "Max. no. of magic options" always.
