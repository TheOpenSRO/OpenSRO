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
| settings block's starting values | exp 1, item 0, anyone 0. READ only that the block is in .bss (zero) and no early writer was found; OPEN |
| "accept party invitations" option | on (the option window has no such row yet) |
| strings on the wire | UTF-8 bytes with the u16 length |
| an update's HP nibble of 11 | drawn as full (the ratio is clamped) |
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
`/level 10` by GM command. Log (Aria):

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
