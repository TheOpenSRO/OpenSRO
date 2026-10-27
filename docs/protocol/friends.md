# Friends, letters and the whisper block list: the messenger (round 834)

Read on 2026-10-26 from `sro_client.exe` (`/var/tmp/decomp_client`, `/var/tmp/sro_client.dis`),
`SR_GameServer.exe` (`/var/tmp/decomp_server`, `/var/tmp/gs_dis.txt`) and `SR_ShardManager.exe`
(`/var/tmp/decomp_shardmgr`, disassembled for this round to `/var/tmp/r834_sm.dis`) on the render
box. Addresses: `c:` client, `gs:` GameServer, `sm:` ShardManager. Labels: READ (seen in code,
addresses given), INFERRED (with why), OPEN, OURS.

The original calls the whole thing the **messenger** (`CMessengerMgr`, `CMessenger`,
`trs_sm_messengerjob`, `trs_messenger_job` are its classes in both servers). It has three parts:
the **friend list**, **letters** (the code says Letter in the UI, Memo in the DB), and the **whisper
block list**. All three live in one window, the Community view of the guild window, as three tabs.

## Corrections from the review (friends_verify.md, READ)

The second reading (`friends_verify.md`, 73 of 76 claims confirmed) corrects two:

- **Box 0x23 shows Accept and No, not Accept and Refuse.** `UIIT_STT_REFUSE` goes on +0x808
  (control 202, CERTIFY, c:0x64859f), which the same case then hides (c:0x6485b0 -> 0x6458ad); the
  visible right button (+0x804, control 201) keeps its layout caption `UIIT_CTL_NO` "No". Accept or
  Enter answers 1, No or Esc 0. Its timer is 30 000 ms (c:0x644650); when it fires the box is
  destroyed unanswered (c:0x63bf40).
- **The count format has no leading space:** `": %d / %d"` (c:0xd8d998).

Also read in review: box 0x22's one button keeps its layout caption `UIIT_CTL_YES`; `0xB304 {1}`
changes nothing on the client (the row goes with the kind-3 push); Whisper does nothing for the
player's own name; the asker's flag `+0x790` stays 1 after a successful accept (only `0xB302`
clears it).

## Summary

- **Friends are added by name** with `0x7302 {str name}`. The target answers a 30 s Accept/Refuse
  box with `0x3303`. The list is capped at **20** on both sides.
- **Friends are mutual.** `_Friend_Add` and `_Friend_Remove` act on both people, and the other
  side is told live.
- **Login** sends the list once (`0x3305`). After that, changes and online/offline arrive as
  `0x3B07` pushes, kinds 2/3/4: added, removed, logged on or off.
- Each friend entry is `u32 CharID, str name, u32 RefObjID, u8 state`, where state 0 is online and
  1 is offline. The RefObjID gives the race icon.
- **Letters** are short notes, at most 1000 characters, sent by character name.
  - A mailbox holds 20. Letters are addressed by their **index** in that list.
  - Each letter carries a sender name, the sender's RefObjID, a packed date and a read flag.
  - A guild or union "multi-letter" (`0x730C`) needs guild level 3 or 4.
- **The whisper block list** has up to 20 names, kept by the server. It reaches the client inside
  the character data (`0x3013`). `0x730D` adds or removes a name.
- **No friend groups in vSRO 1.188.** The text keys exist, but there is no opcode, no handler and
  no control for them (section 9).
- **Two processes decide.** The ShardManager owns the friend lists, online state, the request
  transaction and letter delivery. The GameServer validates requests, holds each player's copy and
  owns letter read/delete and the block list. OpenSRO is one process, so it does both (section 1).

## 1. Who decides what (READ)

| Concern | Process | Where |
|---|---|---|
| Friend request checks on the asker (name length, self, own list, own cap) | GameServer | `gs:FUN_005d7620` (handler `0x302` `0x517f90`) |
| Friend request checks on the target (online, target's cap, already listed) and the 30 s wait | ShardManager | `sm:FUN_00447650` (reached from the `0x7c00` relay `sm:0x410520`) |
| Adding the friendship (`_Friend_Add`) and telling both sides | ShardManager | `sm:FUN_00447850` → `sm:FUN_00447320` → `sm:FUN_00448ad0` |
| Deleting a friend (`_Friend_Remove`) | ShardManager | `sm:FUN_00447b80` → `sm:FUN_00446930` |
| Loading the friend list (`_Friend WHERE CharID = %d`) and the online flags | ShardManager | `sm:FUN_00446100` at character login, `sm:FUN_00446490` when writing |
| Online/offline pushes to friends | ShardManager | `sm:FUN_00447560` (login 0, logout 1) → `sm:FUN_00448c80` |
| Each player's live friend copy, and turning ShardManager events into client messages | GameServer | `gs:CMainProcess::FUN_005d7d20` (the ShardManager's `0x3B07`) |
| Sending letters (`_Memo_Add`, delivering to an online recipient) | ShardManager | `sm:FUN_00447d00` (single), `sm:FUN_00448180` (multi) |
| Loading, reading and deleting letters (`_Memo_Delete`, status update) | GameServer | `gs:AQ_CharDataLoader` `0x5d6f00`, `gs:0x5d79c0` / `0x5d6f80`, `gs:0x5d7a90` / `0x5d70a0` |
| The whisper block list (`_BlockedWhisperer_Add/_Remove`) and whisper filtering | GameServer | `gs:FUN_00518db0` (handler `0x30d`), `gs:GObjPC::0x4356f0` / `0x435ae0`, whisper check `gs:0x415212` |

The GameServer and ShardManager talk to each other through four messages. They never reach a
client, so OpenSRO needs none of them; they are in section 5 for reference.

## 2. Ids, strings and limits

- **Strings.** Every string on this wire is `u16 length` followed by that many single-byte
  (ANSI codepage) characters, with no terminator.
  - READ: client writer `c:0x53d8c0`, reader `c:0x4f7a70`; server writer `gs:0x426040`, reader
    `gs:0x404b60`.
- **The friend id is the friend's CharID.** READ:
  - the ShardManager writes `_Friend.FriendCharID` (`sm:0x44ca4e`);
  - it pushes the logging-in player's `+0x7c` CharID in kind 4 (`sm:0x447585` → `sm:0x447627`);
  - it filters `_Friend` with `WHERE CharID = %d`.

  The ShardManager and GameServer route between themselves by **JID** (`IGObj` slot 2), never shown
  to the client except as the opaque second u32 of the incoming request.

| Limit | Value | Where (READ) |
|---|---|---|
| Friends per character | 20 | `gs:0x5d7746` asker (`cmp [esi+0x14],0x14; jb`); `sm:0x44776a` target (`0x640f`); `sm:0x447320` both again at accept (`< 0x14`, `0x13 <` refuses); `gs:0x5d6b23` will not send a list above 20; client count text ` : %d / 20` (`c:0x5a9982`) |
| Friend name in `0x7302` | 1..32 bytes, else code 2 | `gs:0x5d7662..0x5d7670` |
| Letters per mailbox | 20 | `gs:0x5d79c0` / `0x5d7a90`: index above `0x13` → `0x6411`; `gs:0x5d6550` caps a load at 20; `sm:0x446c00` passes `0x14` to `_Memo_Add` (that this is the box cap is INFERRED); client ` : %d / 20` (`c:0x5c32b0`) |
| Letter text | 1..1000 bytes, else `0x6410` | `gs:0x5d7890`, `gs:0x5d7900`; `sm:0x446c00` truncates to 1000; the client edit is 1000 (G7) |
| Names in `_Memo_Add` | 64 bytes (`0x40`) | `sm:0x446c00` `FUN_006e3ca2(…, 0x40)` |
| Whisper block list | 20 | `gs:GObjPC::0x4356f0`: `count < 0x14`, else result 1 → client 3 "list full" |
| Request wait | 30 s | float 30.0 at `sm:0x79b01c`, the overlapped job's timeout (`sm:0x447792`) |

