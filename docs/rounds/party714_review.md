# Round 714 review (lane C2): the party-matching client

Independent review of `int/party..d199865d` (`1660c7df`, `fc998c70`, `d199865d`; base
`85e6c063`), against `docs/protocol/party_gui.md` §3-§6, the party-match rows of
`party_protocol.md`, rounds 713 and 713-review, and `sro_client.exe` itself. Every claim below was
checked in the decompile (`/var/tmp/decomp_client`) **and** the asm (`/var/tmp/sro_client.asm`),
with the strings read out of the exe. Layout claims are pixel measurements of the lane's kept
frames (`/var/tmp/c2/keep/`, 1280x720, ImageMagick) against `Media.pk2`'s layouts and the user's
screenshots 02, 06, 07, 08 and 09. Race and Purpose as text is the user's decision and is not
flagged.

Totals: **6 BUG, 13 DEPARTURE, 11 WRONG-LABEL, 4 LAYOUT, 0 REGRESSION, 3 MINOR.** The full suite is
green (below). Most departures are cheap. Three are behaviour the player sees: the buttons during an
auto run (B1), the name colour in both popups (B2), and the register dialog closing on OK (D1).

## BUG

### B1. Auto match leaves every button live while it runs
- **Where:** `client/scripts/ui/hud/party_match_window.gd:318` (`enabled()`: only `progress_box`
  disables anything).
- **Evidence (READ):**
  - `0x73ebc0` (Auto match OK) sets `[0x110f80c+0x64c] = 1` and calls `0x738890(1)` (`0x73ed8f`).
    That disables IDs 0xf, 0x11, 0x12, 0x13, 0x14, 0x37 and 0x38: Join, Auto, Form, Change,
    Delete, Search and Refresh.
  - The tail of the enable rules does the same while the run lasts: `0x7384a0` at `0x73868c`
    checks `[edx+0x64c]` and calls `0x738890(1)` at `0x73869f`.
  - The progress window's close also re-disables them while a run is going (`0x7390b0(0)`,
    `0x7391e3`).
  - They come back only when the run ends: `0x8848da`/`0x884961` (`0x738890(0)` on AUTO_FAILURE)
    and `0x73edb0` (no candidate).
  - An auto run never opens the joining window: `0x786e70` only sends `0x706d`. So in ours
    `progress_box` is null for the whole run, and Join, Auto match, Form, Search and Refresh stay
    usable. A second Auto match restarts the queue mid-run, and Join sends a parallel `0x706d`.
- **Fix:**
  - In `enabled()`, return false for the seven IDs while `state.auto_running`.
  - Call `update_buttons()` when the run ends: the `_on_join_result` paths that end it, and the
    joined branch.
  - Test the disable from `start_auto` through AUTO_FAILURE.

### B2. The names in both PML popups are the wrong colour: the four numbers are A,R,G,B
- **Where:** `client/scripts/ui/hud/party_match_box.gd:188-196` (`sml2_to_bbcode` drops the
  *fourth* number). The same claim is in `docs/protocol/party_gui.md` §4's table, "(255,239,218)".
- **Evidence:**
  - **MEASURED, screenshot 08:** the "[Dasha]" pixels are **(230,219,171)**. The rest of the line
    is (255,255,255).
  - **Ours, `A2_leader_popup.png`:** the name is drawn (255,239,218).
  - **ARGB fits.** `255,239,218,164` read as A,R,G,B is **(239,218,164)**, within (9,1,7) of the
    screenshot. The lane's reading is off by (25,20,47).
  - **The census proves the order.** I counted every `<font color>` value in `textuisystem.txt`.
    Each one starts with 255: 16x `"255,0,0,0"`, 3x `"255,255,0,0"`, 7x `"255,0,216,255"`, and so
    on. Read as RGBA, `255,0,0,0` would be invisible red. Read as ARGB it is black. The resinfo
    files use the same order: buttons' `FontColor` `255,255,247,202` is the pale-yellow button
    text.
  - Screenshot 09 shows the same pale gold on "[Dasha]" and "[Tobi]".
- **Fix:**
  - Parse `a,r,g,b` and use `Color8(r, g, b, a)`.
  - Relabel the colour MEASURED (the census plus screenshots 08/09).
  - Correct party_gui.md §4 and §5 to (239,218,164).

