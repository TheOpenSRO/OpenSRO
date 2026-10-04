# Party and party matching: the wire protocol

Recovered in round 709 (lane party709a), the first spec round of the party epic. The user (2026-10-04)
asked for the whole party system, "make sure all the party features match the client/server opcodes
exactly". This page is the wire contract the implementation rounds build against: every party and
party-match message in both directions, with its byte layout, who sends it, and which process makes
the decision behind it. The rules and formulas (EXP/SP sharing, radius, item distribution, party
monsters) are lane party709b's; the windows are lane party709c's. Where a rule decides which reply
goes on the wire, it is recorded here as well.

`docs/protocol/party.md` holds the earlier rounds' reading of the same code. Where this page
contradicts it, this page is newer, and the "Corrections to existing records" table at the end lists
each such case.

## Sources

- **Client**: `sro_client.exe` on the render box (`/opt/sro-files/client/sro_client.exe`), its
  decompile `/var/tmp/decomp_client` and `/var/tmp/sro_client.asm`. Argument values and field sizes
  were confirmed with `objdump` on the exe: the writer `0x508fe0(ptr, size)` and the reader
  `MsgStreamBuffer::Read 0x4f7220(ptr, size)` take the size as a pushed literal.
- **GameServer**: `SR_GameServer.exe` (`/var/tmp/SR_GameServer.exe`), decompile
  `/var/tmp/decomp_server`, asm `srgs.asm`. The append helper `MsgBuf_AppendBytes 0x404090` takes
  the size in `EAX` (`mov eax,N` before each call). Ghidra drops that register, so every server size
  below comes from the asm, not from the decompile.
- **ShardManager**: `SR_ShardManager.exe` from the same package
  (`/opt/sro-files/server/y0gi_Easy_vPLUS/Blitzkrieq_Bin_Data/Blitzkrieq_Bin_Data/`). This round
  made a full decompile of it, **16,634 functions in `/var/tmp/decomp_shardmgr`** (DecompAll,
  project `/var/tmp/party709a/gh_sm`). Its writer `0x402df0` takes the size in `EAX`, like the
  GameServer's.
- **The server package is a private-server distribution's build.** Every server-side READ below
  means "READ (this package's GameServer/ShardManager)", not "retail". Where the two binaries are
  read against each other, the client is the retail consumer. A field the client reads at the same
  position and size the server writes is settled. A field read from one side only says so.
- The user's screenshots of the original, `/root/opensro-handoff/party_refs/01..12`.

**Labels.** **READ**: from a binary, with the address. **MEASURED**: counted. **INFERRED**:
reasoned, not observed. **OPEN**: not known. **OURS**: this project's choice. No game data is in this
file. Ids, codes and text keys are references, as in the other protocol docs.

Addresses are prefixed by binary where it matters: `c:` client, `gs:` GameServer, `sm:`
ShardManager.

## Which process owns the party

**The ShardManager owns parties and the party-match list. The GameServer keeps a mirror and talks
to the clients (READ).**

- `sm:` RTTI strings name the classes: `.?AVCPartyManager@@`, `.?AV?$CQue@PAVCParty@@@@`,
  `.?AV?$CQue@PAUPartyRegData@@@@` (party-match entries), `.?AVtrs_party_job@@`.
- `sm:0x40d190` registers the GameServer-to-ShardManager party opcodes: **`0x7866` ->
  `0x40ff90` -> `0x44ec50`** (the party job request, switched on a kind byte: 0, 2, 0xa, 0xb, 0xc,
  0xd) and **`0x3864` -> `0x40ffc0` -> `0x44f3f0`** (party events: kind 3 remove a member, 6 member
  update, 7 party chat).
- `gs:Party_PostRequest 0x5bf2a0` and `gs:trs_wait_response::FUN_005be4f0` build the `0x7866`
  request: a 0x1114-byte `trs_sm_partyjob` object (`gs:0x46cf50` sets its reply opcode to
  `0xb866`). The ShardManager answers on `0xb866` (`sm:0x44e800`) and pushes events on `0x3864`
  (`sm:0x44e7c0`). The GameServer handles those in `gs:CMainProcess::FUN_005beb80` (switch on kind:
  1, 2, 3, 6, 7, 8, 0xf, 0x10, 0x11, 0x12).
- The ShardManager relays a message meant for a client on another GameServer inside `0x7c00`
  (`sm:0x422230`: u16 inner opcode, u32 target JID, then the payload). The GameServer delivers it
  under the inner opcode (`gs:CMainProcess::MsgHandler_7c00 0x415eb0`, default branch at
  `0x416876`). A failed relay comes back on `0x3c01` (`gs:MsgHandler_3c01 0x4169d0`), which
  answers the original sender on `(opcode & 0x3fff) | 0x8000` with `[u8 2][u16 code]`.

**For OpenSRO (INFERRED):** this split does not change what the client sees. OpenSRO has one server
process, so it can hold the party list itself and send the same client messages. The ShardManager's
decisions still matter, because they choose which reply codes the client gets. They are recorded
under each flow below.

## Identifiers

- **The member id is the JID**: vtable slot 2, `CGObjPC::GetJID` (`gs:0x4e5920`, `[pc+0x188]+0x28`).
  The party's leader field (`party+0xc`), every member record's first field, the kick target, and
  the ids in the `0xb060`/`0xb067` acks are all JIDs (READ: `gs:0x5bae80` stores slot 2 in the
  record, `gs:0x514560`/`0x5146d0` compare slot 2 with `party+0xc`, `gs:0x5bb460` sends slot 2 in
  the ack). Whether retail's JID is the account id or the character id is INFERRED to be the account
  id, from the name. OpenSRO only needs one stable u32 per online character, used the same way in
  every party message.
- **An invite target is a world object id**, the id of the selected object. `0x7060`/`0x7062` send
  it, and the server resolves it through `GObjPC::IsWithinInteractionRange(pc, &id, 0x26)` (READ
  `gs:0x5143b0`, `gs:0x514560`).
- **The party id** is `party+0x8` (READ `gs:0x5bc650`). The ShardManager assigns it
  (`sm:0x44e9c0`: a counter at `manager+4` that skips 0).
