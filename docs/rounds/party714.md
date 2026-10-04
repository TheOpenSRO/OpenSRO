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
  - `0xb069`/`0xb06a` OK: the registration from the echo (`0x97c530`), the dialog closes
    (`0x73f300`), RECORD_COMPLETE / MODIFY_COMPLETE on the warning banner (`0x77b580` ->
    `0x7b3eb0`, GDR_WARNING_WND);
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
  the joining window is up, IDs 15, 17-20, 55 and 56 are disabled (`0x738890`: READ, the asm
  list, which adds Change and Delete to the spec's five); the full party's own registration
  deleted by the client (`0x7387c0`).
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
