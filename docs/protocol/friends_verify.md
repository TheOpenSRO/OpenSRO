# friends.md — adversarial verification (round 834)

Re-read on 2026-10-26 from the binaries, not from friends.md's wording. Client readers are the
authority for S→C, client senders for C→S. Addresses: `c:` sro_client.exe, `gs:` SR_GameServer.exe,
`sm:` SR_ShardManager.exe. Server append `0x404090` / SM writer `0x402df0` sizes were read from EAX
in the asm. Probe scripts: `scratchpad/r834/verify_fr/` (vf.py, strs.py, apc.py, rd.py, tbl.py), run on
the box from `/var/tmp`.

Verdicts: **CONFIRMED**, **WRONG** (corrected reading given), **UNVERIFIABLE**, **RESOLVED** (an OPEN
item of friends.md answered), **NOT CHECKED** (outside this pass).

## Corrections first

| # | friends.md says | Correct reading | Evidence |
|---|---|---|---|
| W1 | Box kind `0x23` (incoming request) has buttons `UIIT_STT_ACCEPT` / `UIIT_STT_REFUSE` (7.4; 3.2 step 4 "with Accept/Refuse") | Visible buttons are **`UIIT_STT_ACCEPT` "Accept"** (left, control 200 at `+0x800`, box x+0x62, y+0x72) and **`UIIT_CTL_NO` "No"** (right, control 201 at `+0x804`, x+0xba, y+0x72; caption left at its `ifmessagebox.txt` default). The `UIIT_STT_REFUSE` caption is written to control 202 (`+0x808`), which the same case then **hides**. | `c:0x648572` ACCEPT → `[esi+0x800]`; `c:0x64859f` REFUSE → `[esi+0x808]`; `c:0x6485b0 push 0; jmp 0x6458ad` → `[esi+0x808]`→vslot `0x5c` (ShowWindow, `c:0x656040`→`0x652b70`) with 0. `+0x800/+0x804/+0x808` = controls 200/201/202 (`c:0x63e570` loads section `MsgBoxINIF`, chosen by `c:0x643c20(1)` from `c:0x6ec5d0`). `resinfo\ifmessagebox.txt` MsgBoxINIF: 200 `UIIT_CTL_YES`, 201 `UIIT_CTL_NO`, 202 `UIIT_CTL_CONFIRM`. textuisystem: `UIIT_CTL_NO` = "No". Compare the party/guild boxes (`c:0x645fb6`/`0x64614b`), which put ACCEPT on `+0x800` and REFUSE on `+0x804`. |
| W2 | Friend count text is `` ` : %d / %d` `` / `` ` : %d / 20` `` (2, 7.3, 7.6) | The format is **`": %d / %d"`** (no leading space), args (count, 20). It is the only such string in the exe; letters use the same one. | `c:0x5a9982 push 0x14; push esi; push 0xd8d998`; UTF-16 at `0xd8d998` = `: %d / %d`, `0xd8d996` = NUL. |

## Section 3.1 — wire layouts