- **A party-match entry number** is assigned by the ShardManager (`sm:0x451290`/`0x451110`: a
  counter at `manager+0x8c` that skips 0). The GameServer keeps the character's own number at
  `pc+0x1cd0` (READ `gs:0x5bf861`).

## The party member record (shared by 0x3065, 0x3864 and 0x706d)

One encoder and one decoder, driven by a **mask byte** that says which fields follow.
Writer: `gs:FUN_00470ba0(record, mask)`. Reader: `c:FUN_00883620`. **Cross-binary exact (READ,
asm both sides):**

| order | mask bit | field | type | source on the server (`gs:0x5bae80`, record built from the PC) |
|---|---|---|---|---|
| 0 | | mask | u8 | |
| 1 | `0x10` | member JID | u32 | vtable slot 2 `GetJID` |
| 2 | `0x01` | name | str (u16 length + bytes) | `GetCharName` (slot 59), or `GetNickName` (slot 60) when `GetJobState` (slot 71) is not 4, i.e. the job alias while in job mode |
| 3 | `0x01` | RefObjID (model) | u32 | slot 1 `GetRefObjID` |
| 4 | `0x02` | level | u8 | slot 73 `GetLevel` |
| 5 | `0x04` | HP/MP | u8 | low nibble = trunc(curHP / maxHP x 10), high nibble = trunc(curMP / maxMP x 10). The FPU control word is set to chop (`or eax,0xc00` at `gs:0x5bafab`/`0x5bb00f`), and the 10.0 is the double at `gs:0xb45c60` |
| 6 | `0x20` | region | u16 | `pc+0x84` |
| 7 | `0x20` | x, y, z | 3 x u32 if `region & 0x8000` (a dungeon), else 3 x u16 | `ftol(pc+0x88/+0x8c/+0x90)`, written in that order |
| 8 | `0x20` | world id | u32 | slot 5 `GetWorldID` |
| 9 | `0x40` | guild name | str | slot 94 `GetGuildName` |
| 10 | `0x80` | job state | u8 | slot 71 `GetJobState` (`chardata+0xf`) |
| 11 | `0x08` | mastery 1, mastery 2 | 2 x u32 | `GObjPC::FUN_005a1890(&m1, &m2)` |

- Full records (join, party info, the join-request popup) are written with mask `0xff` (READ:
  `push 0xff` at `gs:0x5bc700`, `gs:0x5bc210`, `gs:0x5c2df0`).
- An update record (`0x3864` kind 6) carries only the changed fields. `gs:CGObjPC::FUN_005bb0c0`
  maps an event mask to the wire mask (READ): event 8 -> `0x02` level; event 2 -> `0x04`, **set
  only when either tenth-nibble changed**; event 1 -> `0x20` position; event 0x10 -> `0x40` guild;
  event 0x20 -> `0x08` masteries; event 0x40 -> `0x01` name + model. An update never carries `0x10`
  or `0x80`.
- The events are raised through `CGObjPC::vslot_323` (`+0x50c`, `gs:0x4ebd50`). READ call sites:
  `GObjPC_SetLevel` (8), `Skill_HandleMasteryLevelUp` and the skill handler `0x203` (0x20),
  `UpdateCharRefObjIDAndScale` (0x40), `gs:0x4ea290` (0x10), `gs:0x4a8510` (2), `gs:0x4df6b0` and
  `gs:0x4a9410` (1). How often a position update fires is OPEN.
- The race and gender the windows show come from the RefObjID (INFERRED; lane party709c).
- The record has no buff list. The buffs on the HUD member boxes come from the normal buff traffic
  of characters in sight (INFERRED; lane party709c).

## Party flags (the "party type")

One byte, chosen when the party is created, stored at `party+0x10`.

| bit | meaning | evidence |
|---|---|---|
| `0x01` | EXP share ("Exp Auto Share"). Set: cap 8; clear: cap 4 | READ `gs:CParty::CheckCanJoin 0x514560`, `sm:0x44de70`, and the client's two "member full" errors |
| `0x02` | item share ("Item Auto Share") | READ `ground_items.md` (`GetPartyFlags() & 2`), `gs:0x5bdc80` (the pickup notice needs it) |
| `0x04` | anyone may invite ("Can invite without master status") | READ `gs:0x514560` (an OR with the leader test) |

- The client builds the byte from its party-settings singleton (`c:0xeeebd8`, reached through
  `FUN_00986f50`): `+0` exp share -> 1, `+4` item share -> 2, `+8` anyone may invite -> 4 (READ
  `c:SendPartyMsg_060` 0x81c7f0..0x81c833, `c:UI_PARTYMATCH::FUN_0073f370`). The "Set" button edits
  that singleton (screenshot 05). That is client-side: no message carries it (READ: no sender).
- **There is no "change party type" message and no "change leader" message** (READ by absence, in
  four places): the client sends only `0x7060..0x7063`, `0x7069..0x706d` and `0x306e` (asm sweep
  for `push 0x70xx`/`0x30xx`); the GameServer dispatch has party handlers only at 0x060-0x063 and
  0x069-0x06f (`server_handlers.tsv`); the ShardManager's `0x7866` kinds are 0, 2, 0xa-0xd and its
  `0x3864` kinds are 3, 6, 7. The flags last for the party's lifetime. Leadership moves only when the
  leader leaves (below).

## Opcode table

`C->S` from the client, `S->C` to it. Names are OURS unless an engine string is quoted.

