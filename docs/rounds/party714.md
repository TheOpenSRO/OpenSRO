# Round 714 (lane C2): the party-matching client

The client side of party matching on the retail messages: the Party Matching window, the Form
party / Change entry dialog, the auto-match dialog, the delete question, the leader's join popup
and the requester's joining window. It sits on round 710 (S1, the party core), round 711 (C1, the
client party net and window) and round 713 (S3, the party-match server), with their review fixes
(`int/party` at `85e6c063`). Spec: `docs/protocol/party_gui.md` §3-§5, `party_protocol.md`'s
party-match rows and round 713's notes. Labels: **READ** (sro_client.exe), **MEASURED**,
**INFERRED**, **OURS**, **USER DECISION**.

## What is built

- **`net/party_match.gd` (`PartyMatchNet`)**: the codecs, one encoder and decoder per message:
  `0x7069`/`0x706a` entry, `0xb069`/`0xb06a` echo, `0x706b`/`0xb06b`, `0x706c`/`0xb06c` (page
  count, then index, then the rows: `c:0x8841f0` reads them in that order), S->C `0x706d` (job id,
  requester JID, entry, two masteries, job state, member record), `0x306e` and `0xb06d`. The
  window rules as pure functions: the `*name` alias, the Search filter, the job's allowed
  purposes, the auto-match candidate test, the default-title and label keys.
- **`net/party_match_state.gd` (`PartyMatchState`)**: registered on NetClient through round 711's
  `register_handler` hook (net_client.gd is untouched). It applies the replies:
  - a page (`c:0x8841f0`, READ): row 0 whose name is the key (the leader's name in a party, the
    player's own otherwise) becomes the player's registration (`0x97c960`); later rows with that
    name are skipped; every other row is a record. A `[2][code]` page is a coded line;
  - `0xb069`/`0xb06a` OK: the registration from the echo (`0x97c530`: race from the player's
    model, members 1 or the party's count), RECORD_COMPLETE / MODIFY_COMPLETE on the warning
    banner (`0x77b580` -> `0x7b3eb0`, GDR_WARNING_WND). The dialog closes on OK (`0x73f370`'s
    vslot `0xac`), not here: `0x73f300` is the `CPartyRegData` constructor (review D1, W4);
  - `0xb06b`: the own number clears the registration (`0x97c960(0)`); the line is DELETE_COMPLETE,
    or DELETE_COMPLETE2 when the client deleted it because the party filled (`DAT_00eeb8c8`);
  - `0xb06d` (`c:0x8847d0`): joined -> JOIN_COMPLETE_MASTER on the banner, the auto run ends;
    refused -> CREATE_PARTY_REFUSED, no reply -> JOIN_NOREPLY (type 4); `[2][code]` -> the coded
    line (`0x778190`); a running auto match then tries its next candidate (`0x786e70`) with
    AUTO_PROGRESS, or ends with AUTO_FAILURE; and the joining window closes (`0x884a0c` ->
    `0x7390b0`; the argument is INFERRED 0).
- **`ui/hud/party_match_window.gd` (`PartyMatchWindow`)**: the controller over HudPanels'
  GDR_PARTY_MATCH (built from ifpartymatch.txt as before) and the owner of the boxes. Each
  CIFPartyMatchSlot gets ifpartymatchslot.txt built into it; the columns as party_gui.md §3's row
  table; the own registration pinned in row 0 in (135,233,255); the gold bar
  (`com_bar01select_`) on the selected row; the enable rules (`0x7384a0`); Join (`0x739500`),
  Whisper, Auto match, Form party with its client refusals (`0x7397b0`), Change entry, Delete
  entry; Search (`0x73b780`); Refresh with its 2 s lock; the page spin; page 0 on opening; while
  the joining window is up, the spec's five are disabled (`0x7390b0`); `0x738890`'s seven are
  the auto-run disable (review D8, W3); the full party's own registration deleted by the client
  (`0x7387c0`).
- **The boxes** (`party_match_box.gd` the shared shell; caption at (10, 11), w - 21 x 12, READ
  `0x7400c0`):
  - `party_match_register.gd`: 314x373, caption RECORD / MODIFY, the objective radio READ in
    `0x73f820` (origin 0,0; pitch 0x42; label x 0x16, width 0x32; 4 across: 0xdb3ad0 Hunting,
    0xd9670c Quest, 0xdb3a70 Trade Union, 0xdb3a10 Thief Union), the job restriction, the level
    edits (3 digits, 1..0x6e, "1"/"110"), the type line, the title (max 50, the default by
    objective while a default), OK's two refusals;
  - `party_match_auto.gd`: 314x337, the four radios READ in `0x73e790` (objective as above; race
    origin 0,0, pitch 0x5b, x 0x16, width 0x64, CHN / EUR / Open; exp and item origin 2,2, pitch
    0x14, x 0x14, centred, width 0x64, SHARE / SELF), OK -> up to 10 candidates;
  - `party_match_confirm.gd`: the delete question, GInterface `0x788270`'s MsgBoxSimple (360x151,
    Yes at centre - 81, No at centre + 5, the text box at (30, 65));
  - `party_match_req_join.gd`: the leader's popup (screenshot 08), 360x315, every field from the
    `0x706d` as party_gui.md §4, the 10 s timer answering 2;
  - `party_join_progress.gd`: the joining window (screenshot 09), 365x149, the text with the two
    names, 200 ms ticks over 10 000 ms, closing itself at 10 s.
  The register, auto-match and joining boxes are centred on the screen (`0x798b70`, READ: screen
  w / 2 - w / 2, h / 2 - h / 2).
- **`ui/hud/party_match_qa.gd`**: OPENSRO_QA_PARTY's matching steps (World3D's `_qa_party_do`
  hands unknown verbs to it; the QA block's doc lists them).
- **`server/cmd/partybot`**: `-purpose`, `-min`, `-max`, `-flags`, `-title` for a `-register`
  bot, and `-silent` (leave join requests unanswered), for the renders.

## Strings (MEASURED, textuisystem)

The PML strings carry `<sml2>` markup: `<font color="255,239,218,164">[%s]</font>` and `<br>`.
They are drawn as BBCode in a RichTextLabel, the colour's fourth number dropped (INFERRED from
screenshots 08 and 09, which draw the names opaque).