### B3. The registration made from the `0xb069`/`0xb06a` echo has race 0 and 1 member
- **Where:** `client/scripts/net/party_match_state.gd:170-178`.
- **Evidence (READ, `0x97c530`, called by both echo handlers):**
  - number = the entry's; time (+4) = 0;
  - **race (+8) = the player's own model's `+0x9c`** (`[eef5ec]->vfunc 0x90`);
  - **members (+9) = 1 out of a party, else the party's count** (`0x986f50()+0x10`);
  - purpose and flags are swapped into place from the entry's +9/+8; levels; title;
  - the name is the player object's `+0x44` string.

  Ours makes a new `Row` with the defaults `race 0` and `members 1`. So until the next page:
  - a European player's own row reads "CHN";
  - a leader who registers a 3-person party sees "1/8".
- **Fix:** fill race from the player's model and members from `party.members.size()` (or 1). On a
  modify, refresh them too, because `0x97c530` rewrites all of them.

### B4. A page with no rows does not clear the registration
- **Where:** `client/scripts/net/party_match_state.gd:144-163`.
- **Evidence (READ):**
  - `0x8841f0` builds a page object only when `n != 0` (`0x882ff0`). It then calls
    `0x97ddf0(index, page)`.
  - When the page object is null, `0x97ddf0`'s tail runs `lea ecx,[ebp+0x8]; call 0x97c3b0`
    (`0x97de79`). That zeroes the registration at `0xeeec58+8`, the one `0x97b950` returns.
  - With `n > 0` and row 0 not the player's, nothing clears it. Ours matches that case.
- **Why it matters now:** round 713's review added silent 60-minute expiry. The original then
  sends `[1][0][0][0]` when no listings are left, and the client unpins its stale row. Ours keeps
  it pinned, with Change and Delete live, until a delete fails `0x2c1c`.
- **Fix:** when `p.rows.is_empty()`, set `registration = null` and `registration_entry = null`.
  Test it with `b06c_empty`.

### B5. An 8 MB build artifact is committed: `server/partybot`
- **Where:** `fc998c70` adds `server/partybot`, an "ELF 64-bit ... with debug_info, not stripped"
  of 8 077 026 bytes. `.gitignore` lists `/server/server` and the other tool binaries, but not
  this one.
- **Fix:** before the lane is merged, drop the file from `fc998c70` with a rebase (rebasing the
  branch, not `int/party`) and add `/server/partybot` to `.gitignore`. Once the file reaches
  `int/party` or `dev`, it stays in the history for good.

### B6. The match controller outlives its HudPanels and stays connected to `NetClient.party`
- **Where:**
  - `party_match_window.gd:101-114`: the lambdas on `state` capture `self`, and `party.changed`
    is connected to `_on_party_changed`;
  - `hud_panels.gd:386-417`.
- **Evidence (MEASURED, a probe run on the box, since deleted):**
  - I built a `PartyMatchWindow` over a `PartyState`, then dropped every reference and freed its
    window.
  - `weakref` still resolves.
  - `party.changed` keeps 1 connection, before and after the state is dropped.

  `NetClient.party` is the autoload's own object and lives for the whole process. So every
  HudPanels rebuild, for example at each world entry, leaves one more controller listening.
  - Each listener runs `_on_party_changed`.
  - If its stale state still holds a registration whose name is the character's, a full party
    makes each stale controller send its own `0x706b`.
  - The extra deletes come back as `0xb06b [2][0x2c1c]` lines.
- **Fix:** on HudPanels `_exit_tree`, disconnect `party.changed` and clear the state's signal
  connections. Or hold the controller with a weak `self` in the lambdas, and disconnect in a
  `dispose()`.

## DEPARTURE

### D1. The register dialog closes on OK, not on the server's echo
- **Where:**
  - `party_match_window.gd:473-484`: the submit handler leaves the box up, and `_close_register`
    runs on `register_done`;
  - `party_match_state.gd:180`.
- **Evidence (READ):**
  - `0x73f370` (OK) sends the request, `SendOnRegisterPartyReq` or `SendPartyMatch_HandleModify`.
  - It then calls `(**(code **)(*param_1 + 0xac))()`, the same close the auto dialog uses after
    its OK (`0x73ee30`), and `0x73f2b0`.
  - The echo handlers `0x883f90`/`0x8840d0` close nothing. The `0x73f300` they call is the
    `CPartyRegData` constructor (it zeroes +0..+0xb and the string), building the local the echo
    is read into.

  So in the original, a server refusal (`0x2c1b`, `0x2c20`, `0x2c23` ...) arrives with the dialog
  already gone. Ours keeps it up.
- **Fix:** close the box in the `submitted` handler after sending, and drop `register_done`'s
  close. Correct the notes (W4).

### D2. A click on an empty row clears the selection; the selection belongs to the slot
- **Where:**
  - `party_match_window.gd:361-366` (`select_slot`: "an empty row does not");
  - the test asserts the opposite at `party_match_window_test.gd:190`.