| dir | opcode | name | layout | evidence |
|---|---|---|---|---|
| C->S | `0x7060` | create party + invite | u32 target world id, u8 flags | READ both: `c:0x81c6d0` writes 4, 1; `gs:0x5143b0` reads u32, u8 |
| S->C | `0xb060` | create ack (to the inviter) | u8 result; 1: u32 own JID; 2: u16 code | READ both: `c:0x880010`; `gs:0x5bb53f`, `0x5be7cd`, `Msg_SendTwoFieldReply 0x4e7250` = `[u8 2][u16]` |
| C->S | `0x7062` | invite into my party | u32 target world id | READ both: `c:0x81c8f0`; `gs:0x514560` |
| S->C | `0xb062` | invite result (to the inviter, errors only) | u8 result; 2: u16 code | READ both: `c:Party_OnJoinResult 0x8800b0`; `gs:0x5145f1`, `0x5bea65` |
| S->C | `0x3080` | invitation (to the invitee) | u8 kind (2 = new party, 3 = existing party), u32 inviter world id, u8 flags | READ client `c:0x88aa60` (reads 1, 4, then 1 for kinds 2/3); server `gs:trs_wait_response::vslot_004 0x46c8e0` (kind, `+0x2c`, one byte for kinds 2/3). Which server field holds the flags is INFERRED (register arguments lost) |
| C->S | `0x3080` | invitation answer | u8 answer; 1: u8 1; 2: u16 code (0x2c0c for kind 2, 0x2c17 for kind 3) | READ client `c:0x81cc30`/`0x81ce00` (yes), `c:0x81cd20`/`0x81cef0` (no), and the auto-decline in `c:0x88aa60`. `gs:trs_wait_response::vslot_002 0x46cb30` reads one u8. The bytes after it are unread by this GameServer (READ) |
| S->C | `0xb067` | join ack (to the invitee / joiner) | u8 result; 1: u32 own JID; 2: u16 code (`0x2c10` = timeout is special-cased) | READ both: `c:0x880120` ("OnJoinPartyAck"); `gs:0x5be848`, `0x5be95f`, `0x5bea6f`, `0x5bfd01` |
| S->C | `0x3065` | full party info (to a member who just joined) | u8 mask (`0xff`), u32 party id, [mask&1: u32 leader JID, u8 flags], [mask&2: u8 count, count x member record] | READ both: `gs:0x5bc650`; `c:0x883cc0`. The client reads the party id **before** testing the mask. The server writes it inside `mask&1`. They agree because the mask is always `0xff` |
| S->C | `0x3864` | party event | u8 kind, then per kind (next table) | READ both: `c:UI_PARTY::FUN_00886b10`; `gs:0x5bb670`, `0x5bc210`, `0x5bc390`, `0x5bdbd0`, `0x5bf150` |
| C->S | `0x7061` | leave party | (empty) | READ both: `c:0x81cad0` writes nothing; `gs:0x514530` reads nothing |
| C->S | `0x7063` | kick member (leader only) | u32 member JID | READ both: `c:SendPartyMsg_063 0x81cb70`; callers push stored member `+0x3c` (the JID, `c:0x6d5a89`, `0x7ae348`); `gs:Party_HandleExpelMember_063 0x5146d0` |
| C->S | `0x7069` | party match: register ("Form party") | entry (below) | READ both: `c:0x823d30` -> `0x823c20`; `gs:0x5c2e10` |
| S->C | `0xb069` | register result | u8 result; 1: entry; 2: u16 code | READ both: `c:PartyMatch_OnRecordResult 0x883f90` -> `0x883780`; `gs:0x5bf7d0` (`0x470e70` on `request+0x54`) |
| C->S | `0x706a` | party match: change entry | entry | READ both: `c:0x823df0`; `gs:0x5c2e10` |
| S->C | `0xb06a` | change result | as `0xb069` | READ both: `c:0x8840d0`; `gs:0x5bf870` |
| C->S | `0x706b` | party match: delete entry | u32 entry number | READ both: `c:UI_PARTY::SendPartyMsg_06b 0x81cfd0`; `gs:Party_PostRequest` kind 0xc reads u32 |
| S->C | `0xb06b` | delete result | u8 result; 1: u32 entry number; 2: u16 code | READ both: `c:UI_PARTYMATCH::FUN_008801e0`; `gs:0x5bf900` |
| C->S | `0x706c` | party match: list page | u8 page | READ both: `c:SendPartyMsg_06c 0x81d090`; `gs:Party_PostRequest` kind 0xd reads u8; `sm:0x450d20` reads u8 |
| S->C | `0xb06c` | list page | u8 result; 1: u8 page count, u8 page index, u8 n, n x list entry; 2: u16 code | READ both: `c:0x8841f0`; `sm:0x450d20` + `0x44f640`, relayed verbatim by `gs:0x5bf980` |
| C->S | `0x706d` | party match: join request | u32 entry number | READ both: `c:SendPartyMsg_06d 0x81d150`; `gs:FUN_005bf570` |
| S->C | `0x706d` | join request (to the entry's leader) | u32 job id, u32 requester JID, u32 entry number, u32 mastery 1, u32 mastery 2, u8 job state, member record (mask `0xff`) | READ: `c:0x884660` reads 4, 4, 4, 4, 4, 1, record; `gs:0x5c2db0` writes the last six; `sm:0x422230` prepends job `+4` and job `+8`; `gs:0x416876` relays the rest verbatim |
| C->S | `0x306e` | join request answer (leader) | u32 job id, u32 requester JID, u8 answer (1 confirm, 0 cancel, 2 closed) | READ both: `c:CIFPartyMatchReqJoin::FUN_0081d210` (callers `0x73fc68` push 1, `0x73fca6` push 0, `0x73fb8d` push 2); `gs:FUN_00514900` (index 0x06e) reads u32, u32, u8 |
| S->C | `0xb06d` | join request result (to the requester; on success also to the leader) | u8 result; 1: u16 outcome (1 joined, 0 refused, 2 no reply); 2: u16 code | READ: `c:0x8847d0` (strings JOIN_COMPLETE_MASTER / CREATE_PARTY_REFUSED / JOIN_NOREPLY); `gs:0x5bfac0`; `sm:0x44fbe0` |
| S->C | `0x3068` | item-share pickup notice | u32 picker JID, u32 RefItemID, then a gold-class item: amount; a stackable: u16 count; anything else: u8 1 | READ both, **disagreeing on the gold branch**: the client reads 8 bytes (`c:0x873990`, `Read(&x, 8)`), this GameServer writes 4 (`gs:0x5bdd1c`). See OPEN |
| C->S | `0x7025` | party chat | u8 type = 4, u8 index, str text | READ, `chat.md` |
| S->C | `0x3026` | party chat line | u8 type = 4, str sender name, str text | READ, `chat.md`; delivery below |

### `0x3864` kinds

| kind | layout after the kind byte | client effect (`c:0x886b10`) | server writer |
|---|---|---|---|
| 1 | u16 code | party dissolved: clears the party, shows `UIIT_MSG_PARTY_BROKEN`. The code is read and not used | `gs:0x5bb670` (to every local member); `gs:0x5bf150` sends `0x2c0b` to a returning member whose party is gone |
| 2 | member record (mask `0xff`) | member joined: adds, shows `UIIT_MSG_PARTY_JOIN` | `gs:0x5bc210`, broadcast to the members **already** in the party, before the joiner is added |
| 3 | u32 JID, u8 reason | member left. If the JID is my own, my party is cleared. Reason: 1 `UIIT_MSG_PARTY_LOGOUT`, 2 `UIIT_MSG_PARTY_SECEDE`, 3 server migration (silent; only the debug line `LEAVE_PARTY_SERVER_MIGRATION`), 4 `UIIT_MSG_PARTY_BOOTED` | `gs:0x5bc390`, broadcast **before** the member is removed, so the leaver gets it too |
| 6 | u32 JID, member record (update mask) | updates the member's fields by mask bit | `gs:0x5bdbd0`, broadcast to every member except the one updated (`BroadcastToLocalMember(msg, jid)`) |
| 9 | u32 new leader JID | leader changed: `UIIT_MSG_PARTY_HOST_ROLE_DELEGATED` | `gs:0x5bc390`, when the removed member was the leader and others remain |

The reason byte is the second argument of `gs:Party_RemoveMember 0x5be1a0`: the leave handler passes
2 (`gs:0x514530` -> `0x5144e0(2)`) and the kick handler passes 4 (`gs:0x5146d0`). The client's
jump table (`c:0x8872e8`, indexed by reason - 1) names all four (READ, strings `c:0xddc0b4`..`0xddc174`).

## Party-match entry (0x7069, 0x706a, 0xb069, 0xb06a)

Writer `c:UI_PARTYMATCH::FUN_00823c20` = `gs:FUN_00470e70`. Readers `gs:FUN_005c2e10` =
`c:FUN_00883780`. **Cross-binary exact (READ):**

| field | type | client fills (`c:0x73f370`) | server |
|---|---|---|---|
| entry number | u32 | the current entry's number (`this+0x7c0`; 0 for a new one, INFERRED) | the ShardManager assigns it on register |
| party id | u32 | 0 | the GameServer overwrites it with the requester's party id (`gs:0x5bf3ed`) |
| flags | u8 | the party-settings byte (1/2/4 as above) | must equal the existing party's flags, else `0x2c20` (`sm:0x450680`) |
| purpose | u8 | the purpose combo's index (`FUN_00657a10` on control 0x28) | 2 = trader, 3 = thief (READ, the job tables below); 0 and 1 OPEN |
| min level | u8 | edit 0x2a | client refuses min < 1 or min > max (`UIIT_MSG_PARTYMATCH_RECORD_ERROR_LEVEL`) |
| max level | u8 | edit 0x2b | |
| title | str | edit 0x31; empty is refused (`..._RECORD_ERROR_TITLE`) | |

## Party-match list entry (0xb06c)

Writer `sm:FUN_0044f640`. Reader `c:FUN_008841f0`. Sizes READ on both sides, in this order:

| field | type | ShardManager source | client stores at |
|---|---|---|---|
| entry number ("No.") | u32 | `entry+0` | `+0` |
| second u32 | u32 | `entry+0x30`, written by `_time32` when the entry is registered or changed (`sm:0x451290`, `0x451110`, `0x4513c0`). INFERRED a timestamp: Ghidra's FID match is marked `FID_conflict` | `+4`; its use is OPEN |
| name ("Name") | str | purpose 2/3: the leader member record's name (the job alias), or before a party exists, the nickname saved at register (`char+0x258`); otherwise the character name (`char+0x1a8`) | |
| race | u8 | the leader's `char+0x250` = byte `+0x88` of the leader's ref record (`sm:0x42a7d0`). INFERRED race/country | `+8` |
| member count | u8 | party size, 1 when no party yet | `+9` |
| flags ("Type") | u8 | `entry+8` | `+0xb` |
| purpose ("Purpose") | u8 | `entry+9` | `+0xa` |
| min level | u8 | `entry+0xa` | `+0xc` |
| max level | u8 | `entry+0xb` | `+0xd` |
| title ("Title") | str | `entry+0x10` | |

**Paging (READ `sm:0x451630`, `sm:0x450d20`):**
- The ShardManager pre-builds the pages after every change, walking the entries in entry-number
  order. A page closes at **23 entries** (`cmp al,0x17` at `sm:0x4517ed`) or at the last entry.
- A page request clamps a page index that is too large to 0.
- **If the requester has an entry, or is in a party whose leader has one, that entry is written
  first**, and the page's count is one more (`sm:0x450d20`, `local_19 + 1` then `FUN_0044f640`).
  Screenshot 02 shows this: Tobi's own entry 3480 heads page 1, ahead of entry 4.
- With no entries: `[1][0][0][0]`.
- The "Members" column's "x/8" or "x/4" is the count over the cap given by flag bit 0 (INFERRED;
  lane party709c).
