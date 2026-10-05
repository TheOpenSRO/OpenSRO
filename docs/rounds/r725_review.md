# Round 725 review: lane A of the NPC GUI epic

This is an adversarial review of `dev..worktree-agent-a6d9501431861fa5c` (`f5bfd2ef`, `ed82522a`,
`760d4f6e`). Every claim below was re-read in the client binary (`/var/tmp/sro_client.asm` and the
decompiled dump on the render box), in the box's archive, or in the user's screenshots. No code was
changed.

## Verdicts on the two priority questions

### 1. White registry captions: correct for every registry window, but the label is wrong
**White is the original's rule for every registry window. It was never right to draw them beige,
so this is not a regression.** The colour is READ, not only MEASURED:

- **What sets the colour.** `CIFMainFrame::vslot_010` (0x816f80) creates the caption `CIFStatic`
  at +0x7b0. It sets the font and the H/V alignment, and never a colour.
- **The default is white.** Every window is a `CTextBoard`. Its constructor 0x655b50 runs 0x8b4f30,
  then 0x8b46d0, which writes `0xffffffff` to the five colour slots +0x10..+0x20. Those are the same
  five slots the colour setter 0x8b2b70 writes (the talk box's beige goes through 0x8b2b70).
- **Nothing overrides it.** No function in `CIFStatic`, `CIFWnd`, `CGWnd`, `CGWndBase`, `CIFFrame`,
  `CIFTileWnd` or `CIFMainFrame` calls 0x8b2b70. Of all functions, only two both touch `+0x7b0` and
  call 0x8b2b70:
  - `IFRequestGuildWar::FUN_0071bf30`: its +0x7b0 is a byte flag, not the caption;
  - `CICCos::vslot_009`.
- **Every framed class inherits it.** Each class framed through `REGISTRY_FRAMES` or the main popup
  is a `CIFMainFrame` subclass (RTTI): `CIF_NPCWindow`, `CIFStoreForPackage`, `CIFStorageRoom`,
  `CIFExchange`, `CIFSystemWnd`, `CIFPartyMatch`, `CIFAutoPotion` and `CIFMainPopup`. So all of them
  inherit the white caption.
- **The original agrees.** The party window in `party_refs/01_1RyCLTb.png` (the original client)
  also has a white "Party" caption.

**The windows the change affects:**
- the NPC window, the store and the storage;
- Exchange, System, Party Match and Auto Potion;
- the main popup (Inventory, Character, Skill, Party and the other panes).

All of them are correct now.

**The store tab caption is the same case.** `CIFStoreForPackage::vslot_010` creates each tab (gwnd
0xba20b0 at 0x6d2d85) and sets only its font and alignment (0x6d2da4..0x6d2dfa), never a colour. So
the tab's white is the `CTextBoard` default: READ, not MEASURED.

### 2. Duplicate text rows: round 634's rule is right for this binary, and the archive differs
**`TextStringManager` keeps the first row. Neither the service column nor the language column
picks the later row.**

**The loader keeps the first row (READ):**
- **One insert site.** 0x8cb266 is the only call to 0x8ca120 in the binary. The six CGame loads
  (0x849227..0x8493ad) and the recursive list load at 0x8cb0a2 all reach it through 0x8cac30.
- **The insert never overwrites.** 0x8ca120 is the MSVC `stdext::hash_map` insert, which walks the
  bucket and compares the keys (0x40eae0).
  - On an equal key it writes `{existing, false}` to the result pair and returns. It does not touch
    the value (the `-1 < 0` branch before LAB_008ca582).
  - The caller never reads `[esp+0x74]` after the call.
  - There is no assignment path.
- **The service column cannot select.** All six duplicate rows have column 0 = 1, so all pass
  0x8cb110.
- **The language column cannot select.** Row 649 holds its English in columns 8 **and** 9, so no
  choice of language column reaches row 7577.

**The archive explains the screenshot, not the loader.** The box's `textuisystem.txt` (13,915 lines)
is two whole tables concatenated:
- **Lines 1–6955** are 16-column rows: a private server's reworded English ("Party Information:",
  "&Team", "Teleport to [%s] for [%d] Gold.").