## 3. The client wire

### 3.1 Every message

**Friend list and requests**

| Dir | Opcode | Meaning | Layout | Where (READ) |
|---|---|---|---|---|
| C→S | `0x7302` | ask a player to be friends | `str name` | `c:0x824c30`; `gs:0x517f90` → `0x5d7620` |
| S→C | `0xB302` | the request failed | `u8 2, u16 code`; if code is `0x640b`, then also `u8 reason, str name` | `gs:0x518007` (asker's checks), `gs:MsgHandler_3c01` (ShardManager's checks), `gs:0x5d7f35` (refused or timed out); `c:0x885e50` |
| S→C | `0x7302` | the incoming request | `u32 jobID, u32 askerJID, str askerName` | the ShardManager's `0x7c00` relay (`sm:0x420950` → `sm:0x422230`), delivered by `gs:MsgHandler_7c00`; `c:0x886000` |
| C→S | `0x3303` | the answer | `u32 jobID, u32 askerJID, u8 answer` (1 accept, 0 otherwise) | `c:0x820b20`, called from `c:0x798a15` / `0x798a29`; `gs:0x518080` → `gs:0x4168f0` relays it |
| C→S | `0x7304` | delete a friend | `u32 friendCharID` | `c:0x820a60`; `gs:0x5180b0` → `0x5d77d0` |
| S→C | `0xB304` | delete result | `u8 1, u32 friendCharID` or `u8 2, u16 code` | `gs:0x5d8330`; `c:0x881fd0` |
| S→C | `0x3305` | the friend list, sent once at login | `u8 n`, then n × `{u32 CharID, str name, u32 RefObjID, u8 state}` | `gs:0x5d6b10` + `0x5db1a0`; `c:0x87fdd0` → `0x9993b0` (replaces the list) |
| S→C | `0x3B07` | messenger push | `u8 kind`, then the kind's body (3.3) | `gs:0x5d6650` / `0x5d6a30` / `0x5d69b0` / `0x5d6cc0` / `0x5d6c50`; `c:0x886310` |

**Letters**

| Dir | Opcode | Meaning | Layout | Where (READ) |
|---|---|---|---|---|
| C→S | `0x730B` | ask for the letter list | (empty) | `c:0x820c10`, sent on the letter pane's first show; `gs:0x5180f0` → `0x5d7820` |
| S→C | `0xB30B` | letter list | `u8 1, u8 n`, then n × `{str sender, u32 senderRefObjID, u32 date, u8 status}`; or `u8 2, u16 code` | `gs:0x5d7820` + `0x5d6bc0` + `0x5db310`; `c:0x882030` → `0x9976a0` |
| C→S | `0x7308` | read a letter | `u8 index` | `c:0x820cb0`; `gs:0x518780` → `0x5d79c0` |
| S→C | `0xB308` | the letter's text | `u8 1, u8 index, str text`; or `u8 2, u16 code` | `gs:0x5d7a34..0x5d7a6c`; `c:0x886170` (sets status 1, fills the read view) |
| C→S | `0x7309` | send a letter | `str to, str text` | `c:0x824760`; `gs:0x518120` |
| S→C | `0xB309` | send result | `u8 1` or `u8 2, u16 code` | `gs:0x5d83e0` / `0x5d8670`, `gs:0x518120`; `c:0x8820b0` |
| C→S | `0x730A` | delete a letter | `u8 index` | `c:0x820d70`; `gs:0x5187d0` → `0x5d7a90` |
| S→C | `0xB30A` | delete result | `u8 1, u8 index` or `u8 2, u16 code` | `gs:0x5d7adb..0x5d7b08`; `c:0x882130` → `0x997870` (removes the entry at that index) |
| C→S | `0x730C` | guild or union letter | `u8 kind (1 guild, 2 union), u8 n, n × str name, str text` | `c:0x825490`; `gs:0x518330` |
| S→C | `0xB30C` | multi-letter result | `u8 1, u8 nFailed`, then nFailed × `{str name, u16 code}`; or `u8 2, u16 code` | `gs:0x5d8470`; `c:0x895530` |

**Whisper block list**

| Dir | Opcode | Meaning | Layout | Where (READ) |
|---|---|---|---|---|
| C→S | `0x730D` | block or unblock whispers from a name | `u8 op (1 block, 2 unblock), str name` | `c:0x824dd0`; `gs:0x518db0` |
| S→C | `0xB30D` | block result | `u8 op, u8 result`, and `str name` only when result is 0 | failures `gs:0x518f23`; success `gs:CGObjPC::_AsyncQuerySucceeded` `0x4e8bf6..0x4e8c39`; `c:0x89c3a0` |
| S→C | `0x3013` | character data | includes the block list as `u8 n, n × str name` | `gs:0x4e3d86` → `gs:0x435eb0` (writer `0x409ae0` = u8) |

**Not used:** `0xB302 {1}` (success) is never sent. The GameServer's `0x302` handler replies only on
failure (`gs:0x518000`). Success shows up as `0x3B07` kind 2 instead. The client ignores
result 1 anyway (`c:0x885e98`).

**Registration census (READ).** These are all of the client's handlers in this range:
`c:0x8714cb..0x8715cf` registers `0x3305, 0xB302, 0xB304, 0x7302, 0xB30B, 0xB308, 0xB309, 0xB30A,
0x3B07`; `c:0x898285` registers `0xB30C`; `c:0x8a425a` registers `0xB30D`. `0x330F` is a trap message,
not part of this system. The client's only senders in the range are `0x7302, 0x3303, 0x7304,
0x7308..0x730D`, found by an immediate census of `c:0x820a60..0x825840`.

### 3.2 The friend request, step by step (READ)

1. **The asker sends `0x7302 {target name}`.** Three places send it:
   - the Add-friend box (`c:0x5a7920`);
   - the target menu's button 17 (`c:0x60a2d0`), with the selected player's name;
   - `/invite` and `/friend` in chat (`c:0x7af513`).

   The client sets the friend pane's request flag `+0x790 = 1`. The box sends only a non-empty name
   that is not your own (`c:0x5a7840`).
2. **The GameServer checks the asker** (`gs:0x5d7620`). The first failure is answered
   `0xB302 {2, code}`:

   | Check | Code |
   |---|---|
   | The name is 0 or more than 32 bytes long | 2 |
   | The asker has no messenger yet | `0x6407` |
   | The name is your own (`CompareStringA`, `gs:0x426f30`) | 3 |
   | The name holds `'`, `"` or a filtered word (`gs:0x7312f0`, the SQL/abuse string check) | 3 |
   | The name is already on your list (`gs:0x5d6890`) | `0x6409` ALREADYFRIEND |
   | Your list already has 20 friends | `0x6408` FULLLIST |

   Then it relays the request to the ShardManager (`gs:0x5d7cc0`). That always returns 1, so
   `0x640e` SYSPROGRESS is never sent from here (READ `gs:0x5d7d16 mov al,1`).
