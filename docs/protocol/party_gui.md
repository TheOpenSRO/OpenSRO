# Party GUI: the party window, settings, matching, join dialogs and the HUD member boxes

Recovered in round 709 (lane party709c) to drive the party epic's client rounds. The user's
request (2026-10-04) is in `/root/opensro-handoff/party_system_prompt.txt`; the twelve
screenshots of the original it refers to are `party_refs/01..12` beside it. This page covers
what the player sees. The wire messages are named by purpose here; their opcodes and byte
layouts are party709a's (`docs/protocol/party_protocol.md`), and the rules and formulas are
party709b's (`docs/protocol/party_rules.md`). The round-709 review's findings
(`docs/rounds/party709_review_pg.md`) are applied below.

**Sources.**
- The client: `sro_client.exe` (`/opt/sro-files/client` on the render box), the decompile
  `/var/tmp/decomp_client`, and objdump of the exe for every constant, register argument and
  string. Every address below is a VA in that exe.
- The archive: `Media.pk2` on the box. The layouts are `resinfo\*.txt`, the art is
  `interface\party\`, `interface\quickparty\` and `interface\ifcommon\`, and the strings are
  `server_dep\silkroad\textdata\textuisystem.txt`.
- The screenshots. They come from the user's server ("Esro Online"), whose client is **not** this
  exe. Where they differ from the code, both are given below.

**Labels.**
- **READ**: from the exe or a layout file, with its address or file.
- **MEASURED**: counted or decoded from the archive's textures.
- **INFERRED**: reasoned, or read off a screenshot.
- **OPEN**: not known.
- **OURS**: this project's choice.

No game data is in this file. It gives paths, ids and text keys only, with the English
abridged.

## Corrections to existing records

| Record | Says | What is true |
|---|---|---|
| `docs/UI_TODO.md` "Party / Community / Guild" | the party rows "need one row per member with name, level and HP" | Each row has a portrait (the member's 3D render, the same buffer the HUD box uses), race mark, name, `Lv`, level, HP and MP bars, guild name, and a Banish/Leave button. The leader has its own row above the seven member rows (READ, `0x6d6640`, `0x6d7680`). |
| `docs/TODO.md` "The party race mark always shows China's art" | the server does not send the leader's race | The client sends no race field. It takes the race from the member's model id: the member record's `+0x38` refobj id, then that reference's `+0x9c` byte (`0x93f630`), with the 16-px art from `0x98caa0` (READ, `0x6d67ea..0x6d682c`). So the race comes from the model id the member update carries. |
| `docs/UI_TODO.md` rule 21 list of dead layouts | does not list them | `ifquickpartywnd.txt` and `ifpartymemberviewer.txt` are not named in the exe (neither encoding; MEASURED). `CIFQuickPartyWnd` builds its slots in code (`0x6da110`). |
| the user's screenshots 02/06/07 (party matching) | the Race and Purpose columns are icons (shields, a red flag) | In this exe both columns are **text**. Race is "CHN"/"EUR" (`0x740870`). Purpose is "Hunting"/"Quest"/"Trade"/"Thief" (`0x740910`). The icons belong to the user's server's client. **USER DECISION (2026-10-03): build them as text, as this exe draws them.** |
| the user's screenshots (level box defaults `1 ~ 100`) | max level 100 | This exe's literal default is **110** (`0x6e`, `0x73b030`, `0x73facc`). The 100 is the user's server's cap. OpenSRO uses **110**, following the binary (not a user decision; the user was not asked). |

## 1. The party window (`CIFParty`, `resinfo\ifparty.txt`)

**Where it lives (READ).** It is the party pane of `GDR_MAINPOPUP`, at `13,38` in the popup,
364x303 (`hud_main_popup.gd` already builds it this way). `CIFParty::Create` (`0x6d6fc0`) loads
`ifparty.txt` section `Create` and keeps these controls:

| member | id | control | role |
|---|---|---|---|
| +0x388 | 41 | GDR_PTY_PICTURE (28x28 at 9,33) | leader portrait; mask `interface\party\pt_face.ddj` |
| +0x38c | 48 | GDR_PTYSLOT_BTN_EXITFROMPARTY (316,38, `pt_button.ddj`) | **Dismiss**; text `UIIT_STT_PARTY_DISSOLVE` set at create |
| +0x390 / +0x394 | 43 / 44 | GDR_PTY_STATIC_LEVEL / _LEVEL_DATA | `Lv` and the leader's level (`%d`) |
| +0x398 | 42 | GDR_PTY_STATIC_NAME (71,32,83,17) | leader name |
| +0x39c | 45 | GDR_PTY_STATIC_GUILD (201,46,104,17) | leader guild |
| +0x3a0 / +0x3a4 | 46 / 47 | GDR_PTY_GAUGE_HPGAUGE / _MPGAUGE (54,53 / 54,57) | `pt_hp.ddj` / `pt_mp.ddj`, 136x4 |
| +0x3a8 | 14 | GDR_PTY_PARTY_LEADER (33,27, `com_pt_leader.ddj`, Style 64) | the red leader flag, 12x12 |
| +0x3ac | 15 | GDR_PTY_PARTY_LEADER_RACE_MARK (53,34,16,16, Style 64) | race mark |
| +0x36c..+0x384 | 30..36 | GDR_PTY_PARTYSLOT_0..6 (`CIFPartySlot`, 360x36, pitch 33 from y=69) | the seven member rows |
| — | 20 / 21 / 22 | GDR_PTY_BTN_INVITE / _SETTING / _MATCH | **Invite**, **Set**, **Party match** |
| — | 49 / 50 (+ 52 / 53) | GDR_PTY_OPTION_EXP / _ITEM and their `com_diamond.ddj` | the type line |
| — | 1 | GDR_PARTY_FRAMEL (`sframe_wnd_`) | the window's caption (below) |

The Party match button gets the tooltip `UIIT_STT_TOGGLE_PARTYMATCH` with flag `0x80`
(`0x6d71be..0x6d7221`). Each frame the window rewrites it with the bound key's name
(`0x6d5e5e..0x6d5ea8`, key slot `0x3f8`).

**The caption (READ, `0x6d5ef0` and `0x6d61e0`).**
- With the party settings' "anyone may invite" flag set it reads
  `Text(UIIT_STT_PARTY_INFO) + " (" + Text(UIIT_STT_PARTY_JOIN_ANYONE) + ")"`. Screenshots 01,
  05 and 12 show this as "Party informaiton (Invitation of party member available)", with the
  original's spelling.
- With the flag clear it is `UIIT_STT_PARTY_INFO` alone.
- OpenSRO does not draw a CIFSubFrame's Text yet (UI_TODO "Found on the way"), so this needs that
  builder fix.

**The type line (READ, `0x6d5ef0`).**
- Control 49 shows `UIIT_STT_PARTY_EXP_SHARE` when the exp mode is 1, else
  `UIIT_STT_PARTY_EXP_SELF`.
- Control 50 shows `UIIT_STT_PARTY_ITEM_SHARE` when the item mode is 1, else
  `UIIT_STT_PARTY_ITEM_SELF`.
- The values come from the party manager's state (below), so a player who is not in a party sees
  their own preferences.
- The colours change with membership. In a party (`0x6d66a0..0x6d6725`) both texts and both
  diamonds are (240,217,165). Out of a party (`0x6d6d12..0x6d6dd1`) all four are (167,155,122),
  the greyed look in screenshot 01.

**The party manager's state (READ).** It is the object at `0xeeebd8`. `0x986f50` returns its
block at `+0x20`:

| offset | type | meaning | evidence |
|---|---|---|---|
| +0x00 | u32 | exp mode: 1 share, 0 free-for-all; **starts at 1** | type line; the 4/8 cap test `0x987050` (`exp==0 && count==4` or `exp==1 && count==8` → full) |
| +0x04 | u32 | item mode: 1 share, 0 free-for-all | type line |
| +0x08 | u32 | "anyone may invite" (party flag bit 2); **starts at 1** | caption; Invite enable |
| +0x0c | u8 | names drawn `*%s` and guild hidden | `0x6d6859..0x6d6899`, `0x6d793b`; set by `0x986f60` to `(player vslot 43 != 4)` |
| +0x0d | u8 | the player is the leader | `0x987080`; the PMI leader flag (`0x7b81c5`) |
| +0x0e | u8 | the player is in a party | `0x987070` |
| +0x10 | u32 | member count, at most 8 | `0x6d6c46` asserts "Party Memeber N - Error" above 8 |
| +0x14 | u32 | leader's id (JID) | the leader row; leader flags |
| +0x18 | u32 | the player's own id | `0x6d6740`, `0x6d7698` |

`0x986f60(exp, item, anyone)` is the in-party setter. It is called from the party-info handler at
`0x883de7`. It stores the three values, sets in-party, zeroes the count, and sets `+0x0c`. The
player's vslot 43 is CICPlayer `0x9c7a60`, which returns byte `+0x50d`, **the player's job state**.
The client works it out itself from the job suit it wears (READ, review of round 709): the setter is
`0x9c7a50`, the reset writes 4 (`0x9d2d97`), and for the player `0x9dbcc0` sets `+0x50d =
0x9db8b0(item in equip slot 8)`: an empty slot gives 4 (`0x9db92d`), TID mask `0xf800 == 0x1800`
gives 3, TID4 = 1 (`0x9c8440`) gives 1, TID4 = 2 (`0x9c8480`) gives 2, anything else 4. (This page's
first draft cited `0x9cd235` as "the spawn parse writing it from the wire"; that is a save-and-restore
inside the equip-change routine `0x9cd090`.) The values are the server's: 1 trader, 2 thief,
3 hunter, **4 not in job mode** (`party_protocol.md`, "Job rules"). So `+0x0c = (job != 4)`
(`0x986f96 cmp al,4; setne al`) marks a **job-mode party**, whose members show as `*alias` with no
guild. READ.

**Out of a party (`0x6d6d00`, READ).**
- Leader flag and race mark hidden.
- Name shows `UIIT_STT_NO_PARTY_LEADER` and guild shows `UIIT_STT_NO_GUILD`, both (167,155,122).
- Gauges are full (1.0) on `pt_hp_disable.ddj` / `pt_mp_disable.ddj`.
- Dismiss is disabled, with grey text (153,153,153).
- Invite and Set are enabled.
- All seven rows are cleared (`0x6d7520`).
- The box's archive has an English `<You are not in a party!>` in the first
  `UIIT_STT_NO_PARTY_LEADER` row and an empty one in the second. Screenshot 01's "<Party leader
  doesn't exist>" is the user's server's text. The language-column rule is `UiTextTable`'s.

**In a party (`0x6d6640`, READ).**
- The quick-party board refreshes first (`0x6dae90`).
- Leader flag and race mark are shown.
- If the player is the leader (`+0x14 == +0x18`), Dismiss is enabled with text colour
  (255,245,218), and Invite is enabled.
- Otherwise Dismiss is disabled, and Invite is enabled only when "anyone may invite" is set.
- **Set is disabled in a party.** Screenshot 12 shows it greyed.
- The leader row:
  - name `%s`, or `*%s` with `+0x0c`;
  - level `%d`;
  - race from the model id;
  - guild in (255,225,148). With `+0x0c` it is a grey `<No guild>`. For the player it is their
    own guild (`0x9870d0` + 0x18). Otherwise it is the member's guild string, or a grey
    `<No guild>` when that is empty.
  - HP and MP: the member's `+0x44/+0x48` and `+0x4c/+0x50` as ratios. If the player is the
    leader, their own live HP/MP instead (`+0x458/+0x454/+0x45c` on the player).
- Then every member whose id is not the leader's fills the next row (`0x6d7680`), and the rows
  left over are cleared.

**A member row (`CIFPartySlot`, `resinfo\ifpartyslot.txt`, `0x6d7be0` / `0x6d7680`, READ).**
- Controls:
  - 11 name (63,4,80,17);
  - 12 `Lv` and 13 level (145 / 161,4);
  - 14 guild (199,14,104,17) under the 15 `pt_guildname_02.ddj` label art;
  - 10 race (44,5,16,16);
  - 9 picture (2,4,28,28, `pt_face.ddj` mask);
  - 16 / 17 HP / MP (43,22 / 43,26);
  - 18 the row button (314,7).
- Name is white (`%s` / `*%s`) and level `%d`. The guild follows the leader row's rule.
- The player's own row uses live HP/MP. The others use the member record.
- **The button:**
  - If the player is the leader: `UIIT_CTL_BAN_PARTY` ("Banish"), colour (255,245,218), shown
    on every member row.
  - Else on the player's own row: `UIIT_CTL_LEAVE_PARTY` ("Leave"), shown.
  - Else hidden.

  Screenshot 12 matches: a non-leader sees Leave on their own row only.
- **The portrait** (per-frame, `0x6d72f0`): the player's own row borrows the player mini info's
  render (`0x7b5410`). A member's row borrows that member's quick-party slot render
  (`0x6dab10` → `0x6d7f30`). A member who is not spawned has no render, so the square stays
  black, as in screenshot 12.

**The buttons (READ; message map rows at `0xeb91f8`, built at `0xd6d160`).**

| id | handler | does |
|---|---|---|
| 20 Invite | `0x6d5970` | needs a selected target (`0x778120` ≠ 0). Out of a party it sends the **create-and-invite** request (`0x81c6d0`, 0x7060). In a party, if the player is the leader or "anyone may invite" is set, it sends the **invite** request (`0x81c8f0`, 0x7062). |
| 21 Set | `0x6d6620` | opens the settings dialog **only when not in a party** |
| 22 Party match | `0x6d59f0` | toggles the matching window (`0x79c170(1)`) |
| 48 Dismiss | `0x6d5a00` | in a party, sends the **leave** request (`0x81cad0`, 0x7061; `0x6d5a00 -> jmp 0x81cad0`). There is no disband message: a leader's Dismiss in a party of 3 or more **passes leadership on**; only a party of two dissolves (`sm:0x44f5c1`). READ, review of round 709 |
| 30 row buttons | `0x6d5a40` | a leader **banishes** that row's member (`0x81cb70`, 0x7063, the member's JID). Anyone else **leaves** (0x7061). The member is looked up as **list index row + 1** (`0x6d5a6b add esi,1; push esi; call 0x992380`, then `[eax+0x3c]`), which assumes the leader is member 0 of the list the quick-party drag (`0x992490`) reorders. READ |
| msg 200 from child 10 | `0x6d6470` | the settings dialog's answer (below) |

Both invite senders check the target on the client before sending (READ, `0x81c6d0`,
`0x81c8f0`):
- it is a character, and not the player;
- if it is not a player, its owner is invited instead (`0x9ce910` → `+0xf8`), so clicking a
  member's pet or transport invites the member.

They then write `UIIT_STT_PARTY_PROPOSAL_PENDING` ("[%s]is requesting to party.") with the
target's name to the system messages, type 4 (`0x778210`). The create request's type byte is
`exp | item<<1 | anyone<<2`, taken from the settings block (`0x81c7f0..0x81c82e`). This is
GUI-relevant because **the Set dialog's values are what a new party is created with**.

## 1b. The invitation the invitee sees (`0x3080` kinds 2 and 3)

READ (review of round 709). The `0x3080` handler `0x88aa60` serves request kinds 1..10 (jump table
`0x88b1d4`); the party kinds 2 (form) and 3 (join) go to `0x88ad8a`:
1. It reads the flags byte. When option byte `+1` of `0x4f9d00` (the "accept party invitations"
   game option) is 0 it **auto-declines**: kind 2 through `0x81cd20` (`[2][0x2c0c]`), kind 3
   through `0x81cef0` (`[2][0x2c17]`).
2. **It silently drops the invitation unless the inviter is spawned in the invitee's client as a
   player** (`0x88ae1c cmp edi,ebx; je`; `0x88ae2b call 0xb94b90` with class `0xef1bc0`; `je`).
   Nothing is answered, so the server times out after 30 s and both sides get `0x2c10`.
3. Otherwise it queues **HUD request kind 6** (`0x6ec5d0`, a 308x160 popup for kind 6) with the
   inviter's name and the flags repacked as `anyone<<2 | exp<<1 | item`.
4. Yes sends `0x81cc30` (kind 2) / `0x81ce00` (kind 3), `[1][1]`; No sends `0x81cd20` / `0x81cef0`.

The popup's text keys and any timer of its own are **OPEN** (OPEN item 7). The request queue is
shared: Join, Refresh and the page-0 request on opening the matching window run only when it is
empty (§3).

## 2. The party settings dialog (`CIFSetPartyMode`, `resinfo\ifsetpartymode.txt`)

**Opening (READ, `0x6d61e0`).**
- It is child id 70 (`0x46`) of the party pane, at (32,85,300,200), on the
  `msgbox2_window_` frame.
- The caption is `UIIT_STT_CONFIRM_BOX` ("Confirmation window"), as in screenshot 05.
- The message is `UIIT_STT_SET_PARTY_INFO_MSG` ("Set the party properties.").

**Controls (READ, `CIFSetPartyMode::Create`, `0x6db980`).**
- Radio group 13 (exp, at 24,76,120,44): items 20 high at a pitch of 20. Item 0 is
  `UIIT_STT_PARTY_EXP_SHARE`, item 1 is `UIIT_STT_PARTY_EXP_SELF`. The vararg order is
  `0x657ba0(radio, SHARE, SELF)`. Group captions `UIIT_STT_PARTY_EXP_METHOD` /
  `_ITEM_METHOD` are set through `0x657c10`, but screenshot 05 shows none.
- Radio group 14 (item, at 155,76): item 0 `UIIT_STT_PARTY_ITEM_SHARE`, item 1 `_ITEM_SELF`.
- Check box 17 (260,132,16,16, `com_radiobutton_off.ddj`) with label 18
  `UIIT_STT_PARTY_INVITATION_ANYONE` ("Can invite without master status.").
- Yes (20) / No (21).

**Initial state (READ, `0x6d61e0`).**
- The exp radio is item 0 when exp = 1 and item 1 when exp = 0. The item radio follows the same
  rule.
- The check box is the "anyone" flag (`0x6db770` / `0x6db7b0`).

**Yes (READ, `0x6d6470`).** It writes exp = (radio 0 ? 1 : 0), the same for item, and anyone =
the check box into the manager's block. It then refreshes the type line and caption
(`0x6d5ef0`) and destroys the dialog. **No request is sent**: the values wait for the next
create. **No** only destroys the dialog.

OpenSRO has no `CIFCheckBox` builder yet (UI_TODO "Found on the way").

## 3. The Party Matching window (`CIFPartyMatch`, `resinfo\ifpartymatch.txt`)

**Frame (READ).** It is `GDR_PARTY_MATCH` in `ginterface.txt`: 785x480 on `mframe_wnd_`, caption
`UIIT_PAG_PARTYMATCH_PSEARCH`. `CIFPartyMatch::Create` (`0x73ae90`) applies CIFMainFrame's
chrome (`0x816f80`) and then loads, in order, the sections `Create`, `SearchInfo`,
`SlotListButton` and `SlotList`. The sections `JoinProgress`, `PartyRegister` and `AutoMatch`
are child windows created on demand (ids 100 / 105 / 110, `0x7390b0` / `0x7392c0` /
`0x739400`).

**Search row (READ, Create).**
- Name edit 47: max length 12.
- Level edits 49 / 50: max length 3, range 1..110, defaults "1" and "110".
- `~` between them (id 43).
- Purpose combo 45: items in this order — Hunting (`UIIT_CTL_PARTYMATCH_PSEARCH_OBJECTCOMBAT`),
  Quest (`UIIT_STT_QUEST`), Trade (`UIIT_CTL_PARTYMATCH_PSEARCH_FIND_OBJECTTRADER`), Thief
  (`UIIT_CTL_PARTYMATCH_PSEARCH_FIND_OBJECTTHIEF`), All
  (`UIIT_CTL_PARTYMATCH_PSEARCH_OBJECTALL`). The default is index 4, All. **The purpose byte
  0..3 uses the same order** (`0x740910`'s jump table at `0x740a2c`).
- Search 55, Refresh 56.

**The list.**
- 12 `CIFPartyMatchSlot` rows (ids 70..81, 715x24, pitch 23 from y=144).
- Header buttons 60..67, sorting by:
  - type bit (`0x7326e0`/`0x732750`);
  - race (`0x7327c0`/`0x732820`);
  - name (`0x732880`/`0x7328f0`);
  - purpose (`0x732960`/`0x7329c0`);
  - and the rest. Each has an ascending and a descending comparator. Handler `0x73e050`.
- A vertical scroll (26). Its range is the held records minus 12 (`0x73bb20`).
- A page spin (25).

**A row (READ, `CIFPartyMatchSlot`, `resinfo\ifpartymatchslot.txt`, fill `0x740d30`).** The
record (`CPartyRegData`) fields it shows:

| column | control | from | format |
|---|---|---|---|
| No. | 10 (10,7,36,11) | +0x00 u32 | `%d` |
| Type | 11 MARK (60,5,16,16) | +0x0b bit 0 | `pt_association.ddj` (exp-sharing, 8) or `pt_eachone.ddj` (4); 16x16 (MEASURED) |
| Race | 12 (101,7,31,11) | +0x08 | text: 0 → `UIIT_CTL_PARTYMATCH_AUTOMATCH_RACE_CH` "CHN", 1 → `_EU` "EUR" |
| Name | 13 (150,7,78,11) | +0x10 wstring | `%s`; **`*%s` when the purpose is Trade or Thief** (a job alias) |
| Title | 14 (248,7,306,11) | +0x2c wstring | clipped to 302 px (`0x8b47c0(…,0x12e,1)`) |
| Purpose | 15 (566,7,37,11) | +0x0a | text: 0 Hunting, 1 Quest, 2 Trade, 3 Thief |
| Member | 16 (619,7,24,11) | +0x09 | `%d/8` with bit 0, `%d/4` without |
| Level range | 17 (659,7,51,11) | +0x0c / +0x0d | `%d~%d` |

- **Selection:** a click on a row with data (`0x73aab0`) clears the previous selection and gives
  the row's bar `interface\ifcommon\com_bar01select_` (3-slice). Unselected rows use
  `com_bar01_` (`0x740ca0`). MEASURED: `com_bar01select_mid` has a (255,178,82) line at rows 2
  and 21 of its 24, which is the gold border in screenshot 06.
- **The player's own listing is pinned to the top row in light blue**: when the player has a
  registration (`0x97b950`), row 0 shows it with highlight 1, which colours every column
  (135,233,255) (`0x740ea1`). The other rows skip it (`0x73a770`). Screenshot 02 shows this
  (Tobi, first and blue).
- **Hover tooltip** (`0x740750`): the row's party type, the `_EXP_SHARE`/`_EXP_SELF` line by bit
  0 and `_ITEM_SHARE`/`_ITEM_SELF` by bit 1.

**Buttons (READ; message map at `0xebc5c8`, built at `0xd6fa80`).** The enable rules are from
`0x7384a0`:

| id | button | enabled when | does |
|---|---|---|---|
| 15 | Join party | no own registration, not in a party, level ≥ 1, and the list has records | `0x739500` (only when the HUD request queue is empty, `0x6ec4b0(..) == 0`): the selected row's record → the **join request** (`0x81d150`, 0x706D, the record id); then the join-progress window opens with (own name, the leader's name), each `*`-prefixed for a Trade/Thief party. **No client-side level or job check**: the refusal comes back from the server. |
| 16 | Whisper | the list has records | `0x7386e0`: opens a whisper to the selected party's name (not the player's own) |
| 17 | Auto match | as Join | `0x7396e0`: opens the Auto match dialog |
| 18 | Form party | no own registration, and either (not in a party and level ≥ 5) or (leader and the party not full) | `0x7397b0`: client refusals to the system messages, type 4: an existing registration → `UIIT_MSG_PARTYMATCH_RECORD_ERROR_AGAIN`; not in a party and level < 5 → `_JOIN_ERROR_LEVEL`; in a party but not the leader → `_JOIN_ERROR_PARTY`; full → `UIIT_MSG_PARTYERR_ALREADY_FULL`. Otherwise opens the register dialog (new). |
| 19 | Change entry | own registration whose name is the player's | `0x739900`: the register dialog in modify mode, filled from the record |
| 20 | Delete entry | as Change | `0x738a30` → `0x738940`: a confirm box (`UIIT_STT_CONFIRM_BOX`, `UIIT_STT_PARTYMATCH_DELETE_CONFIRM`); Yes sends the **delete** request (0x706B, the reg id; `0x732680`) |
| 55 | Search | always | `0x73bb80` → `0x73b780`: **a client-side filter over the records already held**: an exact, case-sensitive whole-name match when the name box is not empty (READ, `0x47ec20`; see the closed OPEN items), the purpose unless All, and the level ranges overlapping. Nothing left → `UIIT_MSG_PARTYMATCH_PSEARCH_NORESULT`, type 4. |
| 56 | Refresh | — | `0x732a80` (only when the HUD request queue is empty): requests the spin's page (0x706C) and **disables itself for 2 s** (timer 10, 2000 ms; `0x73ab60` re-enables) |
| 25 | page spin | — | `0x732630`: requests that page (0x706C) |

- Opening the window requests page 0 (`0x73b1ff`), only when the HUD request queue is empty
  (`0x73ae90`).
- A 1 s timer (id 20) redraws the list (`0x73ab96`).
- While the player's party is full and they hold the registration, the client deletes it itself
  (`0x7387c0`).

**The register dialog (`CIFPartyMatchRegister`, `ifpartymatchregister.txt`, 314x373,
`0x73f820`; caption `UIIT_PAG_PARTYMATCH_RECORD` "Forming party", or `_MODIFY` "Editing
party").**
- Objective radio 40: 4 items, 66x22 at a spacing of 50. Hunting, Quest, Trade, Thief.
- **Job restriction (READ, `0x73f957..0x73fa14`)** on the player's job byte (vslot 43):
  - 1 (Trader) or 3 (Hunter): only Trade is enabled, and selected.
  - 2 (Thief): only Thief is enabled, and selected.
  - Anything else: Trade and Thief are disabled.
- Level min/max edits 42 / 43: 1..110, defaults 1 / 110.
- The type line shows the current settings (`0x73f1f0`).
- Title edit 49: max 50. The default title comes from the objective (`0x73f610`): Hunting
  `_RECORD_DEFAULT1`, Quest `_DEFAULT3`, Trade `_DEFAULT2`, Thief `_DEFAULT4`. It is replaced
  only while the title is still one of the defaults.
- OK (`0x73f370`) refuses a min/max not in order with `UIIT_MSG_PARTYMATCH_RECORD_ERROR_LEVEL`,
  and an empty title with `_RECORD_ERROR_TITLE` (type 4). It sends the **register** request
  (`0x823d30`, 0x7069) or, in modify mode, the **modify** request (`0x823df0`, 0x706A).

**The auto-match dialog (`CIFPartyMatchAuto`, `ifpartymatchauto.txt`, 314x337, `0x73e790`).**
- Objective radio: the same items and job restriction.
- Race radio: CHN, EUR, Open (`UIIT_CTL_PARTYMATCH_AUTOMATCH_RACE_*`).
- Exp radio (Share, Free) and item radio (Share, Free).
- OK (`0x73ebc0`) picks candidates **client-side from the held records**: the purpose must equal
  the chosen one; the race must equal it unless Open; the type flags must equal (exp share
  bit 0, item bit 1, and bit 2 from the player's own "anyone" setting); the player's level must
  lie inside the record's range.
- It queues up to 10 candidates and tries them one by one through the join request
  (`0x786e20`/`0x786e70`/`0x786eb0`).
- It reports `UIIT_MSG_PARTYMATCH_AUTO_PROGRESS` or `_PSEARCH_NORESULT`, type 4.

## 4. The leader's join-request popup (`CIFPartyMatchReqJoin`)

**Frame and controls (READ).**
- It is `GDR_PARTY_MATCH_REQ_JOIN` in `ginterface.txt`: 360x315 on `msgbox2_window_`, caption
  `UIIT_PAG_PARTYMATCH_JOINREQUEST` ("Join request sent", as screenshot 08 shows).
- Layout `ifpartymatchreqjoin.txt` (`0x7400c0`).
- Fill: `0x7403f0`, from the server's request.

| control | shows |
|---|---|
| 21 DESC_PML | `UIIT_STT_PARTYMATCH_JOIN_REQUEST` with the requester's name: "[%s]has requested to join this party. Confirm?", the name in (255,239,218) by the string's own `<font>` |
| 34 / 35 (88,121 / 130,121, 32x32, on `pt_icon_frame02.ddj`) | the requester's two masteries' icons, from the two mastery ids of the `0x706d` message (`+0x7c4`/`+0x7c8`, not the member record's) (`0x73fed0` → `0x937010` → the mastery's icon), with the mastery name as the tooltip; an id with no record leaves the frame empty |
| 30 LEVEL | `%d` |
| 31 RACE | CHN / EUR from the requester's model id (`+0x9c`) |
| 32 POS | the requester's region, named through `0x740030` (region id → zone-name text) |
| 33 GUILD | the guild name when the request's **job state** byte (`+0x7cc`) is 4, i.e. the requester is not in job mode, else empty (`0x74064d`) |
| 45 Confirm (`UIIT_CTL_PARTYMATCH_JOINREQUEST_CONSENT`) / 46 Cancel (`_REFUSE`) | — |

**What the fill stores (READ, review of round 709).** `0x884660` passes (job id, requester JID,
struct) to `0x7403f0`, which stores `+0x7b8` job id, `+0x7bc` requester JID, `+0x7c0` entry,
`+0x7c4`/`+0x7c8` masteries, `+0x7cc` the u8 job state and `+0x7d0` the member record
(`0x740425..0x740462`).

**Answers (READ).** Each answer sends the reply (`0x81d210`) with (`+0x7b8` job id, `+0x7bc`
requester JID, code):
- Confirm sends code 1 (`0x73fc40`).
- Cancel sends code 0 (`0x73fc90`).
- **10 s with no answer** (timer 1, `0x2710` ms, set at `0x7406de`) sends code 2 and closes
  (`0x73fb70`).

## 5. The joining progress window (`CIFPartyJoinProgress`, section `JoinProgress`)

**Frame and controls (READ).**
- 365x149 on `msgbox2_window_`, caption `UIIT_PAG_PARTYMATCH_JOINPROGRESS` ("Joining").
- Layout `ifpartyjoinprogress.txt`:
  - PML 5, the text;
  - gauge 11 (35,104), `pt_progress.ddj` 296x12, gold (MEASURED);
  - `pt_progress_window.ddj` (308x24) behind the gauge.

**Text (READ, `0x732000`, kind 1).** `UIIT_STT_PARTYMATCH_JOIN_PROGRESS` formatted with
(requester's own name, the party's name). That gives "[Dasha]You [Tobi] has requested to join
this party." in screenshot 09, where Dasha is the requester and Tobi the listing's leader. Kind 2
is the academy's reuse (`UIIT_MSG_TC_JOIN_ERROR_DUPLE`, 15 s).

**Timer (READ, `0x7322e0`).**
- It ticks every 200 ms (timer 1, 0xc8).
- The bar is `elapsed / 10000 ms` (`0x2710`, the double 10000.0 at `0xdb3720`).
- At 10 s the bar fills, the timer stops, and the matching window runs its close
  (`0x7390b0(0, …)`).

**While open (READ).** It disables Join, Auto match, Form party, Search and Refresh. They come
back on close, unless an auto-match run is still going (`0x110f80c+0x64c`).

Both client windows count 10 s. The ShardManager's own 15 s is a backstop: with a stock client the
leader's popup answers code 2 at 10 s first, so the requester gets "no reply" about 10 s after the
request (`party_protocol.md`, Timers).

## 6. Where refusals and party notices appear

**The system message window (READ).**
- It is `GDR_SYSTEM_MESSAGE_VIEW`, child 0x44, bottom right at x = W − 357 (see
  `docs/protocol/system_message.md`; OpenSRO's `hud_system_message.gd`).
- Every client-side party and party-match refusal above is written there with **type 4**,
  through `0x7781b0(4, text)`: the PARTY filter checkbox.
- The invite's "[%s]is requesting to party." uses `0x778210(4, …)`.
- Joins and leaves are type 4 from `UI_PARTY 0x886b10` (already recorded).
- **The server's coded refusals are drawn there too** (READ, review of round 709): the `0xb06d`
  error branch calls `0x778190`, which takes child `0x44` (`0x778192 push 0x44`) and jumps to the
  code-to-text table at `0x7b8b40`. The code → `UIIT_*` names are in `party_protocol.md`.

## 7. The HUD party member boxes (`CIFQuickPartyWnd` / `CIFQuickPartySlot`)

**The board (READ).**
- It is `GDR_QUICKPARTYBOARD` in `ginterface.txt`, at **4,137**. That is the left column under
  the player mini info, as screenshots 03 and 04 show.
- `ifquickpartywnd.txt` is not loaded.
- The rebuild (`0x6dae90`):
  - with no party, it destroys every slot and hides;
  - otherwise it makes one slot per member, **skipping the player** (by name);
  - each slot is a 122x40 child (`0x6da110`) on `interface\ifcommon\window_all.ddj`, the
    atlas slice **u 0.723633–0.842773, v 0.138672–0.216797** (741..863 x 71..111 of the
    1024x512 atlas: the round-faced box). **Corrected in round 715**: this line first read
    "UV (0.216797, 0.138672)–(0.842773, 0.723633)", the same four floats (`0xda5438`
    0.723633, `0xda973c` 0.842773, `0xda9740` 0.138672, `0xda9738` 0.216797, READ from the
    exe) paired the wrong way -- a 641x300 region of unrelated panels; the 122x40 the pairing
    above gives is the slot's own size;
  - slots sit at x = board x + 13 + column × 133;
  - **y steps 73 px when the game option byte `+0x08` (`0x4f9d00`) is set, else 56** (INFERRED:
    that option is "Quick Party View Buff Status", `UIIT_MSG_QUICK_PARTY_CHARACTER_BUFF`, since
    it is also what feeds the buff row);
  - a new column starts when less than 230 px would remain below a 73-px slot.

**The lock button (READ, `0x6db290`, `0x6da210`, `0x6da9d0`).**
- It is a 20x20 button at screen x 0, 7 px above the board.
- Its art is `quickparty_move_lock.ddj`, or `_unlock.ddj` while reordering is unlocked.
- Its tooltip is `UIIT_STT_QUICKPARTY_MOVE` + "\n" + `_MOVE_STATE` with `_LOCK`/`_UNLOCK`.
- A click flips the state and makes every slot draggable or not. A drop swaps two members'
  order (`0x6db5e0` → `0x992490`).
- It is shown only while the party has **more than 2 members** (`0x6db58a`).

**A slot (READ, `CIFQuickPartySlot::Create`, `0x6d8890`, `resinfo\ifquickpartyslot.txt`).**

| member | id | control | role |
|---|---|---|---|
| +0x388 | 1 | GDR_QPS_PICTURE (6,6,28,28) | the 3D portrait: a 64x64 BufRender (`0x9edae0(0x40,0x40)`) through the `qpt_face.ddj` disc mask |
| +0x38c | 5 | GDR_QPS_STATUS (6,6,28,28) | the "far away" overlay (below) |
| +0x390 / +0x394 | 2 / 3 | GDR_QPS_GAUGE_HP / _MP (42,24 / 42,30, 76x4) | `qpt_hp.ddj` / `qpt_mp.ddj`; HP/MP from the member record |
| +0x398 | 4 | GDR_QPS_TXT_ID (43,5,73,12) | the name |
| +0x39c | 7 | GDR_QPS_PARTY_LEADER (30,6, `com_pt_leader.ddj`) | **the red flag**, shown iff this member's id is the leader's (`0x6d7db0`) |
| +0x3a0 | 10 | GDR_QPS_PARTY_BUFF (`CIFBuffViewer`, 32,39) | the buff row |
| +0x3b4 / +0x3b8 | 20 / 21 | GDR_QPS_EFFECT_HP / _MP (`pmi_*_quick_effect_caution.ddj`, Style 512) | low HP/MP caution |
| +0x3bc | 100 | GDR_QPS_SELECT (-3,-4, `qpt_grope_select.ddj`, Style 64) | **the selected glow** |
| +0x3c0 / +0x3c4 | new 101 / 102 | two 17x17 children at (-3,39) and (15,39), tooltip flag 0x80 | **the two mastery icons** |

GDR_QPS_PARTY_RACE_MARK (id 6) is never taken by Create, so it keeps its Style 64 and stays
hidden. Screenshots 03, 04 and 11 show no race mark on the HUD boxes.

**The 3D portrait (READ).**
- `0x6d8bf0` renders the member's model from its "Bip01 Head" bone.
- Offsets 0.2 and 6.5, field 30, light terms 0.58 / 0.3, far 1000. These are the player mini
  info portrait's constants (`docs/protocol/player_mini_info.md`).
- It needs the member's model (`+0x3e4`). ~~With the member not spawned in the client, nothing
  is drawn and the disc stays black (screenshot 04).~~ **Corrected in round 715:** the model is
  the slot's OWN, not the spawned body's: `0x6d80d0` loads the record's model id into the
  animation object embedded at `+0x3e0` (whose `+4`, i.e. `+0x3e4`, is the model `0x6d8bf0`
  draws), plays ANI_POSE (`0x3c`) on it and turns it to 0.1 rad (`0xe1b7fc`). Nothing in the
  chain looks the member up in the world, so a member has a face whether spawned or not (bare:
  the id carries no equipment). Screenshots 03, 04, 11 and 12 show every disc black -- the
  player's own mini-info portrait included, whose render is certain -- so they were taken where
  that client's BufRender draws nothing; they are not evidence about the rule.
- The model is rebuilt when the member record's model id `+0x38` changes (`0x6d80d0`), and the
  render runs only while the dirty byte `+0x3dc` is set (set by `0x6d7f20` after a model change,
  checked by the slot's vslot_012 `0x6d90e0`; cleared at `0x6d8bf0`'s start, re-set while the
  model is not ready).

**The "far away" overlay (READ, `CIFQuickPartyWnd::vslot_012`, `0x6db380`, and `0x6d86e0`).**
- Each frame, for each member, it takes the squared 3D distance between the player and the
  member (`0x9ed1e0`: region-aware dx² + dy² + dz²).
- It uses the member's live object position when spawned, else the record's last position
  (`+0x5a` region, `+0x5c` x, `+0x64` z) **at y = 0** -- the record's y is not read (round 715:
  `local_8` stays 0 in `0x6db380`).
- **Only in an exp-sharing party (exp mode = 1)** it maps the distance to a level. In a
  free-for-all party the level is always 0.

| distance (units) | level | STATUS art |
|---|---|---|
| < 600 | 0 | none (cleared) |
| 600 – 700 | 1 | `qpt_face_faraway_60.ddj` |
| 700 – 800 | 2 | `_70` |
| 800 – 900 | 3 | `_80` |
| 900 – 1000 | 4 | `_90` |
| ≥ 1000 | 5 | `_100` |

- The thresholds are the squared constants 360000 / 490000 / 640000 / 810000 / 1e6 (`0xda98fc`,
  `0xda9900`, `0xda9908`, `0xda990c`, `0xda9910`; the comparisons are `>=`). They mix floats and
  doubles: `0xda98fc`, `0xda9908` and `0xda990c` are floats, `0xda9900` (490000) and `0xda9910` (1e6)
  are doubles, which is why `0xda9904` is skipped (review of round 709).
- MEASURED: every faraway texture is a 28x28 disc (632 texels) of (14,96,255) with alpha
  130 / 158 / 181 / 211 / 241 for _60.._100. So the fade is **stepped, five steps**, not
  continuous. `qpt_face_faraway.ddj`, `_50` and `qpt_face_warning.ddj` (red (255,17,0) α128) are
  in the archive but not named in the exe.
- At level 5 the HP/MP caution effects are hidden too (`0x6d91c5`).

**Buffs (READ, `0x6d9250`, `0x6d8b20`).**
- A slot shows buffs only when the buff option above is on **and** the member's object exists in
  the client (`0x9c35e0` on the member id, a CICPlayer). The buffs are then read from that object
  (`0x9d25e0`) into the viewer (`0x6d9010`: `0x7fab90(1,1)`, `0x7fabb0(6)`, `0x7fabc0(15,15)`,
  `0x7fabe0(12,12)`). **Round 715:** the target window's viewer makes the same calls
  (`0x7fabb0(8)`, `0x7fabc0(0x17,0x17)`, `0x7fabe0(0x14,0x14)`), read in round 638 as per-row
  count, pitch and icon size, so here **6 a row at a 15-px pitch, 12x12 icons** (the earlier
  "icons 15x15, 12 per row" swapped them); `0x7fab90(1,1)` stays OPEN.
- Otherwise the viewer is cleared.
- So **"can't see buffs when far" means the member is not spawned in the player's client**. That
  is the spawn range, not the 1000-unit fade.

**HP/MP caution (READ, `0x6d90e0`).**
- EFFECT_HP shows when the HP gauge's ratio is ≤ 0.3 and the member record's byte `+0x58` is 0.
  Its visibility also follows game-option byte `+0x12`. EFFECT_MP is the same with `+0x13`.
- The meaning of `+0x58` is OPEN. With `+0x58 == 0` and HP 0, the HP gauge shows 0.2 instead of
  0 (`0x6d9303`).

**Masteries (READ, `0x6d93fc..0x6d951b`).**
- The two icons are the member record's mastery ids `+0x6c` and `+0x70`, each resolved through
  `0x937010` (icon path `+0x64`, name `+0x4` as the tooltip).
- An id with no record hides its icon. Screenshot 04 has OverTalanted with one icon.
- **Which two masteries the server puts there** is `GObjPC::FUN_005a1890(&m1, &m2)` on the
  server (`party_protocol.md`, the member record's bit `0x08`); how that function picks the two was
  not read (OPEN item 8). The client draws what it is sent.

**Selection.**
- The world's SetTarget (`0x780ee0`) hands every selected id to the board (`0x6d9610`).
- Each frame (`0x6db1a0`) a slot whose member's object is the selected object shows
  GDR_QPS_SELECT, and every other slot hides it.
- Selecting anything else (a monster, an NPC, another player, the player, a deselect) clears it.
  **A ground click is not a selection (round 715, READ):** the left press `0x793570` sends a
  ground click to `UI_SILKMALL::FUN_0078f8d0`, which never calls the deselect `0x778650(0)` or
  `0x780ee0`; it moves the ring (`ground_markers.md`). So the glow stays through a walk. (This
  line first listed "ground" among the things that clear it, as the user's request says.)
- MEASURED: `qpt_grope_select.ddj` is a 132x48 frame in teal/cyan ((63,164,149), (0,255,229),
  (81,255,243)). This is the glow in screenshot 11, and what the user calls "blue".
- **A left click on a slot** (vslot_030 `0x6d8500`) looks the member up by name (`0x9c3640`).
  When the member is spawned it selects them (`0x78f5f0`) and plays `prim\snd\ui\uiwinopen.wav`.
  A member who is not spawned cannot be selected from the slot.
- **Ctrl+2..8** select slot N−2's member the same way, and Ctrl+1 selects the player
  (`0x77f230`).

**The player's own yellow glow (READ).**
- The player mini info shows GDR_PMI_SELECT (id 200, `interface\playerminiinfo\pmi_select.ddj`,
  256x128) exactly when the selected id is the player's own (`0x7b7cbe..0x7b7cd6` →
  `0x7b5490`).
- MEASURED: its colours are (255,255,0) and (169,164,77), the yellow in screenshot 10.
- The player selects themselves with a left press on their own block or with Ctrl+1.
- The PMI's own leader flag GDR_PMI_PARTY_LEADER (id 14) shows while the player is the party
  leader (`0x7b81ba..0x7b81d9`).

## 8. Strings

The archive's `textuisystem.txt` has **273** keys matching `PART|PTY` (MEASURED: last row wins;
English is column 8 unless that is "0", then column 9). Many are private-server or vSRO-plus
additions (`VPLUS_*`, region locks, summons). Here are the ones the code above uses, with the
English abridged:

| key | English (abridged) | used by |
|---|---|---|
| UIIT_STT_PARTY_INFO | Party informaiton | caption |
| UIIT_STT_PARTY_JOIN_ANYONE | Invitation of party member available | caption suffix |
| UIIT_STT_PARTY_EXP_SHARE / _EXP_SELF | Exp Auto Share / Exp Free-For-All | type line, dialogs, tooltip |
| UIIT_STT_PARTY_ITEM_SHARE / _ITEM_SELF | Item Auto Share / Item Free-For-All | the same |
| UIIT_STT_PARTY_EXP_METHOD / _ITEM_METHOD | Acuqire experience point / Collect item | settings radio captions |
| UIIT_STT_PARTY_INVITATION_ANYONE | Can invite without master status. | settings check box |
| UIIT_STT_SET_PARTY_INFO_MSG | Set the party properties. | settings message |
| UIIT_STT_CONFIRM_BOX | Confirmation window | settings / delete captions |
| UIIT_CTL_YES / UIIT_CTL_NO | Yes / No | settings |
| UIIT_STT_NO_PARTY_LEADER | (archive-dependent; see §1) | leader name, no party |
| UIIT_STT_NO_GUILD | <No guild> | guild fields |
| UIIT_STT_LEVEL_LV | Lv | rows |
| UIIT_STT_PARTY_DISSOLVE | Dismiss | leader-row button |
| UIIT_CTL_BAN_PARTY / UIIT_CTL_LEAVE_PARTY | Banish / Leave | row button |
| UIIT_CTL_INVITE_PARTY / UIIT_CTL_PARTY_SETTING / UIIT_CTL_PARTYMATCH_MAINBUTTEN | Invite / Set / Party match | buttons |
| UIIT_STT_TOGGLE_PARTYMATCH | Party Matching(E) | Party match tooltip |
| UIIT_STT_PARTY_PROPOSAL_PENDING | [%s]is requesting to party. | invite notice, type 4 |
| UIIT_PAG_PARTYMATCH_PSEARCH | Party Matching | match caption |
| UIIT_CTL_PARTYMATCH_PSEARCH_NAME / _OBJECT / UIIT_STT_LEVEL | Name / For. / Level | search row |
| UIIT_CTL_PARTYMATCH_PSEARCH_OBJECTALL / _OBJECTCOMBAT / UIIT_STT_QUEST / _FIND_OBJECTTRADER / _FIND_OBJECTTHIEF | All / Hunting / Quest / Trade / Thief | purpose combo, purpose column |
| UIIT_CTL_PARTYMATCH_PSEARCH_FIND / _REFRESH | Search / Refresh | buttons |
| UIIT_CTL_PARTYMATCH_PSEARCH_LIST_NUM / _LIST_TYPE / _LIST_RACE / UIIT_STT_COSNEWUI_BASICINFO_NAME / UIIT_STT_LETTER_TITLE / _PSEARCH_OBJECT / _LIST_NUMBER / _LIST_LEVEL | No. / Type / Race / Name / Title / For. / Member / Lv. Range | headers |
| UIIT_CTL_PARTYMATCH_PSEARCH_JOIN / UIIT_STT_GET_WHISPER / _AUTOMATCHING / _RECORD / _MODIFY / _DELETE | Join party / Whisper / Auto match / Form party / Change entry / Delete entry | buttons |
| UIIT_CTL_PARTYMATCH_AUTOMATCH_RACE_CH / _EU / _ANYTHING | CHN / EUR / Open | race column, auto match, join popup |
| UIIT_PAG_PARTYMATCH_RECORD / _MODIFY / _AUTOMATCH | Forming party / Editing party / Auto matching | dialog captions |
| UIIT_CTL_PARTYMATCH_RECORD_OBJECT / _LIMITLEVEL / _LIMITLEVEL_MIN / _MAX / _PARTYTYPE | Party Objective / Level Restrict / Min. / Max. / Party type | register / auto labels |
| UIIT_MSG_PARTYMATCH_RECORD_DEFAULT1..4 | default titles | register |
| UIIS_CTL_CONFIRM / UIIS_CTL_CANCEL | Confirm / Cancel | register / auto |
| UIIT_STT_PARTYMATCH_DELETE_CONFIRM | Delete this party? | delete confirm |
| UIIT_PAG_PARTYMATCH_JOINREQUEST | Join request sent | leader popup caption |
| UIIT_STT_PARTYMATCH_JOIN_REQUEST | [%s]has requested to join this party. Confirm? | leader popup |
| PARAM_MASTERY / UIIT_CTL_PARTYMATCH_JOINREQUEST_PLACE / _GUILD | Mastery / Position / Guild | leader popup labels |
| UIIT_CTL_PARTYMATCH_JOINREQUEST_CONSENT / _REFUSE | Confirm / Cancel | leader popup buttons |
| UIIT_PAG_PARTYMATCH_JOINPROGRESS | Joining | progress caption |
| UIIT_STT_PARTYMATCH_JOIN_PROGRESS | [%s]You [%s] has requested to join this party. | progress text |
| UIIT_MSG_PARTYMATCH_PSEARCH_NORESULT | No parties found matching your search. | search / auto, type 4 |
| UIIT_MSG_PARTYMATCH_AUTO_PROGRESS | Automatic party matching is in progress. | auto, type 4 |
| UIIT_MSG_PARTYMATCH_RECORD_ERROR_AGAIN / _JOIN_ERROR_LEVEL / _JOIN_ERROR_PARTY / UIIT_MSG_PARTYERR_ALREADY_FULL | already formed / not the level / already in a party / cannot add more | Form party refusals, type 4 |
| UIIT_MSG_PARTYMATCH_RECORD_ERROR_LEVEL / _RECORD_ERROR_TITLE | level submission incorrect / title not changed | register refusals, type 4 |
| UIIT_STT_QUICKPARTY_MOVE / _MOVE_STATE / _MOVE_LOCK / _MOVE_UNLOCK | Change Quick Party Window Sequence / Current Condition : %s / Lock / Unlock | lock button |

Server-reply messages (`UIIT_MSG_PARTYERR_*`, `UIIT_MSG_PARTYMATCH_JOIN_*`, `UIIT_MSG_PARTY_JOIN` …)
are party709a's to map to codes.

## Gap list: OpenSRO's client today

**Round 711 built items 1-4 and 9** (`docs/rounds/party711.md`); the rest stand.

The starting values of the block (READ, round 711's review): the static initializer `0xd75d80`
constructs the manager (`0x99c1c0`), which calls `0x99ba00` on `+0x20`: exp 1, item 0 (`+0x04`),
anyone 1; the party clear `0x998be0` never rewrites them.

1. ~~**Protocol.**~~ (done, round 711) `client/scripts/net/party.gd` speaks OpenSRO's own 0x0080–0x0089
   (create/join-by-id/leave/info by name). The retail messages are party709a's.
2. ~~**The debug party panel**~~ (removed, round 711) (`World3D` ActionTabs/Party: Create, Leave, Join-by-id) is still the
   only way to form a party, plus `OPENSRO_QA_PARTY`. Retire it once Invite works.
3. ~~**Party window:**~~ (built, round 711; the members' 3D portraits wait for item 5) the layout is built (`HudPanels`, the popup pane), but only the leader marks
   are wired (`set_party_marks`). Not built:
   - the caption suffix (a CIFSubFrame Text, not drawn at all yet);
   - the type line and its colours;
   - the leader row (name/level/guild/HP/MP/race from the model id);
   - the seven rows and the Banish/Leave rule;
   - the button enable rules, the Invite pre-checks, and the portrait borrowing.
4. ~~**Settings dialog:**~~ (built, round 711) not built. Missing are the client-side preference block (exp/item/anyone)
   that the create request reads, and a `CIFCheckBox` builder.
5. ~~**Quick party board:**~~ (built, round 715: `ui/hud/hud_quick_party.gd`; the game option
   bytes +0x08/+0x12/+0x13 default on, OURS) not built at all. That covers:
   - slot layout and column wrap;
   - 3D portraits (TODO "party and academy slots' portraits");
   - the stepped faraway overlay, exp-share only;
   - HP/MP and caution;
   - the leader flag, two mastery icons and the buff row (spawned members only);
   - the teal select glow following the world target;
   - click-to-select by name;
   - the lock and drag reorder;
   - Ctrl+2..8 (keymap no-ops).
6. ~~**PMI:**~~ (built, round 715: `HudPlayerInfo.set_selected` / `set_party_leader`)
   GDR_PMI_SELECT (yellow) and GDR_PMI_PARTY_LEADER are hidden by `HudPlayerInfo`'s
   allow-list. Both need their show rules above.
7. **Party matching:** layout only. Not built:
   - list fill, the own row pinned in blue, the gold selection, the type tooltip;
   - sorting, the page spin and the Refresh cooldown;
   - the client-side Search filter;
   - the enable rules;
   - the register/modify, auto-match and delete-confirm dialogs;
   - Whisper;
   - the join progress (10 s) and the leader's popup (10 s, codes 1/0/2).
   - Race and Purpose columns as **text** (USER DECISION 2026-10-03), level defaults 1 / 110.
8. **System messages:** the type-4 filter exists (`hud_system_message.gd`). None of the
   party-match lines are routed to it.
9. ~~**The invitation popup** (§1b):~~ (built, round 711) not built; today an invite joins directly by party id.
10. Out of this lane, noted only: minimap and worldmap party signs (`mm_sign_party`,
   `wmap_sign_party`), and the target window's party re-centring (UI_TODO).

## OPEN items that block implementation

Closed in round 709:
- ~~1. Icons or text in the matching list.~~ **USER DECISION (2026-10-03): text**, as this exe draws
  it ("CHN"/"EUR", "Hunting"/"Quest"/"Trade"/"Thief"). `pt_flag.ddj` (12x12, red) stays unused, as in
  the exe.
- ~~2. The job byte's wire value 4.~~ **READ**: 4 is "not in job mode"; the client works the byte
  out from its own job suit, and the values are the server's 1 trader / 2 thief / 3 hunter / 4 none
  (§1).
- ~~4. The leader popup's second id and kind byte.~~ **READ**: the requester JID and the job state
  (§4).
- ~~7 (first draft). The Search name compare.~~ **READ:** `0x47ec20` is `wstring::compare(pos, n,
  ptr, len)`, called as `search.compare(0, search.size(), name, name.size())` and tested against 0
  (`0x73b97a..0x73b99b`). So the match is **exact on the whole name**, compared as raw wide
  characters (so case-sensitive). An empty name box skips the test (`0x73b974`).

Still open:
3. **The member object the board and window read**: `+0x04` name, `+0x20` guild, `+0x38` model,
   `+0x3c` JID, `+0x40` level, `+0x44/+0x48` HP/max, `+0x4c/+0x50` MP/max, `+0x58` a byte,
   `+0x5a/+0x5c/+0x64` region and position, `+0x6c/+0x70` masteries. HP and MP arrive only as the
   tenths byte, split into nibbles at `0x99a34b` (READ, review of round 709), so the ratios drawn are
   tenths. Which wire field fills each remaining slot (the conversion at `0x99a34b`'s function), and
   where the "max" slots come from, is not traced.
5. **The meaning of member byte `+0x58`**, which suppresses the caution effect and the 0.2 HP floor.
   (Round 715: and whether the 0.2 is drawn at all -- `0x6d9250` writes it into the gauge's
   `+900` and `+0x380`, then `0x6d7db0` in the same rebuild writes the raw ratio into `+900`.)
6. ~~The quick-party buff viewer's argument meanings.~~ **Round 715:** the target window's
   viewer was read with the same calls (round 638: per row, pitch, icon size), so 6 a row, 15-px
   pitch, 12x12 icons (§7); `0x7fab90(1,1)` alone stays OPEN.
7. **The invitation popup's text keys and timer** (§1b, HUD request kind 6 at `0x6ec5d0`).
8. **How the server picks the two masteries** (`gs:FUN_005a1890`).
