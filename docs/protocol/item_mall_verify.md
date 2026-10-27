# Item mall window spec: adversarial verification (round 837)

This file checks the claims in `docs/protocol/item_mall.md`. They were re-read on 2026-10-27 from
the following sources:

- `sro_client.exe`: the local copy (md5 matches the box's), objdump, and the decompile in
  `/var/tmp/decomp_client`.
- The box's archives (`/opt/sro-files/client/*.pk2`), extracted on the box only:
  - `resinfo\ifnewitemmall*.txt`, `ifnewitemslotpopupwnd.txt`, `ifnewitemmallconfirmbuy.txt`,
    `ifnewitemmallmessagebox.txt`, `ifitemmallusepoint.txt`;
  - `res_ui\silksearch.2dt`, `silkrecievelist.2dt`, `nifundermenubar.2dt`;
  - `itemdata_*.txt`, `characterdata_*.txt`, `refscrapofpackageitem.txt`, `textuisystem.txt`;
  - the `interface\mall\*.ddj` art.
- `vsroplus_lib.dll`, read only for the Chest claim.

Every address is a client address. The probes, decoded art and disassembly slices are in this
round's scratchpad (`r837/verify_ui/`); no game data is committed.

Verdicts:

- **CONFIRMED**: the code or data at the cited place says what the spec says.
- **CONFIRMED+**: right, but the code does more, and the extra matters for building it.
- **WRONG**: the correct reading and its address are given.
- **UNVERIFIABLE**: not re-read, or it cannot be settled from the binary.

The spec's corrections are in its own "Corrections from the review" section. The rest of the
spec was left as written.

## WRONG items first

| # | Spec claim (section) | Correct reading | Evidence |
|---|---|---|---|
| W1 | §4b left drag: "The models turn in place: no orbit … Pet and ride turn about their own origins" | **The pets orbit the player.** `0x55f520(angle)` writes the yaw into each model's matrix as m00 = cos, m02 = sin, m20 = −sin, m22 = cos. In D3DX terms that is RotationY(−angle). `0x55f470` then sets the translation row to the model's base position (`+0x14..+0x1c`) multiplied by that matrix: x' = cos·x − sin·z, z' = sin·x + cos·z. The world matrix is diag(scale) × that matrix (`0x55ebd0`), with the translation unscaled. So the whole group turns as one turntable about the world origin, where the player stands. The player turns in place only because its base position is (0, 0, 0). A drag to the right swings each model's +X side toward +Z, away from the camera; that the body faces the camera at yaw 0 is INFERRED from the screenshots. | `0x55f520` (`fst [esi+0xc]`, `+0x20`, `+0x28`, `+0x40` = −sin, `+0x48`); `0x55f470` (`+0x50`, `+0x58`); `0x55fe70` sets the base position, then the yaw from `+0x394`. |
| W2 | §4c step 4: "INFERRED: 3 = a ride, 4 = a pet". Also §4a step 2 ("`+0x858` (pet), `+0x85c` (ride)") and the Summary ("a pet / ride beside it") | **Both previews are pets, and no ride can be tried on.** COS TypeID4 3 (`0x666c00`) is the attack (growth) pet: all 9795 `COS_P_*` rows with 1/2/3/3 in this archive's characterdata. TypeID4 4 (`0x666c40`) is the pick (ability) pet: 26 rows, `COS_P_BROWNIE`, `COS_P_CAT`, …. The items are 3/2/1/1 (attack-pet flutes, `ITEM_COS_P_FLUTE`, `_BEAR_SCROLL`, …) and 3/2/1/2 (pick-pet scrolls, `ITEM_COS_P_RABBIT_SCROLL`, `_GOLDPIG_SCROLL`, …). Horses (`COS_C_*`, 1/2/3/1) are summoned by 3/3/3 items, which are not 3/2/1, so the try-on cannot show them. Placement: `+0x85c` = **attack pet** at (−5.5, 0, −2.5), screen left; `+0x858` = **pick pet** at (4.5, 0, −2.5), screen right. Both stand 2.5 units nearer the camera than the player. | `0x7d88c0` (`c:0x7d8a8b..0x7d8b0f`, `0x7d8b36..0x7d8bbd`); `0x666c00`/`0x666c40`; MEASURED counts from `characterdata_*.txt` and `itemdata_*.txt` (columns TypeID1..4). |
| W3 | §4a camera: "camera type 2 adds a fixed π/2 (`0xe096d4`)" | **It has no effect in perspective mode.** For type 2, `0xbae580` builds RotX(π/2) into its first matrix buffer. The perspective path then writes `RotZ(a2)·RotX(a0)` **into that same buffer**: `pOut` = the type matrix, at `0xbae6db..0xbae6f0`. That discards the type rotation. The view rotation is `RotZ(+0x420)·RotX(+0x418)·RotY(+0x41c)`. (The jump table at `0xbae7fc` maps type 1 → RotY(π), 2 → RotX(π/2), 3 → RotX(3π/2), 4 → RotY(π/2) and 5 → RotY(3π/2).) For the mall the angles are (0, 2π, 0), so the rotation is the identity either way. | `0xbae5d8`, `0xbae6db..0xbae70a` (`0xaa37f1` = MatrixMultiply, pushed pOut last) |
| W4 | §6c request: "u64 pointsUsed // left out in one mode, `0x667120()+0x10 == 3`" | **The u64 is always written.** The request branch writes, in order: u16 `+0x12`, u8 `+0x14`, u8 `+2`, u8 `+3`, string `+0xf4`, u16 `+6`, **u64 `+0xb0`**, u32 `+0xc`, with no condition. The mode test (`0x667120` returns a table with one mode per payment-device bit; `+0x10` is the points bit) decides only whether the points value is copied into the struct. `item_mall_wire.md` has this right. | `c:0x792944..0x79299d`; case 0x18 jumps there at `0x79286f`/`0x792874`; value copy at `0x826532..0x82656c` |
| W5 | §6d `0xB034` result 1: "`u8 0x18 …, u8 n, n × u8 inventory slot, u16 count`" and "(That the 0x18 byte comes first is INFERRED.)" | Two corrections. First, the client reads **a rent block for each created item** (`0x8bb130` at `c:0x87e0dc`, in `0x87ba20` case 0xa7): a u32 of flags; bit 0 adds u16, u32, u32; bit 1 adds u16, u32. `item_mall_wire.md` lists these blocks. Second, the leading type byte is **READ**: `0x87eb50` reads one byte before its switch. The reply branch's order is u16 `+0x12`, u8 `+0x14`, u8 `+2`, u8 `+3`, u8 n, n × u8 slot, u16 `+6` (`0x87f227`), then the per-item rent blocks. | `0x87eb50`, `0x87ba20`, `0x87e0dc` |
| W6 | §6c "The second sender, `0x7978a0` (the try-on Buy and the reserve Buy All), repeats checks 1 and 2 itself" | **Its checks differ from the confirm box's.** Slots: it refuses when free slots < count, with no exception for stackable items (`c:0x79794d..0x79795b`). Silk: it refuses with `0x1880` only when **silk + gift < price × count AND point < points to use** (`0x778e10` = `+0x4ac` + `+0x4b0`; point `+0x4b4` is compared separately, `c:0x797a32..0x797a90`). With 0 points to use it never refuses on silk and leaves that to the server. All four callers pass kind 0xc and count 1 (`c:0x7d80e2`, `0x7d83da`, `0x7db0d5`, `0x7db3a0`). | `0x7978a0` |
| W7 | §4g Buying list: "12 rows" | **11 rows.** silksearch.2dt has 11 `CNIFSilkRecieveListSlot` records, each 402×24, at y 367..597 in 23 px steps, each with three children (ids 25/26/27: No. / amount / date). silkrecievelist.2dt also has 11. The window is 462×527. | MEASURED (976-byte 2DT records); fill loop `0x7ec630` |
| W8 | §1b row 106: the search edit's colour is 247,202,1 | Control 106's FontColor is **222,217,162** (Color 143,110,60). 247,202,1 is control 104's FontColor (MAIN PAGE). Create also sets text field `+0x94` to `0xff3b457a` with `0x635030(1)`, then overwrites it with `0xff000000` (`0x7d905e` → `0x655290`). Which colour `+0x94` is remains OPEN. | `ifnewitemmall.txt`; `c:0x7d9049..0x7d9076` |
| W9 | Summary: `CIFNewItemMallShopSlot` is "a `CIFVScrollColumnView`, ID 105" | RTTI: `CIFNewItemMallShopSlot : CIFWnd`. It **contains** a `CIFVScrollColumnView`, ID 301, at 5,3,541,507. §2d says this correctly. | `0x7e5eb0` |
| W10 | §2b "For each tab group of the shop …"; Summary "its sub-tabs are that shop's `refshoptab` rows" | **Only the shop's first tab group** gets sub-tabs and views. `0x7e4a90` takes the first entry of the tab-group vector (`0x982760`) once, at `0x7e4b04`, and keeps it in `[esp+0x64]`. Each loop back-edge (`0x7e50e2`) re-reads that same group's tab list. The row test `0x7e3090` walks **all** groups. So a shop whose goods sit only in a later group gets a menu row with no sub-tabs. | `c:0x7e4ae1..0x7e4b20`, `0x7e50e2..0x7e50fc` |
| W11 | §3d CMallItemData: "`+0x14` a word from the tab (`0x983ca0`)"; `+0x8`, `+0x18` unknown | `+0x14` = **the mall shop group's u16** (`0x9262c0()`, kept at `[esp+0x6c]` from `0x7e4ae8`; `0x983ca0` is an identity function). It is the word that `0x7121` and `0x7034` send. `+0x8` = **the tab's index** in the first tab group: 0-based, empty tabs counted (zeroed at `0x7e4b0c`, incremented at `0x7e50ea`). `+0x9` = **SlotIndex**, now READ (`0x7e4f84`). `+0x18` = the tab record's `+8`, **the refshoptab ID** (`0x7e4d43`). | fill `0x97fa40` at `0x7e4d72` |
| W12 | §3b bit 16: "the `shopitemstockquantity.txt` row for this tab and package" | A row **matches** on u16 `+4` = CMallItemData `+0x14` (the shop group word, **not the tab**) and u32 `+8` = package id. A match with quantity > 0 shows `" %d"` and sets `+0x550`. Separately, **any row with quantity 0, matching or not, marks the cell "Sold out"** and sets `+0x553`. That flag stays set even when a later matching row has stock. So one zero row anywhere in the table sells out every bit-16 cell (a retail bug to reproduce or to fix as OURS). | `c:0x7def72..0x7df030` (`cmp word [eax+0xc],0` → `0x7defd2` with no match test) |
| W13 | §3c hover: "when no mall box is open (`+0x7c4` = 0)" | `+0x7c4` is **the open silk-history window** (Buying list or Obtained list), set at `0x7d719a`/`0x7d721a` and cleared at `0x7d7012`. The mall-box busy byte is `+0x7c8`, and hover does not test it. | `0x7deb80` (`0x7debaa`) |
| W14 | §3a "A cell whose package has no icon path gets neither content nor background (`0x7df701`)" | The test (`0x7df6f3..0x7df703`) checks a std::string's c_str pointer, which is never NULL. **Every cell is filled and gets `mall_item_wnd.ddj`.** An `xxx` icon is stored as an empty string (`0x97f860`). | `0x7df6c0` |

## OPEN and INFERRED items now settled

| Spec item | Now | Evidence |
|---|---|---|
| `0x8bf0d0` (the try-on gate, the quantity cap) | READ: **the good holds 2 or more items**, i.e. a bundle. It is the same test as `+0x555`. | `0x8bf0d0`: `(+0x30 − +0x2c) / 4 > 1` |
| `+0x7dc` "INFERRED pending purchases" | READ: **the count of purchases awaiting a reply**. `0x7d6d80(n)` sets it only when it is 0. `0x7d6da0` decrements it in reserve or lump mode, or else zeroes it, and kills timer 0x96 on each reply. `0x7d6de0` zeroes it on failure. | `0x7d6d80`, `0x7d6da0`, `0x7d6de0` |
| `0x666c00` / `0x666c40` | READ + MEASURED: COS 1/2/3/3 = attack pet, 1/2/3/4 = pick pet (W2) | |
| The preview camera's rotation axes | READ: `0xaa432a` RotationX, `0xaa43c6` RotationY, `0xaa447d` RotationZ. View = RotZ·RotX·RotY (W3). For the mall the result is eye (0, 13, −35), at (0, 13, 0), up +Y, left-handed, vertical FOV 60°. | §4a below |
| STAND1 looping (INFERRED) | READ, through `animation_mixer.md`: play(0, fade-in 0, 0, events off, speed 1, weight 1). The clip's own IsCyclic flag decides loop or one-shot. Each try-on replays it from t = 0. | `0x5602c0`, `0x560121`, `0x9cfb40` |
| Whether worn avatars are attached twice at build | READ: **no**. The avatar map insert is unique (`0x452230`), and `0xa609f0` skips a resource already attached (`0xa5e270`). | |
| `0x8bb570` bits 0x08, 0x10, 0x20, 0x100, 0x400, 0x800 | Mostly READ (§4c row): 0x20 = the level pairs; 0x400 = TID 3/1/6/16 only; 0x800 = item `+0x178` ∉ {0, 2}, default 3. That 0x08/0x10 are ReqStr/ReqInt is INFERRED from the column order. | `0x8bb570`, `0x8ba750` |
| `0x56bce0` before `0x7121` | READ: `0x8cb900` = manager `+0x3f8`, a set of shop-group words, filled by the stock-table loader (`0x9549a2`). `0x7121` is sent **only when `shopitemstockquantity.txt` has rows for the mall's shop group**; otherwise the mall opens at once. This archive's file is empty, so here F10 → warning → OK opens without `0x7121`. | `0x791a30`, `0x56bce0` |
| The icon the cell draws (`icon64` join) | READ: `"icon64" + str.substr(4)` of `"icon\" + path`, so `icon64\item\…`. The archive has 651 icon64 files. What the slot draws when the file is missing is still OPEN. | `0x7dea73` |
| The scrap count field (INFERRED Data) | READ: `0x982350` returns record `+8`, and the cell reads `+0x18` of that, which is record `+0x20` = the **Data** column (`0x9824e0`: `+0x14` OptLevel, `+0x18` u64 Variance, `+0x20` Data). The "`+0x2c8` bit 2 → 1" case also needs the item to be 3/3/13/15 (`0x5dd780`). | `0x7df287`, `0x7df318` |
| CMallItemData `+0x8`, `+0x14`, `+0x18` | READ (W11) | |
| The request string (INFERRED CodeName) | READ: package `+0x10`, the CodeName (pushed at `0x7e867c`) | |
| `0xB11a`'s second byte | READ: read and never used | `0x8990c0` |
| `0x8bf0d0` as "multi-item" in the quantity cap (§6b) | READ (above). The MaxStack cap applies only to a 3/3 item **whose scrap `+0x18` field is 0**; otherwise the cap is 5. | `0x7e8ab0` |

## 1–3. The window, the menu, the cell

| Claim | Verdict | Evidence |
|---|---|---|
| 1a class, ID 167, layout path, sections | CONFIRMED | `0x7d8f3b`/`0x7d8f66`/`0x7d8f8c` |
| 1a Create's control fields and their order | CONFIRMED+ | The fields are as listed (`0x7d8fa1..0x7d9133`). The list leaves out that Create **runs the preview build `0x7d8bf0` at `0x7d915e`**, zeroes `+0x7e8`, `+0x7dc`, `+0x7e0`, `+0x7e4`, `+0x7e9`, and calls `0x8b4400(5, flags & ~1)` on 109 and 110. |
| 1b every other row of the control table, and the MyInfo paragraph | CONFIRMED | Re-checked row by row against `ifnewitemmall.txt`/`ifnewitemmallmyinfo.txt`. Not listed: MyInfo 213 (MONEY_SIGN at 80,58, always hidden). |
| 1b row 106 colour | **WRONG, W8** | |
| 1c message map `0xec03a0` and its handlers; WM_CHAR rules | CONFIRMED | Filled by `0xd72b00` (Original `0xd72b14` → `0x7d8d30`, Buy `0xd72b1e` → `0x7d7080`). Search also closes an open cell menu. Enter is not taken when the edit is unfocused. |
| 1e F10 path, box kind 0x1e 400×210, the warning lines | CONFIRMED+ | F10 = index 84 → byte 8 → `0x7807aa`. **F10 never closes an open mall.** The box also shows `interface\mall\mall_pic.ddj` (148×52 at 128,43). The lines are at x 20, y 108/125/142, each 359×15; the buttons are at (123,168) and (203,168). OK reaches case 0x1e only on answer 1 (`0x7986eb`). |
| 1e `0xB121` | CONFIRMED+ | Result 2 reads a u16 and returns **without opening** the mall. |
| 1e `0x79b580` open/close | CONFIRMED | Opens only when not already open. Close: sound, hide, unload "NewItemMall" (`0x8b59f0`). |
| 1e close request `0x7d7020` | CONFIRMED+ | Order: refused on `+0x7c8`; then the Buying-list cancel `0x711a {1, 0xff}` (`0x7eabe0`) and `0x468c50(0x26)`; then refused on `+0x7dc`. So the cancel goes out even when the close is then refused. |
| 1e bottom-bar button 9, `ub_new_mall`, 859,459,32,32, tooltip | CONFIRMED | MEASURED in `nifundermenubar.2dt`; `0x60a6d5` |
| 1e `0x7d16c0` → `0x79b580(1)`; a buy reply opens/closes the mall | CONFIRMED | `0x87e00e`/`0x87e31a` |
| 1e `DONOT_USE_TELEPORT` not in the exe | CONFIRMED | |
| 2a loader, the two maps, this archive's rows | CONFIRMED | `0x957392..0x9574c4` |
| 2a row creation (`refshop` by code; `xxx` hides HOT shop and Reserved) | CONFIRMED+ | `0x7e5220..0x7e525b`. `0x7e3090` also requires the shop to be in the mall shop group's list, and it counts the raw, unfiltered goods vector. The row counter advances for skipped rows too. |
| 2a main slot 116×32, disabled form unused | CONFIRMED | The flag passed (`+0x370`) is always non-zero there. |
| 2a "columns 6..9 unused" | UNVERIFIABLE | Not re-read. |
| 2b one view per tab, hidden, 400 wide; cells 199×81, two per row; SaleTag bit → list map (16 and 32 both → `+0x8fc`) | CONFIRMED | `0x7e4c56..0x7e4c7f`, `0x7e4f1d`, `0x7e4dc8..0x7e4e6a` |
| 2b "for each tab group" | **WRONG, W10** | |
| 2b sub-tab 116×23, title at x+43, 93×15, no background | CONFIRMED+ | The title's y is the slot's y + 0; the layout's 5 is overridden. |
| 2b order by SlotIndex; click messages; selected sub-tab yellow and bold | CONFIRMED+ | `0x985590`. Messages 0x2806c/0x2806d. Bold via `0x8b4400(5, 2)`. A row click always clears `+0x7c9` first. Buy All and Empty also require `+0x7dc` = 0. |
| 2c main page: one section per HOTITEM row, dedupe on package id (`+0x91c`) | CONFIRMED+ | `0x7e3c00`; the dedupe runs after the filter. **The flag → list map has no key for 32** (`0x7e5449..0x7e54fc`), so a bit-32 main-page section can never be made. |
| 2d scroll view ID 301, 5,3,541,507, art, thumb 14×28, menu view 303, columns 124/424 | CONFIRMED | `0x7e5eb0` |
| 3a cell 199×81, layout sections, control table | CONFIRMED+ | `0x7de3b0` binds 801/802/805/803/807/900. Layout control 800 (an empty static at 60,9,130,26) is loaded and never filled; 806 is not bound. |
| 3a "no icon path → no content, no background" | **WRONG, W14** | |
| 3a name, price slot 1, the flags `+0x555`/`+0x551` | CONFIRMED | `0x7de530`, `0x7de0d0`, `0x7df430`. (The "READ in the confirm box" sentence is duplicated in the price bullet.) |
| 3a unit | CONFIRMED+ | See "settled" above. Equipment packages show their Data value as a unit count: the axe row shows "69 Unit". |
| 3b filter: bit 32 only, between begin and end | CONFIRMED+ | Strictly begin < now < end. |
| 3b badge bits → art, positions x = 9 + 13n, y 60, 12×12, IDs 1100+n | CONFIRMED | `0x7dec60`. MEASURED letters: blue N, red H, green S, magenta R, purple D. Badges 12×12, `mall_item_wnd` 200×84, `mall_menu_bar` 420×20, silk coin 14×14. The space in `mall_icon_recommendation .ddj` is in the archive's file name. |
| 3b bit 16 stock lookup | **WRONG, W12** | |
| 3b bit 32 period text and "Sold out" | CONFIRMED | `0x7de250`, `0x7ddf70` |
| 3c hover offset (132, 56) | CONFIRMED+ | `0x7dec1c`/`0x7dec20`. The menu's corner lands **inside** the 199×81 cell: it covers the cell's lower right and hangs below it, rather than sitting "beside" it. |
| 3c hover gate `+0x7c4` | **WRONG, W13** | |
| 3c menu enable rules | CONFIRMED | `0x7de900`: Detail (`+0x7c0`) iff `+0x555`; Buy (`+0x7bc`) iff not `+0x553`; Wear Item (`+0x7b8`) iff `+0x551` and not `+0x555`. Button 13 text: `0xd9b56c`/`0xd9b608` by `+0x552`. The menu's tick (`0x7e6790`) also disables 10–12 and resets 13's text. |
| 3c handlers, boxes 1200–1204 and sizes | CONFIRMED+ | All of them also require `+0x7dc` = 0. Buy sets `+0x7c9` before the gate test. The bundle press also needs the pointer inside the cell. |
| 3c the reserve list is client-only | CONFIRMED | No sender on that path. |
| 3d CMallItemData | **WRONG in part, W11** | |

## 4. The preview and the try-on (the hardest check)

Every address below was re-read in the disassembly, not only the decompile.

### 4a. Control, build, camera, light

| Claim | Verdict | Evidence |
|---|---|---|
| Control `CIFRenderStatic` ID 123 at `+0x850`, rect = control 111's (215×332) | CONFIRMED | `c:0x7d90f3` (`0xb8f420` on `+0x838`), `0x7d911b..0x7d9133` (`push 0x7b`, class `0xee7a78`) |
| Start: `0x5612f0`, `+0x1f0 = 1`, hidden (vslot `0x5c(0)`), then the build | CONFIRMED | `c:0x7d9139`, `0x7d9144`, `0x7d915a`, `0x7d915e`. The ctor clears `+0x1f0` (`0x560a50`, `param_1[0x7c] = 0`). |
| The render clears only Z; Z on, alpha blend off, lighting on | CONFIRMED | `0x560c30`: device `+0xac` = Clear(0, 0, **2**, 0, 1.0, 0); render state 7 = 1, 0x1b = 0, 0x89 = 1. Viewport = the control's screen rect, MinZ 0, MaxZ 1 (`0x6531a0`). |
| `*_avatawindow.ddj` not referenced by the exe | CONFIRMED | No `avatawindow` (ASCII or UTF-16) in the exe; the archive has 10+ such files. |
| Build step 1: `pEquip` = window 0x19 `+0x7c0`, assert line 0x1e6 | CONFIRMED | `0x798d00` = `0x8b51f0(0x19, 1)`; `0x6a1d50`; `c:0x7d8c1a` |
| Step 2: model slots `+0x854/+0x858/+0x85c` = −1 | CONFIRMED (labels **WRONG, see W2**) | `c:0x7d8c2c..0x7d8c3b` |
| Step 3: new body from the player's RefObj id; PC class `0xef1bc0`, COS `0xeef6f0`; ref `+0x260` → anim flag (0/2→0, 1→1, 3→3); `0xa5b4b0(ref+0x124, 1)`; `0x9c4130(1)`; scale ref `+0x110`/100 | CONFIRMED | `0x561780`: TID tests `0x5617d1..0x5617f7` (COS = 1/2/3, bionic bit set); `0x56182c` jump table; `0x5618a8`; `0x5618cd`; `0x55e550` (`+0x10` = ref`+0x110` × 1.0 / 100.0, `0xe1b7d8`). Also `0x9c7b00(0.0)` and entity vslot `0xd0`. |
| `0xa617d0` mode 0 dress copy (four lists cleared, two 9-slot arrays, avatars from `+0x160` via `0xa60ef0`, slots 8..0 `InstallEquipVisual(slot, src[+0x38+12·slot], plus, 0)`, scale byte `+0x30`, vslot `0x20`) | CONFIRMED | `0xa617d0` (`param_1[0x52/0x55/0x58/0x5b]` = `+0x148/+0x154/+0x160/+0x16c`; memsets `+0x38`, `+0xa4`, 0x6c bytes each; the slot walk starts at src`+0x98`). Only a PC body is dressed: `0x561930` tests TID 1/1 first. |
| Step 4: `0x5602c0(idx, 0)` plays action 0 via `0x9cfb40` → anim vslot `0xc`; looping INFERRED | CONFIRMED+ | `c:0x5602fd..0x56030f`: entity vslot `0xbc` = `0x9cfb40` with **(type 0, A 0, B 0, C 0, speed 1.0, weight 1.0)**. Per `animation_mixer.md` the clip's own IsCyclic decides loop vs one-shot; a loop gets fade-in A = 0 ms (full weight at once), key events off (C = 0), and **a replayed loop starts over at t = 0**. Every try-on (`0x560030`, `0x5600fd..0x560121`, same arguments with action `+0x5a0` = 0) therefore restarts the stand. |
| Step 5: `0x561250` computes the pan box | CONFIRMED | Box reset to 0 then min/max over every model (`0x55f1c0`). At build only the player exists (`0x561040` empties the vector: `+0x388 = +0x384`). |
| Step 6: look-at (0, 13, 0), angles (0, 2π, 0), distance 35, far 500 | CONFIRMED | `c:0x7d8c86..0x7d8ce4`; floats `0xd8acc8` = 13.0, `0xdcc1a4` = 6.2831855, `0xdcc1a0` = 35.0, `0xdcc19c` = 500.0. `0x55e820` writes `+0x3f4..+0x3fc`; `0x55efd0` writes `+0x418..+0x420`, `+0x424` and `+0x3e0`. |
| Step 7: world matrix = identity (`0xeafb20[0]`) | CONFIRMED | `0x5603b0`; the table's first 64 bytes are the identity. |
| Step 8: the five avatar slots `pEquip+0x5f8+i·0x1d0` (occupied: byte `+0x28`) go through `0x7d8bd0(slot, 0)` | CONFIRMED | `0x6ab800` (i ≤ 4), `c:0x7d8d00..0x7d8d22`. |
| "Whether they are thus attached twice is OPEN" | **Resolved: not twice** (READ) | `0xa60ef0` inserts into a unique map (`0x452230`) and `AttachEquipVisualResource` (`0xa609f0`) skips a resource already in `+0x148`/`+0x154` (`0xa5e270` returns 1). |
| Camera object at `+0x3e4`, ctor `0xbae0a0`, perspective `+0x428` = 1, FOV `+0x434` = 60°, near 1.0, far 500, aspect = viewport w/h | CONFIRMED+ | `0xbae0a0`: type 2, near (`+0x42c`) 1.0, perspective byte 1, FOV 60.0. `0xbae810`: `PerspectiveFovLH(fovy = +0x434 × π/180 (0xe1b8d8), aspect, near, far)`, the generic body at `0xaa4ef0` (half angle, cot/aspect). **The 60° is vertical.** Aspect = 215/332 = 0.648 for this control. View = `LookAtLH(eye, at, up)` (`0xaa4bad`: z = normalize(at − eye)). |
| "Which axis each D3DX thunk turns is OPEN" | **Resolved** (READ) | `0xaa432a` = RotationX (generic body `0xaa434c`: m11 = 1, m22 = cos, m23 = sin, m32 = −sin), `0xaa43c6` = RotationY (`0xaa4402`), `0xaa447d` = RotationZ (`0xaa449f`). Each thunk's pointer (`0xec7798/c/a0`) starts at the thunk itself; the first call picks a CPU-specific copy of the same function. |
| "eye = target − R(angles)·(0, 0, distance)" | CONFIRMED+ | `0xbae580`, perspective path: `M = RotZ(+0x420) · RotX(+0x418)` (`0xaa37f1` at `0xbae6f0`, pOut = the type matrix's buffer), then `V = M · RotY(+0x41c)` (`0xbae70a`). Row vectors: `off = (0, 0, dist) · V`, `eye = at − off` (`0xbae7ab..0xbae7de`), `up = (0, 1, 0) · V`. With the mall's angles V is the identity, so **eye = (0, 13, −35), at = (0, 13, 0), up = +Y**, left-handed: the camera sits on −Z looking toward +Z. The camera never turns in the mall; only the models do. |
| "camera type 2 adds a fixed π/2 (`0xe096d4`)" | **WRONG, see W3** | |
| Light: one directional `D3DLIGHT9` at `+0x538`, diffuse 0.7, specular 1.0, ambient 0.3, range 10000, direction = `+0x40c` every update | CONFIRMED | `0x5612f0`/`0x560a50`: Type 3, Diffuse rgb 0.7 (`0xd82f04`), alpha 0; Specular rgb 1.0; Ambient rgb 0.3 (`0xd82f00`); Range 10000 (`0xd82efc`). `0x560fc0` copies `+0x40c..+0x414` to the direction each tick. `+0x40c` is camera `+0x28` = **at − eye, unnormalised** (`0xbae95d..`), so the light points along the view: a headlight. `0x560fc0` also advances each model (`0xa5ac80(1, 0)`). |

### 4b. The mouse

| Claim | Verdict | Evidence |
|---|---|---|
| Only while `+0x1f0` ≠ 0 | CONFIRMED | `0x560720` (`0x56072c`), wheel `0x55ee26` |
| Left press: unless a right drag holds the capture, start angle `+0x3cc = +0x394`, remember x/y, capture | CONFIRMED+ | Jump table `0x560a2c` (index = msg − 0x200: 0 move `0x5608b7`, 1 L-down `0x560755`, 2 L-up `0x5607b1`, 4 R-down `0x560825`, 5 R-up `0x56088a`; 0x203 ignored). **Missed:** a left press while this control holds the capture for a right drag **releases the capture** (`0x560767` → `0xb9d9c0`) and does nothing else; the pan stops there. The same applies the other way: a right press during a left drag releases the capture (`0x560835` → `0x560767`). |
| Left drag: angle = start + 2π·dx / control width, wrapped, applied to every model as its yaw; "no orbit … Pet and ride turn about their own origins" | Formula CONFIRMED; orbit claim **WRONG, see W1** | `0x5608d1..0x560909`: `dx / (+0x48 width) · π (0xd81948) · 2 + +0x3cc`. Then for every model in `+0x380`: `0x55f520(angle)`. |
| The wrap `0x55e780` | CONFIRMED+ | `k = trunc(angle / 2π)` (`0xd81930`, `0xb42d10` = cvttsd2si); it subtracts `k·2π` **only when k > 1** (`fcomp 1.0`, `test ah,0x41`). Angles in [2π, 4π) and all negative angles are left as they are. |
| Left release: keep the angle in `+0x394`, release | CONFIRMED+ | `0x5607b1`: releases the capture if a left drag held it, then **always** recomputes the angle from the release x and `+0x3cc`, wraps it, clears `+0x3d0` and stores `+0x394`. It does not touch the models. |
| Right press/drag: pan x = x0 − dx·dist·2/width, y = y0 + dy·dist·2/height, z unchanged, clamped by `0x55e5b0` to the box | CONFIRMED | `0x56099c..0x560a12` (2.0 = `0xe1b898`; width/height = control `+0x48`/`+0x4c`). The box: x in [min(0, pos.x + aabb.min.x), max(0, pos.x + aabb.max.x)], y in [min(0, pos.y + 0.5·aabb.min.y) (`0xe1b7d0` = 0.5 double), max(0, entity `+0x22c`)] (`0x55f1c0`). Both start points live in `+0x3c8`/`+0x3cc`: **`+0x3cc` is shared** by the left drag (start angle) and the right drag (start y). |
| Right release: release | CONFIRMED | `0x56088a`: releases if a right drag held it; clears `+0x3d4`. |
| Wheel: delta > 0 → +2.0, else −2.0, clamped to [s + near, s + 40]; the look-at slides toward the pointer | CONFIRMED+ | `0x55ee20`: **delta 0 also counts as −2** (`jle`). Positive (wheel away from the user) **zooms out**. `0x55e6a0`: s = max(|Δz|, |Δx|) of the box, min = s + `+0x42c` (near 1.0), max = s + `+0x398` (40.0, ctor). Exact slide: `r = d / dist` (d = the clamped change; r = 0 → nothing); `vx = (2·px/w − 1) / proj._11`, `vy = −(2·py/h − 1) / proj._22` (px, py relative to the control; proj at `+0x478`); `w = vx·invView.row0 + vy·invView.row1 + invView.row2` (`0xaa3e65` = MatrixInverse of `+0x438`); `target.x −= r·dist·(w.x − fwd.x)`, `target.y −= r·dist·(w.y − fwd.y)`, z unchanged (0.0 × r); `dist += r·dist`; then the pan clamp. With the mall's fixed camera, w = (vx, vy, 1) and fwd = (0, 0, dist), so zooming in by 2 moves the target by 2·(vx, vy): the point under the pointer stays put. |
| Original resets target/distance; `+0x394` is reset only by the ctor (INFERRED) | CONFIRMED (now READ) | The only writers of `[reg+0x394]` in `0x55e000..0x562000` are `0x560815` (left release) and `0x560c00` (ctor); none in the mall code (the `+0x394` hits there are other classes). The window is rebuilt on every open, so it is 0 on each open. |

### 4c. The try-on

| Claim | Verdict | Evidence |
|---|---|---|
| Trigger: only Wear Item, in the cell menu or the bundle box (1703 → `0x7d9cd0` → `0x7df560`) | CONFIRMED+ | Menu thunk `0x7e65e0` (`ecx = menu+0x7b0` = the cell) → `0x7df560`. **But the bundle box's Wear Item is created disabled** (`0x7dcbb4..0x7dcbc5`: control 0x6a7, `0x655ec0(0)`, in `0x7dcb10`, which both bundle boxes use), and its handler would refuse a bundle anyway (`0x8bf0d0`). The only working trigger is the cell menu. |
| What can be worn: `+0x551` = avatar 3/1/13 except TypeID4 3, or 3/2/1 whose COS passes `0x666c00`/`0x666c40`; never a bundle | CONFIRMED, OPEN resolved | `0x7df430`. `0x666c00` = COS **1/2/3/3**, `0x666c40` = COS **1/2/3/4** (bionic bit set). MEASURED in this archive's data: avatar TypeID4 1 = hats (917 rows), 2 = dresses (827), **3 = attachments (wings, 640): never wearable here**, 4 = flags (68). Devil spirits (3/1/14) are not wearable either. COS 1/2/3/3 = the attack pets `COS_P_*` (9795 rows), 1/2/3/4 = the pick pets (26: `COS_P_BROWNIE`, `COS_P_CAT`, …); the 3/2/1/1 items are the attack-pet flutes, 3/2/1/2 the pick-pet scrolls. Horses (`COS_C_*`, 1/2/3/1) cannot be tried. |
| The gate `0x7df560`: busy `+0x7c8`, pending `+0x7dc`, `0x8bf0d0` (OPEN) | CONFIRMED, OPEN resolved | `c:0x7df56e`, `0x7df57b`, `0x7df58e`. **`0x8bf0d0` = the good holds more than one item** (`(+0x30 − +0x2c)/4 > 1`): the bundle test, on the good at cell `+0x544`. Also the package's scrap vector (`+0xbc`) must be non-empty. The item tried is the good's first item (`0x8bf090` → `+0x2c[0]`). |
| A 3/1 item must pass `0x8bb570(-1)`, else `UIIT_MSG_STRGERR_EQUIPITEM` via `0x7781b0(5, …)` | CONFIRMED | `c:0x7df5ef..0x7df657`; key at `0xda7468`; English "Cannot equip the selected item". (`0x4e8dd0` after it re-tests 3/1 and always passes here.) A COS item skips the test. |
| `0x8bb570` bits: 0x40 gender (ref `+0x1c4`, 2 = both), 0x200 race (ref `+0x9c`, 3 = both), 0x08/0x10/0x20/0x100 … OPEN | CONFIRMED+ | `0x8bb570`, all bits on with −1. The ones an avatar can fail: **0x01** item byte `+0x28` must be set; **0x02** the item must be 3/1 (so a COS item always fails, which is what routes it to the pet path); **0x04** if item `+0xf4` ≠ 0 then item `+0x98` ≠ 0; **0x08** ref `+0x1c8` ≤ player word `+0x21f`; **0x10** ref `+0x1cc` ≤ player word `+0x87e`; **0x20** level: the four (type `+0xd0+4i`, level `+0xe0+4i`) pairs, type 1 = character level, compared with the player byte `+0x21a`; **0x40** gender; **0x200** race; **0x800** item `+0x178` must not be 0 or 2 (default 3, `0x8ba750`). 0x80 (weapon/shield pairing, `0x56fa30`/`0x8bac40`), 0x100 (skill requirements) and 0x400 (TID 3/1/6/16 only, `0x56fb00`) never apply to avatars. **So a level requirement above the player's also refuses with the same line**, not only gender and race. INFERRED from the itemdata column order: `+0x1c8`/`+0x1cc` = ReqStr/ReqInt. |
| Putting on: one per exact TypeID1..4 (`0x7d8500(ref, 0)` on the first match), push ref `item+0x34` | CONFIRMED | `0x7d88c0`: XOR of the masks `0x1c`, `0x60`, `0x780`, `0xf800` (`c:0x7d891a..0x7d8944`); only the first match is removed. The list `+0x810` holds ref ids. Note "one attachment" in the spec's example is reachable only from the build (a worn attachment); the user cannot try one on. |
| If `0x8bb570(-1)` passes: `0x560030(+0x854, ref, 1)`: 3/1/13 or 3/1/14 by AttachAvatarVisual, else `InstallEquipVisual(ResolveVisualSlotForItem(TID), ref, 0, 0)`; rebuild; action `+0x5a0` | CONFIRMED | `0x560030`; entity vslot `0xbc(+0x5a0, 0, 0, 0, 1.0, 1.0)` at `0x560121`. It runs only if the model wrapper `+4` is set (render vslot `0xdc`). |
| Else a COS 3/2/1 item: COS T4 3 → `+0x85c` at (−5.5, 0, −2.5); T4 4 → `+0x858` at (4.5, 0, −2.5); made once, swapped, preview yaw, action 0. "INFERRED: 3 = a ride, 4 = a pet" | Positions CONFIRMED; meaning **WRONG, see W2** | `c:0x7d8a9d..0x7d8b0f` and `0x7d8b52..0x7d8bbd` (vector = {`0xdcc198` −5.5 / `0xdcc190` 4.5, 0, `0xdcc194` −2.5}); COS ref = `0x9461a0(item ref + 0x304)`; `0x561780` / `0x561170`; `0x55fe70` (position, then yaw = `+0x394`); `0x5602c0(idx, 0)`. |
| Anything else is pushed and draws nothing | CONFIRMED | `0x7d88c0` returns after the push. |
| Buy list: same first-item type removed (`0x7d8140(pkg, 0)`), then appended | CONFIRMED+ | `0x7d8720`: the test is **equality of the whole 16-bit packed TID** (`c:0x7d87bc` `cmp si, word [eax]`), and nothing happens when the good is 0 (the build's call). |
| Taking off `0x7d8500(ref, reapply)`; reapply puts the worn one back; COS model deleted | CONFIRMED | `0x55ff20(+0x854, ref, 1)` (entity vslot `0xc8`, then `0xa60470` or `InstallEquipVisual(slot, 0, 0, 0)`, rebuild, replay action); reapply loop over the five avatar slots with **full 16-bit TID equality** → `0x7d8bd0(slot, 0)`. COS: T4 3 → delete `+0x85c`, T4 4 → delete `+0x858` (`0x561480`), slot −1. |
| Lifetime: ends with the window, survives tabs/search/main page; reset only by Original and `0x7d8d60` | CONFIRMED | `0x79b580` (open only when not open; close unloads); callers of `0x7d8d30`: the message map (`0xd72b14`) and `0x7d8e15` in `0x7d8d60`, which is called only from `0x7de355`. |

### 4d. Original and Buy

| Claim | Verdict | Evidence |
|---|---|---|
| Original only with `+0x7c8` = 0: `0x7d8480` (+ `0x561040`), `0x7d8840`, `0x7d8bf0` | CONFIRMED+ | `0x7d8d30`. **It does not test `+0x7dc`**: pressing Original during a lump buy empties the buy list. The new body starts at yaw 0 while `+0x394` keeps the old angle (4b), so a pet tried on after Original stands at the old angle until the next drag. |
| Buy: `+0x7dc` = 0, `+0x824` ≠ 0, `+0x7c8` = 0; box ID 122, 368×348, class `0xeec628`, at `+0x7d8`, `0x7db490(&list)`; busy set | CONFIRMED | `0x7d7080` (`0x170`×`0x15c`, `push 0x7a`, `0x798b70`, `0x7d711e`) |
| Lump: `+0x7e8`, one good per message, next on each reply; reply calls `0x7d8140(pkg, 1)` and `0x7d8500(ref, 1)` | CONFIRMED | `0x7d7d80` sets `+0x7e8 = 1`; `c:0x87e2a3..0x87e2d5`. After each bought good the preview drops it and the player's own worn avatar of that type returns. |

### 4e–4g. Event picture, info block, silk lists

| Claim | Verdict | Evidence |
|---|---|---|
| 4e `0x7d76e0` reads `Mall_Open`, `Mall_BeginTime`, `Mall_EndTime`, `Mall_FrontImg`; event on → 103 and 101 shown, preview hidden; else preview shown | CONFIRMED | `0x7d91b4..0x7d9241`; path = base folder + `event\mall_notify.txt` (`0xdc8c28`). Off `0x7d6e60` hides 103 and 101 and shows 123. `Mall_Open "0"` re-MEASURED. |
| 4f info block controls and sources; `+0x160 == 4` hiding; 213 hidden | CONFIRMED+ | `0x7dd710`, refresh `0x7dd3a0`. **The block refreshes by polling every tick** (`vslot_012 0x7dd6a0`), not from the `0x3153` handler. |
| 4f Buy Silk / Coupon: `ShellExecuteW("open", "IEXPLORE.EXE", "http://…")`, disabled when the link is shorter than 5 | CONFIRMED | `0x7dd89d`/`0x7dd8bd`. This archive's Coupon link text is `"0"` (not empty); it is still disabled. |
| 4g two `HISTORY_FOR_BUYING_SILK` windows, button 132 disabled | CONFIRMED | `0x7d6eb0`/`0x7d6f50` |
| 4g "12 rows" | **WRONG, W7** | |
| 4g Inquiry `0x711a {1, index+1}`; close `{1, 0xff}`; `0xB11a` layout | CONFIRMED | `0x7ecb90`, `0x7eabe0`, `0x8990c0` |
| 4g the Obtained list's handlers only re-filter | UNVERIFIABLE | Not re-read |

## 5. Search

| Claim | Verdict | Evidence |
|---|---|---|
| All of §5: non-empty text, new view ID 0x1ffffff, every built good that passes the filter, substring match with no case folding, no de-duplication | CONFIRMED | `0x7e32d0`; `0x4ee310` is an exact wchar compare; there is no `+0x91c` test. |

## 6. The purchase flow

| Claim | Verdict | Evidence |
|---|---|---|
| 6a cell Buy → `CNewItemMallConfirmBuy` ID 1200, 338×212; busy; `+0x7c9` in the reserve view | CONFIRMED+ | `0x7ddb90`. **`+0x7c9` is set before the busy check**, so it is set even when the box is refused. |
| 6a bundle box Buy → the same handler; layout controls | CONFIRMED | `0x7d9d00`. Control 21's key is `UIIT_STT_AMOUNT` ("Quantity"). The spin buttons use `interface\outer\server_up/down.ddj`. |
| 6b price rows, labels, 30 px apart | CONFIRMED | `0x7e7c30`, `0x7d9420`. The Gift Silk row's unit is "Silk". After a quantity change (`0x7e8d10`) the silk row shows price × count − points used, and the point row shows the points used. |
| 6b quantity | CONFIRMED+ | Starts at 1 (`0x7e998d`). Spin-up is `0x7e8ab0` (the spec's `0x7e8b20` is inside it). Spin-down can reach 0. MaxStack only for a 3/3 item with scrap `+0x18` = 0; otherwise 5. |
| 6c check 1 slots `0x1807` | CONFIRMED+ | The one-slot exception has the same `+0x18` condition. A failed slot check **does not** close the box. |
| 6c check 2 `0x1880`, box closes; count 0 closes without sending | CONFIRMED | `0x7e8567..0x7e85c4`. Only the bit-0x2 (silk) price is tested. |
| 6c the dealing counter, group word, shop index, tab, slot, package id | CONFIRMED | `0x7d6d80`; `0x8264b4..0x826511`; package `+0xc` (`0x7e8786`) |
| 6c the u64 left out in one mode | **WRONG, W4** | |
| 6c the reply parser reads the request in the same order | CONFIRMED | `0x87eb50` case 0x18 |
| 6c lock `0xee9b10`, cleared by any `0xB034` | CONFIRMED+ | `0x7999c0(1)` also starts **timer 0xa for 3000 ms**; `0x87f3cf` calls `0x7999c0(0)`. |
| 6c `0x7978a0` "repeats checks 1 and 2" | **WRONG, W6** | |
| 6d `0xB034` result 1 layout | **WRONG, W5** | |
| 6d result 1 effects | CONFIRMED | `0x87ba20` case 0xa7: opens the mall if closed, creates the items (`0x6b7770`), refreshes the reserve list, continues a lump buy, drops the counter, plays `snd_equip`. |
| 6d result 2 | CONFIRMED | `0x7d6de0(1)`; log `0xddb0b4`. The code list was not re-read. |
| 6d `0x3153` | CONFIRMED | `0x882de0` → `0x778e50` |
| 6d `vslot_005(1)` | CONFIRMED+ | `0x778dc0(5000)` starts **timer 0xb, 5000 ms**. What timer 0xb does, who calls `vslot_005`, and where timer 0x96 is started are still OPEN. |

## 7. Textdata

| Claim | Verdict | Evidence |
|---|---|---|
| Parser offsets for refpackageitem, refshop, refshopgoods, refpricepolicyofitem | CONFIRMED | The table numbers were not re-read. |

## The Chest window

| Claim | Verdict | Evidence |
|---|---|---|
| Not in `sro_client.exe` | CONFIRMED | No `UIIT_STT_BOX`, `VPLUS` or `Chest` (ASCII or UTF-16) in `sro_client.exe`, `sro_client_NODLL.exe`, `sro_client.bak`, `silkroad.exe` or `replacer.exe`. The only "CHEST" is a pet error key. |
| The DLL is packed, with no readable strings | CONFIRMED+ | `vsroplus_lib.dll`'s code and data sections are empty on disk. One 13 MB `.vsroplu` section holds everything. It has `.detourc`/`.detourd` sections, i.e. Microsoft Detours: **it hooks client functions** rather than adding a layout file, which fits the absence of any layout (INFERRED). |
| "Its art and texts are vPlus's" | CONFIRMED, with a caveat | The vPlus chest art and 23 `VPLUS_*` chest and storage-box keys are present. **The archive also carries a second add-on, MaxiGuard** (93 files, among them `maxiguard\icon\chest\icon_*.png`), plus `interface\ifcommon\gopro\chest_guide_*.ddj`. "Not retail" is solid. "vPlus specifically" rests on the text keys alone. vPlus's columns are Name / Quantity / Type / Date, and the screenshot has "From", so the screenshot server's chest may be a third implementation (INFERRED). Either way, OpenSRO's chest is OURS. |

## Where item_mall.md and item_mall_wire.md disagree

1. The points u64: the wire doc says it is always present, and it is (W4).
2. `0xB034` success: the wire doc has the per-item rent blocks; the client spec does not (W5).
3. The request string: the wire doc reads it as the CodeName. That is right, and it is now READ here too.
4. `0x711a` senders: the wire doc lists six, the client spec two. This is not a conflict.
5. Neither doc says that `0x7978a0` checks differently from the confirm box (W6).

## Missed

### The try-on (in order of how badly an implementation would go wrong without it)

1. **The pets orbit with the drag** (W1). Each model's position is rotated with its yaw about
   the world origin. A newly added pet takes `+0x394` (the angle of the last left release), not
   the current drag angle. **After Original the body is at yaw 0 while `+0x394` keeps the old
   angle**, so a pet tried on next stands at the old angle. The next left press also resumes from
   the old angle, so the body jumps.
2. **Which items can be tried, exactly** (§4c): avatar hats, dresses and flags (3/1/13, TypeID4
   1, 2, 4) and the two pet kinds. **Not attachments (3/1/13/3, wings), not devil spirits, not
   horses.** Any level requirement above the player's (`0x8bb570` bit 0x20) also refuses, with
   the same line "Cannot equip the selected item", as do gender and race.
3. **The camera in full**: eye (0, 13, −35), at (0, 13, 0), up +Y, D3D left-handed, **vertical**
   FOV 60°, near 1, far 500, aspect = control w/h (215/332). The camera never turns; the models
   do. In OpenSRO's coordinates this needs the same z flip and BodyMirror care as the other
   `D3DSpace` screens (AGENTS.md). That is an implementation note, not a retail fact.
4. **Mouse edge rules**: a left press during a right drag (or a right press during a left drag)
   releases the capture and ends the drag. Left release always recomputes and stores the angle
   from the release x, even with no left drag active. `+0x3cc` is shared by the two drags. The
   wrap leaves angles in [2π, 4π) and all negative angles alone. Wheel delta 0 counts as −2, and
   **a positive wheel delta zooms out**. The exact zoom-to-pointer formula is in §4b.
5. **Every Wear Item restarts the stand** at t = 0 (the loop is replayed; fade-in 0).
6. **The pan box never includes the pets**: it is built once, from the body alone, by
   `0x561250` at build time. Pan clamps x and y only. The wheel's distance limits use the same
   box (s = max(Δx, Δz)).
7. **The scale is applied late for the player**: `0x5603b0` sets an identity world matrix, and
   ref `+0x110`/100 is applied only by `0x55f470` on the first drag. Pets get it at once. For
   bodies with scale 100 there is no difference.
8. **Original does not test `+0x7dc`**: pressing it during a lump buy empties the buy list.
9. **The bundle box's Wear Item is created disabled**, so the cell menu is the only working
   trigger.
10. One per exact type and the buy-list replacement compare different things. The try list
    compares TypeID1..4. The buy list and the reapply loop compare the whole 16-bit packed TID,
    the cash and bionic bits included.

### The rest

- `0x7121` is sent only when stock rows exist for the mall's shop group; with this archive F10
  opens the mall without it.
- Only the shop's first tab group is built (W10).
- The stock sold-out bug, and the stock key being shop group + package (W12).
- Cells draw the 64-px `icon64\…` icons. The cell menu covers the cell's lower right. Opening
  the menu sets the icon slot's byte `+0x39a` (meaning OPEN).
- F10 never closes the mall. `0xB121` result 2 fails silently. The warning box carries
  `mall_pic.ddj`.
- No bit-32 main-page section can exist. The unit field shows the Data column for non-bundles.
- Most actions also require `+0x7dc` = 0. A row click clears `+0x7c9`.
- **The confirm box has a second, non-mall mode.** With `CIFInventory` (class `0xeea7c8`) as
  its parent it checks gold (bit-0x1 price × count), fails with `0x180f`, and sends through
  `0x7950b0` (`0x7e8320`, `0x7e91c0`).
- The confirm box layout has two more sections, ConfirmPoint and StockQuantity: a stock edit 7
  with label 6 `UIIT_STT_SILKMALL_STOCK`, and an embedded `CItemMallUsePoint` (ID 400, 233×177;
  controls 40/41/50/20–23 from `ifitemmallusepoint.txt`). Its code is still OPEN.
- Opening the Buying list or the Obtained list makes it modal: it needs no box and no pending
  purchase, sets `+0x7c8 = 1`, and keeps the window in `+0x7c4`.
- With `0x703fc0()` ≠ 0 the gold price row goes through `0x6fc910(price, 1)` (possibly a tax;
  OPEN).
- The serializer clamps the struct's gold slot `+0x90` to 0..1e8 for op 0x18. That slot is not
  sent for 0x18.
- Popup control 14 is a `com_bg_tile_p.ddj` background at 32,32,63,79. Button 13's layout text
  is `UIIT_STT_SILKMALL_ZZIM` "Reserve"; the code replaces it.

## Counts

- **WRONG: 14** (W1–W14).
  - Three are in the try-on: W1 (the pets orbit), W2 (pets, not a ride), W3 (no effect on the
    mall).
  - Three are on the wire: W4, W5, W6. Implementing the requests from `item_mall_wire.md` was
    already right for W4 and W5.
  - Five change what the window shows or builds: W10, W11, W12, W13, W14.
  - Three are precision fixes: W7, W8, W9.
- **CONFIRMED: 90 table rows**, 31 of them CONFIRMED+ for behaviour the spec leaves out.
- **UNVERIFIABLE: 2** (2a "columns 6..9 unused"; 4g the Obtained-list handlers). The 6d error-code
  list was also not re-read.
- **Spec OPEN/INFERRED items settled: 14** (table above).