- **Evidence (READ, `0x73aab0`, asm):** for the slot under the mouse, the click does three things
  in order:
  1. It resets the previously selected slot's bar first: `0x73aaed` loads `+0x7ec`, then
     `0x740ca0(0)`.
  2. It stores the clicked slot (`0x73ab02`) and calls `0x740ca0(1)`.
  3. That call returns 0 for a slot without data (`+0x3b4 == 0`). Then `+0x7ec` is zeroed
     (`0x73ab11`).

  So an empty row deselects. The selection is the **slot** (`+0x7ec`), not an entry number:
  - Join and Whisper read the slot's number (`0x740740` = `slot+0x36c`);
  - the bar stays on that slot across redraws (`0x740d30` resets it only when the slot is
    emptied).

  Ours keys the selection by entry number, so after a scroll or a new page the bar follows the
  entry.
- **Fix:**
  - Store the selected slot index.
  - On a click: clear, then select only if the slot has data.
  - On a fill that leaves the slot empty, deselect.
  - Correct the test.

### D3. The party window's Settings button is locked while registered or while matching is open
- **Where:** not built. Not in the gap list.
- **Evidence (READ):** `0x6d5ab0(enable)` is CIFParty's toggle of control **0x15 = 21 =
  `GDR_PTY_BTN_SETTING`** (`push 0x15` at `0x6d5ab2`, on the pane returned by
  `IFMainPopup::0x6a1de0`). Its callers:
  - `0xb069` OK: `0x884040`, disable;
  - `0xb06b` for the own number: `0x880268`, enable, only when not in a party and the matching
    window is closed;
  - opening the matching window: `0x79c252` in `0x79c170(1)`, disable;
  - closing it with no registration: `0x79c2fd`, enable.

  Ours leaves Set enabled out of a party at all times. `HudPartyPane._refresh_out_of_party`
  forces it on.
- **Fix:** expose a "matching lock" on the party pane. Set it from the four points above, and make
  `_refresh_out_of_party` honour it.

### D4. The auto-match dialog's starting choices are READ, and they are not the lane's
- **Where:** `client/scripts/ui/hud/party_match_auto.gd:42, 46, 54-55`. The header labels this
  OURS: "the dialog's own defaults were not read".
- **Evidence (READ, `CIFPartyMatchAuto` Create `0x73e790`):** the radios are `+0x7bc` objective
  (ID 35), `+0x7c0` race (37), `+0x7c4` exp (39) and `+0x7c8` item (40) (`0x73e7f0..0x73e827`).
  - The end of Create chooses race **2** (Open), exp **1** and item **1**: `0x73eb83..0x73eba8`.
  - Exp's items are `[EXP_SHARE, EXP_SELF]` (pushed `0xd9cf5c` SELF then `0xd9cf8c` SHARE, so
    item 0 is SHARE). Exp 1 is therefore "Exp Free-For-All", and item 1 is "Item Free-For-All".
  - The objective gets **no** `0x6579b0` at all. The job branches only disable items:
    `0x73e949..0x73e995`.

  Ours:
  - copies exp and item from the party settings block;
  - picks the first allowed objective (Trade for a trader, where the original leaves the radio's
    initial item, which is disabled for any job holder).
- **Fix:**
  - `choose("exp", 1)`, `choose("item", 1)`, labelled READ.
  - Leave the objective as the radio's initial item rather than `allowed[0]`, and say what that
    item is once CIFRadioButton's constructor is read; otherwise label `allowed[0]` OURS with
    this evidence.

### D5. The title column fits to 302 px and adds "..."
- **Where:** `party_match_window.gd:280-281` (`clip_text` on the 306-wide static).
- **Evidence (READ):**
  - `0x740d30` calls `0x8b47c0(…, 0x12e, 1)`.
  - `0x8b47c0` fits the text and, when it was cut, appends `L"..."` (`0x4780b0(&0xe17a40, 3)`;
    the bytes at `0xe17a40` are `2e002e002e000000`).
- **Fix:** fit the title to 302 px and append "..." when it is cut (Godot's
  `OVERRUN_TRIM_ELLIPSIS` on a 302-wide label is the nearest). Label it READ.

### D6. Search's level edge cases
- **Where:** `party_match_window.gd:500-520`.
- **Evidence (READ, `0x73b780`):**
  - min = `atoi(edit 0x31)`, and a value below 2 becomes **1**;
  - max = `atoi(edit 0x32)`, and **0 becomes 110** (`if (bVar3 == 0) bVar3 = 0x6e`);
  - **when min > max, nothing happens**: no filter and no NORESULT. The whole body is under
    `if (bStack_4e <= bVar3)`.

  Ours:
  - treats a max of "0" as 0, so every row fails and NORESULT appears;
  - refilters and says NORESULT when min > max.