| Claim | Verdict | Evidence |
|---|---|---|
| C→S `0x7302 {str name}` | CONFIRMED | `c:0x824c30`: one `0x53d8c0` string write. After the send (even if the send fails) it sets `+0x790 = 1` (`c:0x824da0`). |
| S→C `0x7302 {u32, u32, str}` | CONFIRMED | `c:0x886000`: `0x4f7220(4)`, `0x4f7220(4)`, `0x4f7a70`. The two u32 are stored as box params "1" and "2" (`c:0x8860d6`, `0x8860e7`; strings at `0xda2f08`="1", `0xda40dc`="2") and echoed in `0x3303` in the same order. They are opaque to the client. |
| S→C `0xB302 {u8 2, u16 code}` + `{u8 reason, str name}` when code = `0x640b` | CONFIRMED | Client `c:0x885e50`: Read 1; ≠2 → exit; Read 2; ≠`0x640b` → `0x778190(0x13, code)`; else Read 1 + `0x4f7a70`. Server kind 5 → `gs:0x5d7fb9..0x5d7fe8`: sizes 1, 2, 1, then string. |
| C→S `0x3303 {u32, u32, u8}` | CONFIRMED | `c:0x820b20`: `0x508fe0` 4, 4, 1. Called from `c:0x798a15` (answer 1) and `c:0x798a29` (answer 0). |
| C→S `0x7304 {u32 friendCharID}` | CONFIRMED | `c:0x820a60`: one 4-byte write. |
| S→C `0xB304 {u8 1, u32}` / `{u8 2, u16}` | CONFIRMED | `c:0x881fd0`. **On success the client reads the u32 and does nothing else**: the row is removed only by `0x3B07` kind 3. Server `gs:0x5d8330` sends kind 3 (`0x5d6a30`) and then `B304` (sizes 1, 4). |
| S→C `0x3305 {u8 n, n × {u32 CharID, str name, u32 RefObjID, u8 state}}`, replaces the list | CONFIRMED | `c:0x87fdd0` clears (`0x9970e0`) and then `0x9993b0` reads 1, then per entry 4, u16+bytes, 4, 1 → `0x9971c0(CharID, name, RefObjID, state)`. Server `gs:0x5db1a0`: 4, str, 4, 1. |
| state 0 = online, 1 = offline | CONFIRMED | Lamp `c:0x5a7a44`: 0 → `gil_contact_on.ddj` (`0xd919d0`), 1 → `gil_contact_off.ddj` (`0xd8dae8`). `sm:0x446490` writes 0 for a friend whose user state is 1 or 2. Kind 2 adds the entry with 0 (`c:0x8863da push ebx`, ebx=0). |
| `0x3B07` dispatch: `kind−2` through `c:0x886778` | CONFIRMED | Table entries: 2→`0x886377`, 3→`0x886449`, 4→`0x886485`, 5/6/7→`0x886732` (assert), 8→`0x88662d`, 9→`0x886702`. |
| kind 2 `{u32 CharID, str name, u32 RefObjID}` | CONFIRMED | `c:0x8863a1` 4, `0x8863ad` str, `0x8863bb` 4. Server `gs:0x5d67de..0x5d6801`: 1, 4, str, 4. |
| kind 3 `{u32 CharID}` | CONFIRMED | `c:0x88645a` 4 → `0x997290`. Server `gs:0x5d6aa0/0x5d6ab1`: 1, 4. |
| kind 4 `{u32 CharID, u8 state}` | CONFIRMED | `c:0x886499` 4, `0x8864a7` 1. Server `gs:0x5d69ef..0x5d6a11`: 1, 4, 1. |
| kind 5 → `0xB302 {2, 0x640b, reason, name}` | CONFIRMED | `gs:0x5d7f35..0x5d7fe8` (opcode `0xb302` pushed at `0x5d7f8e`). |
| kind 8 `{str sender, u32 senderRefObjID, u32 date}` | CONFIRMED | `c:0x886659` str, `0x886667` 4 → entry `+0x1c`, `0x886675` 4 → entry `+0x3c` (`c:0x992ca0`). `+0x3c` is what the letter row prints as the packed date (`c:0x5c13d0`). Server `gs:0x5d6e6d..0x5d6e99`: 1, str, 4 (memo `+0x6c`, the RefObjID), 4 (the date). |
| kind 9 `{u8 unread}` | CONFIRMED | `c:0x886710` reads 1 and ignores it; banner `UIIT_MSG_LETTERERR_UNKNOWNLETTER`. Server `gs:0x5d6c50` sends only when the count is above 0 (`jbe 0x5d6cb0`). |
| `0x730B` (empty) | CONFIRMED | `c:0x820c10`: no writes. |
| `0xB30B {u8 1, u8 n, n × {str, u32 RefObjID, u32 date, u8 status}}` / `{2, u16}` | CONFIRMED | `c:0x882030` + `c:0x9976a0`: 1, then 1, then per entry u16+bytes, 4, 4, 1. Server entry `gs:0x5db310`: str, 4, 4, 1. |
| `0x7308 {u8 index}` | CONFIRMED | `c:0x820cb0`: one 1-byte write. |
| `0xB308 {u8 1, u8 index, str text}` / `{2, u16}` | CONFIRMED | `c:0x886170`. |
| `0x7309 {str to, str text}` | CONFIRMED | `c:0x824760`: `0x53d8c0(param_1)`, then `(param_2)`. It is not sent when the name starts with the character at `0xd92240` (the alias check). |
| `0xB309 {u8 1}` / `{2, u16}` | CONFIRMED | `c:0x8820b0`. |
| `0x730A {u8 index}` | CONFIRMED | `c:0x820d70`. |
| `0xB30A {u8 1, u8 index}` / `{2, u16}` | CONFIRMED | `c:0x882130` → `0x997870(index)`. |
| `0x730C {u8 kind, u8 n, n × str, str text}` | CONFIRMED | `c:0x825490`. The kind byte is written **only when it is 1 or 2**; then n, the names, and the text last. |
| `0xB30C {u8 1, u8 nFailed, n × {str, u16}}` / `{2, u16}` | CONFIRMED | `c:0x895530`. nFailed 0 → the `UIIT_MSG_LETTER_SENDOK` banner. |
| `0x730D {u8 op, str name}` | CONFIRMED | `c:0x824dd0`: 1-byte write, then a string. |
| `0xB30D {u8 op, u8 result}` + `str` only when result is 0 | CONFIRMED | `c:0x89c3a0`. Results 1/2/3 map to the keys in 3.6. |
| `0xB302 {1}` is never sent; the client ignores result 1 | CONFIRMED, refined | Never sent: `gs:0x517f90` replies only when `!= 1`. The client shows nothing for result 1, but **every** `0xB302` (result 1, any code, any reason) ends at `c:0x885fc5`, which resets `+0x790` to 0. |
| Client registration census (`0x3305, B302, B304, 7302, B30B, B308, B309, B30A, 3B07`; `B30C` at `0x898285`; `B30D` at `0x8a425a`); senders only `7302, 3303, 7304, 7308..730D` | CONFIRMED | An immediate census of `0x33xx/0x73xx/0xB3xx/0x3Bxx` over the whole client asm finds exactly these, plus `0x330f` (`c:0x87048d`) and unrelated `0x7380`. |