- **There is no server-side search.** The request carries only the page byte (READ, three
  binaries). Name, purpose and level filtering happen in the client (INFERRED; lane party709c).

## Flows

### Create a party with a selected player (0x7060)

1. The inviter's client checks that it is in no party and has a target, then sends `0x7060` and
   shows `UIIT_STT_PARTY_PROPOSAL_PENDING` (READ `c:GInterfaceSend::FUN_006d5970`,
   `c:0x81c6d0`). If the target is not a player character, the sender substitutes the id at `+0xf8`
   of `FUN_009ce910`'s result (READ shape, INFERRED to be a COS's owner).
2. `gs:0x5143b0`: `CParty::CheckCanCreate` (refuses `0x2c19`, `0x2c0a` level < 5, `0x2c09`), then:
   - range 38 (`IsWithinInteractionRange`; its own refusal code);
   - the target must be a PC (else 3);
   - `CParty::CheckTargetAvailable` refuses `0x2c06` locked, 3 not alive/dead, `0x2c12` or
     `0x2c18` already in a party, `0x2c1f` invite pending, `0x2c25` listed in party matching,
     `0x2c28` battle-arena opponent.

   A refusal is `0xb060 [2][code]`. Otherwise `Party_SendFormationInvitation` opens a
   `trs_wait_response` of kind 2 and sends `0x3080 [2][inviter id][flags]` to the target.