3. **The ShardManager checks the target** (`sm:0x447650`). A failure goes back as `0x3C01`, and the
   GameServer turns that into `0xB302 {2, code}` (`gs:MsgHandler_3c01 0x4169d0`, party_protocol.md):

   | Check | Code |
   |---|---|
   | No character by that name, or it is not in the game (user state `+0x234` ≠ 2) | `0x640d` UNKNOWNUSER |
   | The target has no messenger | `0x6407` |
   | The target has 20 friends | `0x640f` TARGETLISTFULL |
   | The asker is already on the target's list | `0x6409` |
   | The job could not be created | 2 |

   On success it creates an overlapped job: asker JID, opcode `0x7302`, target JID, 30.0 s. It sends
   the target `0x7302 {jobID, askerJID, askerName}`.
4. **The target's client** (`c:0x886000`) opens message box kind `0x23` and sets its flag
   `+0x790 = 2`.
   - The box shows `'name'` + `UIIT_MSG_FRIEND_REQUEST_01` and `UIIT_MSG_FRIEND_REQUEST_02`, with
     Accept/Refuse (`c:0x6482ef`).
   - There is no auto-refuse option. The `/BlockFriendInvitation` keys are in textdata but not in the
     exe (section 9).
5. **The target answers** `0x3303 {jobID, askerJID, 1}` on Accept, or `{…, 0}` on anything else
   (`c:0x798a00`), and the flag returns to 0.
   - The GameServer forwards it as `0xBC00 {jobID, askerJID, u16 0xB302, answer}` (`gs:0x4168f0`).
   - The ShardManager matches the job by id, by asker JID and by `(0xB302 & 0x3fff) | 0x4000 == 0x7302`
     (`sm:0x421ec0`), then calls `sm:0x447850(asker, target, answer)` (`sm:0x420900`).
6. **Accept (answer 1)** → `sm:0x447320`.
   - Both messengers must exist, neither may already list the other, and both lists must be under 20.
   - It runs `{?=CALL _Friend_Add (%d,'%s',%d,'%s')}`. A return of 1 or more is success.
     `-1000` and `-1002` end the accept silently; `-1001`, `-1003` and the rest assert or log
     (`sm:0x44747d`).
   - It reloads both rows (`WHERE CharID = %d and FriendCharID = %d`, `sm:0x446730`) and pushes
     `0x3B07` kind 2 to **both** players (`sm:0x448ad0`).
   - If any of these checks fails, **nothing is sent** (READ: `sm:0x447320` returns without a
     message). The asker's flag then stays 1 (INFERRED: nothing clears it).
7. **Anything else, or the 30 s timeout** (`sm:0x420a00` calls `0x447850(…, 2)`).
   - **Both** players get `0x3B07` kind 5 `{JID, targetName, reason}`, which reason is the answer
     byte, 0 for Refuse and 2 for the timeout.
   - Their GameServers turn it into `0xB302 {2, 0x640b, reason, targetName}` (`gs:0x5d7f35`).
   - The client (`c:0x885e50`) reacts:
     - **reason 0** → the banner `UIIT_MSG_FRIENDERR_REFUSAL` "The other player has refused your
       proposal to make friends.". The client does not check its flag, so **the refuser sees this
       line too** (READ quirk);
     - **reason 2** with flag 1 (the asker) → `UIIT_MSG_FRIEND_SYSCANCEL`;
     - **reason 2** with flag 2 (the target) → the kind-0x23 box is closed (`c:0x778b90(0x23)`);
     - then the flag is reset to 0.

### 3.3 `0x3B07`, the messenger push (READ)

The client handler `c:0x886310` jumps on `kind − 2` through `c:0x886778`.

| Kind | Body | Sent by | Client effect |
|---|---|---|---|
| 2 | `u32 CharID, str name, u32 RefObjID` | `gs:0x5d6650`, after the ShardManager's kind 2 | Adds the friend with **state 0** (online; `c:0x8863da` pushes 0). Refreshes the pane. Opens box kind 0x22: `UIIT_MSG_YOUNME` "[%s]and [%s]'s" + `UIIT_MSG_FRIEND_CONCLUSION` "The proposal to make friends was accepted." |
| 3 | `u32 CharID` | `gs:0x5d6a30`, on your own delete and on the other side's | Removes the friend (`c:0x997290`). No text. |
| 4 | `u32 CharID, u8 state` | `gs:0x5d69b0` | Stores the state at entry `+0x24` and redraws the row. State 0 → system line `UIIT_MSG_FRIEND_CONNECT` "Friend [%s]has logged on.", 1 → `UIIT_MSG_FRIEND_DISCONNECT` "Friend [%s]has logged off.". Printed only when the name is not your own (`c:0x592e00`). |
| 5, 6, 7 | — | — | No client case: they fall to the assert at `c:0x886732`. The GameServer can send a kind 6 `{u32, str}` (`gs:0x5d7e78`) that the client cannot handle (READ: no case). |
| 8 | `str sender, u32 senderRefObjID, u32 date` | `gs:0x5d6cc0`, a new letter | Adds the letter with status 0 (unread) and refreshes the list. Shows the letter alarm icon unless the letter pane is already showing (`c:0x8866c0`). |
| 9 | `u8 unreadCount` | `gs:0x5d6c50`, after the letters load at login, only when unread > 0 | Reads the byte and ignores it. Banner `UIIT_MSG_LETTERERR_UNKNOWNLETTER` "You have a new message." (`c:0x886702`). |

### 3.4 Login and logout (READ)

1. The character data `0x3013` carries the whisper block list (`gs:0x4e3d86`).
2. At character login the ShardManager loads `_Friend` (`sm:0x446100`). Every friend starts with
   state 1.
3. On `ENTERGAME_ACK` (`sm:0x40ebb0` → `sm:0x4472a0`) the ShardManager sends the GameServer
   `0x3B07 {1, JID}`. The GameServer creates the player's `CMessenger` (`gs:0x5d7410`; a duplicate
   is logged "Messenger LOGIN USER DUPLICATED!!!" with `0x6417`) and starts loading the letters.
4. The GameServer then sends `0x7B06 {6, JID}`. The ShardManager answers `0x3B07 {7, JID, list}`
   (`sm:0x447a70`). Each friend found online, with user state 1 or 2, is written with state 0
   (`sm:0x446490`).
5. The GameServer stores the list and sends the client **`0x3305`** (`gs:0x5d6550` → `0x5d6b10`). That
   is the only sender of `0x3305` (`gs:0x5d6638`).
6. The ShardManager tells every friend who is online: `0x3B07 {4, friendJID, myCharID, 0}`
   (`sm:0x447560(…, 0)` → `sm:0x448c80`). Their clients print "Friend [me]has logged on."
7. When the letters have loaded (`gs:AQ_CharDataLoader::CommitBlockedWhisperer` case 3,
   `gs:0x43e3e6`), the GameServer sends `0x3B07 {9, unread}` if any letter is unread.
8. **Logout.** The GameServer destroys the messenger (`gs:0x4df27c` → `0x5d7580`). The ShardManager
   destroys its own (`sm:0x447210` → `sm:0x446300`) and calls `sm:0x447560(…, 1)`. Online friends
   get kind 4 state 1, "has logged off."

There is no other status: no away or busy, no location, no level (READ: the entry has only the
state byte, `sm:0x44ca30`).

### 3.5 Letters (READ)

- **Index.** A letter is addressed by its 0-based position in the mailbox list.
  - The server's list is a vector in load order. New letters are appended (`gs:0x5d8c90`), and a
    delete shifts the rest down (`gs:0x5d71c0`, `memmove`).
  - The client's list (`+0x260`) is kept in the same order. `0xB30A` removes the entry at that
    position (`c:0x997870`).
