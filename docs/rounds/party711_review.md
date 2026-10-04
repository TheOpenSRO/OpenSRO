# Round 711 (lane C1) review: the party messages, the party window, the settings dialog, the invitation box

An independent adversarial review of commits `57e1973e`, `bbb7c753` and `c873a9bc` on
`worktree-agent-abe16b97e5af0a1ae`. The review checked them against `party_gui.md` §1, §1b, §2
and §6, against `party_protocol.md`, and against the client itself:
- the decompile `/var/tmp/decomp_client` and the disassembly `/var/tmp/sro_client.asm` on the
  render box;
- `Media.pk2`'s layouts and text table;
- the lane's four live frames;
- two new renders of the action, storage and academy panes, made for this review;
- the user's screenshots 01, 05 and 12.

No code was changed.

## Test results (render box, this branch's head)

| run | result |
|---|---|
| `RENDER_DIR=/opt/opensro-client-r711rev GODOT_LOCK=/var/tmp/r711rev/lock remote_godot.sh tests` | **ran 226 suites, 0 failing** |
| `remote_godot.sh check` | **checked 586 scripts and 9 scenes, ALL LOAD** (the only errors are the missing native library: no `native_bin` built locally, so the fallback loads) |
| `party_test.gd` alone | all checks passed (131 `ok` lines) |
| `hud_party_pane_test.gd` alone | all checks passed (84 `ok` lines) |

Two of the passing checks assert behaviour this review finds wrong (findings 2 and 1):
- `party_test.gd:250`, "bare code 4: no client message";
- `party_test.gd:240`'s "(INFERRED)", which is READ now.

## Findings, most severe first

### 1. BUG + WRONG-LABEL: the settings block's starting values are READ, and "anyone may invite" starts at 1, not 0

- **Where:**
  - `client/scripts/net/party_state.gd:38-45`: `anyone_invite := 0`, and the comment saying "OPEN: the block … lies past .data's raw bytes (the image's .bss, zero at load), and no writer before the first Set or 0x3065 was found. OURS: exp 1, item 0, anyone 0";
  - `docs/rounds/party711.md:79`, the OURS table.
- **Evidence (READ, asm and decompile):** the block has a constructor.
  1. The static initializer at `c:0xd75d80` does `mov ecx,0xeeebd8; call 0x99c1c0`.
  2. `0x99c1c0`, the manager's constructor, does `lea ecx,[esi+0x20]; call 0x99ba00` at `0x99c1f1..0x99c1fe`, so `ecx` is exactly the block that `0x986f50` returns.
  3. `0x99ba00` writes `*param_1 = 1; param_1[1] = 0; param_1[2] = 1;`, then zeroes the bytes at `+0xc/+0xd/+0xe` and the words at `+0x10/+0x14/+0x18`.

  So the client starts with **exp 1, item 0, anyone 1**. The party clear `0x998be0` (kinds 1 and 3 call it) zeroes only `+0x2d/+0x2e/+0x30/+0x34`, which are leader, in-party, count and leader id. It never rewrites the three preferences, so they persist for the process's life.
- **The screenshots agree, and the lane read only half of one.**
  - Screenshot 01 (out of a party) shows the type line "Item Free-For-All / Exp Auto Share". It also shows the caption **"Party informaiton (Invitation of party member available)"**, which is the anyone-flag suffix (`0x6d5ef0`).
  - Screenshot 05 (the Set dialog, out of a party) shows "Exp Auto Share" selected, "Item Free-For-All" selected, and **the "Can invite without master status." box ticked**.

  Both show exactly (1, 0, 1). Taken alone, the screenshots are only moderate support: they come from the user's server's client, and a player could have pressed Set before taking them. With `0x99ba00` they are confirmation. The lane's own frames show the result of the wrong default:
  - `live1/f00000150.png`: the caption has no suffix;
  - `live1/f00000200.png`: the box is unticked.

  Both differ from screenshots 01 and 05.
- **Fix:**
  - set `anyone_invite := 1`;
  - relabel the three values READ, citing `c:0x99ba00`, called from `0x99c1fe` with `ecx = 0xeeebd8 + 0x20`, from the initializer `0xd75d80`;
  - correct the OURS row in `party711.md` and the "OPEN" in `party_state.gd`;
  - add the starting values to `party_gui.md` §1's state table;
  - change `party_test.gd:240`'s "(INFERRED)" to READ `0x998be0`;
  - re-check every test that builds a fresh `PartyState` and assumes anyone = 0.