- **Fix:** mirror the three rules in `search_filter`/`press_search`.

### D7. Register OK: the title test is "empty", and there is no "max > 110" test
- **Where:** `client/scripts/ui/hud/party_match_register.gd:113-117`.
- **Evidence (READ, `0x73f370`):**
  - the only checks are `min < 1 || max < min` (ERROR_LEVEL) and an empty title after the
    multibyte conversion (`iStack_18 == 0`);
  - a title of spaces passes;
  - there is no upper bound at OK. The edit itself carries the range 1..0x6e:
    `0x634ee0(1,0)` and `0x634f20(0x6e,0)` at `0x73fa45`/`0x73fa50`, the same at
    `0x73faa8`/`0x73fab3`.
- **Fix:** test `title == ""` instead of `strip_edges()`. Clamp the level edits to 1..110 as you
  type, and remove `max > 110` from OK. (How CIFEdit applies the range was not read; clamping is
  INFERRED.)

### D8. The joining window disables only five buttons, and re-enables them outright
- **Where:** `party_match_window.gd:58, 318-320`.
- **Evidence (READ, `0x7390b0`):**
  - Open (`0x73915e..0x739253`) disables **0x12, 0x11, 0xf, 0x37, 0x38**: Form, Auto, Join,
    Search and Refresh. Change and Delete are untouched.
  - Close (`0x7391f6..0x739253`) pushes **1** for the same five, enabling them without
    re-running `0x7384a0`. When an auto run is going, it calls `0x738890(1)` instead.
  - The seven-ID list the notes cite (`0x738890`) is the auto-run disable (B1), not the joining
    window's.
- **Fix:** disable the five while the box is up. On close, enable those five, or keep re-running
  the rules but label that OURS. Change and Delete are already off with no registration, so the
  visible difference is small.

### D9. The Refresh lock restarts with every enable-rules pass
- **Where:** `party_match_window.gd:523-537`.
- **Evidence (READ):**
  - `0x7384a0` ends with `push 0x7d0; push 0xa; call 0xb93320` (`0x7386a4`), which re-arms
    timer 10 for 2000 ms.
  - `CIFPartyMatch::vslot_005` (`0x73ab60`) enables 0x38 when timer 10 fires.
  - Refresh itself (`0x732a80`) disables 0x38 and arms the same timer.

  So Refresh comes back 2 s after the **last** rules pass, usually the page's arrival, not 2 s
  after the press.
- **Fix:** restart `refresh_locked_ms` (only if it is running) in `update_buttons`/`refresh`.
  Label it READ.

### D10. Whisper's own-entry test is by number
- **Where:** `party_match_window.gd:396-400`.
- **Evidence (READ, `0x7386e0`):**
  - It refuses when the selected slot's number equals the registration's (`local_58[0] != iVar2`).
  - `0x7ab470` then refuses the player's own name.

  In a party whose pinned entry is the leader's, the original does not whisper from that row. Ours
  compares the leader's name with the player's own, so it does.
- **Fix:** also refuse when `row.number == state.registration.number`.

### D11. Confirm needs a job id and a requester JID
- **Where:** `client/scripts/ui/hud/party_match_req_join.gd:69-70`.
- **Evidence (READ):**
  - `0x73fc40` sends only when `+0x7b8 != 0 && +0x7bc != 0`.
  - Cancel (`0x73fc90`) and the timer (`0x73fb70`) have no such test.

  The server's job ids skip 0 (`match.go:544-547`), so this is unreachable today.
- **Fix:** add the guard to `press_confirm`.

### D12. The boxes belong to the matching window, which cannot close during a join
- **Where:**
  - `party_match_window.gd:577-582`: the boxes go on HudPanels and survive the window;
  - nothing blocks the window's close.
- **Evidence (READ):**
  - Closing the window (`0x79c170(0)`) first asks `0x732ae0`, "is child 100 (the joining window)
    up", and does nothing if it is.
  - The register, auto and joining windows are children 105, 110 and 100 of `PartyMatch`
    (`0x7392c0`, `0x739400`, `0x7390b0`), so they go with it.
- **Fix:**
  - Refuse to close the window while `progress_box` is up.
  - Close `register_box` and `auto_box` when it closes.
  - The leader's popup is a top-level window (`GDR_PARTY_MATCH_REQ_JOIN`), and stays as it is.