- **The date** is `u32` packed by `sm:0x43f8c0` from `GetLocalTime`:

  | Bits | Field |
  |---|---|
  | 0-5 | year − 2000 (`(wYear − 16) & 63`) |
  | 6-9 | month |
  | 10-14 | day |
  | 15-19 | hour |
  | 20-25 | minute |
  | 26-31 | second |

  The client prints `YY-MM-DD <Forenoon/Afternoon> hh:mm`. An hour above 12 shows as h−12 with
  `UIIT_STT_LETTER_AFTEMOON`; 12:xx shows as "Forenoon 12" (`c:UI_LETTER::0x5c13d0`; the sort
  key without the AM/PM word is built by `c:0x5c41f0`).
- **Status:** 0 unread, 1 read.
  - The GameServer counts letters whose `+0x68` is 0 as unread (`gs:0x5d7270`).
  - Reading one sets 1, both in memory and in the DB (`gs:0x5d6f80`).
  - The client sets `+0x40 = 1` on `0xB308` (`c:0x997840`).
- **Single send** (`gs:0x518120`). The checks, in order:

  | Check | Result |
  |---|---|
  | The sender is chat-banned by a GM (`gs:0x4f0a00(0)`) | `0x3405 {0, time}` sent, the request dropped |
  | The recipient name fails the string check | `0xB309 {2, 2}` |
  | The text fails the string check | `0x6410` |
  | No messenger | 2 |
  | Empty recipient | 3 |
  | Text 0 or more than 1000 bytes | `0x6410` |

  Then `0x7B06` kind 3 goes to the ShardManager (section 5), which runs `_Memo_Add`:

  | `_Memo_Add` returns | Result |
  |---|---|
  | above 0 | the new memo id: success |
  | −1 | `0x640d` → client `UIIT_MSG_MLEAVEERR_USERNOTEXIST` "The name of that character is not listed in the game." |
  | −2 | `0x6414` → `UIIT_MSG_LETTERERR_FULLLETTERBOX` |
  | other | 2 |

  On success, a recipient in the game gets kind 8 at once; the others see the letter at their next
  login. The sender gets `0xB309 {1}` → `UIIT_MSG_LETTER_SENDOK`.
  - When `_Memo_Add` fails and the recipient is online, the ShardManager also sends the recipient's
    GameServer `0x3B07 {0x10}`. That GameServer ignores it, since its table covers kinds 1 to 8
    (`gs:0x5d7d89`).
  - Nothing stops you writing to yourself (READ: no such check in `gs:0x518120` / `sm:0x447d00`).
- **Multi-letter** (`gs:0x518330`):

  | Condition | Result |
  |---|---|
  | No guild | `0x6416` |
  | Kind 1 with guild level 2 or lower | `0x6415` |
  | Kind 2 with guild level 3 or lower | `0x6415` |
  | Kind other than 1 or 2 | 5 |

  - Kind 1 keeps only names that are members of your guild (`gs:0x5d0cf0`); kind 2 keeps every
    name.
  - Text and recipients are checked as for a single letter (`gs:0x5d7900`), then `0x7B06` kind 7.
  - The ShardManager runs `_Memo_Add` per name. It delivers kind 8 to those online and replies with
    the list of names that failed, each with its code (`sm:0x448180`).
- **Read** (`gs:0x5d79c0`): index above 19 → `0x6411`; no messenger → `0x6407`; no letter at that
  index → `0x6412`. Otherwise it marks the letter read and replies.
- **Delete** (`gs:0x5d7a90` → `{CALL _Memo_Delete (%I64d)}`, `gs:0x5d70a0`): the same three codes
  (`0x6411`, `0x6407`, `0x6412`), or 2 if the DB call fails.

### 3.6 Whisper block (READ)

- **Block** (`gs:0x4356f0`, op 1). The checks, in order:

  | Check | Result |
  |---|---|
  | Name already listed (`gs:0x435db0` returns 2) | 1 |
  | 20 names already | 1 → sent as **3** |
  | Name is your own | 3 → sent as **2** |
  | String check fails, or the DB job cannot be queued | 4 |

  Otherwise the async `_BlockedWhisperer_Add` runs (`gs:GObjPC::0x44e0f0`). When it completes,
  `0xB30D {1, result, name}` is sent; the DB status is mapped by `gs:0x435930`: 100 → 0, 1 → 3,
  2 → 1, 3 → 2.

  The mapping in `gs:0x518ee9` is: 1 → 3, 2 → 1, 3 → 2, others → 4.
- **Unblock** (`gs:0x435ae0`, op 2):

  | Check | Result |
  |---|---|
  | List empty, or the name not listed | 3 → sent as 2 |
  | String or queue failure | 4 |

  Otherwise `_BlockedWhisperer_Remove` runs, and its completion (`gs:0x435cd0`: 100 → 0, 1 → 2)
  sends `0xB30D {2, result, name}`.
- **What the client shows** (`c:0x89c3a0`):

  | Result | Shown |
  |---|---|
  | 0, op 1 | the system line `UIIT_MSG_CHAT_WHISPER_BLOCK` "Blocked whisper from [%s]." |
  | 0, op 2 | `UIIT_MSG_CHAT_WHISPER_ADMISSION` "Removed whisper block from [%s]." |
  | 1 | `UIIT_MSG_COSPETERR_PETNAME_SUMENESS` "Name already exists." |
  | 2 | `UIIT_MSG_ALIAS_ACTION_ERR_NOTALLOW` "User does not exist." |
  | 3 | `UIIT_STT_BLOCKMAN_DELETE_LISTFULL` "Cannot register any more users to block list." |
  | 4 | a Korean debug string (`c:0x49d620`) |

- **The effect.** The GameServer drops a whisper from a blocked name before delivering it
  (`gs:0x415212`, `0x435db0 == 2` → no `0x3026`).
- **The PC list.** The block pane's second sub-tab is a client-only list, kept on the PC and filled
  with `/ban` and `/unban`. It filters chat locally (`c:0x5871d0` in the chat display `c:0x876810`)
  and never reaches the server (G6).

## 4. Error codes and their text (READ)

Every result-2 code goes through `c:0x778190(category, code)`, which feeds the error switch
`c:0x7b8b40` (error_codes.md) and shows the text on the centre banner (`c:0x77b580`). Friend
messages (`0xB302`, `0xB304`) use category `0x13`; letters (`0xB308` to `0xB30C`) use `0x14`.

| Code | Category 0x13 (friend), `c:0x7baad7` | Category 0x14 (letter), `c:0x7bacf6` | Sent by |
|---|---|---|---|
| 2, 3, 5 | — (nothing shown) | — | GameServer generic refusals |
| `0x6406` | — | — | `sm:0x446b10`, the "someone erased me" log; never reaches a client |
| `0x6407` | — | — | no messenger (`gs` and `sm`) |
| `0x6408` | FRIENDERR_FULLLIST | — | `gs:0x5d775d` |
| `0x6409` | FRIENDERR_ALREADYFRIEND | — | `gs:0x5d7734`, `sm:0x44778b` |
| `0x640a` | FRIEND_SYSCANCEL | — | not found sent (the timeout uses `0x640b` reason 2 instead) |
| `0x640b` | FRIENDERR_REFUSAL (plus the reason logic in `c:0x885e50`) | — | `gs:0x5d7fa2` |
| `0x640c` | — | — | not found |
| `0x640d` | FRIENDERR_UNKNOWNUSER | MLEAVEERR_USERNOTEXIST | `sm:0x4477ff` (friend), `sm:0x446f54` (letter) |
| `0x640e` | FRIEND_SYSPROGRESS | — | unreachable in this GameServer (3.2 step 2) |
| `0x640f` | FRIENDERR_TARGETLISTFULL | — | `sm:0x447770` |
| `0x6410` | — | LETTERERR_SENDERR "Failed to send the note" | `gs:0x518120`, `gs:0x5d7890` / `0x5d7900` |
| `0x6411` | — | — | bad letter index (`gs`) |
| `0x6412` | — | — | no letter at that index (`gs`) |
| `0x6414` | — | LETTERERR_FULLLETTERBOX | `sm:0x446f6e` |
| `0x6415` | — | empty banner (`''`) | guild level too low (`gs:0x518330`) |
| `0x6416` | — | empty banner | no guild (`gs:0x518330`) |
| `0x6417` | — | — | duplicate messenger at login; logged only |