## Choices of ours (OURS) and what is INFERRED

| what | choice |
|---|---|
| the scroll bar (GDR_PARTYMATCH_SCROLL, CIFVerticalScroll) | not drawn; the wheel over the list scrolls a row |
| the column headers' sorting (0x73e050) | not built |
| the row tooltip (0x740750) | not built |
| a new page and the Search filter | the page clears the filter (whether 0x73b5b0 re-applies it was not read) |
| the leader's popup's position | centred on the screen (0x79c330 does not move it; the record's rect is 0,0) |
| the purpose combo (CIFComboBox) | drawn with the Option window's combo art and list (ComboList); CIFComboBox's own art was not read |
| the radio labels' alignment where Create does not set it | left (the radio's default was not read) |
| the auto-match dialog's starting choices | the first allowed objective, race Open, exp / item as the settings block |
| Whisper | opens the chat line with `$<leader> `, as R does (the original opens its whisper window) |
| the delete question's style | 1, Yes / No (INFERRED from its wording; the style argument was not traced) |
| the full-party delete | on every party change, window open or not (0x7387c0's caller was not read) |

## Tests

- `net/party_match_test.gd`: every matching message the client sends, byte for byte against the
  fixtures; every reply decoded field by field (page, echo, delete, join request, all four
  `0xb06d` forms) and the page and join request re-encoded to the same bytes; the rules; the
  state through paging (registration, the second copy skipped, another key), registration,
  delete, the join outcomes, the leader's request and answer, and auto match. All pass.
- `ui/hud/party_match_window_test.gd` (synthetic layouts with the archive's names and rects): the
  list fill from the fixture page (own row pinned in (135,233,255), `*Bram`, race and purpose as
  text, 2/8 and 1/4), selection, the enable rules, Refresh's 2 s lock, Join -> `0x706d` and the
  joining window (text, centring, half bar at 5 s, closed at 10 s), Search, the register dialog
  (caption, job restriction, default titles, the level refusal, OK = fixture `7069_register`,
  `0xb069` closes it and pins entry 12), the leader's popup (fields, PML, 10 s answer 2 =
  fixture `306e_closed`, Confirm = `306e_confirm`). All pass.
- Render box (`RENDER_DIR=/opt/opensro-client-c2`, `GODOT_LOCK=/var/tmp/c2/lock`):
  `remote_godot.sh check` ALL LOAD (598 scripts).
- Full suite on the box (`RENDER_DIR=/opt/opensro-client-c2t`): 228 suites; the only failure was
  this round's own check message containing the word the runner greps for ("AUTO_FAILURE"),
  reworded since; `party_match_test.gd` alone passes.

## Live, against a server built from this branch (S1 + S3, in memory)

`qa_shot.sh --server` with partybots on the same server (`/var/tmp/c2/runA2.sh`, `runB.sh`):
Sonila (1~100, "LVL 100 PT"), Levi (quest, 20~40), Eone (flags 0, a 1/4 party), Tobi
(`-silent`, leaves join requests unanswered) and Dasha (level 1, `-request Aria`).

- **Run A2, Aria rendered (the leader side).** `match` -> page 0 listed Sonila, Levi, Eone (the
  `QA MATCH ROW` lines; Eone's Type icon is the one-person art, 1/4). `select:Sonila` -> the gold
  bar. `form` -> the Forming party dialog (Trade / Thief greyed, the default title DEFAULT1, the
  type line "EXP Auto Share / Item Free-For-All" from the settings block, flags 0x05).
  `register` -> `0xb069`, the RECORD_COMPLETE banner, Aria's entry 4 pinned in row 0 in light
  blue. Dasha's bot then saw entry 4 and sent `0x706d`; Aria's popup showed "[Dasha]has requested
  to join this party. Confirm?", Level 1, Race CHN, Position Jangan, no guild; `req:confirm` sent
  `0x306e` answer 1 and the server formed the party (Dasha's log: `0x3065 party=1 leader=1
  flags=0x05 members=[Aria(1) Dasha(4)]`).
- **Run B, Bram rendered (the requester side).** `join:Levi` (Bram is level 10, Levi's entry
  20~40) -> `0xb06d [2][0x2c1e]` drawn in the bottom-right system message window: "Not the
  required level for the party." `join:Tobi` -> the Joining window, "[Bram]You [Tobi] has
  requested to join this party." with the gold gauge; Tobi's bot logged the relayed `0x706d`
  (requester Bram, job state 4, level 10).
- **Measured** (ImageMagick on the frames, edges of the msgbox2 frame): the Joining window spans
  x 457..821, y 285..433 = 365x149 at (457, 285), the READ size centred on 1280x720 exactly; the
  leader's popup x 460..819, y 202..516 = 360x315 at (460, 202). The rows sit on the READ 23 px
  pitch (row tops 264, 287, 310 in the `QA MATCH` select-bar lines: 144 + 23 i + the window's
  origin).
- **Found and fixed by the runs.** The first run drew no gold bar: the slot layout's own
  GDR_PARTYMATCH_SLOT_SELECT (ID 5, `com_bar01_`) covered the select bar laid under it. The
  client swaps that control's art (`0x740ca0`); the select bar now sits right above it and
  replaces it while selected (run A2's frame shows the gold rows at the selected row's top and
  bottom). A `form` QA step (the dialog left up) was added.
- **Timing caveat.** A rendered client draws about 3 frames a real second, while the server's
  15 s backstop and the bots run in real time; so a frame shows only the first few percent of the
  Joining gauge, and the first run's late `req:confirm` (160 frames after the request, past the
  real 15 s) reached a request the server had already closed as "no reply". The gauge itself is
  measured in the unit test (half at 5 s, closed at 10 s).
- **Frames kept** on the box, `/var/tmp/c2/keep/`: `A2_selected.png` (screenshot 06's gold
  bar), `A2_register_dialog.png`, `A2_own_row.png` (screenshot 02's own row in blue, as text
  columns), `A2_leader_popup.png` (screenshot 08), `B_list.png`, `B_refusal_2c1e.png`,
  `B_joining.png` (screenshot 09). The other frames were deleted.

## Left open

- The register dialog's objective labels are READ 50 wide (0x657960(0x32)); "Trade Union" runs
  past that and under the next item's dot, as drawn here. Whether CIFRadioButton's label clips
  was not read.
- Not exercised live: Change entry, Delete entry, Auto match, Search, Whisper (each is in the
  window test, except Whisper and Auto match's dialog, whose candidate rule and queue are in the
  state test).
- The column sorting, the row tooltip and the drawn scroll bar (OURS table above).

## Review fixes (round 714 review, `docs/rounds/party714_review.md`)

| # | fix |
|---|---|
| B1 | An auto-match run disables Join, Auto, Form, Change, Delete, Search and Refresh (`0x738890(1)`) until it ends; the end (`0xb06d`'s join_finished with no joining window) re-applies the rules. Tested |
| B2 | `<font color>` is A,R,G,B: the names draw (239,218,164) (MEASURED: the textuisystem census, screenshot 08). party_gui.md §4 corrected |
| B3 | The echo's registration takes the player's race (`_skill_race`) and members 1 or the party's count, time 0, the name rewritten (`0x97c530`). Tested |
| B4 | An empty page clears the registration (`0x97ddf0` -> `0x97c3b0`). Tested with `b06c_empty` |
| B5 | `server/partybot` (an 8 MB build of the bot) removed from the history by rebuilding the branch on `85e6c063`; `/server/partybot` added to `.gitignore` |
| B6 | `PartyMatchWindow.dispose()` disconnects `NetClient.party.changed` and every connection on the state, and closes the boxes; HudPanels calls it in `_exit_tree` |
| D1 | The register dialog closes on OK; the echo only redraws |
| D2 | The selection is the slot (`+0x7ec`): a click on an empty slot deselects; a fill that empties the slot drops it. Tested |
| D3 | Party matching locks the party window's Set (`HudPartyPane.set_match_lock`, `0x6d5ab0` on control 0x15) at the four READ points: the `0xb069` OK, the window's open (lock); the own `0xb06b` out of a party with the window closed, the window's close with no registration (unlock) |
| D4 | The auto dialog starts race 2, exp 1, item 1 (READ, `0x73eb83..0x73eba8`); the objective keeps the radio's initial item 0 (INFERRED: CIFRadioButton's constructor not read), disabled or not |
| D5 | The title fits 302 px with "..." (`0x8b47c0(.., 0x12e, 1)`, `OVERRUN_TRIM_ELLIPSIS`) |
| D6 | Search's levels: min below 2 is 1, max 0 is 110, min above max does nothing. Tested |
| D7 | Register OK tests `max < min` and an empty title only; the edits clamp to 1..110 as typed (INFERRED) |
| D8 | The joining window disables the five of `0x7390b0` and its close enables them outright (or keeps an auto run's disable) |
| D9 | A running Refresh lock restarts with every rules pass (`0x7384a0`'s tail, `0x7386a4`) |
| D10 | Whisper refuses the registration's own number |
| D11 | Confirm needs a job id and a requester (`0x73fc40`) |
| D12 | The window cannot close while the joining window is up (`0x732ae0`); its close takes the register and auto boxes with it |
| D13 | A `0xb06b` for another number also leaves the filtered list (`removed` signal, `0x73a700`) |
| W1 | Whisper is READ (`0x7386e0` -> `0x777d10` -> `0x7ab470`: `$` + name + space, focused), identical |
| W2 | The leader's popup is centred by `0x79ac50(0x83)` (READ) |
| W3, W4 | Notes corrected above |
| W5 | A new page clearing the filter is READ (`0x73b5b0`) |
| W6 | The combo art is READ (`CIFComboBox::vslot_010` `0x6327f0`) |
| W7 | The joining window's close argument 0 is READ (`push ebx` at `0x884a01`) |
| W8 | The delete question's style 1 is READ (`push 1` at `0x738986`, stored at +0x908 by `0x643e50`) |
| W9 | The full-party delete's only caller is `0x886c79` (`UI_PARTY 0x886b10`'s member-joined branch); testing on every party change is equivalent |
| W10 | The auto dialog's starting choices: D4 |
| W11 | The PML colour: B2 |
| L1 | "~" between the level edits (`0x73af56` / `0x73af69`, `0xd884b0`) |
| L2 | The purpose combo's text right-aligned (alignment 2, `0x73b062..0x73b073`) |
| L3 | **Open.** Whether the radio label's static (class `0xee9720`, margins zeroed by `0x6527d0(0,0,0,0)` at `0x657edc`) clips its text was not settled; "Trade Union" still runs past its 50 px |
| L4 | The Title header ("UIIT_STT_LETTER_TITLE") and the blank DUMY cell are set by the window itself (OURS, local to it; UiBuilder's CIFBarWnd 3-slice path is left alone). The low digits in the edits and the page spin are UiBuilder's and other windows', left for a builder round |
| M1 | A reply with a result byte other than 1 or 2 is ignored (the decoders return null). Tested |
| M2 | HudPanels accumulates the frame time as a float for the 2 s lock |
| M3 | The scroll bar is built: HudChat.ChatScroll with ifverticalscroll.txt's parts, the range records - 12 (READ), the length the record's 232 (INFERRED) |