## Section 3.2–3.4 — client reactions and server flow

| Claim | Verdict | Evidence |
|---|---|---|
| `B302` reason 0 → `UIIT_MSG_FRIENDERR_REFUSAL` banner, flag not checked (the refuser sees it too) | CONFIRMED | `c:0x885e50`: the reason-0 branch never calls `0x5a6310`. Banner via `0x8c9bb0` → `0x77b580`. The name is read but not shown. |
| reason 2 + flag 1 → `UIIT_MSG_FRIEND_SYSCANCEL`; reason 2 + flag 2 → close box `0x23` (`0x778b90(0x23)`); then flag = 0 | CONFIRMED | `c:0x885f48` reads the flag. Other reasons show nothing. The reset `0x799520(0)`→`0x5a6300(0)` runs on every path. `+0x790` is on the friend pane (`0x799520` = `GetWindow(0xb1)`→`0x58ee90`). |
| Incoming `0x7302` opens box `0x23` and sets the flag to 2 | CONFIRMED | `c:0x8860c6` `0x77f0a0(mgr, 0x23, 2, …)`, then `c:0x886102` `0x5a6300(2)`. The flag is set even when a box of that kind already exists (`0x6ec400` refuses a second one). |
| Box `0x23`: 360×151, title `UIIT_STT_AGREEMENT_BOX`, `'name'` + `REQUEST_01`, then `REQUEST_02` | CONFIRMED | `c:0x6482ef..0x6484e6` (`push 0x97; push 0x168`; `'%s'` at `0xd9c020`). |
| Box `0x23` buttons Accept / Refuse | **WRONG**, see W1 | Accept / No. |
| Box `0x23` has a client timer of its own (OPEN 4) | **RESOLVED: yes, 30 s** | The case ends at `c:0x6458bc` → `0x644650`: `SetTimer(10, 30000)` (10000 if the box param `simple_msgbox_type` is 4, 15000 if 8; the friend box sets neither, and `0x6441b0` defaults to 0). On expiry, `CIFMessageBox::vslot_005` `c:0x63bf40` kills timer 10 and, for any kind but `0xe`, destroys the box (`0xba0e40`) **without the callback**: no `0x3303` is sent, and the server's own 30 s timeout then answers. |
| Answer mapping: Accept → 1, otherwise 0 | CONFIRMED, refined | `c:0x63b6e0` (control 200, or Enter when 200 is visible) sets result 1; `c:0x63b8b0` (control 201 "No", or Esc when 201 is visible) sets 0; `c:0x641eb0` (control 202, hidden here) sets 2. Message-box keys `c:0x6449ed..0x644a6a`. The kind-0x23 callback `c:0x7989fb`: result 1 → `0x3303{p1, p2, 1}`, anything else → `{p1, p2, 0}`; then `0x820b20` resets the flag to 0. |
| Kind 2 → box `0x22`: 360×151, `UIIT_STT_CONFIRM_BOX`, `UIIT_MSG_YOUNME` + `UIIT_MSG_FRIEND_CONCLUSION`, one button | CONFIRMED, completed | `c:0x648114..0x6482ea`. YOUNME is formatted (`vslot 0xc4`) with **(the friend's name, your own name)**: the box string `+0x820` (set from the kind-2 name, `c:0x886417`) and then `0x9d6580`. The one visible button is control 200, with its caption left at the default **`UIIT_CTL_YES` "Yes"**; 201 and 202 are hidden. No timer. |
| Kind 4: system line `FRIEND_CONNECT` (0) / `FRIEND_DISCONNECT` (1), printed only when the friend's name ≠ your own | CONFIRMED | `c:0x8864f1..0x88661a`: `0x592e00(ownName, entry+4)` returns `compare != 0`; printed via `0x7781b0(0, …)`. Other state values store but print nothing. |
| Kind 3: remove, no text | CONFIRMED | `c:0x886449`. |
| Kind 8: add unread and refresh; alarm unless the letter pane is showing | CONFIRMED | `c:0x8866a9..0x8866f8` (`0x798fe0(1)`). |
| `0xB304` handling | CONFIRMED (no client effect) | See the `0xB304` row above. |
| The asker's flag stays 1 after an accept that fails (INFERRED) | CONFIRMED, broader | The only writers of `+0x790` are `c:0x824da0` (1), `c:0x820bf8` (0), `c:0x885fd3` (0) and `c:0x886102` (2); the only reader is `c:0x885f48`. The kind-2 handler touches none of them, so the asker's flag stays 1 **after a successful accept too**, until the next `0xB302`, `0x7302` or `0x3303`. |
| GS asker checks, in order: len 0 or >32 → 2; no messenger → `0x6407`; own name (CompareStringA) → 3; `'` `"` or filtered word → 3; already listed → `0x6409`; 20 → `0x6408` | CONFIRMED | `gs:0x5d7620`. `0x426f30` returns `CompareStringA − 2` (0 = equal); `0x7312f0` returns 1 on `'`, `"` or a list hit; `0x5d6890` matches by name; the cap test is `*(msgr+0x14) < 0x14`. A null asker also gives 2. |
| Relay always returns 1 (so `0x640e` is unreachable) | CONFIRMED | `gs:0x5d7cc0` ends `return 1`. |
| SM target checks: not found or `+0x234 ≠ 2` → `0x640d`; no messenger → `0x6407`; 20 → `0x640f`; asker already on the target's list → `0x6409`; job failure → 2 | CONFIRMED, completed | `sm:0x447650` asm: `0x4477ff` (`0x640d`), `0x447754` (`0x6407`), `0x447770` (`0x640f`, `cmp [eax+0x14],0x14; jb`), `0x44778b` (`0x6409`; `0x4468d0` is called on the target's messenger in EAX with the asker's `+0x7c` CharID), `0x4477f3` (2). Code 2 also comes back when the asker cannot be found or has no messenger (`0x4476b9`/`0x4476c9`) and when the opcode ≠ `0x7302` (`0x4476e3`). |
| SM failure → `0x3C01` → `0xB302 {2, code}` | CONFIRMED | `sm:0x410653..0x4106bc`: when `0x447650` ≠ 1, `0x3C01 {u32 JID, u16 opcode, u16 code}`. `gs:0x4169d0` replies with opcode `(op & 0x3fff) \| 0x8000` = `0xB302`. |
| 20-friend cap places | CONFIRMED | `gs:0x5d7620` asker; `sm:0x44776a` target; `sm:0x447320` both again (`byte +0x14 < 0x14`, `0x13 <` refuses; codes `0x640f`/`0x6408`/`0x6409` returned but dropped); `gs:0x5d6b23` (`cmp al,0x14; ja` skips the `0x3305`); client `c:0x5a9982 push 0x14`. |
| 30 s wait | CONFIRMED | `sm:0x447792 fld [0x79b01c]` = 30.0f, passed to job vslot 4 with (askerJID, `0x7302`, targetJID). |
| Accept → `0x3B07` kind 2 to both, each with the other's data | CONFIRMED | `sm:0x448ad0`: two messages, to `param_1+0x1c4` and to `ebx+0x1c4`; each carries the other side's CharID, name and RefObjID (`+0x248`). |
| A failed accept sends nothing | CONFIRMED | `sm:0x4478bf cmp ax,1; jne 0x4479fe` (return). |
| Refuse/timeout → kind 5 to **both**, both carrying the **target's** name and the answer byte as reason | CONFIRMED | `sm:0x4478d8..0x4479fc`: both messages write `ebx+0x1a8` (ebx = arg 3 = the target, from `sm:0x420938` job `+0x10`). The answer is the raw `0x3303` byte (`sm:0x420919 0x41b550`); the timeout passes 2 (`sm:0x420a00`). |
| `0x3305` is sent once at world entry | CONFIRMED | The only `push 0x3305` is `gs:0x5d6b3a`, reached only by `0x5d6550` ← kind 7 (`gs:0x5d7e6e`). Kind 7 is written only by `sm:0x447a70` (`0x447b10`), answering `0x7B06` kind 6, which `gs:0x5d75c0` sends only from kind 1 (`gs:0x5d7df8`), i.e. messenger creation. |
| Kind 4 pushes on a friend's login (0) and logout (1) | CONFIRMED | `sm:0x447b63` `0x447560(…, 0)` right after the kind-7 list; `sm:0x446323` `0x447560(…, 1)`. `0x448c80` writes kind 4 (`0x448caa`). |
| Delete is mutual; the other side gets kind 3 | CONFIRMED | `sm:0x446930` `_Friend_Remove` > 0 → `0x446b10` on the friend's messenger → `0x448d10`, which writes `0x3B07 {3, friendJID, myCharID}` (`sm:0x448d3a mov byte,3`), but only when the friend is in game (`+0x234 == 2`). The deleter's own client gets kind 3 from `gs:0x5d8330`→`0x5d6a30`. GS refusals: not listed → 3, no messenger → `0x6407` (`gs:0x5d77d0`). |

## Section 7.3 — friend pane (dumped `res_ui\cumunity_friend.2dt` with `tools/dump_2dt.gd` on the box)

| Claim | Verdict | Evidence |
|---|---|---|
| Pane 646 origin (301,253) | CONFIRMED | Record 646 at P(301,253), S(601,362), `CNIFFriendWnd`. |
| 79 frame 6,5,588,350; 15 tile 22,21,557,319; 16 border 15,31,569,281 | CONFIRMED | (307,258), (323,274), (316,284) absolute. |
| 17 342,13,177,15 `UIIT_CTL_FRIEND` ffefdaa4; 18 527,13,55,15 | CONFIRMED | 17 has halign 2. |
| 255 18,34,68,24; 62 87,34,479,24 `UIIT_STT_FRIENDLIST`; 337 566,34,16,24; 338 565,73,16,206 | CONFIRMED | |
| 11 rows at x 18, y 56+23i, 546×24, `com_bar01_left.ddj`; lamp 52 (30,5,12,16), race 51 (107,5,16,16), name 341 (149,5,370,15) | CONFIRMED | 11 `CNIFFriendSlot` records at y 309..539 absolute. The `.2dt` default race texture is `com_kindred_europe16.ddj` and the lamp default is `gil_contact_on.ddj`, both replaced by the row fill. |
| Buttons 39/40/41 at (121/244/366, 322), 112×24, `com_mid_button02.ddj`, texts `GET_WHISPER` / `FRIENDADD` / `FRIENDDEL` | CONFIRMED | Color fffff7ca. Message map `0xeb1e68..`: 39→`c:0x5a6350`, 40→`0x5a7570`, 41→`0x5a76c0`, 62→`0x5a99f0`, scroll 338→`0x5a8dc0`, box results `0x8075`→`0x5a7840`, `0x8077`→`0x5a87c0`. |
| Count ` : %d / %d` | **WRONG**, see W2 | `": %d / %d"`. |
| Lamp: 0 on, 1 off, other values unchanged | CONFIRMED | `c:0x5a7a44..0x5a7a8b`. |
| Race: RefObjID record `+0x9c`, 0 → `com_kindred_china16.ddj`, 1 → `com_kindred_europe16.ddj` | CONFIRMED | `c:0x5a7aaa` `0x93f370(RefObjID)` → `0x971210(1)` → byte `+0x9c` → `0x98caa0(out, race, 1)` (the 16 px pair). When the RefObjID has no record the icon is set empty. |
| Name in one colour whatever the state | CONFIRMED | Only `SetText` (vslot `0xbc`) on `+0x4e8`, `c:0x5a7b62`. |
| Left click selects; no double-click or right-click | CONFIRMED | `CNIFFriendSlot::vslot_017` `c:0x5a8880` handles only `0x201`. |
| Whisper: `$name ` into the chat line, online not checked | CONFIRMED | `c:0x5a6350` → `0x777d10` → `0x7ab470`: `'$'` (`0xdbb848`) + name + `' '` (`0xe19330`). It does nothing when the selected name equals your own. |
| Add box `c:0x5a7160`: 306×151, purpose 4, title `UIIT_STT_INPUT_BOX`, text `UIIT_MSG_FRIEND_IDINPUT` | CONFIRMED | `0x132×0x97`; `0x643c20(4)` = section `MsgBoxInsertMsg`; `0x641f40(4)` sets title INPUT_BOX and case 4 sets `FRIEND_IDINPUT`. It is not reopened while `+0x794` holds a box. Pre-fill: the selected player's `+0x110` name, or for a non-player the owner looked up through `0x9ce910` (the spec's pet INFERENCE fits the code shape). |
| Add OK sends `0x7302` when the name is non-empty and not your own | CONFIRMED | `c:0x5a7840` (type `0x51`, result 1): empty → no send; `0x592e00(name, own)` ≠ 0 → `c:0x5a7920`. |
| Delete: confirm `UIIT_STT_CONFIRM_BOX` + `UIIT_MSG_FRIEND_IDDELET` (formatted with the name) → `0x7304` | CONFIRMED | `c:0x5a76c0` (needs a selection `+0x79c`; params `type`=`0x52`, `del_friend_id`); `c:0x5a87c0`: type `0x52` and result 1 → `0x7304(del_friend_id)` at `c:0x5a8805`, then deselect. |
| 7.7 caller list | CONFIRMED, incomplete | Also `c:0x70e760` (`0x7302`) and `c:0x70d152` (`0x7304`) in the `CIFFriend` code that 7.1 calls dead. This is consistent with that INFERENCE and changes nothing to build. |