- **Lines 6956–13915** are 19-column rows: the stock English, typos included ("Party informaiton",
  "&Academy", "Teleport to [%s]area. [%d]gold").
- **5,181 keys appear twice**, and 404 of them with different English.

Prepending a block only makes sense on a client where the first row wins, which agrees with the
READ rule.

**The user's original shows the second (stock) block on every duplicated key checked: six keys.**
- **NPC lines (`npc_refs`):** `UIIT_CTL_TELEPORT_RESULT`, `UIIT_CTL_TELEPORT_TARGET` and
  `UIIT_CTL_RECALL_POSITION` (the spec).
- **The party window (`party_refs/01_1RyCLTb.png`):** "Party informaiton (Invitation of party member
  available)" and "Exp Auto Share". These are `UIIT_STT_PARTY_INFO`, `UIIT_STT_PARTY_JOIN_ANYONE`
  and `UIIT_STT_PARTY_EXP_SHARE`, whose first rows read "Party Information:", "Invitation of party
  members is active!" and "EXP Auto Share".

**So the user's own install differs from the box's.** One of two things holds:
- (a) The user's `Media.pk2` does not carry the prepended block. This is the likely case, since it
  matches "vanilla has only &Academy" from round 634.
- (b) The client's `vsroplus_lib.dll` patches the loader. The DLL is on the box, imported by
  `sro_client.exe` but not by `sro_client_NODLL.exe`. It is packed and carries Microsoft Detours
  sections (`.detourc`, `.detourd`, two `.vsroplu`), so it cannot be read statically here.

Either way OpenSRO reads each user's own archive, and with a stock table it shows the stock wording
under the first-row rule.

**Do not change `UiTextTable.keep_first`.** Re-label the spec's OPEN 9 (OPEN 8 in the round notes)
as "the box's archive is not the user's". It is settled by one fact from the user: the line count
or first line of their `textuisystem.txt`, or whether their stat panel reads "Phy. atk" or "Phy.
Atk:". Until then, every box render and every test that resolves a duplicated key shows the private
server's wording, and the user's client does not. That covers 404 keys, among them the party
window's strings and five NPC lines (the storehouse line, the three teleport lines and the job
lines).

## Findings, most severe first

### F1. WRONG-LABEL: the caption colour is called MEASURED and "not read"
- **Where:** `client/scripts/ui/hud/hud_window.gd` 95–107 (`MAINFRAME_CAPTION_COLOUR`), and
  `docs/rounds/r725.md` "Registry window captions".
- **Evidence:** as in verdict 1. The colour is the `CTextBoard` default `0xffffffff` (0x8b46d0), and
  CIFMainFrame's OnCreate leaves it alone.
- **Fix:** re-label the colour READ with those addresses. Remove "The colour is not READ, since
  nothing in OnCreate sets it". The beige that self-framed windows keep stays OURS.

### F2. WRONG-LABEL: the store tab caption colour is called MEASURED
- **Where:** `hud_panels.gd` `SHOP_TAB_CAPTION`, and `r725.md` "The caption is now white, MEASURED".
- **Evidence:** 0x6d2d85..0x6d2dfa sets no colour, so the tab draws the `CTextBoard` default.
- **Fix:** label it READ (the default).