### 2. BUG: server refusal codes 2, 3, 4, 5, 0x2c06, 0x2c07, 0x2c11 and 0x2c29 have client messages, but OpenSRO shows nothing

- **Where:**
  - `client/scripts/net/party.gd:84-107` (`ERROR_KEYS`);
  - `World3D.gd:21360-21362` (`_on_party_notice` prints a log line and shows nothing for an empty key);
  - `party_test.gd:249-250`;
  - the spec, `docs/protocol/party_protocol.md:537` ("2, 3, 5 | bare codes; no client message").
- **Evidence (READ):**
  - All three ack handlers call `0x778190(2, code, 0xffdbc99b, 0, 1)`.
  - `0x778190` is a thunk to `UI_SILKMALL::FUN_007b8b40`, whose first argument is a category.
  - Category 2 (jump-table entry 2 at `0x7bb378` gives `0x7b96ae`) has its own tables: `0x7bb7cc` for codes 2..5, and `0x7bb7dc` for `0x2c07..0x2c29`, plus a direct compare for `0x2c06`.
  - The strings, read out of the exe:

    | code | key |
    |---|---|
    | 2 | `UIIT_MSG_PARTYERR_UNKNOWN_ERROR` |
    | 3 | `UIIT_MSG_PARTYERR_INVALID_TARGET` |
    | **4** | `UIIT_STT_ERR_COMMON_TOO_FAR` ("The object is too far.") |
    | 5 | `UIIT_MSG_PARTYERR_UNKNOWN_OPERATION` |
    | `0x2c06` | `UIIT_MSG_PARTYMATCH_ERROR_BUSY` |
    | `0x2c07` | `UIIT_MSG_PARTYERR_OUT_OF_LEVEL` (plus a call to `0x77b580` at `0x7b9719..0x7b9742`) |
    | `0x2c11` | `UIIT_MSG_PARTYERR_CREATER_LEFT_PARTY` |
    | `0x2c29` | `UIIT_MGS_ARENA_ERR_FREGIST_PARTY_IN_BATTLE_ARENA` |

  - All eight keys are in the archive's `textuisystem.txt`.
  - Codes `0x2c09, 0x2c0b, 0x2c15, 0x2c16, 0x2c19, 0x2c1a, 0x2c20..0x2c22, 0x2c27` go to `0x7b913a`, which shows nothing. Those really have no message.
  - The rest of `ERROR_KEYS` matches the exe's table exactly.

  The server sends:
  - codes 3 and 4 for the range and type checks;
  - code 2 for a failed post;
  - `0x2c06` for a locked target.

  The fixtures `b060_err_too_far` and `b060_err_post_failed` are those messages. Today a player who invites someone out of range sees nothing.
- **Fix:**
  - add the eight entries to `ERROR_KEYS`, citing `c:0x7b96ae`/`0x7bb7cc`/`0x7bb7dc`;
  - give `0x2c07` its extra call, or say it is not reproduced;
  - make `party_test.gd:250` expect `UIIT_STT_ERR_COMMON_TOO_FAR`;
  - correct the spec's row 537, and the "no name" rows for `0x2c06`, in `party_protocol.md`.

### 3. BUG: the invitee's `0xb067 [2][0x2c10]` shows the timeout line; the client closes the box silently

- **Where:** `client/scripts/net/party_state.gd:177-181`. On any `0xb067` error, `_on_ack` closes the invitation **and** emits the notice.
- **Evidence (READ, decompile of `c:0x880120`):**

  ```
  if ((short)param_1 == 0x2c10) { FUN_00778b90(6); FUN_006ec7f0(6); return; }
  FUN_00778190(2,param_1,0xffdbc99b,0,1);
  ```

  The timeout branch closes request kind 6 and **returns before** the message call. Every other code shows its message and does not close the box. The other codes reach the invitee only after the box has already gone with the player's answer, so closing on them does no harm.

  The lane's own run 2 shows the divergence: "Bram's: the box shows, and the same timeout line closes it". Retail's invitee gets no line; only the inviter's `0xb060` handler `0x880010` prints `UIIT_MSG_PARTYERR_TIMEOUT`.