### D13. A delete result for another number
- **Where:** `party_match_state.gd:192-199`.
- **Evidence (READ, `0x8801e0`):**
  - With the current page cached, it removes the record (`0x97dd40`); with no page, it asks for
    the page again (`0x706c`).
  - With the window open, it also removes the record from both display lists (`0x73a700`).

  Ours removes it from `rows` only, so a filtered view (`_filtered`) still shows it.
- **Fix:** also remove the record from `PartyMatchWindow._filtered`, for example through a
  `removed(number)` signal. Requesting the page when the list is empty is optional.

## WRONG-LABEL

| # | where | says | what is true |
|---|---|---|---|
| W1 | `hud_panels.gd:465-472`; notes, OURS table; party_gui.md gap item 7; party_protocol.md "Whisper ... INFERRED" | Whisper is OURS: "the original opens its whisper window" | **READ, and ours is identical.** `0x7386e0` → `0x777d10` (chat window, child 1) → `0x7ab470`. That function builds `L"$"` (`0xdbb848`) + the name + `L" "` (`0xe19330`), sets it as the chat input's text (`[+0x4a0]->vfunc 0xb4`), and focuses it (`0x799630` → `0x7a9a70` → SetFocus `0xb9d9f0`). It skips the player's own name |
| W2 | `party_match_req_join.gd:18-19`; notes, OURS table | the popup is centred as OURS; "0x79c330 does not move it" | **READ.** `0x79c330(1)` calls `0x79ac50(0x83)` at `0x79c39b`, which centres window 0x83 (`w/2 - ww/2`, `h/2 - wh/2`). Same result, wrong label |
| W3 | `party_match_window.gd:29-32`; notes, "What is built", 3rd bullet | the joining window disables "IDs 0xf, 0x11..0x14, 0x37, 0x38 (`0x738890`: READ, the asm list, which adds Change and Delete to the spec's five)" | `0x738890(1)` is the **auto-run** disable (`0x7384a0` tail, `0x73ed8f`). The joining window's own list (`0x7390b0`) is the spec's five. The spec was right (D8) |
| W4 | notes, "What is built" (`0xb069` OK: "the dialog closes (`0x73f300`)") | `0x73f300` closes the dialog | `0x73f300` is the `CPartyRegData` constructor. OK closes the dialog (D1) |
| W5 | `party_match_window.gd:36-39`; notes, OURS table; test line 248 | a new page clearing the filter is OURS ("whether 0x73b5b0 re-applies it was not read") | **READ.** `0x73b5b0` empties both lists (`0x73aa40`) and refills both from the page (`0x73b4d0` pushes each record into `+0x7c0` and `+0x7d0`), skipping the registration's number. The edits keep their text. The filter is not re-applied |
| W6 | `party_match_window.gd:188-191`; notes, OURS table | the combo art is OURS, "CIFComboBox's own art was not read" | **READ.** `CIFComboBox::vslot_010` (`0x6327f0`) builds the arrow from `com_qst_downarrow_button.ddj` (20 wide), the field from `com_blacksquare_`, and the fill `0xff000000`. Those are the Option page's pieces |
| W7 | `party_join_progress.gd:12-13`; notes | the `0x884a0c` close argument is "INFERRED 0" | **READ 0.** `ebx` is the null `0x8849b8` tests the window pointer against, and `push ebx` at `0x884a01` |
| W8 | `party_match_confirm.gd:12-13`; notes, OURS table | the question's style 1 is INFERRED | `0x738940` pushes **1** at `0x738986`, right before the two string objects (message `0xdb3868`, caption `0xd89140`), as `0x788270`'s third argument. Trace it into `0x643e50` and label it READ |
| W9 | `party_match_window.gd:589-590`; notes, OURS table | the full-party delete's caller "was not read" | The only caller is `0x886c79`, inside `UI_PARTY 0x886b10`'s member-joined branch. Calling it on every party change is equivalent, but should say so |
| W10 | `party_match_auto.gd:18-20` | the starting choices are OURS | READ (D4) |
| W11 | `docs/protocol/party_gui.md` §4 (DESC_PML row), §5; `party_match_box.gd:184-187` | the name is (255,239,218), "the fourth number dropped (INFERRED from screenshots 08 and 09)" | (239,218,164), ARGB, MEASURED (B2) |

## LAYOUT

The window's origin in the kept frames is (248, 120). I measured it from the gold bar's
(255,178,82) rows at y 266/285 (rows 2/21 of the 24-px slot at 264) and its left edge at x 278.