### F3. WRONG-LABEL: the `#ifdef` table is called INFERRED
- **Where:** `client/scripts/ui/ui_builder.gd` 36–38 ("INFERRED, strongly: this is the table the
  layout parser's `#ifdef` consults"), and the spec's OPEN on the same point.
- **Evidence, both READ:**
  - **The parser consults this table.** The layout parser's directive switch
    (`IFTVariable::FUN_00b37a30`, case 1 = `#ifdef` from 0xb350f0) asks
    `IFTVariable::FUN_005004a0`. That looks the name up in the `std::map` at **0xeed4e0**
    (`mov ecx,0xeed4e0` at 0x500502, head 0xeed4e4) and returns its value, or 0 when absent.
  - **`define.txt` fills that table.** Its loader writes through 0x6441b0 with
    `ecx = [CGame]+0x660` (0x848355..0x8483ba). The CGame global is 0xeece80, so the map is
    0xeece80 + 0x660 = 0xeed4e0, the same one.
  - **Nothing else writes it.** The other callers of 0x6441b0 (0x64447e, 0x64456f, 0x6446ab,
    0x644719, 0x71be7e) write the silk-mall and other maps (`+0x7d0`, `+0x7f0`, `simple_msgbox_type`).
- **Fix:** label it READ and close that OPEN.

### F4. DEPARTURE (parser detail, harmless on this archive): `define.txt` is tokenised, not read by identifier
- **Where:** `ui_builder.gd` `parse_define_txt`.
- **Evidence:**
  - **The tokenizer.** The client splits each line on `=`, `"`, `,`, space and tab (`0x401070`
    with 0x3d, 0x22, 0x2c, 0x20, 0x09 at 0x8482e4..0x848341).
  - **What it stores.** It takes the first token as the name, and stores the second token's value,
    with 0 or absent forced to 1 ("%s Value 0 => 1", 0xdd3d50). So **every listed name is defined,
    even `NAME = 0`**.
  - **No comment handling.** It has none: a `// Define String` line defines the token `//`, which is
    harmless.
  - **The result here is the same.** On the archive's file (extracted on the box) the two parsers
    give the same 22 names.
- **Fix:** none needed now. If the parser is ever extended, it must not treat `NAME = 0` as
  undefined. Note the rule in the comment.

### F5. DEPARTURE (lane C data, recorded): the store line's red state is not modelled
- **Where:** `NpcTalkView.coloured` / `npc_service_reader.gd` store lines.
- **Evidence:** `FUN_006fb630` draws a store line in red **`0xffff4a4a`** (hover still `0xffff8a00`)
  in two cases:
  - the NPC has id 0x0f and `FUN_009870d0()+5 <= 2`, apparently a guild level of 2 or less;
  - the NPC has id 0x19 and both `0x997ea0` and `0x997f00` fail (the branches around `LAB_006fb9f5` / `LAB_006fbacf`).
- **Context:** none of the Jangan NPCs rendered has either id, so the renders are unaffected.
- **Fix:** add `COLOUR_MENU_DISABLED = 0xffff4a4a` with that rule, and record it in spec §1.

### F6. MINOR (answers OPEN 2 / spec OPEN 7): "Talk to this person." is registered by the quest objects
- **Evidence, in the server binary (`srgs.asm`):**
  - **Id 2 is pushed.** It goes through the NPC's `[vtable+0x164]` (the AddAvailableInteraction
    slot that `CGObjNPCNPC::Create` uses) at 0x88ea5b, in **`CQSP_ALL_POTION_3::vslot_017`**: the
    herbalist's potion quest, whose `SN_TALK_QSP_ALL_POTION_3_*` strings are set in the same
    function.
  - **Other quest classes push it too:** `CQNO_WC_PRIEST3_1::vslot_017` at 0x898557 and
    `CQNO_WC_SOLDIER_SO_1` at 0x89a36b.
  - **Unnamed functions push it as well:** 0x926ed0, 0x927040, `GObjPC::FUN_0092f740` and 0x931f30.
  - **The receiving object is INFERRED.** That `[edi]` there is the quest's talk NPC follows from
    the shape of the call.
  - **No id 10 push was found** next to a +0x164 load.
- **Conclusion:** it is a server gap, as the lane says. The server supplies id 2 in the `0xb045`
  interaction list while the NPC is the talk target of a quest the player can take or continue.
  Id 10's registrar is still OPEN.