- **Fix:** in `_on_ack`, when `is_join_ack and a.code == 0x2c10`, close the invitation and return without `notice`.

### 4. BUG: the player's own HP/MP in the party window is not live

- **Where:** `client/scripts/ui/hud/hud_party_pane.gd`.
  - The window refreshes only on `PartyState.changed` (`:82`).
  - `_own_vitals()` (`:370`) is read only inside `refresh()`, for the leader row (`:269-272`) and the player's own row (`:301-305`).
- **Evidence (READ):** the client redraws both every frame.
  - `CIFPartySlot`'s per-frame function `0x6d72f0`: when the row is the player's (`+0x398`, set by `0x6d769d`), it recomputes the HP and MP gauges from the player's `+0x458` (HP) and its max via `0x9c7880`, and from `+0x45c/+0x454` (MP), at `0x6d7302..0x6d73c7`.
  - `CIFParty`'s `0x6d5ca0` does the same for the leader row when the player leads (`0x6d5cdf call 0x987080`, then `0x6d5cff..`).

  In OpenSRO the bars stay where the last party message left them. A player who takes damage or drinks a potion does not see it in the party window until someone joins, leaves or updates.
- **Fix:** update the two gauges each frame, or on the player block's HP/MP change, while the pane is visible and the player is in a party. The rest of the refresh does not need to run.

### 5. BUG: member rows draw a member's guild in (255,225,148); the client draws it white

- **Where:** `client/scripts/ui/hud/hud_party_pane.gd:336-345` (`_guild`), used for both the leader row and the member rows.
- **Evidence (READ):**
  - The row fill `0x6d7680` sets a non-empty guild's colour with `push 0xffffffff` (white): at `0x6d7a0c` for the player's own guild, and at `0x6d7a5b` for a member's guild.
  - An empty guild is `0xff999999` with `UIIT_STT_NO_GUILD` (`0x6d7a8b`).
  - Only the leader row uses `0xffffe194`, for its name and its guild (`0x6d682e`, `0x6d6971`, `0x6d69c3`).
  - Screenshot 12 shows the same: the leader row's "SCORN" is gold, and every member row's guild ("ChinaTown", "NewVision", …) is white.
- **Fix:** take the colour as a parameter, `COLOR_NAME_IN` for the leader row and white for rows, and add a test for both.

### 6. LAYOUT: the invitation box's black-box labels overflow their boxes and are not centred

- **Where:** `client/scripts/ui/hud/party_invite_popup.gd:148-172` (`_black_box`).
- **Measurements:** pixel columns in `live2/f00000150.png`, the box origin at (486, 286).

  | | box (x) | text (x) | result |
  |---|---|---|---|
  | `EXP Auto Share` | 531..627 | 549..634 | text runs 7 px past the box's right edge |
  | `Item Free-For-All` | 643..739 | 662..770 | text runs 31 px past the box's right edge |

  Both texts start about 18 px in from the box's left edge. Text centred in the inset would overflow both sides equally, so they are not centred. The label is laid at (3, 7) with width `box − 6`, and a Godot `Label` with `clip_text = false` grows to its text from the left.

  The client resizes the static to the art's size and sets the inset (3, 7, 3, 6) (`0x645e01..0x645ed3`, verified), so the box itself is right. The text is wider than the box in OpenSRO's font.
- **Fix:** centre the text on the box's centre whatever its width, as a CIFStatic with HAlign 1 draws. For example, size the label to the text's width and centre it, or clip it. Then record how the client draws a text wider than its static. That was not read in this round.

### 7. LAYOUT (INFERRED tile size, measured result): the message box's background tile covers its frame's right border