3. The invitee's client auto-declines when its "accept party invitations" option is off
   (`c:0x88aa60`, option byte `+1` of `FUN_004f9d00`): `0x3080 [2][0x2c0c]`. Otherwise it shows the
   confirm box with the three flags.
4. The answer `0x3080 [1][1]` or `[2][code]` reaches `gs:0x46cb30` -> `gs:0x5be350`:
   - a decline gives `0x2c0c`;
   - a vanished inviter gives `0x2c0e`;
   - an invitee no longer pending gives 3;
   - a failure to post gives 2.

   Any of these sends `0xb060 [2][code]` to the inviter and `0xb067 [2][code]` to the invitee
   (`gs:0x5be9b0`). If nobody answers, the transaction times out with **`0x2c10`** (TIMEOUT,
   `gs:trs_wait_response::OnTimeout 0x46ce44`) on the same two messages. The client's `0xb067`
   handler closes the box on `0x2c10` (`c:0x880120`).
5. On yes, the GameServer posts `0x7866` kind 0 with both members' records (`gs:0x5be4f0`). The
   ShardManager (`sm:0x44ed70`) refuses:
   - `0x2c0f`: a member is gone;
   - `0x2c09`: the inviter is already in a party;
   - `0x2c18`: the invitee is already in a party;
   - `0x2c23`: job mismatch (table below);
   - `0x2c20`: the inviter's match entry has other flags.

   Otherwise it creates the party: party id, flags, leader = inviter, members = [inviter, invitee].
6. On success (`gs:trs_sm_partyjob::FUN_005be710`), each member gets the following in order (the
   kind-2 broadcast goes to members already in the party):
   - inviter: `0xb060 [1][own JID]`, then `0x3065`;
   - invitee: `0xb067 [1][own JID]`, then `0x3864` kind 2 about it goes to the inviter, then
     `0x3065` to the invitee.

### Invite into an existing party (0x7062)

1. Client: in a party, and the leader or flag bit 2 is set (READ `c:0x6d5970`, also the chat
   command path `c:0x7adf70`). It sends `0x7062`.
2. `gs:CParty::CheckCanJoin 0x514560`: caller in a party; caller is the leader or bit 2 is set;
   target is not self. These three fail **silently**. Then:
   - full is `0xb062 [2][0x2c13]` with exp share, `[0x2c14]` without;
   - range 38;
   - PC check;
   - `CheckTargetAvailable`;
   - `Party_SendInvitation` (`trs_wait_response` kind 3): `0x3080 [3][inviter id][flags]`.
3. Answer: a decline gives `0x2c17`, plus `0x2c0e`/3/2 as above. These go out as `0xb062 [2][code]`
   to the inviter and `0xb067 [2][code]` to the invitee (`gs:0x5bea20`). A timeout gives `0x2c10`.