- **Fix:** add these addresses to spec OPEN 7. Lane C sends id 2 from the quest state.

### F7. MINOR: the tax line's NPC set is broader than the original can be
- **Where:** `npc_talk_view.gd` `fortress_strid_for`.
- **Evidence:**
  - **The original's test is narrower.** `FUN_00700440` adds the line only when
    `*(npc+0x18c) != 0` and `+0x800 != 0`.
  - **Ours is wider.** It gives the line to every `_CH_` code, including the storage keeper, the
    guild NPC and the job NPCs.
  - **The label is honest.** The rule is labelled OURS in both the code and the notes.
- **Fix:** none required. When lane C reads `+0x18c`, restrict the line to it.

### F8. MINOR (pre-existing, round notes are ambiguous): our builds still read the four undefined branches
- **Where:** `r725.md` census table.
- **Evidence:** "Result: the branch is off" describes the original. OpenSRO builds `ginterface.txt`,
  `ifmessagebox.txt`, `ifquestslot.txt` and `pstitle.txt` read-all-branches, so it builds the
  `EVENT_FESTIVAL`, `PROVIDE_ITEM_BY_COUPON`, `EU_QUESTWINDOW_IMPROVE_SECOND` and
  `APPLY_GNGWC_SYSTEM_2007` branches that the original leaves off.
- **One build differs from the rest.** The store's and the NPC window's registry entries are parsed
  from `ginterface.txt` with the archive defines, so they come from a different parse than every
  other registry entry.
- **Fix:** reword the table as "original: off; OpenSRO: read" and keep it under OPEN 11.

### F9. MINOR: `archive_defines()` caches an empty result
- **Where:** `ui_builder.gd` `archive_defines()`.
- **Evidence:** when it is called before `_media_pk2` is set, it caches an empty array for good.
  Today the store is first built after the archive opens, so this does not trigger.
- **Fix:** cache only when `_media_pk2 != null`.

### F10. MINOR: the script count in the round notes
- `r725.md` says `check` "checked 616 scripts". This review's run of the same tree reports
  **615 scripts and 9 scenes, ALL LOAD**.

## Verified (no finding)
- **Scroll length and pitch (READ).** `CIF_NPCTalk::Create`:
  - child 10 (the text) → +0x7b0 and child 6 (the scroll) → +0x7b4;
  - `push 0x140` at 0x6fa1c9 into 0x65a390 on the scroll;
  - `push 0x12` at 0x6fa1e1 into 0x638c20, which writes text +0x39c;
  - +0x3a0 = 100 and +0x3a4 = 19.
- **Talk colours (READ).**
  - Tax line `0xffd6ff7e` and greeting `0xffffffff`: `FUN_00700440` lines 134/137.
  - Store lines `0xffefdaa4` / `0xffff8a00` / `0xffff8a00`: `FUN_006fb630`.
  - The tax line exists only under `+0x18c && +0x800`.
- **Store lines (READ, as the lane says).** `FUN_006fb630` walks shop → tab group and writes
  "`%d. `" + the group's name.
  - The archive's four shop tables have no service-0 rows, so the missing service filter in
    `ShopReader._rows` changes nothing.
  - `NPC_CH_ARMOR` gets two lines (GROUP1 and GROUP2), as the walk gives.