### L1. The `~` between the level edits is missing
- **Where:** `party_match_window.gd:175-196` (`_build_search` never sets ID 43).
- **Evidence:**
  - **READ:** `CIFPartyMatch::Create` sets control 0x2b's text to `L"~"`: `push 0x2b` at
    `0x73af56`, then `[+0xb4](0xd884b0)` at `0x73af69`. The bytes at `0xd884b0` are `7e 00 00 00`.
  - **MEASURED:** no glyph pixels between the two boxes in `A2_selected.png` (x 674..694).
  - Screenshots 02, 06 and 07 show "1 ~ 100".
- **Fix:** set `GDR_PARTYMATCH_SEARCH_LEVEL_DIV_STA`'s text to "~". Label it READ.

### L2. The purpose combo's text is centred; the original right-aligns it
- **Evidence:**
  - **READ:** Create calls `[combo+0x84]->vfunc 0x14(2)` (`0x73b062..0x73b073`). That is the same
    alignment slot the radio labels use (`0x657eab..0x657eba`, value `+0x37c`, where 1 is
    centred).
  - **MEASURED:** "All" spans x 521..533 in the 501..555 field, centred.
  - In screenshots 02, 06 and 07, "All" ends about 6 px left of the arrow.
- **Fix:** right-align the OptionButton's text in this combo (alignment 2). Label it READ.

### L3. The objective radio's labels run into the next item, and past the frame
- **Where:** `party_match_register.gd:54` and `party_match_auto.gd` (the geometry is READ
  correctly: origin 0,0, pitch 66, label x 22, width 50).
- **Evidence (MEASURED, `A2_register_dialog.png`, box at x 483):**
  - "Trade Union" runs from 667 into the Thief dot at 711..727 ("Trade U" shows).
  - "Thief Union" spans 729..794, past its 50-px label (ends at 783) and onto the frame (the box
    ends at 797).
- **What I read of the original:**
  - The label is a `0xee9720`-class child at (dot x + 0x16, y + 3, 0x32, h - 4), with text
    margins zeroed (`0x6527d0(0,0,0,0)` at `0x657edc`).
  - Whether that class clips its text was **not** settled in this review.
  - The original clips **title** text explicitly (`0x8b47c0`, D5). That suggests statics do not
    clip on their own, but that is INFERRED.
- **Fix:** keep this as an open item and say so. Do not clip by guess.

### L4. Pre-existing in HudPanels and UiBuilder, but in this lane's window and not in its gap list
- **The Title header is blank.** I counted 0 text pixels at x 520..820, y 242..266.
  - `GDR_PARTYMATCH_SLOTLIST_SUBJECT` is a `CIFBarWnd` on `com_bar02_` with
    `Text=UIIT_STT_LETTER_TITLE`.
  - It is built through the 3-slice path (`_build_frame`), which drops the text.
  - Screenshots 02, 06 and 07 show "Title".
- **The `GDR_PARTYMATCH_SLOTLIST_DUMY` static draws a literal "L"**: 13 text pixels at
  x 993..1006, from `Text=STRING,"L"`. The screenshots show that cell empty. Presumably "L" is a
  missing text key that the original resolves to nothing; that is INFERRED.
- **The edit digits sit low.** The search edits' glyphs span y 204..212, against an edit at
  198..213 and a BG tile at 199..211.
- **The page spin's digit sits low.** Its glyph reaches y 575, below the spin's 557..573 rect. The
  screenshots centre it between the arrows.

## MINOR

- **M1.** An unknown result byte in `0xb06c`, `0xb069`, `0xb06a` or `0xb06b`
  (`party_match.gd:143-215`) becomes a `Result`/`Page` with `ok=false, code=0`. The state then
  emits a notice with an empty key, and World3D logs "code 0x0". The original ignores such a
  packet (`else if (local_3d == '\x02')`, no else). Return null for a kind other than 1 or 2.
- **M2.** `hud_panels.gd:2961` truncates `delta*1000` to an int on each frame, so the 2 s lock runs
  about 2.08 s at 60 fps. Accumulate a float.
- **M3.** The original's scroll range is "records − 12" even with the registration pinned
  (`0x73b5b0`/`0x73b780`: `count - 0xc`). So with a registration, the last record cannot be
  scrolled into view. Ours allows 11 rows. Since the bar is OURS (not drawn), say so in the OURS
  table. The bar itself is cheap to build: `hud_chat.gd:186-200` already reads CIFVerticalScroll's
  art and geometry. "Not drawn" is therefore not the least-invented choice.

## Each OURS choice, against the original