The old note in `friend.go` that "`0x640f` appears nowhere in the server's .text" was true of the
GameServer only. The ShardManager returns it (`sm:0x447770`).

## 5. GameServer ↔ ShardManager (READ; reference only — OpenSRO does not need these)

| Message | Direction | Layout | Use |
|---|---|---|---|
| `0x7C00` | GS→SM | `u32 askerJID, u16 0x7302, str targetName, str askerName` | the friend request (`gs:0x5d7cc0` → `gs:0x46f530`; `sm:0x410520` case `0x7302` → `sm:0x447650`) |
| `0x7C00` | SM→GS | `u16 0x7302, u32 targetJID, u32 jobID, u32 askerJID, str askerName` | the request relayed to the target's GameServer (`sm:0x422230`); delivered to the client as `0x7302 {jobID, askerJID, askerName}` |
| `0xBC00` | GS→SM | `u32 jobID, u32 askerJID, u16 0xB302, u8 answer` | the answer (`gs:0x4168f0`; `sm:0x4107e0` → `0x421f70`) |
| `0x3C01` | SM→GS | — | a failed relay, answered to the client as `0xB302 {2, code}` (party_protocol.md) |
| `0x7B06` | GS→SM | `u8 kind`; kind 6 `u32 JID`; kinds 2/3/7 `u32 trsID, u32 JID`, then kind 2 `u32 friendCharID`; kind 3 `u32 senderRefObjID, str to, str text`; kind 7 `u32 senderRefObjID, u8 n, n × str, str text` | `gs:0x5d75c0` (6), `gs:trs_sm_messengerjob::vslot_004 0x46ea30` (2/3/7); `sm:0x410450` → `0x447a10` |
| `0xBB06` | SM→GS | `u32 trsID`, then `u8 1` (kind 7 adds `u8 n, n × {str, u16}`) or `u8 2, u16 code` | `sm:0x448a90`; `gs:0x414601` → `trs_sm_messengerjob` `0x5d82b0` / `0x5d82f0` |
| `0x3B07` | SM→GS | `u8 kind` with: 1 `u32 JID`; 2 `u32 JID, u32 friendCharID, str name, u32 RefObjID`; 3 `u32 JID, u32 friendCharID`; 4 `u32 JID, u32 friendCharID, u8 state`; 5 `u32 JID, str name, u8 reason`; 6 `u32 JID, u32, str`; 7 `u32 JID, u8 n, n × entry`; 8 `u32 JID, u64 memoID, str sender, u32 RefObjID, str text, u32 date`; 0x10 (ignored) | `gs:CMainProcess::0x5d7d20` (jump table `gs:0x5d8290`) |

## 6. Database (READ from the binaries' SQL; procedure bodies OPEN)