- **Where:** `party_invite_popup.gd:82-91`. It builds ifmessagebox.txt's `Create` (`GDR_MSGBOX_BG` at 16,40,284,122) into a box that is 300 wide.
- **Measurement (`live2/f00000150.png`):**
  - The frame's right border is at x = 780 (box-local 294) for y = 293..317 and again from y ≈ 450.
  - Between y ≈ 323 and ≈ 445 (box-local 37..159, the tile's rows 40..162), the tile's pixels reach x = 785 and the border is gone.
  - The left border, at x = 487, is intact for the whole height.
- **Cause:** kind 6 calls only the box's resize (`vslot 0x54(0x12c, 0xb0)` at `0x645c98`). Whether `CIFMessageBox`'s resize also re-lays `GDR_MSGBOX_BG` was not read, and the lane marked the tile's size INFERRED.
- **Fix:** read the message box's resize handler and size the tile as it does. Until then, clamp the tile inside the frame's border (`300 − 16 − border`). The overdraw is a measured artefact of the inference, not a retail look.

### 8. LAYOUT: the settings dialog's radio labels sit about 10 px right of their READ rect and overflow the black boxes

- **Where:** `client/scripts/ui/hud/party_settings_dialog.gd:122-130`. The labels are bare `Label.new()` objects, not made through the builder's static path (`font_at`, `place_label`).
- **Measurements (`live1/f00000200.png`; dialog at 858,386; the exp group at 882,462 and the item group at 1013,462):**
  - The dots are exactly right: (885, 466) and (885, 486), (1016, 466) and (1016, 486), 16 px each, matching `0x657910(3,4)` and pitch 20.
  - The READ label rects are 905..1005 and 1036..1136, centred.
  - The drawn texts are:

    | text | x span | centre | READ centre |
    |---|---|---|---|
    | "EXP Auto Share" | 920..1005 | 962.5 | 955 |
    | "EXP Free-For-All" | 920..1009 | 964.5 | 955 |
    | "Item Auto Share" | 1055..1139 | 1097 | 1086 |
    | "Item Free-For-All" | 1055..1143 | 1099 | 1086 |

  - "EXP Free-For-All" ends at 1009. The left black box's border is at about 1003, and the right box starts at 1009, so the text touches the next box. "Item Free-For-All" ends 9 px past its box's border (about 1134).
  - Screenshot 05, scaled by 1.97 (the dialog's 300 px measured as 592), puts the label text start about 52 px from the dialog's left edge. OpenSRO's is 62.
- **Fix:** build the labels with the builder's static text, as CIFRadioButton's statics are (font 0, `place_label` in the 100x12 rect, centred). Then re-measure.

### 9. MINOR (each small)

| # | where | what | fix |
|---|---|---|---|
| a | `hud_party_pane.gd:316-318` | The client sets the **Leave** text colour to 0xfffff5da too: `0x6d78a7` jumps into the same path as Banish, `0x6d7881`. The code sets it only for Banish, so Leave keeps the authored (254,245,218) or whatever a previous state left. | Set `COLOR_BUTTON` on Leave as well. |
| b | `hud_party_pane.gd` | The Party match button's tooltip `UIIT_STT_TOGGLE_PARTYMATCH` with the key name (`0x6d71be..0x6d7221`, `0x6d5e5e..0x6d5ea8`, `party_gui.md` §1) is not built. The lane did not claim it. | Build it, or list it as not done. |
| c | `party_invite_popup.gd`, `party_settings_dialog.gd` | Enter and Esc on a message box (`UI_SILKMALL::FUN_006449d0` switches on the box mode for keys 0xd/0x1b) are not handled. What each key does for kind 6 was not read. | Read `0x6449d0`'s mode-1 branch and wire the keys, or list them as not done. |
| d | `party_invite_popup.gd:134-137` | When the box's own 30 s timer fires, `close()` runs but `PartyState.pending_kind` stays set until the server's `0x2c10` arrives. | Have the timeout go through `PartyState` (or `HudPanels.close_party_invitation`) so the state and the box agree. |
| e | `net/net_client.gd:732-735` | The doc comment "Registers `handler` … for `opcode`" sits above `func _init()`, not above `register_handler` (`:740`). | Move it. |
| f | `party.gd` `Member.hp_tenths` doc vs `party711.md` | The doc calls the clamp of an update's 11 "INFERRED"; the round's OURS table calls the same clamp OURS. | Pick one: OURS, with the INFERRED note on how retail draws 11. |
| g | `docs/protocol/party_gui.md:589-627` | The gap list still says the client speaks 0x0080-0x0089, the debug panel exists, and the pane, settings dialog and invitation box are not built (items 1-4, 9). | Mark those items done in round 711. |
| h | `client/scripts/net/useitem.gd:9` | "those are PartyNet.OP_CREATE and its result": `PartyNet.OP_CREATE` is now 0x7060. | "were OpenSRO's party create and its result (retired in round 711)". |
| i | `inventory_pages_test.gd:171-196` | The test drives `pane.state`, which is the autoload `NetClient.party`, and leaves its settings block changed for later suites in the same process. | Give the panels their own `party_state` (`HudPanels.party_state`) in the test. |
| j | `/var/tmp/c1/run_party.sh` (box) | Run 1, the source of `live1/*`, ran at 04:29 UTC with the `;`-separated `--second-client` from before the 04:38 change to `|`. With the final `qa_shot.sh`, that command passes the whole string as one variable. Run 2 uses `|`. | Re-record the run-1 command in `party711.md` with `|`. |
| k | CIFParty `+0x3b0` | When a refresh runs with the settings dialog open, the client recolours the dialog's `+0x90`: 0xffffff94 in a party (`0x6d6693`), 0xffa79b7a out of one (`0x6d6d12`). What `+0x90` is was not read. It matters only if the dialog is open when a party forms. | Read it, or note it as not built. |

## Regressions checked

### The CIFSubFrame caption: nine layouts

READ: the generic layout loader `0x8b5580` calls the control's SetText (`vslot 0xb4`) whenever the control's Text is non-empty (`0x8b5580` decompile: `if (... || *(int *)(iVar3 + 0x80) != 0) (**(code **)(*piVar6 + 0xb4))();`). `CIFSubFrame::vslot_045` (`0x81a610`) forwards SetText to the caption static that `vslot_010` (`0x81a530`) built at (10, 7, w − 20, 12), centred, top. The `0x81a530` geometry was verified in asm. So the client draws every one of these captions.

| layout | subframe | caption rect (layout units) | overlap with authored controls (computed) | seen in a render |
|---|---|---|---|---|
| ifparty | GDR_PARTY_FRAMEL 0,0,364,303 | 10,7,344,12 | none | live1: centre measured 1006-1007 against 1008 |
| ifaction | GDR_ACTION_BG_CTRL 0,0,364,117 | 10,7,344,12 | none | `/var/tmp/r711rev/panels2/f00000069.png`: centre 640.5 against 641 |
| ifaction | GDR_ACTION_BG_SUM 0,120,178,117 | 10,127,158,12 | none | 547 against 548 |
| ifaction | GDR_ACTION_BG_BRU 186,120,178,117 | 196,127,158,12 | none | 733 against 734 |
| ifaction | GDR_ACTION_BG_ACT 0,240,364,117 | 10,247,344,12 | none | 640 against 641 |
| ifapprenticeship | GDR_APPRENTICESHIP_FRAMEL 0,0,364,303 | 10,7,344,12 | none | `panels/f00000069.png`: "Academy Member" on the header bar |
| ifstorageroom | GDR_STORAGE_BG_CTRL 9,38,236,241 | 19,45,216,12 | none | same frame: "Deposit items" on the header bar |
| ifquest | GDR_QUEST_FRAME 0,0,365,355 | 10,7,345,12 | none | not rendered: the quest window is `quest_window.gd`'s own build now, and the ifquest pane is reached only through the popup |
| ifitemmallmyinfo | GDR_ITEM_MALL_MYINFO_FRAME1 0,0,256,518 | 10,7,236,12 | none | not built by the client |

Every caption sits on its subframe's blue header bar, and none collides with anything. It is not a regression: retail draws them too.

### Stale references

No code in `client/` still references:
- the debug party panel (`ActionTabs/Party`, `party_list`, `_chat_in_party`, `_party_names`, `set_party_marks`);
- the old `PartyNet` API (`create_party`, `join_party`, `party_info`, `MemberJoined`, `Result`);
- the old `OPENSRO_QA_PARTY=create|join:` syntax.

`0x0080`-`0x0089` survive only as history:
- `party.gd:8`;
- `useitem.gd:9` (finding 9h);
- `party_protocol.md:552/619` and `party_rules.md:787`, which are gap lists describing the past;
- `PROGRESS.md`.

`party_gui.md`'s gap list is stale (finding 9g).

### World3D outside the party block

- **The chat drop:** `_on_chat_update` drops a type-4 line whose sender is the player. READ `c:0x877810` case 4: `FUN_004e9530(player+0x110, sender)` equal goes to `LAB_00877f7e`, which skips the line. The player's own line still appears from the `0xB025` OK (`HudChat.on_result` adds it). Verified.
- **The `#` gate:** `_hud_chat.group_check` reads `NetClient.party.in_party`. Correct.
- **The removed request:** the entry-time `party_info` request and the `"party"` populate request are gone. The retail window sends no request. Correct.
- **The QA hook:** it runs only when `OPENSRO_QA_PARTY` is set. No per-frame world code changed, so skipping the perf gate is justified.

## Verified correct

### Codecs (`party.gd`)

- Every opcode in the table matches `party_protocol.md`.
- The member record's field order is JID, name+model, level, HP/MP, position (region, then u16 or **signed** u32 for `region & 0x8000`, then world), guild, job, masteries. Checked against the spec table and by decoding `3065_two_members`, `record_full_dungeon` (x 70000, y −5, z 12) and `3864_k6_position_dungeon` by hand.
- The HP/MP nibbles are low = HP and high = MP (`c:0x99a34b`).
- `0x3080` answers: yes is `01 01`; no is `02 0c 2c` for kind 2 and `02 17 2c` for kind 3.
- `0x7060`'s flags byte is `exp | item<<1 | anyone<<2`, and its sender (`0x81c6d0`) is verified.
- `0x3065` reads the party id before testing the mask.

### Edge cases (traced by reading; `Reader` fails soft)

- A mask without position skips the position fields.
- An empty guild is a u16 0 and decodes to "".
- A 0-member `0x3065` gives in-party with no leader record. `refresh` returns early, as `0x6d67c6` does.
- An unknown `0x3864` kind decodes to an `Event` that `_on_event` ignores.
- A truncated packet sets `bad`, every decoder returns null, and every handler returns on null. No out-of-range read is possible: `_need` guards `decode_u16`/`decode_u32` and `slice`.
- A `0x3080` kind other than 2 or 3 is ignored.

### Window rules (asm)

| rule | client address |
|---|---|
| Invite: create out of a party, invite in one when leader or anyone | `0x6d5970` |
| Set opens the dialog only out of a party | `0x6d6620` |
| Party match toggles the matching window | `0x6d59f0` → `0x79c170(1)` |
| Dismiss is leave when in a party | `0x6d5a00` |
| A row button: the leader kicks list index row + 1 (`esi` is incremented before the compare), anyone else leaves | `0x6d5a40` |
| In a party: Invite enabled when leader or anyone; Dismiss enabled with 0xfffff5da only for the leader; Set disabled; Party match untouched | `0x6d6640` |
| Out of a party: Invite and Set enabled; Dismiss disabled in 0xff999999; Lv, level and picture hidden; name centred in (167,155,122); guild (167,155,122); gauges 1.0 on `pt_hp_disable`/`pt_mp_disable`; seven rows cleared | `0x6d6d00` |
| A cleared row hides all ten ifpartyslot controls, so hiding the row's holder is equivalent | `0x6d7520` |

### Colours

| what | value | client address |
|---|---|---|
| Type line and diamonds, in a party | (240,217,165) | `0x6d66d3` |
| Type line and diamonds, out of a party | (167,155,122) | `0x6d6d38..0x6d6dd1` |
| Leader name and leader guild | (255,225,148) | |
| Row name | white | `0x6d782e` |
| "No guild" | grey 153 | |
| Banish | 0xfffff5da | |

### Caption and strings

- The caption is `UIIT_STT_PARTY_INFO`, plus `" (" + UIIT_STT_PARTY_JOIN_ANYONE + ")"` when anyone == 1 (`0x6d5ef0`). The string constants `0xda8fd4` " (" and `0xda8fa8` ")" were read out of the exe.
- Strings `0xda9298`/`0xda92c0`/`0xda90c0`/`0xda562c`/`0xe18044` resolve to BAN/LEAVE/NO_PARTY_LEADER/`*%s`/`%s`.

### Refusal type 0 (the lane's change from the spec): verified

- `0x7b8b40` passes its 4th argument as the filter to `0x7b89e0(0xff, colour, text, filter, 1)`.
- The ack handlers pass 0, the `switch(param_5)` default, which is shown unconditionally.
- So server-coded refusals are type 0 (always shown), in 0xffdbc99b. The spec's "type 4" in §6 applies to the client's own refusals through `0x7781b0(4, …)`.
- Party events stay type 4 (`0x886b10` → `0x778210(…, 4, …)`).
- Own-leave prints its reason line before the clear (`0x886d8b..0x886e6a`, then `0x886e77`). The code does the same.

### The invitation path

- **Auto-decline:** the option byte off sends `0x81cd20` for kind 2 and `0x81cef0` for kind 3 (`0x88ad98..0x88adc7`).
- **The spawned-inviter drop:** `0x88ae1c`/`0x88ae2b` (`CICPlayer` class `0xef1bc0`).
- **Box placement:** x = W/2 − 0x9a and y = H/2 − 0x4a for a 0x134 x 0xa0 box (`0x6ec66b..0x6ec69b`).
- **Kind 6's layout** (`0x645c59..0x646024`), all verified:
  - title `UIIT_STT_CONFIRM_BOX`;
  - resize to 300x176;
  - `+0x840` at 16,48 and `+0x844` at 16,64;
  - OK at 72,139 and Cancel at 152,139; the third button hidden;
  - black boxes at 44,93 and 156,93, at the art's size, inset (3,7,3,6);
  - `+0x850` at 6,121;
  - the timer is set by `0x644650` (10 s / 15 s / 30 s by `simple_msgbox_type`, which the lane labelled INFERRED).

### Settings dialog

- Child 70 at (32,85), 300x200 (`0x6d61e0`).
- Caption static (10, 11, w − 21, 12), centred (`0x6db980`).
- Radio setup `0x657910(3,4)`, `0x657930(20)`, `0x657940(20)`, `0x657950(1)`, `0x657960(100)`, `0x657c40(2,0)`; SHARE is item 0.
- Yes (`0x6d6470`) writes the radios and the box, then calls `0x6d5ef0`. No only destroys the dialog.

### Labels the round marks OURS

- **The accept-invitations default (on):** OURS. The option byte is `0xeece80 + 0x544`, and no initializer for it was found in this review either.
- **Strings as UTF-8:** OURS.
- **The 11-nibble clamp:** OURS (see finding 9f).
- **No pet/horse owner substitution:** OURS.

All four are correctly unlabelled as READ.

### Geometry, measured on the live frames

Measured as pixel edges and glyph bounds. The pane origin is (826, 301), derived from the Invite button's left edge (882 = 826 + 56) and top edge (640 = 301 + 339).

**Buttons:**
- the pitch is 87 (882 / 969 / 1056), which is ifparty's 56 / 143 / 230;
- member rows repeat every 33 px from y 370, which is 69 + 301.

**The leader row (`f00000410`):**

| element | measured | layout gives |
|---|---|---|
| flag | (859, 329) | (859, 328) |
| race mark | (879, 336) | (879, 335) |
| name | starts at 896 | 897 |
| Lv | 982 | 982 |
| level | 998 | 998 |
| HP and MP gauges | 879..1012 | 880 + 136 |
| guild text centre | 1077.5 | 1079 |
| Dismiss | (1142, 339) | (1142, 339) |

**Bram's row:**

| element | measured | layout gives |
|---|---|---|
| race | (872, 376) | (872, 375) |
| name | 891 | 891 |
| Lv | 973 | 973 |
| level | 989 | 989 |
| HP and MP gauges | 870..1003 | 871 + 136 |
| Banish | (1142, 377) | (1142, 377) |

**Settings dialog (`f00000200`):**
- the frame is 858..1157 by 386..585;
- the caption centre is 1006, against 1007.5;
- the check box is at 1118, against 260 + 858;
- the anyone label starts at 869, against 12 + 858;
- the radio dots are given under finding 8.

**Invitation box (`live2/f00000150`):** the box is 486..785, and the black boxes start at 531 and 643, against 486 + 44 and 486 + 156.

**Against the user's screenshots:**
- 01: same layout. The caption suffix is missing (finding 1). "<You are not in a party!>" is this archive's text.
- 05: same layout. The box is unticked (finding 1) and the labels are offset (finding 8).
- 12: same layout. Rows show their own guild colour (finding 5).