| OURS choice | verdict |
|---|---|
| no scroll bar | Still OURS. It can be built from hud_chat's READ CIFVerticalScroll (M3) |
| no header sort | Still OURS (comparators `0x7326e0..0x7329c0`, handler `0x73e050`, not reviewed for build) |
| no row tooltip | Still OURS (`0x740750`) |
| a new page clears the filter | **READ** (W5) |
| the popup centred | **READ** (W2) |
| the combo art | **READ** (W6). The text alignment is READ too, and wrong (L2) |
| Whisper as `$name ` | **READ**, identical (W1) |
| "Trade Union" at 50 px | Not settled. See L3 |
| radio label alignment left where Create sets none | Not contradicted. The register objective and auto race radios have no `0x657950` call |
| the auto dialog's starting choices | **READ**, and different (D4) |
| the delete question's style | Readable (W8) |
| the full-party delete on every party change | Caller read (W9) |

## Verified correct

- **Codecs.** Each matches `party_protocol.md`, the fixtures and the client readers:
  - `0x7069`/`0x706a` entry: u32, u32, u8 flags, u8 purpose, u8, u8, str.
  - `0x706b` u32, `0x706c` u8, C->S `0x706d` u32.
  - `0x306e`: u32 job, u32 JID, u8 answer.
  - `0xb069`/`0xb06a`/`0xb06b`/`0xb06d`: result byte, then the payload or a u16 code.
  - `0xb06c` row order: number, time, name, race, members, flags, purpose, min, max, title.
    `0x8841f0` reads +8, +9, +0xb, +0xa, +0xc, +0xd. Count comes before index:
    `0x97b930(second, first)` puts the index at +4, which is the byte `0x73b5b0` looks the page up
    with, and the count at +5, which sets the spin's top.
  - S->C `0x706d`: 4, 4, 4, 4, 4, 1, then the record (`0x884660`).
  - A truncated page or row returns null. A short `0x706d` returns null.
  - `b06c_page` decodes to count 3, index 0, entry 12 "Aria"...
- **The page handler `0x8841f0`.**
  - The key is the leader's name in a party (`0x987070` → `0x9921e0`), else the player's own
    (`+0x110`).
  - Row 0 with that name becomes the registration (`0x97c960`). Later rows with the same name are
    skipped only once it was found (`0x8844a6..0x8844e8`). A row 0 that is not the player's
    leaves the registration alone.
  - The window then rebuilds (`0x73b5b0`) and re-runs the rules.
- **The `*name` alias.** It is added for purpose 2 or 3 in the row (`0x740d30`) and, for both
  names, in Join's progress text (`0x739500`: `*` = `0xd92240`).
- **Search.** A whole-name compare when the name box is not empty (`0x47ec20`). Purpose equals,
  or All, the combo's last index. The three-clause level test is equivalent to overlap for valid
  rows. NORESULT is type 4, and the displayed list empties (`+0x7c8 = +0x7c4`) as ours does.
- **The purposes each job may list** (register Create `0x73f957..0x73fa14`; auto Create
  `0x73e917..0x73e995`):
  - 1/3: 0, 1 and 3 disabled, Trade chosen;
  - 2: 0, 1 and 2 disabled, Thief chosen;
  - else: 2 and 3 disabled.
  - The disabled label colour is `0xff999999` (`0x657890`), the 0.6 grey ours uses.
- **Auto match.**
  - Candidate test (`0x73ebc0`): purpose equal; race equal unless 2; flags equal to
    `(exp==0)|(item==0)<<1|(anyone==1)<<2`; the level inside the range.
  - The test runs over the displayed (filtered) list and stops at 10.
  - Stepping: `0x786e70` sends the next `0x706d`, or ends with `0x786e20`.
  - `0xb06d` (`0x8847d0`): outcome 1 ends the run; 0 or 2 and `[2][code]` step; AUTO_PROGRESS or
    AUTO_FAILURE are type 4.
  - The run never opens the joining window.
- **Default titles** (`0x73f610`): DEFAULT1/3/2/4 for 0/1/2/3. A title is replaced only when it is
  empty or one of the four. Create applies it (`0x73fa1b`, `0x73fae8`).
- **The enable rules `0x7384a0`.**
  - Join and Auto: no registration, not in a party, level ≠ 0, displayed list not empty.
  - Whisper: list not empty.
  - Form: no registration and (out of a party with level ≥ 5, or leader (`+0xd`) and not full
    (`0x987050`)).
  - Change and Delete: registration name == own name (`+0x114`/`+0x124`).
  - Search is always on.
- **The Form party refusal order** (`0x7397b0`): AGAIN, LEVEL, PARTY, FULL, with keys and type 4
  as ours.