## Section 9 — absence claims (spot-check)

| Claim | Verdict | Evidence |
|---|---|---|
| No server opcode beyond those in 3.1 | CONFIRMED | GS handler slots `0x300..0x311` (table base `0xcd5508`, 8-byte stride; stores at `gs:0x50e7c2..`): set only for `0x302, 303, 304, 308, 309, 30A, 30B, 30C, 30D`. Control: the known handlers (`0x517f90` = 0x302, `0x5180f0` = 0x30B at `0xcd5560`) land in the slots the stride predicts. |
| No client handler or sender beyond 3.1 | CONFIRMED | See the registration census row. |
| Friend-group / help / invitation-block keys absent from the exe and `vsroplus_lib.dll` | CONFIRMED | `FRIEND_GROUP`, `FRIEND_HELP`, `BlockFriendInvitation` and `FRIEND_BLOCK` have 0 hits (UTF-16 and ASCII) in both files. Control: `FRIENDERR_REFUSAL` is found in the exe (UTF-16, 1). |

## Not checked in this pass

The server-side letter checks and codes (3.5), the whisper-block server checks and status maps (3.6), the
position of the block list in `0x3013`, sections 4–6 (except the codes touched above) and 7.4–7.6
beyond the friend boxes. None of these was contradicted by anything read here.

## Counts

76 claim rows across the four tables (the two correction rows at the top repeat two of them):
**73 CONFIRMED**, of which 10 carry a refinement or completion (`0xB302` result 1 still resets the
flag; `0xB304` success is ignored by the client; the answer mapping and the silent timer close; the
`0x22` button caption and YOUNME arguments; the extra SM code-2 cases; the flag after a successful
accept; the 7.7 dead-code callers; the `0x730C` kind byte; the whisper own-name no-op; the S→C `0x7302`
u32s are opaque to the client and only echoed). **2 WRONG** (W1 the `0x23` buttons, W2 the count
format). **1 RESOLVED** OPEN item (box `0x23` has a 30 s client timer and closes silently).
**0 UNVERIFIABLE**. The add-box pre-fill for a non-player target stays the spec's INFERRED: it fits
the code shape, but this pass did not name `0x9ce910`.