4. On yes, `0x7866` kind 2. The ShardManager (`sm:0x44f130`) refuses:
   - `0x2c0d`: party or leader not found;
   - `0x2c23`: job mismatch between the leader and the invitee (`al` = leader record `+0x49`, `cl`
     = invitee's job state, `sm:0x44f223`);
   - `0x2c0f`: invitee gone;
   - `0x2c25`: the invitee has a match entry;
   - `0x2c12`: already a member;
   - `0x2c13`/`0x2c14`: full.
5. On success the inviter gets **no** `0xb062` (READ: the 0x062 handler returns without replying
   on success, and `gs:0x5be940` writes only `0xb067 [1][JID]` to the invitee). The party gets
   `0x3864` kind 2. The invitee gets `0x3065`.

### Leave, kick, dissolve, leader passing

- **Leave** `0x7061` -> reason 2. **Kick** `0x7063` -> reason 4. The kick needs a party, the caller
  to be the leader (`pc JID == party+0xc`), and a target other than self; it fails silently
  otherwise (READ `gs:0x5146d0`). Logout uses reason 1 (INFERRED from the client's table; the
  logout caller was not read).
- **The ShardManager decides what a removal does** (`sm:0x44f580`):
  - **with exactly 2 members the party is dissolved** (`sm:0x44eb30`): `0x3864` kind 1 with code
    `0x2c0b` to everyone; the leader's match entry is deleted;
  - otherwise the member is removed (kind 3 with the reason), and **the leader becomes the first
    remaining member in join order** (`sm:0x44e1a0`, `party+4 = members[0].JID`). The GameServer
    mirrors this in `gs:0x5bc390`: when the removed JID was the leader it sends kind 9 with the new
    leader. A match entry owned by the old leader passes to the new leader (`sm:0x44e1a0`, kind
    0x12).
- The client's party window: `c:0x6d5a00` and `c:0x6d5a20` send leave when in a party.
  `c:0x6d5a40` maps a click on one of the seven member-row buttons (`this+0x36c`) to that row's
  member: kick if I am the leader, leave otherwise (READ). Which visible button ("Dismiss",
  "Leave") is bound to which handler is lane party709c's.

### Party matching

- **Register** `0x7069`. GameServer checks, `gs:CParty::CheckCanCreateForMatch 0x514170`:
  - `0x2c09`: locked or not alive;
  - `0x2c26`: wearing a job item (`chardata+0x13`);
  - 5: in job mode with an empty alias;
  - `0x2c24`: the state byte is not 0 or 2;
  - not in a party: level < 5 gives `0x2c0a`;
  - in a party: not the leader gives `0x2c1d`;
  - `0x2c28`: the instance does not allow it;
  - `0x2c23`: `Party_UserMatches` fails (`gs:0x5bf2a0`, kind 0xa).

  ShardManager, `sm:0x450680`:
  - `0x2c0f`: gone;
  - `0x2c1b`: already has an entry (`RECORD_ERROR_AGAIN`);
  - `0x2c20`: flags mismatch;
  - `0x2c1d`: not the leader;
  - `0x2c08`: the party is full (`ALREADY_FULL`).

  On success the GameServer sends `0xb069 [1][entry]`, stores the number at `pc+0x1cd0`, and sets
  the state byte to 4 when the character has no party (`gs:0x5bf858`).
- **Change** `0x706a`: GameServer `gs:0x514260` refuses `0x2c1d` not the leader and `0x2c1c` no
  entry. The ShardManager (`sm:0x4513c0`) refuses `0x2c1c`, `0x2c1d`, and **5 when the flags
  differ from the entry's**: the flags cannot be changed this way either. Changeable: purpose,
  level range, title.
- **Delete** `0x706b`: GameServer `gs:0x5142c0` refuses `0x2c1c` when there is no entry.
  ShardManager `sm:0x451490`: `0x2c1c`, `0x2c1d`, `0x2c0d`. Result `0xb06b [1][number]`; the state
  byte returns to 0 when not in a party.
- **List** `0x706c [page]` -> `0xb06c` (above).
- **Join request** `0x706d [entry]`. GameServer `gs:0x514300`, the requester:
  - `0x2c06`: locked;
  - 3: not alive;
  - `0x2c12`: in a party;
  - `0x2c1f`: invite pending;
  - `0x2c25`: has an own entry;
  - `0x2c28`: instance.

  It then sets the requester's state byte to 1 and forwards entry, masteries, job state and its own
  record (`gs:0x5bf570`).

  ShardManager `sm:0x44f850`:
  - `0x2c18`: in a party;
  - `0x2c25`: has an entry;
  - `0x2c1c`: no such entry;
  - **`0x2c13`/`0x2c14`**: the entry's party is full;
  - **`0x2c23`**: job mismatch with the leader (the leader-job table), or with the entry's purpose
    (the purpose table);
  - **`0x2c1e`**: level outside min..max (inclusive);
  - **`0x2c1f`**: another request to this entry is pending;
  - `0x2c0e`: the leader is offline.

  An error reaches the requester as `0xb06d [2][code]` through the relay error path. The client
  shows it with the generic error display, `FUN_00778190`. That is the "refused, and it says why"
  the user described (INFERRED; where it is drawn is lane party709c's).
- Otherwise the ShardManager marks the entry busy and relays `0x706d` to the leader with a
  **15.0** timeout (the float at `sm:0x79b018`, passed as the job's timeout argument; INFERRED
  seconds). The requester's client shows the joining progress window (lane party709c).
- The leader answers `0x306e [job][requester][answer]` (`sm:0x420e50`). A timeout behaves as
  answer 2 (`sm:0x420e10`, `0x44fbe0(.., 2)`).
- Results (`sm:0x44fbe0` -> GameServer kind 0x11 -> `0xb06d`):
  - answer 0: the requester gets `[1][0]`, "refused";
  - answer 2: `[1][2]`, "no reply";
  - answer 1: if the leader has no party yet, a party is created with the entry's flags and the
    leader first (`sm:0x44e9c0`); otherwise the requester is added (`sm:0x44e140`). Both requester
    and leader get `0xb06d [1][1]` (the leader's copy INFERRED from the second send in `0x44fbe0`).
    The usual `0xb060`/`0xb067` acks, kind 2 and `0x3065` follow (kinds 0xf / 0x10);
  - an accept that fails gives `[2][code]` (`0x2c0f`, `0x2c1c`, `0x2c0d`, `0x2c12`-`0x2c14`).
- **Auto match** has no opcode of its own. The client sends `0x706d` to successive entries
  (`c:FUN_00786e70` calls the `0x706d` sender) and continues after each refusal or no-reply
  (`c:0x8847d0`, `UIIT_MSG_PARTYMATCH_AUTO_PROGRESS`/`_FAILURE`). READ that the loop is
  client-side; how it steps is lane party709c's.
- **Whisper** in the match window is ordinary whisper chat (INFERRED; lane party709c).

### Job rules (the "user mismatch" refusals)

`GetJobState` (`chardata+0xf`): 1 trader, 2 thief, 3 hunter (the labels `jobs.md` reads for the
same slot), **4 = not in job mode**. 4 is READ as the normal state: the party name selection
(`gs:0x5bae80`), guild creation (`guild.md`) and teleports (`teleport_network.md`) all test `!= 4`.

| table | where | rule |
|---|---|---|
| person to person | `sm:0x44ed20`: forming a party; inviting into one (leader vs invitee); a join request (entry leader vs requester) | trader and hunter go together; thief only with thief; no-job only with no-job |
| person to purpose | `gs:Party_UserMatches 0x5bf240` (register: own job vs the entry's purpose, `cl = [entry+9]` at `gs:0x5bf358`); `sm:0x44f7f0` (join: requester vs purpose) | trader or hunter -> purpose 2; thief -> purpose 3; no-job -> any purpose except 2 and 3 |

Both refuse with `0x2c23` `UIIT_MSG_PARTY_USER_MISSMATCH`. The user expected that "thieves only with
thieves; traders can have hunters": READ.

## Party chat

- Send: `0x7025 [4][index][text]`. The client refuses a party line without a party
  (`UIIT_MSG_PARTYERR_CANT_FIND_PARTY`, `chat.md`).
- The GameServer forwards it to the ShardManager (`gs:GObjPC::FUN_005bb8c0`, `0x3864` kind 7:
  party id, name, text; called from `gs:0x4b1db5`). The ShardManager sends it back out as its own kind
  7 (`sm:0x44e840` -> `0x44e380`). That `0x44e380` reaches every GameServer with a member is
  INFERRED; the fan-out inside `sm:0x412120` was not read.
- Each GameServer broadcasts `0x3026 [4][name][text]` to **all** its local members, the sender
  included (`gs:0x5bef50`; the exclude argument is `ebx`, zeroed at `gs:0x5bef84` and pushed at `gs:0x5bf062`).
- The sender's client **drops a type-4 line carrying its own name** (`c:Chat_OnChatUpdate
  0x877810`, case 4: `FUN_004e9530(own name, sender)` skips it). The client shows its own line from
  the `0xB025` OK instead (`c:0x877340`, case 4).
- Only party members receive it. That matches the user's "limit it to the party": READ.

## Server-side state byte, `chardata + 7`

Round 359 left the meaning of 3 and 4 open. This round settles it (READ):

| value | meaning | writers |
|---|---|---|
| 0 | free | |
| 1 | an invitation or a join request is pending | `Party_SendInvitation`/`FormationInvitation` (target), `gs:0x5bf570` (join requester) |
| 2 | in a party | `GObjPC::SetParty` |
| 3 | listed in party matching (4) and has sent an invitation | `Party_SendFormationInvitation`: `(state == 4) * 2 + 1` |
| 4 | **listed in party matching, no party** | `gs:trs_sm_partyjob::FUN_005bf7d0` (`0x5bf858`) after a successful register; back to 0 on delete (`gs:0x5bf900`). `gs:0x5bea90` returns 3 to 4 when the invitation ends |

Handler 0x06f (`gs:0x514af0`) clears 4 and `pc+0x1cd0`. **No client sender for it was found**
(`push 0x706f`/`0x306f` and `mov ...,0x706f`: none). Who sends it is OPEN.

## Error codes the party system sends

From `docs/protocol/error_codes.md` (client names); where the code is sent is READ above.

| code | client name |
|---|---|
| `0x2c06` | (no name; character locked) |
| `0x2c08` | `UIIT_MSG_PARTYERR_ALREADY_FULL` |
| `0x2c09` | (no name; locked or not alive) |
| `0x2c0a` | `UIIT_MSG_PARTYERR_TOO_LOW_CREATOR_LEVEL` |
| `0x2c0b` | (no name; the dissolution code in kind 1, ignored by the client) |
| `0x2c0c` | `UIIT_MSG_PARTYERR_CREATE_PARTY_REFUSED` |
| `0x2c0d` | `UIIT_MSG_PARTYERR_CANT_FIND_PARTY` |
| `0x2c0e` | `UIIT_MSG_PARTYERR_CANT_FIND_CREATER` |
| `0x2c0f` | `UIIT_MSG_PARTYERR_INVALID_USER` |
| `0x2c10` | `UIIT_MSG_PARTYERR_TIMEOUT` |
| `0x2c12` | `UIIT_MSG_PARTYERR_EXISTING_MEMBER` |
| `0x2c13` | `UIIT_MSG_PARTYERR_MEMBER_FULL_EXP_SHARED_PARTY` |
| `0x2c14` | `UIIT_MSG_PARTYERR_MEMBER_FULL_NONEEXP_SHARED_PARTY` |
| `0x2c17` | `UIIT_MSG_PARTYERR_JOIN_PARTY_REFUSED` |
| `0x2c18` | `UIIT_MSG_PARTYERR_MEMBER_OF_ANOTHER_PARTY` |
| `0x2c19` | (no name in the table; `CheckCanCreate`'s slot-0x244 test) |
| `0x2c1b` | `UIIT_MSG_PARTYMATCH_RECORD_ERROR_AGAIN` |
| `0x2c1c` | `UIIT_MSG_PARTYERR_CANT_FIND_PARTY` |
| `0x2c1d` | `UIIT_MSG_PARTYMATCH_RECORD_ERROR_PARTYLEADER` |
| `0x2c1e` | `UIIT_MSG_PARTYMATCH_JOIN_ERROR_LEVEL` |
| `0x2c1f` | `UIIT_MSG_PARTYMATCH_JOIN_ERROR_DUPLE` |
| `0x2c20` | (no name in the table; flags differ from the match entry) |
| `0x2c23` | `UIIT_MSG_PARTY_USER_MISSMATCH` |
| `0x2c24` | `UIIT_MSG_PARTYMATCH_JOIN_ERROR_DUPLE` |
| `0x2c25` | `UIIT_MSG_PARTYMATCH_RECORD_ERROR_INVITE` |
| `0x2c26` | `UIIT_MSG_JOBITEM_WEAR_ERR_PARTYMATCH` |
| `0x2c28` | `UIIT_MGS_ARENA_ERR_CANT_PARTY_WITH_OPPONENT_IN_BATTLE_ARENA` |
| 2, 3, 5 | bare codes; no client message |

## Timers

| what | value | evidence |
|---|---|---|
| invitation wait (`0x3080` box) | 30.0 | the float `gs:0xb45b48` stored at `trs_wait_response+0x1c` by `gs:0x46c7e0`. INFERRED to be the timeout in seconds (its reader was not traced) |
| party-match join request | 15.0 | `sm:0x79b018`, loaded at `sm:0x44fb15` and passed as the job's timeout argument. INFERRED seconds |

## Gap list: OpenSRO today

| area | OpenSRO | retail |
|---|---|---|
| opcodes | `session/party.go` and `client/scripts/net/party.gd`: `0x0080`..`0x0089` (create, join, leave, member joined/left, info), all OURS | everything in the opcode table above. **None of OpenSRO's party messages is retail.** |
| payloads | names as strings and 64-bit character ids; create/leave send the character name | JIDs (u32), world object ids, the masked member record |
| invitation | none: `Join(partyID)` joins directly by party id | `0x7060`/`0x7062` -> `0x3080` box -> answer -> `0xb060`/`0xb062`/`0xb067` -> `0x3065`/`0x3864` |
| party types | none: EXP is shared unconditionally, cap 8 (`party.go` MaxSize; `MaxSizeNotShared` unused) | flags byte: exp share (cap 8/4), item share, anyone may invite |
| leader rules | creator level 5 (`CanCreate`) | the same, plus: leader-only kick; leadership passes to the oldest member; a party of 2 dissolves when one leaves |
| member updates | none | `0x3864` kind 6 with the masked record (HP/MP tenths, level, position, guild, masteries) |
| party matching | none | `0x7069`..`0x706d`, `0x306e`, the `0xb069`..`0xb06d` replies, paging, job and level gates, the 15 s join request |
| job gates | none | the two tables above |
| item-share notice | none | `0x3068` |
| party chat | `chat.go` `ChatParty`: delivered to party members only, sender excluded, over OURS chat opcodes `0x00A5`/`0x00A6`/`0x00A7` | the same visible result. Retail echoes the sender, whose client drops its own line, and uses `0x7025`/`0x3026`/`0xB025` (all chat) |

## Corrections to existing records

| record | says | what is true |
|---|---|---|
| `party.md`, round 356, `0x061` | "a party-side *teleport* action, not an invite" | `0x7061` is **leave party**. The client's sender `c:0x81cad0` writes no payload and is called by the `UIIT_STT_CHAT_COMMAND_PARTY_EXIT` chat command and the party window (`c:0x6d5a00`, `0x6d5a20`, `0x6d5a40`). The server removes with reason 2, which the client shows as `UIIT_MSG_PARTY_SECEDE`. The `SaveCurPosAsLastTelPosition` call inside it does not make it a teleport; that name deserves a second look |
| `party.md` / `recovered_names.tsv`, `Party_RemoveMember` | "WHAT REASON 1 IS, AND THE REASON ENUM'S OWN NAMES, ARE NOT CLAIMED" | 1 LOGOUT, 2 SECEDE, 3 SERVER_MIGRATION, 4 BOOTED: the client's `0x3864` kind-3 jump table `c:0x8872e8` with its strings |
| `party.md`, `0x06e`/`0x06f` | "both things a character with no party does ... the answering side" | `0x06e` is **`0x306e`, the party-match leader's answer** to a relayed `0x706d` (`[u32 job][u32 requester JID][u8 answer]`). Invitations are answered on `0x3080`. `0x06f` has no client sender |
| `party.md`, state byte | "What 3 and 4 MEAN is not claimed" | 4 = listed in party matching without a party; 3 = such a character has an invitation out (this page's table) |
| `party.md`, round 271 | "the party lives in the global/agent process" | It lives in **`SR_ShardManager.exe`**: `CPartyManager`, `0x7866`/`0x3864` handlers at `sm:0x44ec50`/`0x44f3f0` |
| `party.md` / `recovered_names.tsv`, `Party_UserMatches` | "WHAT THOSE VALUES ARE IS NOT CLAIMED" | `AL` = `GetJobState`, `CL` = the match entry's purpose byte (`gs:0x5bf358`). The table is the person-to-purpose job rule |
| `party.md`, `Party_PostRequest` kinds | "WHAT EACH KIND MEANS DOWNSTREAM IS NOT CLAIMED" | 0xa register, 0xb change, 0xc delete, 0xd list page (`sm:0x44ec50`'s switch and its four handlers) |
| `party.md`, "Whether the exp-sharing flag can change after creation" | open | No message changes it, in any of the three binaries (this page, "Party flags") |
| `party.md`, size section | "OpenSRO's parties share experience unconditionally ... MaxSizeNotShared is recorded for completeness" | Still true of the code. The user wants the real party types, so the 4/8 split becomes live |
| `recovered_names.tsv` | `FUN_00514530` (index 0x061), `GObjPC_HandlePartyMsg_06b`/`_06c`/`_06d`, `FUN_00514900`, `FUN_0081cad0` | Proposed: `Party_HandleLeave_061`, `PartyMatch_HandleDeleteEntry_06b`, `PartyMatch_HandleListPage_06c`, `PartyMatch_HandleJoinRequest_06d`, `PartyMatch_HandleJoinAnswer_06e`, `SendPartyLeave_061`; client `FUN_00880010` -> `Party_OnCreateResult` (its own log string "OnCreatePartyAck"), `FUN_00880120` -> `Party_OnJoinPartyAck` ("OnJoinPartyAck"), `FUN_00883cc0` -> `Party_OnPartyInfo_3065`, `FUN_00883620` -> `Party_ReadMemberRecord`, `gs:FUN_00470ba0` -> `Party_WriteMemberRecord`, `FUN_008841f0` -> `PartyMatch_OnListPage`, `FUN_008847d0` -> `PartyMatch_OnJoinResult`, `FUN_00884660` -> `PartyMatch_OnJoinRequest_706d` |
| `client_senders.tsv` | lacks `0x306e` and the party `0x3080` answers | add `0x306e CIFPartyMatchReqJoin::FUN_0081d210`; `0x3080` `FUN_0081cc30`/`0081cd20`/`0081ce00`/`0081cef0` |
| `handler_payloads.tsv` | `0x069`/`0x06a` "expansion NOT confirmed -- dropped"; `0x06b`/`0x06c` client-only | `0x069`/`0x06a`: u32, u32, u8, u8, u8, u8, str (exact, `gs:0x5c2e10` vs `c:0x823c20`). `0x06b`: u32. `0x06c`: u8. `0x06e`: u32, u32, u8 (exact). `0x061`: empty (exact) |
| `jobs.md` | slot 71 is `GetJobType` with "0 no job" | Party, guild and teleport code treat **4** as "not in job mode" for the same slot (`GetJobState`, `chardata+0xf`). The two readings disagree about the no-job value. Not resolved here; flagged |

## OPEN, and what each one blocks

1. **The `0x3068` gold branch**: the client reads 8 bytes, this GameServer writes 4. Blocks an exact
   gold pickup notice. Recommendation: follow the client (8 bytes), because the client is the
   retail consumer and a short message would make its read run past the end.
2. **Purpose values 0 and 1** (which is "combat", whether "all" is a search-only value). Blocks the
   register combo. Lane party709c, from the window's combo order
   (`UIIT_CTL_PARTYMATCH_PSEARCH_OBJECTALL`/`_OBJECTCOMBAT`/`_FIND_OBJECTTRADER`/`_FIND_OBJECTTHIEF`).
3. **Client-side search** (name, purpose, level): the request carries only the page. How the client
   filters is lane party709c's.
4. **The list entry's second u32** (a timestamp, INFERRED) and **the race byte** (INFERRED): what the
   client draws from each. Lane party709c.
5. **The second byte of the `0x3080` "yes"** (`[1][1]`). This GameServer does not read it. Send it as
   the client does.
6. **The two timeouts** are floats whose consumers were not traced: 30.0 and 15.0, INFERRED seconds.
   The join progress bar's own duration is in the client (lane party709c).
7. **How often a position update (`0x3864` kind 6, bit `0x20`) is sent**: the callers are known, the
   cadence is not.
8. **How the client links a party member (JID) to a world object** for selection, distance and the
   portrait. Lane party709c.
9. **Handler 0x06f's sender.**
10. **Logout and server migration**: the client shows reasons 1 and 3; the GameServer paths that
    send them were not read.