| Object | Columns or parameters | Where |
|---|---|---|
| `_Friend` | `CharID, FriendCharID, FriendCharName, RefObjID` | `gs:DB_Bind__Friend 0x84ef40`; `sm:"WHERE CharID = %d"` |
| `_Friend_Add` | `(%d,'%s',%d,'%s')`, returns int | `sm:0x447320`. That the arguments are (askerCharID, askerName, targetCharID, targetName) is INFERRED from the order of the locals. −1000 and −1002 end the accept without a log (their meaning is OPEN). |
| `_Friend_Remove` | `(%d,%d)` = (myCharID, friendCharID), returns > 0 on success | `sm:0x446930`. Both directions are removed (INFERRED: the ShardManager then also drops me from the friend's live list, `sm:0x446b10`). |
| `_CheckFriendValidity` | — | only its name, in the shard's procedure list (`/opt/sro-files/db/procs/_all_names.txt`); no caller found in these binaries (OPEN) |
| `_Memo` | `ID64, FromCharName, Message, Date, Status, RefObjID` (and the owner) | `gs:DB_Bind__Memo 0x84fdb0` |
| `_Memo_Add` | `{?=CALL _Memo_Add (?, ?, ?, ?)}`: recipient name (64), sender name (64), text (1000), int 20 → returns the memo id, −1 for no such character, −2 for a full box | `sm:0x446c00`. The parameter order is INFERRED from the binding order. |
| `_Memo_Delete` | `(%I64d)` | `gs:0x5d70a0` |
| `_BlockedWhisperers` | `OwnerID, TargetName` | `gs:DB_Bind__BlockedWhisperers 0x85ccd0` |
| `_BlockedWhisperer_Add` / `_Remove` | — | `gs:GObjPC::0x44e0f0` |

## 7. The client GUI (READ unless marked)

Most of this was traced by this round's GUI pass. The window frame was already documented
in `client/scripts/ui/hud/guild_window.gd` (round 595/821).

### 7.1 Windows

| Class | Id | Source | Notes |
|---|---|---|---|
| `CNIFCommunityWnd` | 177 | `res_ui\cumunity_friend.2dt` | A child of `CNIFGuildWnd` (176), loaded at `c:0x5b5848`. Its OnCreate `c:0x58ec70` loads `cumunity_cut.2dt` (59) and `cumunity_note.2dt` (700) onto pane 646. |
| `CNIFFriendWnd` | 646 | — | 11 × `CNIFFriendSlot` |
| `CNIFBlockWnd` | 59 | — | 10 × `CNIFBlockSlot` |
| `CNIFLetter` | 700 | — | 11 × `CNIFLetterSlot`, the write/read frame 800, `CNIFMultiLetter` 900 (11 × `CNIFMultiLetterSlot`) |
| `CIFLetterAlarmGuide` | GDR 55 | `ginterface.txt` `LetterAlarmGuide`, 40×40 | Its icon alternates `icon\etc\letteralarm_1.ddj` / `_2.ddj` every 500 ms. It is managed by `CAlramGuideMgrWnd` (0x9e). |
| `CIFCommunity`, `CIFFriend`, `CIF*Blocking`, `CIFLetterSlot` … | — | — | Dead code (INFERRED): no `GetWindow(0x17)`, and `CIFCommunity::vslot_010` loads no children. |

`UI_LETTER` / `UI_LETTERERR` are only the dump's module names for the CNIFLetter / CNIFMultiLetter
code.

### 7.2 Opening

- **No hotkey of its own.** U (key slot 6) opens the **guild** view.
- The underbar menu item 108 (`c:0x60ce78` → `0x5b49c0`) toggles the **community** view. Its
  caption is `UIIT_STT_TOGGLE_CONTENTS_MENU_COMMUNITY` "Community ( %s )".
- The window's left menu (220 guild / 221 community) switches views. The community view's caption
  is `UIIT_STT_COMMUNITY` "Community".
- **Tabs:** 72 Friend / 73 Block / 74 Letter (group 50), showing panes 646 / 59 / 700.
  - Each tab is 72×24 at (23/100/176, 41), on `interface\guild\gil_friend_tab_off.ddj` /
    `gil_cut_tab_off.ddj` / `gil_note_tab_off.ddj`.
  - Hover texts: `UIIT_CTL_FRIEND`, `UIIT_STT_BLOCKMAN_BLOCK`, `UIIT_CTL_LETTER`.
  - The community's OnCreate checks the Friend tab.
- **The letter alarm icon.** Clicking it (`CIFLetterAlarmGuide::vslot_029 c:0x711930`) opens the
  community view on the Letter tab (`c:0x58eec0(5)`) and removes the icon. Showing the letter pane
  also removes it (`c:0x5bf6d0` → `0x798fe0(0)`).

### 7.3 Friend pane 646 (origin 301,253)

| Id | Kind | Rect | Art / text | Action |
|---|---|---|---|---|
| 79 | frame | 6,5,588,350 | `interface\frame\frameg01_wnd_` | — |
| 15 / 16 | tile / border | 22,21,557,319 / 15,31,569,281 | `com_bg_tile_b.ddj` / `com_blacksquare_` | — |
| 17 | static | 342,13,177,15 | `UIIT_CTL_FRIEND` "Friend", ffefdaa4 | — |
| 18 | static | 527,13,55,15 | ` : %d / %d` (size, 20) | `c:0x5a97b0` |
| 255 | button | 18,34,68,24 | `gil_subj_button05.ddj` | inert |
| 62 | button | 87,34,479,24 | `gil_subj_button13.ddj`, `UIIT_STT_FRIENDLIST` "Friends list" | sorts by name (`c:0x5a99f0`; ascending is INFERRED) |
| 337 | static | 566,34,16,24 | `gil_shape.ddj` | — |
| 338 | scroll | 565,73,16,206 | — | — |
| rows | 11 × CNIFFriendSlot | x 18, y 56+23i, 546×24 | `com_bar01_left.ddj`; selected `com_bar01select_Left.ddj` | Inside each row: lamp 52 (30,5,12,16), race 51 (107,5,16,16), name 341 (149,5,370,15). |
| 39 | button | 121,322,112,24 | `com_mid_button02.ddj`, `UIIT_STT_GET_WHISPER` "Whisper" | puts `$name ` into the chat line (`c:0x5a6350`); online is not checked |
| 40 | button | 244,322 | `UIIT_CTL_FRIENDADD` "Add friend" | input box (below) |
| 41 | button | 366,322 | `UIIT_CTL_FRIENDDEL` "Delete friend" | confirm box `UIIT_MSG_FRIEND_IDDELET` "Will you delete [%s] in the friends list?" → `0x7304` |

- **Row fill** (`c:0x5a7990`):
  - **Lamp:** state 0 → `interface\guild\gil_contact_on.ddj`, 1 → `gil_contact_off.ddj`. Any
    other value leaves it unchanged.
  - **Race icon:** from the RefObjID's character record `+0x9c`. 0 →
    `interface\ifcommon\com_kindred_china16.ddj`, 1 → `com_kindred_europe16.ddj`.
  - **Name:** in one colour whatever the state.
  - An empty row hides all three.
- **Mouse.** A left click selects the row. There is no double-click and no right-click menu
  (`CNIFFriendSlot::vslot_017 c:0x5a8880`).
- **Add friend box** (`c:0x5a7160`): `CIFMessageBox` 306×151, purpose 4, title
  `UIIT_STT_INPUT_BOX` "Input window", text `UIIT_MSG_FRIEND_IDINPUT`.
  - It is pre-filled with the selected player's name; for a selected pet with an owner link, the
    owner's name (INFERRED).
  - OK sends `0x7302` when the name is non-empty and not your own.

### 7.4 Request box and other boxes

| Kind | Size | Title | Content | Buttons |
|---|---|---|---|---|
| `0x23`, the incoming request (`c:0x6482ef`) | 360×151 | `UIIT_STT_AGREEMENT_BOX` "Agreement window" | `'name'` + `UIIT_MSG_FRIEND_REQUEST_01` " proposed to make friends with you." / `UIIT_MSG_FRIEND_REQUEST_02` "Will you accept it?" | `UIIT_STT_ACCEPT` / `UIIT_STT_REFUSE` |
| `0x22`, accepted (`c:0x648114`) | 360×151 | `UIIT_STT_CONFIRM_BOX` | `UIIT_MSG_YOUNME` + `UIIT_MSG_FRIEND_CONCLUSION` | one button |

The request box is queued through `CMessageBoxManager` (`c:0x77f0a0` → `0x6ec5d0`), the same queue
as party's boxes (party_gui.md). Its ids are box params "1" and "2".

### 7.5 Block pane 59

- **Sub-tabs.** 395 is the server list (`gil_whisper_sub_tab_off.ddj`); 396 is the PC list
  (`gil_totality_sub_tab_off.ddj`).
  - Header 336 shows `UIIT_STT_CHATING_SHUT_SAVE_SERVER` "Block whisper (Stored on server)" or
    `_SAVE_PC` "Block all chat (Stored on PC)".
  - The help button 337 shows `…_SERVER_HELP` / `…_PC_HELP`.
  - The count shows ` : %d / 20` for the server list and ` : %d` for the PC list.
- **Rows.** 10 rows at x 18, y 81+23i, 548×24 (`com_bar01_mid`). The lamp 46 is always
  `gil_contact_off`; the name is 400 (78,6,462,15).
- **Add Block** (40). An input box, purpose 7, `UIIT_STT_BLOCKMAN_ENTRY_WND`. The name is checked
  (`c:0x8c3cb0`, `UIO_MSG_ERROR_CHARACTER_WRONGSTRING`). The server tab sends `0x730D {1, name}`;
  the PC tab adds the name locally.
- **Remove Block** (41). A confirm box, `UIIT_STT_BLOCKMAN_DELETE_WND` "Delete [%s] from the block
  list?". The server tab sends `0x730D {2, name}`.
- **Chat commands:** `/mute` and `/unmute` send `0x730D`; `/ban` and `/unban` change the PC list.

### 7.6 Letter pane 700 (moved onto 646 at 11,63)

**List and buttons**

- **Headers.** 114 is `UIIT_STT_LETTER_SENDER` "From" (18,34,323,24) and sorts by sender. 113 is
  `UIIT_STT_LETTER_ADDTIME` "Received time" (342,34,225,24) and sorts by date, flipping the order.
- **Count.** 18 shows ` : %d / 20`.
- **Rows.** 11 rows at y 56+23i, 547×24: sender 341 (7,5,309,15), date 304 (335,5,202,15).
  - Unread rows get text style `c:0x4774f0(0,2)`; what that looks like is OPEN.
  - A left click selects; a double-click reads.

| Button | Text | Action |
|---|---|---|
| 55 | `UIIT_CTL_LETTER_SEND` "Send msg" | write view |
| 40 | `UIIT_STT_LETTER_READ` "Read msg" | `0x7308(index)` and the read view |
| 41 | `UIIT_CTL_LETTER_DELETE` "Delete msg" | `UIIT_MSG_LETTER_LETTERDELETE` "Will you delete the note?" → `0x730A(index)` |
| 56 | `UIIT_CTL_LETTERERR_GUILD` "Guild msg" | the multi-letter list of guild members; needs guild level 3 or more (`c:0x5bec70`) |
| 57 | `UIIT_CTL_LETTERERR_UNION` "Union msg" | union guild masters; needs level 4 or more |

The first time the pane shows, the client sends `0x730B` (`c:0x5bf6d0`).

**Frame 800** (`msgbox2_window_`, 439×271, centred)

| Part | Id and rect |
|---|---|
| Recipient edit | 64 (95,62,239,17), 12 characters (INFERRED maximum) |
| Text edit | 67 (21,113,396,104), 1000 characters |
| Write view buttons | Send 100 (83,235), Cancel 200 (231,235) |
| Read view buttons | `UIIT_CTL_LETTER_REPLYLETTER` "Reply" 118, Delete 119, `UIIT_CTL_LETTER_WINDOWSCLOSE` "Close" 120 |

- **Captions and labels:** `UIIT_STT_LETTER_LETTERWRITE` "Write message" or `UIIT_STT_LETTER_READ`;
  the label is `UIIT_STT_LETTER_ADDRESEE` "To" or `UIIT_STT_LETTER_SENDER` "From".
- **Sending** (`c:0x5c4b90`):
  - an empty name gives `UIIT_MSG_LETTERERR_IDWRITE`, empty text `UIIT_MSG_LETTERERR_MESSAGEWRITE`;
  - a recipient starting with `*` (an alias) gives `UIIT_MSG_MEMO_NOTUSE_JOB`;
  - otherwise it sends `0x7309`, or `0x730C` in guild/union mode;
  - it then disables Send/Cancel and starts a 5000 ms timer (id 0x19). `0xB309` / `0xB30C` re-enable
    them.

**Multi-letter 900.** 11 rows with a checkbox 75, a race icon 76 and a name 341. 115
`UIIT_CTL_MLEAVE_SELECT` "Select" toggles all of them. In mode 1 or 2 the recipient field shows
`UIIT_MSG_LETTERERR_GUILD` "Guild member" / `_UNION` "Union guild master" and is read-only.

### 7.7 Which control sends what (READ)

| Request | Sender | Called from |
|---|---|---|
| `0x7302` | `c:0x824c30` | Add box OK `c:0x5a7920`; target menu 17 `c:0x60a314`; `/invite`, `/friend` `c:0x7af513` |
| `0x3303` | `c:0x820b20` | box kind 0x23 Accept / other (`c:0x798a15` / `0x798a29`) |
| `0x7304` | `c:0x820a60` | delete confirm `c:0x5a87c0` |
| `0x7308` | `c:0x820cb0` | Read `c:0x5c0d60` |
| `0x7309` | `c:0x824760` | Send `c:0x5c4d37` |
| `0x730A` | `c:0x820d70` | delete confirm `c:0x5c2aa0` |
| `0x730B` | `c:0x820c10` | the pane's first show `c:0x5bf6d0` |
| `0x730C` | `c:0x825490` | guild/union Send `c:0x5c4dd3` |
| `0x730D` | `c:0x824dd0` | Add/Remove Block `c:0x588ac0` / `0x588125`, `/mute`, `/unmute` |

## 8. Text keys (textuisystem.txt, English column 8)

The file has two rows for many keys. The second row's column 9 sometimes differs, for example
`FRIEND_CONNECT` "Friend [%s]Is now Online". Which row the client keeps is OPEN; the table uses
column 8 of the first row.

**Friend**

| Key | English |
|---|---|
| `UIIT_CTL_FRIEND` | Friend |
| `UIIT_STT_FRIENDLIST` | Friends list |
| `UIIT_CTL_FRIENDADD` / `FRIENDDEL` | Add friend / Delete friend |
| `UIIT_STT_GET_WHISPER` | Whisper |
| `UIIT_MSG_FRIEND_IDINPUT` | Type character name that you want to add. |
| `UIIT_MSG_FRIEND_IDDELET` | Will you delete [%s] in the friends list? |
| `UIIT_MSG_FRIEND_REQUEST_01` / `_02` | proposed to make friends with you. / Will you accept it? |
| `UIIT_MSG_FRIEND_CONCLUSION` | The proposal to make friends was accepted. |
| `UIIT_MSG_FRIEND_CONNECT` / `DISCONNECT` | Friend [%s]has logged on. / Friend [%s]has logged off. |
| `UIIT_MSG_FRIEND_SYSCANCEL` | The friend registration canceled because the other player didn't respond. |
| `UIIT_MSG_FRIEND_SYSPROGRESS` | You have already proposed to add friend. |
| `UIIT_MSG_FRIENDERR_UNKNOWNUSER` | Cannot  proceed to add friend because the other player is not a subscriber or disconnected to the server. |
| `UIIT_MSG_FRIENDERR_REFUSAL` | The other player has refused your proposal to make friends. |
| `UIIT_MSG_FRIENDERR_FULLLIST` | You can't add anymore friends. |
| `UIIT_MSG_FRIENDERR_ALREADYFRIEND` | The other player is already on the friend list. |
| `UIIT_MSG_FRIENDERR_TARGETLISTFULL` | The other player is unable to add anymore friends. |

**Boxes, community and chat commands**

| Key | English |
|---|---|
| `UIIT_STT_AGREEMENT_BOX` | Agreement window |
| `UIIT_STT_ACCEPT` / `UIIT_STT_REFUSE` | Accept / Refuse |
| `UIIT_STT_CONFIRM_BOX` | Confirmation window |
| `UIIT_STT_INPUT_BOX` | Input window |
| `UIIT_STT_COMMUNITY` | Community |
| `UIIT_STT_TOGGLE_CONTENTS_MENU_COMMUNITY` | Community ( %s ) |
| `UIIT_STT_CHAT_COMMAND_FRIEND_INVITE1` / `2` | /invite / /friend |
| `UIIT_STT_CHAT_COMMAND_WHISPER_BLOCK` / `_ADMISSION` | /mute / /unmute |

**Block**

| Key | English |
|---|---|
| `UIIT_STT_BLOCKMAN_BLOCK` / `_ENTRY` / `_CANCEL` | Block / Add Block / Remove Block |
| `UIIT_STT_BLOCKMAN_ENTRY_WND` | Enter the character name you wish to block. |
| `UIIT_STT_BLOCKMAN_DELETE_WND` | Delete [%s] from the block list? |
| `UIIT_STT_BLOCKMAN_DELETE_LISTFULL` | Cannot register any more users to block list. |
| `UIIT_MSG_CHAT_WHISPER_BLOCK` / `_ADMISSION` | Blocked whisper from [%s]. / Removed whisper block from [%s]. |
| `UIIT_MSG_COSPETERR_PETNAME_SUMENESS` | Name already exists. |
| `UIIT_MSG_ALIAS_ACTION_ERR_NOTALLOW` | User does not exist. |

**Letter**

| Key | English |
|---|---|
| `UIIT_CTL_LETTER` / `UIIT_STT_LETTER` | Msg box / Msg |
| `UIIT_STT_LETTER_SENDER` / `_ADDRESEE` / `_ADDTIME` | From / To / Received time |
| `UIIT_STT_LETTER_READ` / `_LETTERWRITE` | Read msg / Write message |
| `UIIT_STT_LETTER_FORENOON` / `_AFTEMOON` | Forenoon / Afternoon |
| `UIIT_CTL_LETTER_SEND` / `_DELETE` / `_REPLYLETTER` / `_WINDOWSCLOSE` | Send msg / Delete msg / Reply / Close |
| `UIIT_CTL_LETTERERR_GUILD` / `_UNION` | Guild msg / Union msg |
| `UIIT_MSG_LETTERERR_GUILD` / `_UNION` | Guild member / Union guild master |
| `UIIT_MSG_LETTER_LETTERDELETE` | Will you delete the note? |
| `UIIT_MSG_LETTER_SENDOK` | The note has been sent successfully. |
| `UIIT_MSG_LETTERERR_SENDERR` | Failed to send the note |
| `UIIT_MSG_LETTERERR_FULLLETTERBOX` | You cannot receive a note anymore because your box is full. |
| `UIIT_MSG_LETTERERR_UNKNOWNLETTER` | You have a new message. (the login notice, kind 9) |
| `UIIT_MSG_LETTERERR_IDWRITE` / `_MESSAGEWRITE` | Enter the ID / Write the note |
| `UIIT_MSG_MLEAVEERR_USERNOTEXIST` | The name of that character is not listed in the game. |
| `UIIT_MSG_MEMO_NOTUSE_JOB` | You cannot send a message to an alias as a target. |
| `UIIT_CTL_MLEAVE_SELECT` | Select |

## 9. What this version does not have

These are INFERRED absent: the evidence is a census, not a single grep.

- **Friend groups.** `UIIT_STT_FRIEND_GROUP` "Unfiled", `UIIT_CTL_FRIEND_GROUP_ADD/_DEL`,
  `UIIT_MSG_FRIEND_GROUP_*` ("Up to 20 groups can be created.") and `UIIT_STT_FRIEND_HELP` are in
  textdata only. The evidence:
  - no client or server opcode exists beyond those in 3.1 (the complete handler registration and
    sender immediate censuses);
  - no `.2dt` control for them;
  - the client exe and `vsroplus_lib.dll` hold none of the keys, by a string search whose control
    (the `FRIENDERR` keys) was found.
- **Letter block** (`UIIT_STT_LETTER_BLOCK*`) and the friend/guild/trade invitation blocks
  (`/BlockFriendInvitation`, `UIIT_STT_CHATING_FRIEND_BLOCK_PC*`, `UIIT_MSG_CHAT_FRIEND_*`): keys only.
- **Offline friend requests.** A request needs the target in the game (`0x640d` otherwise,
  `sm:0x447739`). Nothing is stored, and a request lives 30 s.
- **Context menu on a friend; showing a friend's level, location or job.** None (READ for the row
  fill and the mouse handler).
