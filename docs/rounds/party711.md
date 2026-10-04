# Round 711, lane C1: the client's party messages on the original's opcodes, and the party window

The client half of the party epic's first implementation pair (S1 = round 710 is the server).
Built against round 709's specs (`docs/protocol/party_protocol.md`, `party_gui.md` §1, §1b,
§2, §6) and round 710's golden fixtures, which are copied unchanged into
`client/scripts/net/fixtures/party/` (no disagreement found: every S1 message decodes and
re-encodes byte for byte).

## What was built

- **`net/party.gd` (PartyNet)**, every party message both ways, on the retail opcodes:
  `0x7060`/`0xb060`, `0x7062`/`0xb062`, `0x3080` (invitation and answer), `0xb067`, `0x3065`,
  `0x3864` kinds 1/2/3/6/9, `0x7061`, `0x7063`, with the masked member record (field and dungeon
  positions, signed). OpenSRO's `0x0080`-`0x0089` are gone from the client.
- **`net/party_state.gd` (PartyState)**: the client's party manager (`0xeeebd8`): the settings
  block (exp/item/anyone) the next `0x7060` sends, in-party, leader, own JID (from the
  `0xb060`/`0xb067` OK and from OpSelfId per round 710's id decision), the member list with the
  leader kept at index 0, the job-party flag `+0x0c`. It applies every message and emits
  `changed`, `notice` (system-window lines), `invitation`, `invitation_closed`.
  - invitation rules (`c:0x88aa60`): the "accept invitations" option off auto-declines with the
    kind's code; an inviter not spawned in this client is dropped unanswered;
  - `0xb067` with an error (the `0x2c10` timeout among them) closes the box (`c:0x880120` closes
    request kind 6 on its error branch, asm);
  - refusals with a code go to the system window as type 0, the client's error path
    `0x778190` (READ in all three ack handlers, `c:0x880010`/`0x8800b0`/`0x880120`); joins and
    leaves are type 4 (`UI_PARTY 0x886b10`); a code with no client message shows nothing.
- **`net/net_client.gd`**: `NetClient.party`, the senders `party_create/invite/leave/kick/answer`,
  and `register_handler(opcode, Callable)` -- the hook through which C2's `party_match.gd`
  registers its own opcodes (checked in the dispatcher's default branch).
- **The party window, `ui/hud/hud_party_pane.gd` (HudPartyPane)**, filling ifparty.txt as
  `IFParty 0x6d6640` (in a party) and `UI_NO 0x6d6d00` (out of one) do:
  caption with the anyone-invite suffix; type line and its colours; leader row (name, Lv,
  level, race mark from the model, guild rule, live HP/MP for the player, tenths for others,
  red flag); seven `CIFPartySlot` rows built from ifpartyslot.txt; Banish on every row for the
  leader, Leave on the player's own row otherwise; Dismiss = leave; the kick target is list index
  row + 1; Invite / Set / Party match enable rules; the player's own portrait borrowed from the
  player block's render. Party match toggles the matching window, as its key does.
- **The settings dialog, `ui/hud/party_settings_dialog.gd`** (CIFSetPartyMode, child 70 at
  32,85, 300x200): the two radio groups built as `CIFRadioButton` builds them (dots 16x16 at
  3, 4 + 20 i, labels at +20/+3, 100x12, centred; READ `0x657c40` and the setters
  `0x657910..0x657960` as Create calls them, `0x6db980`), the "anyone may invite" check box,
  Yes writes the block (no request), No closes.
- **The invitation box, `ui/hud/party_invite_popup.gd`** (HUD request kind 6). New READs this
  round (party_gui.md OPEN 7 closed in part):
  - the box is a CIFMessageBox in mode 1, `MsgBoxINIF` of ifmessagebox.txt
    (`c:0x6ec5d0 -> 0x643c20(1)`), and kind 6 is set up by `UI_SILKMALL::FUN_00644c90` case 6/8:
    title `UIIT_STT_CONFIRM_BOX`, 300x176, `UIIT_STT_PARTY_SOMEUSER` (name) at 16,48,
    `UIIT_STT_PARTY_PROPOSAL_ASK` at 16,64, two `msgbox_blackbox.ddj` boxes at 44,93 / 156,93
    with the exp and item modes, `UIIT_STT_PARTY_JOIN_ANYONE` at 6,121, `UIIT_STT_ACCEPT` at
    72,139, `UIIT_STT_REFUSE` at 152,139, the third button hidden;
  - both party kinds (2 and 3) queue kind 6 (`c:0x88b1d4`: both entries 0x88ad8a);
  - the yes/no payloads re-read in asm: yes `[1][1]` for both kinds, no `[2][0x2c0c]` /
    `[2][0x2c17]`;
  - the box arms timer 10 (`0x644650`): 10 s for type 4, 15 s for type 8, else 30 s
    (INFERRED that "simple_msgbox_type" is the request kind; what the timer does was not read,
    so the box only closes).
  - INFERRED: which MsgBoxINIF control each `+0x840..+0x850` is (taken as MESSAGE1..5).
- **`ui/ui_builder.gd`**:
  - CIFSubFrame draws its caption (READ `0x81a530`: a static at 10,7, width - 20, 12 high,
    centred, font 0; vslot 45 sets it). Nine resinfo subframes carry one (MEASURED: ifparty,
    ifaction's four headers, academy, quest, storage, item mall), so those headers now appear.
  - `make_checkbox` (CIFCheckBox: `resinfo\ifcheckbox.txt`, the `com_checkbutton_on.ddj` mark
    shown when checked, checked by default; READ `0x656f90`, `0x656ce0`, `0x656c70`). Not wired
    into the generic build, so other layouts' check boxes are unchanged.
  - `set_button_text` for a button authored with no text.
- **World3D**: the debug party panel (ActionTabs/Party, its scene nodes and handlers) is gone;
  party chat's `#` gate reads `NetClient.party.in_party`; a type-4 chat line carrying the
  player's own name is dropped (`c:0x877810` case 4), since the server now echoes party chat;
  `OPENSRO_QA_PARTY` is now a retail-path step list:
  `"<tick>:<step>;..."` with `window`, `settings`, `set:e,i,a`, `invite:<name>`,
  `accept`/`refuse`, `leave`, `kick:<name>`, each through the window's own buttons.
- **`tools/qa_shot.sh --second-client "K=V|..."`**: a second, headless client on the same
  `--server`, logging to `<out>/second.log`, killed with the run.

## Choices of ours (OURS)

| what | choice |
|---|---|
| ~~settings block's starting values~~ | **READ in the review: exp 1, item 0, anyone 1** (`c:0x99ba00`); see the fixes table |
| "accept party invitations" option | on (the option window has no such row yet) |
| strings on the wire | UTF-8 bytes with the u16 length |
| the gauge clamp above 1 | a kind-6 HP nibble of 11 decodes to 10/9 as the client does (`c:0x991f60`); the windows clamp the ratio to full (whether the client's gauge clamps was not traced) |
| pet/horse owner substitution | nothing to substitute: OpenSRO selects neither |

## Tests

- `net/party_test.gd`: every S1 fixture encoded or decoded and re-encoded byte for byte, records
  field by field, and PartyState through form, join, update, leader change, kick, logout,
  dissolve, own-leave, refusals, and the invitation rules. All pass.
- `ui/hud/hud_party_pane_test.gd`: window geometry against ifparty/ifpartyslot rects, the
  subframe caption, out-of-party, leader, member, anyone-may-invite and job-party states, every
  button's request, live refresh on kinds 2/3/1, the settings dialog's geometry and Yes/No, the
  invitation box's geometry and Accept. All pass.
- `inventory_pages_test.gd`'s leader-mark check now drives the party state.
- Render box (`RENDER_DIR=/opt/opensro-client-c1`, `GODOT_LOCK=/var/tmp/c1/lock`):
  `remote_godot.sh check` ALL LOAD (586 scripts); `remote_godot.sh tests`: 226 suites, 0 failing (the last full run's only failure was the invitation-box fix in progress; the pane test passes after it).

## Live, against S1's server binary (7a4f8772, in memory)

Run 1 (`/var/tmp/c1/run_party.sh`): Aria rendered, Bram headless (`--second-client`), both
`/level 10` by GM command. (That run used `;` between the `--second-client` settings, before the
separator became `|`; with today's `qa_shot.sh` the same command is
`--second-client "OPENSRO_QA_ACCOUNT=qa2:qa-password|OPENSRO_QA_CHARACTER=Bram|OPENSRO_QA_COMMANDS=/level 10|OPENSRO_QA_PARTY=1:accept|OPENSRO_QA_AT=1004,1022"`.)
Log (Aria):

```
QA PARTY: tick 120 window
QA PARTY: tick 170 settings
QA PARTY: tick 220 set:1,1,1
QA PARTY: tick 260 invite:Bram
World3D: selected player 1 (Bram), race 0
SYSLOG [4] [Bram]is requesting to party.
SYSLOG [4] [Bram]joined the party.
```

Bram: `QA PARTY: pressing accept on the invitation`, then at Aria's exit `The party is dismissed.`
(the party of two dissolving on her logout). Frames on the box:
- `/var/tmp/c1/live1/f00000150.png`: the empty window (screenshot 01's layout; the archive's
  own `<You are not in a party!>`);
- `/var/tmp/c1/live1/f00000200.png`: the settings dialog (screenshot 05);
- `/var/tmp/c1/live1/f00000410.png`: the party (screenshot 12's layout): Aria's row with her
  portrait, red flag, race mark, Lv 10, bars, `<No guild>`, Dismiss; Bram's row with Banish; Set
  greyed; the caption's suffix; the type line bright.

The layout numbers are checked by the pane test, not by eye.

Run 2 (`/var/tmp/c1/run_party2.sh`): the roles swapped. Bram is rendered and answers nothing;
Aria is headless, sets `1,0,1` in the dialog and invites at her ticks 1500, 1900 and 2300. Aria's
log: `[Bram]is requesting to party.`, then `In the process of joining a party.` (`0x2c1f`) for
the two invites sent while Bram's was pending, then `The party invite automatically cancelled
due to no response from the other player.` (`0x2c10`, type 0). Bram's: the box shows, and the
same timeout line closes it.

MEASURED, the box's 300x176 area's mean luma over Bram's frames: 0.33 before, 0.187 from frame
110 to 220 (the box up), 0.34 after (closed by `0xb067 [2][0x2c10]`). Frames on the box:
- `/var/tmp/c1/live2/f00000150.png`: the invitation box ("[Aria] sent you party invite.",
  "Accept party invitation?", the EXP Auto Share / Item Free-For-All boxes, the anyone-invite
  line, Accept / Refuse, on the `GDR_MSGBOX_BG` tile);
- `/var/tmp/c1/live2/f00000240.png`: after the timeout, the box gone.

Two fixes came out of these runs: `--second-client` now splits on `|` (a `;` in its settings
broke the env line); the box builds ifmessagebox.txt's "Create" (the background tile) before
MsgBoxINIF, as CIFMessageBox::Create does; and the black boxes' text is top-aligned, as the
statics are authored.

## Not done here

- The 3D portraits of members other than the player: they come from the quick-party slot renders,
  lane C3's.
- Real input (xdotool) was not used: the QA steps press the window's own buttons through their
  signals. A real-click pass belongs with C3's HUD round.
- No perf gate: no per-frame world code changed (the QA step list replaces the old QA hook's
  per-frame check one for one).

## For C2 and C3

- C2: register opcodes with `NetClient.register_handler(op, callable)`; the party-match records
  are in the fixtures (`7069`..`b06d`); `PartyState.flags_byte()` is the type byte the register
  sends; the Party match button already toggles `"partymatch"`.
- C3: `NetClient.party` (members in list order, leader at index 0, `own_jid`, `job_party`,
  `exp_share` for the faraway overlay) and its `changed` signal; `PartyNet.Member` carries
  region/x/y/z/world, masteries and HP/MP tenths. The window's rows show black squares for
  members until C3 provides their renders (`HudPartyPane._face`).

## Review fixes (round 711's review, `docs/rounds/party711_review.md`)

Merged `int/party` first (S1's review fixes, `991bb1c2`), then:

| # | finding | fix |
|---|---|---|
| 1 | settings defaults are READ (`c:0x99ba00`): anyone starts at 1 | `PartyState` starts exp 1, item 0, anyone 1, labelled READ (`0xd75d80 -> 0x99c1c0 -> 0x99ba00`, the clear `0x998be0` leaves them); `party_gui.md` §1 records the starting values; tests check them. Run 6's frames now show the caption suffix and the ticked box out of a party, as screenshots 01 and 05 do |
| 2 | eight refusal codes have client messages | `ERROR_KEYS` gains 2, 3, 4, 5, `0x2c06`, `0x2c07`, `0x2c11`, `0x2c29` (`c:0x7b96ae`, `0x7bb7cc`, `0x7bb7dc`); `0x2c07`'s extra call `0x77b580` is not reproduced (noted). `party_protocol.md`'s error table corrected. Live: run 3/5's out-of-range invite shows "The object is too far." |
| 3 | the invitee's `0xb067 [2][0x2c10]` is silent | `_on_ack` closes the box and returns before the notice (`c:0x880120`). Live, run 4: Bram's log has no line on the timeout; Aria's `0xb060` timeout still shows hers |
| 4 | own HP/MP not live | `HudPartyPane.refresh_vitals()` redraws the player's own row and, when the player leads, the leader row's gauges; HudPlayerInfo emits `bars_changed` on every bar change and World3D wires it through `HudPanels.party_vitals_changed` (on change rather than per frame; same values as `0x6d72f0` / `0x6d5ca0`). Tested |
| 5 | row guilds white | `_guild` takes the colour: (255,225,148) on the leader row, white on member rows (`0x6d7a0c`/`0x6d7a5b`). Tested |
| 6 | box texts overflow / not centred | the mode boxes are built as CIFStatics with the black art, the inset (3,7,3,6), HAlign 1, laid out by `place_label`. MEASURED (run 4, `live4/f00000150.png`): exp text 537..622 in box 531..626, item text 647..735 in box 643..738 |
| 7 | the tile covers the right border | READ `CIFMessageBox::vslot_021` `0x63b5e0 -> 0x63b420`: the resize sizes child 0 (`GDR_MSGBOX_BG`, ID 0) to (w - 32, h - 56) = 268x120, and places the title static at (10, 11, w - 21, 12) (also READ now). MEASURED: the frame's right-border ridge at x 780-781 is present over the tile's rows |
| 8 | radio labels offset | built through the builder's static path (font 0, centred, `place_label` in 100x12). MEASURED (run 6, `live6/f00000200.png`): label centres 953.5 and 1084 against the READ 955 and 1086; "Item Free-For-All" ends at 1128, inside its box |
| 9a | Leave colour | Leave gets 0xfffff5da too (`0x6d78a7`). Tested |
| 9b | Party match tooltip | not built (listed under "Not done here") |
| 9c | Enter/Esc on the boxes | not read, not built (listed) |
| 9d | box timer vs state | the box's timer emits `expired`; HudPanels calls `PartyState.forget_invitation()` |
| 9e | misplaced doc comment | moved onto `register_handler` |
| 9f | OURS vs INFERRED on the clamp | superseded: the client's own decode (`c:0x991f60`) is followed; the clamp above 1 is OURS, the client's gauge behaviour above 1 untraced |
| 9g | stale gap list | `party_gui.md` items 1-4 and 9 marked built in round 711 |
| 9h | `useitem.gd` comment | "were OpenSRO's own party create and its result" |
| 9i | test leaks state into the autoload | `inventory_pages_test` gives the panels their own `PartyState` |
| 9j | run-1 command | re-recorded above with `|` |
| 9k | CIFParty `+0x3b0` recolouring the dialog | not read, not built (listed) |
| S1 note | the HP decode | `Member` keeps `hp_cur/hp_max/mp_cur/mp_max/dead`: a full record n/10 and n/10; a kind-6 update HP 0 = dead, else (n - 1)/9, MP n/10 (`c:0x991f60`); the windows draw `hp_ratio()`/`mp_ratio()`. Tested (nibbles 11, 0, 6) |

### Tests after the fixes

- Render box, `RENDER_DIR=/opt/opensro-client-c1`, `GODOT_LOCK=/var/tmp/c1/lock`:
  `remote_godot.sh tests` ran 226 suites, 0 failing (party_test and hud_party_pane_test included).

### Live after the fixes (the merged server, `int/party` at this branch's merge)

- Run 3 (`/var/tmp/c1/run_party3.sh`) and run 5 (`run_party5.sh`, Bram's client also at
  `QA_AT` 1004,1022): the invite was refused **"The object is too far."** (code 4, finding 2 live).
  The headless client's `QA_AT` moves it only in its own client; the server keeps each character
  where it spawned it, and in these runs that was more than 600 apart (run 1's success had both
  spawned together). Frame: `/var/tmp/c1/live3/f00000250.png`.
- Run 6 (`run_party6.sh`): both characters `/tp` to the same spot by GM command first; Aria opens
  the window, the settings dialog, sets 1,1,1 and invites; Bram accepts; `[Bram]joined the party.`
  Frames: `/var/tmp/c1/live6/f00000150.png` (empty window: the caption's anyone suffix by default),
  `/var/tmp/c1/live6/f00000200.png` (the settings dialog: the box ticked by default, labels
  centred), `/var/tmp/c1/live6/f00000450.png` (the party: Aria and Bram).
- Run 4 (`run_party4.sh`): Bram rendered; the box shows from frame 120 to 230 (the box area's mean
  luma 0.188 against 0.33 before and 0.34 after) and closes on the server's timeout with no line
  in Bram's log. Frames: `/var/tmp/c1/live4/f00000150.png` (the box), `f00000250.png` (after).

### Still not done

- The Party match button's tooltip with the bound key (9b).
- Enter / Esc on the invitation box and the settings dialog (9c; `0x6449d0` not read).
- CIFParty `+0x3b0`'s recolouring of an open settings dialog (9k).