- **Refresh.** It requests the spin's page, disables 0x38 and arms timer 10 for 2000 ms
  (`0x732a80`). The test of the 2 s lock holds (but see D9).
- **The leader's popup** (`0x7403f0`):
  - it stores job, JID, entry, masteries, job state and the record (`+0x7b8..+0x7d0`);
  - PML with the record's name; level `%d`; race CHN/EUR from the model's `+0x9c`; POS `%d` of
    the region looked up as text (`0x740030`); guild only when the job state is 4;
  - timer 1 for 10 000 ms; at 10 s, `0x73fb70` sends `[job][JID][2]` and closes;
  - Confirm sends 1 and Cancel 0. Each echoes `+0x7b8`/`+0x7bc` from the `0x706d`. The fixtures
    `306e_closed` and `306e_confirm` match.
- **The joining window** (`CIFPartyJoinProgress::vslot_005` `0x7322e0`): kind 1, 200-ms timer, the
  gauge `(now − start)/10000.0` (the double at `0xdb3720`), full and `0x7390b0(0)` at 10 s. Text
  (`0x732000`) formatted (own, party).
- **The full-party delete** (`0x7387c0`): in a party, a registration whose name is the player's,
  number ≠ 0 and full (`0x987050`: flag 0 with 4, or flag 1 with 8). It sets `DAT_00eeb8c8` and
  sends `0x706b`. DELETE_COMPLETE2 is shown and the flag is cleared on success (`0x8801e0`).
- **Refusal keys.** I read the `0x7b8b40` category-2 jump table (`0x7bb7dc`): 0x2c1b AGAIN, 0x2c1c
  CANT_FIND_PARTY, 0x2c1d RECORD_ERROR_PARTYLEADER, 0x2c1e JOIN_ERROR_LEVEL, 0x2c1f JOIN_ERROR_DUPLE,
  0x2c23 USER_MISSMATCH, 0x2c25 RECORD_ERROR_INVITE, 0x2c13 MEMBER_FULL_EXP_SHARED. All equal
  `PartyNet.ERROR_KEYS`. `B_refusal_2c1e.png` shows "Not the required level for the party." in
  the bottom-right window.
- **The register and auto radio geometry.**
  - Objective: origin 0,0; pitch 0x42; x 0x16; width 0x32; 4 across.
  - Race: origin 0,0; pitch 0x5b; x 0x16; width 0x64; 3 across.
  - Exp and item: origin 2,2; pitch 0x14; x 0x14; centred; width 0x64; 2 down.
  - The item strings come from the exe.
- **Measured against the layouts.**
  - The slot columns start at slot-relative x 11, 61, 102, 151, 249, 567, 620 and 660, against
    ifpartymatchslot.txt's 10, 60, 101, 150, 248, 566, 619 and 659 (the +1 is the glyph
    bearing). Text rows run 9..17 inside the 7/11 statics.
  - The own row is exactly (135,233,255), the `0xff87e9ff` at `0x740ea1`; 802 pixels.
  - The joining window is 365x149 at (457,285), and the popup 360x315 at (460,202): both centred
    on 1280x720.
  - The gold bar's rows are at 266 and 285.
- **Regressions.**
  - `hud_panels.gd`'s additions, the World3D QA block (an unknown verb is handed to
    `PartyMatchQa.do` and still prints the old error otherwise) and `net_client.gd` (untouched:
    `register_handler` replaces) are fine.
  - C1's suites pass in the full run.
  - `go build` and `go vet` of `cmd/partybot` pass.

## Tests

- `RENDER_DIR=/opt/opensro-client-r714rev GODOT_LOCK=/var/tmp/r714rev/lock
  client/tools/remote_godot.sh check` gives **ALL LOAD**, "checked 598 scripts and 9 scenes".
- The same `… tests` gives **"ran 228 suite(s), 0 failing"**.
- I ran the two lane suites alone, to see their output:
  - `net/party_match_test.gd`: 64 `ok` lines, no FAIL.
  - `ui/hud/party_match_window_test.gd`: "all checks passed".
- **Gaps:**
  - no test covers the buttons during an auto run (B1), an empty page (B4) or the echo's
    race/members (B3);
  - the window test asserts the wrong empty-row behaviour (D2, line 190) and labels W5 as OURS
    (line 248).
- No perf gate. This is a UI and QA-hook round with no world, drawing or loading change.

All box scratch (`/opt/opensro-client-r714rev`, `/var/tmp/r714rev`, including the extracted
layouts and textdata) and my local copies were deleted after the review.