- `UIIT_MSG_FRIEND_REFUSAL`, `UIIT_MSG_LETTERERR_UNKNOWNUSER`, `_OBJECT_FULLLETTERBOX`,
  `_NONEXISTS`, `_SENDERR2`, `_GUILD_FULLLETTERBOX`: keys with no reference in the exe.

## 10. OpenSRO today (round 834)

- **Server.**
  - `server/internal/friend` is an OURS store: memory and SQL, `MaxFriends = 20` (correct),
    mutual friendships, and **persistent pending requests**.
  - `server/internal/session/friend.go` speaks OURS `0x00E0..0x00ED`: request by name to an online
    target, then accept, decline, list, remove and pending list.
  - The list entry is `{i64 CharacterID, str name, u8 online}`, with online computed when the list
    is asked for. It carries no RefObjID.
- **Client.**
  - `client/scripts/net/friend.gd` mirrors that protocol.
  - `guild_window.gd` builds the community view from the retail `.2dt`s and fills the friend rows
    (lamp, name, count ` : n / 20`). The race icon is always empty.
  - The target menu's Friend button sends the OURS request.
  - Requests, accept and decline go through a World3D debug-style panel and chat-log lines, not
    box kind 0x23.
- **Gaps against the original:**
  - none of the retail opcodes;
  - no `0x3B07` pushes, so no live online/offline lines and no "added"/"removed" without a re-list;
  - no RefObjID or race icon;
  - no 30 s Accept/Refuse box, its timeout or `0xB302` codes;
  - no `0x3305` at login;
  - letters, the whisper block list and the PC chat block list are absent;
  - the Whisper / Add / Delete buttons are not wired;
  - the scroll bar is not built.