- **Chaining (READ).**
  - **Store line.** Kind 1 in `CIF_NPCTalk::FUN_007020c0` calls the parent's +0xac,
    `CIF_NPCWindow::vslot_043` 0x7040b0. That runs 0x78fc20 (`0x704b` while the talk object
    exists), then `0x652c00`: ShowWindow(0) (+0x5c), then 0x79a7e0, which plays
    **`snd_window_close`** (the UTF-16 string at 0xd9b18c; its sibling 0xd9b1b0 is
    `snd_window_open`). Only after that does the `0x7046` request go out (0x702316..0x702323).
  - **Warehouse line.** Kind 3 is ShowWindow(0) through +0x5c directly, then `0x7994c0`, which only
    fetches window 0x13. No sound.
  - **Hiding the NPC window does not close the store or storage.** `CIF_NPCWindow::vslot_023`
    (0x704100), on hide, closes:
    - windows 0x12c..0x130 through 0x79cbf0..0x79ce40;
    - the 0x7997f0 and 0x799800 windows through their own +0xac;
    - the 0x799930 window through 0x79e510;
    - window 0xd6.

    The store (0xf) and storage (0x13) are not among them.
  - **No double sound.** OpenSRO's `close("npctalk")` is a plain `hide()`, and `closed` (the close
    button's sound) is emitted only by `_on_close_pressed`. So the store line plays one close sound
    and the warehouse line none, as READ.
- **Store tab rect (READ and MEASURED).**
  - `{ebp, 0x26, 0x38, 0x18}` at 0x6d2d69..0x6d2d7d, so y 38 and 56x24.
  - Measured independently in `3Gw7Ene.png` (stdlib PNG reader, column x=400): the window's dark top
    edge is at y 373, and the tab art's grey top border at y 411 (blue from 414). 411 − 373 = 38.
  - The caption pixels are 255,255,255.
- **Rendered frames.** The lane's renders were deleted after measuring, as its notes say, and this
  review was not allowed to re-render (no `qa_shot.sh`). So OpenSRO's side of the geometry rests on
  the lane's table plus the fixture tests (386x451, clip 34,71 302x343, scroll 347,59 length 320,
  store 254x370, storage title not retitled).
- **Regressions checked.**
  - **The old talk window's users.** Its other users moved to `NpcTalkView.body_of`: the teleport
    list, `qa_press_talk_line` and refresh. `_talk_prompt` (guild name / leave and the recall box)
    still finds `_windows["npctalk"]`.
  - **Escape** still lists `npctalk`.
  - **The fallback** rebuilds a fresh self-framed window from `if_npctalk.txt`, and `compose`
    handles a window with no `GDR_NW_NPCTALK`.
  - **`npc_service_reader`.** "Buy" stays as the stand-in when no tab group resolves. Its gate
    greeting change keeps every owner with a non-empty code.
  - **With a server.** Goods are still the archive's tabs (now per tab group), and the server is
    only asked for prices of those ids (`open_shop` → `NetClient.list_shop(ids)`). Both the `shop:`
    and the `shop` paths call `open_shop` identically.
  - **The store's build** is the only build changed by `define.txt` (`ARCHIVE_DEFINE_PANELS =
    ["store"]`; `PANEL_DEFINES` lost only `"store": []`). The NPC window's registry entry is parsed
    with the defines, but `if_npcwindow.txt` holds no `#ifdef`.
  - **Title colour.** The only window whose title colour changed is each registry window (verdict
    1), and that change is correct.
- **`define.txt` content.**
  - The file was extracted on the box: 22 names, CRLF, EUC-KR comments.
  - `RENEWAL_SHOP_SYSTEM` and `RESTORE_SOLDITEM_INSHOP` are present.
  - `EVENT_FESTIVAL`, `PROVIDE_ITEM_BY_COUPON`, `EU_QUESTWINDOW_IMPROVE_SECOND` and
    `APPLY_GNGWC_SYSTEM_2007` are absent, so the original leaves those branches off (0x5004a0
    returns 0 for an absent name).
  - The client parser knows only `#ifdef`, `#else` and `#endif` (0xb350f0). It has no `#ifndef`.

## Tests
The suite and the compile check ran on the render box with
`RENDER_DIR=/opt/opensro-client-r725rev` and `GODOT_LOCK=/var/tmp/r725rev/lock`:
- `remote_godot.sh tests`: **236 suites, 0 failing**;
- `remote_godot.sh check`: **checked 615 scripts and 9 scenes, ALL LOAD**.