- **OURS behaviours with no retail counterpart:** persistent offline requests, the pending list,
  the explicit list request, and the 64-bit ids.

## 11. Build order for OpenSRO

Use the retail opcodes, as party does; OpenSRO's server is one process, so it plays both the
GameServer and the ShardManager.

1. **Server: the messenger model.**
   - Per character: the friend list `{CharID, name, RefObjID}` with live online state, and the
     letter vector of up to 20 `{memoID, sender, senderRefObjID, text, date, status}`.
   - The block list: names, up to 20.
   - The SQL tables `friends` (add `ref_obj_id`), `letters` and `blocked_whisperers`.
   - Friendships stay mutual; deletes remove both directions.
2. **Server: friends on the retail wire.**
   - `0x7302` with the GameServer checks, then the target checks (3.2), and a request table with a
     30 s timeout.
   - The incoming `0x7302 {jobID, askerJID, name}`. OpenSRO may use any u32 pair here, as long as
     it is echoed in the answer.
   - The `0x3303` answer.
   - `0xB302` errors, and kind 5 (reason 0/2) to both players.
   - `0x3B07` kinds 2/3/4.
   - `0x3305` at world entry, then kind 4 to online friends on entry (state 0) and on logout (1).
   - `0x7304` / `0xB304`.

   This replaces OURS `0x00E0..0x00ED`. Retire them, or keep them only as an OURS extension behind
   the server type (the persistent pending list has no retail form).
3. **Client: friends.**
   - The handlers for `0x3305`, `0x3B07`, `0x7302` (box kind 0x23 through the HUD's message-box
     queue, as party's 0x3080 boxes) and `0xB302` / `0xB304`, with the banner texts.
   - Senders on Add friend (input box), target menu 17, `/invite` and `/friend`, the box's
     Accept/Refuse, and Delete (confirm box).
   - The Whisper button (`$name `).
   - The race icon from the RefObjID, and the system lines for log on/off.
4. **Letters.**
   - Server: `0x730B` / `0x7308` / `0x730A` / `0x7309` / `0x730C` with the codes in 3.5, delivery
     as kind 8, and kind 9 at world entry.
   - Client: the letter pane, frame 800, the 900 list, the alarm icon `CIFLetterAlarmGuide`, the
     packed date and the unread style.
5. **The whisper block list.**
   - Server: `0x730D` / `0xB30D`, the list in the character data, and dropping whispers from a
     blocked name in the whisper path.
   - Client: the Block pane with both sub-tabs; the PC list is client-only, stored locally, and
     filters chat.
6. **QA.** Two characters exercise every row:
   - request, accept, refuse and the 30 s timeout;
   - a full list on either side;
   - log on/off lines;
   - delete seen live by the other side;
   - letter send/read/delete and a full box;
   - a guild letter;
   - block, then a whisper is dropped.

## OPEN

1. **The stored procedures' bodies.** `_Friend_Add` (its exact argument order and its −1000/−1002
   meanings), `_Memo_Add`'s parameter order, `_BlockedWhisperer_Add`'s status values 1/2/3, and
   `_CheckFriendValidity`. They are readable from the restored shard DB (CT 104); not done this
   round.
2. **Where in `0x3013` the block list sits**, and which client function reads it into the Block pane.
   The server writer is READ, `gs:0x4e3d86`.
3. **The requester's flag after an accept that fails on the server.** Nothing is sent and nothing
   seems to clear the flag (3.2 step 6).
4. **Box kind 0x23.** Which of +0x804 / +0x808 end up visible, and whether the box has a client
   timer of its own. The server's 30 s is READ.
5. **Edit lengths.** The friend-name input has no explicit maximum (the server accepts 32). For the
   block box, whether `0x634f80(0xd)` is a 13-character limit is INFERRED.
6. **How the unread style `0x4774f0(0,2)` looks.**
7. **Where `CAlramGuideMgrWnd` places the letter alarm** (`c:0x65c430`).
8. **How `0xB30C`'s per-name failures are shown** (`c:0x894830` / `0x894fc0` not traced).
9. **Duplicate textdata rows** (8): which row's text the client keeps.
10. **The friend list's unsorted order** on the client (the iteration of `c:0x997570`), and whether
    the name sort is ascending.
11. **Who sends the GameServer kind 6** (`gs:0x5d7e78`, `{u32, str}` to a client that has no case
    for it). It is probably dead.
