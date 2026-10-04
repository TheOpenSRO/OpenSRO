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
  `gs:0x5143b0`, `gs:0x514560`). **The `0x26` is not a distance** (review of round 709): it is a
  TypeID filter, compared field by field with the target's type word by `gs:0x4a8d90`
  (`(x>>2)&7`, `(x>>5)&3`, `(x>>7)&0xf`, `x>>11`); a mismatch returns **3** (`gs:0x4a8eb2`). The
  distance is a float picked inside `gs:0x4a8e10`: **600.0** (`gs:0xb46198`) when the found
  target's vtable slot 7 (`+0x1c`, IsPC) returns 1, 320.0 (`gs:0xb460dc`) by default
  (`gs:0x4a8ec0..0x4a8f00`: `ebx` is the found target, reloaded from the out-parameter). The
  distance is **3D** (positions `+0x88/+0x8c/+0x90` through the region-aware delta `gs:0x430ba0`,
  then `sqrt`). Out of range returns the bare code **4** (`gs:0x4a902f..0x4a903b`); not found, or
  another world, returns 0 (`gs:0x4a8e2b`); in range returns 1. Any result other than 1 goes out as
  `0xb060 [2][code]` (or `0xb062` for `0x7062`). READ (GS, both round-709 reviews; which object
  is tested for IsPC re-read by the fix-up pass).
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
| 9 | `0x40` | guild name | str | slot 94 `GetGuildName` (CGObjPC vtable `0xaf59fc` + 94×4 holds `0x4ea640`, recovered name `CGObjPC::GetGuildName`; READ by the fix-up pass). The client stores it at its wire struct's `+0x20` (`c:0x883730`) |
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
- **HP and MP reach the client only as the tenths byte** (READ both sides: `gs:0x470c16`,
  `c:0x883684`, size 1). The client splits it into the member object's HP and MP slots at
  `c:0x99a34b..0x99a36a` (`and ecx,0xf` / `shr eax,4`). So the ratios the party window and HUD
  draw are tenths. Where the client's "max" slots come from was not traced (OPEN, minor).
- The race the windows show comes from the RefObjID: the reference's `+0x9c` byte (READ client,
  `party_gui.md` §1).
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
  four places; `0x7067` sits in the GameServer's `RegisterValueListFilters` list next to
  `0x7060..0x7063` at `gs:0x427f0d`, but it has no dispatch handler and no client sender, so it
  changes nothing here): the client sends only `0x7060..0x7063`, `0x7069..0x706d` and `0x306e` (asm sweep
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
| S->C | `0xb062` | invite result (to the inviter, errors only) | u8 result; 2: u16 code | READ both: `c:Party_OnJoinResult 0x8800b0`; `gs:0x5145f1`, `0x5bea65`. **One `0x7062` refusal goes out on `0xb060` instead**: when posting the invitation fails (`Party_SendInvitation` code 2, `gs:0x5be33c`), the 0x062 handler replies `0xb060 [2][2]` (`gs:0x5146bb mov ecx,0xb060`). Range, type and availability failures use `0xb062` (`gs:0x51465e`). `server_handlers.tsv` already lists both. Retail behaviour, copied as is (review of round 709) |
| S->C | `0x3080` | invitation (to the invitee) | u8 kind (2 = new party, 3 = existing party), u32 inviter world id, u8 flags | READ client `c:0x88aa60` (reads 1, 4, then 1 for kinds 2/3); server `gs:trs_wait_response::vslot_004 0x46c8e0` (kind `+0x28`, inviter `+0x2c`, then for kinds 2/3 the byte `+0x34`, `gs:0x46c986`/`0x46c9a3`). The flags reach `+0x34` READ: `gs:0x5be2a5`/`0x5be311` load them into `EDI`, and `gs:0x4ea0d0` stores `EDI` at `trs+0x34` for kinds 2, 3 and 7 (`gs:0x4ea150`). The kind-3 transaction also holds the party id at `+0x24`, not sent (review of round 709) |
| C->S | `0x3080` | invitation answer | u8 answer; 1: u8 1; 2: u16 code (0x2c0c for kind 2, 0x2c17 for kind 3) | READ client `c:0x81cc30`/`0x81ce00` (yes), `c:0x81cd20`/`0x81cef0` (no), and the auto-decline in `c:0x88aa60`. `gs:trs_wait_response::vslot_002 0x46cb30` reads one u8. The bytes after it are unread by this GameServer (READ). A join accepts only on 1 (`0x5be39f`); a formation on any non-zero byte (`test bl,bl`, `0x5be41c`), the client's "no" included -- OpenSRO accepts only 1 for both (OURS, round 710; step 4 below) |
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
| S->C | `0x706d` | join request (to the entry's leader) | u32 job id, u32 requester JID, u32 entry number, u32 mastery 1, u32 mastery 2, u8 job state, member record (mask `0xff`) | READ: `c:0x884660` reads 4, 4, 4, 4, 4, 1, record; `gs:0x5c2db0` writes the last **five** (entry, mastery 1, mastery 2, u8 job state, record with mask `0xff`; `gs:0x5c2db4..0x5c2dfb`); `sm:0x422230` prepends job `+4` and job `+8` (u16 opcode, u32 target, u32, u32; call site `sm:0x421307..0x421318`); `gs:0x416876` relays the rest verbatim |
| C->S | `0x306e` | join request answer (leader) | u32 job id, u32 requester JID, u8 answer (1 confirm, 0 cancel, 2 closed) | READ both: `c:CIFPartyMatchReqJoin::FUN_0081d210` (callers `0x73fc68` push 1, `0x73fca6` push 0, `0x73fb8d` push 2); `gs:FUN_00514900` (index 0x06e) reads u32, u32, u8 |
| S->C | `0xb06d` | join request result (to the requester; on success also to the leader) | u8 result; 1: u16 outcome (1 joined, 0 refused, 2 no reply); 2: u16 code | READ: `c:0x8847d0` (strings JOIN_COMPLETE_MASTER / CREATE_PARTY_REFUSED / JOIN_NOREPLY); `gs:0x5bfac0`; `sm:0x44fbe0` |
| S->C | `0x3068` | item-share pickup notice, to every member but the recipient (`0x5bb770` skips him) | u32 recipient JID (the member the item went to: `gs:0x526074`/`0x52607e` store the round robin's EBX at the transaction's `+0x28`, read at `0x5bdc95`; round 712), u32 RefItemID, then a gold-class item: amount; a stackable: u16 count; anything else: u8 1 | READ both, **disagreeing on the gold branch**: the client reads 8 bytes (`c:0x873a75 mov ebp,8`), this GameServer writes 4 (`gs:0x5bdd1c`). Both sides use the same item-class test (`gs:0x42fe10` = `c:0x873a2b..0x873a73`). **OURS: send 8 bytes, as the client reads** (see OPEN 1) |
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
| purpose | u8 | the objective radio's index, stored unmapped (`c:0x73f370`: `push 0x28; call 0x8b51f0; call 0x657a10; mov [esp+0x49],al`) | **0 combat ("Hunting"), 1 quest, 2 trade, 3 thief** (READ: the radio's items in that order at `c:0x73f820`, the label table `c:0x740910`/`0x740a2c`, and the job tables below). "All" exists only as index 4 of the search combo (`c:0x73b12e push 4`) and is never sent |
| min level | u8 | edit 0x2a | client refuses min < 1 or min > max (`UIIT_MSG_PARTYMATCH_RECORD_ERROR_LEVEL`) |
| max level | u8 | edit 0x2b | |
| title | str | edit 0x31; empty is refused (`..._RECORD_ERROR_TITLE`) | |

## Party-match list entry (0xb06c)

Writer `sm:FUN_0044f640`. Reader `c:FUN_008841f0`. Sizes READ on both sides, in this order:

| field | type | ShardManager source | client stores at |
|---|---|---|---|
| entry number ("No.") | u32 | `entry+0` | `+0` |
| second u32 | u32 | `entry+0x30`, written by `_time32` when the entry is registered or changed (`sm:0x451290`, `0x451110`, `0x4513c0`). **READ (round 713): `_time32` seconds since the epoch** -- the expiry sweep (`sm:0x4504c0`) subtracts it from `_time32` (`0x6e3cbc`) and divides by 60 | `+4`; its use is OPEN |
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
   `c:0x81c6d0`). If the target is not a `CICPlayer`, the sender substitutes the id at `+0xf8`
   of `FUN_009ce910`'s result (READ: `c:0x81c782 mov edi,[eax+0xf8]`, taken only for a non-player
   target, `c:0x81c741..0x81c74f`; INFERRED to be a COS's owner).
2. `gs:0x5143b0`: a `0x7060` aimed at oneself is dropped with **no reply** (`gs:0x514438 cmp
   eax,[edi+0x8]; je 0x5144cb`). Then `CParty::CheckCanCreate` (refuses `0x2c19`, `0x2c0a`
   level < 5, `0x2c09`), then:
   - `IsWithinInteractionRange` (Identifiers above): type filter mismatch 3, more than **600.0**
     (3D) away the bare code 4, not found 0;
   - the target must be a PC (else 3);
   - `CParty::CheckTargetAvailable` refuses `0x2c06` locked, 3 not alive/dead, `0x2c12` or
     `0x2c18` already in a party, `0x2c1f` invite pending, `0x2c25` listed in party matching,
     `0x2c28` battle-arena opponent.

   A refusal is `0xb060 [2][code]`. Otherwise `Party_SendFormationInvitation` opens a
   `trs_wait_response` of kind 2 and sends `0x3080 [2][inviter id][flags]` to the target.
3. The invitee's client (`c:0x88aa60`, kinds 2 and 3 at `c:0x88ad8a`, jump table `c:0x88b1d4`):
   - auto-declines when its "accept party invitations" option is off (option byte `+1` of
     `FUN_004f9d00`): `0x3080 [2][0x2c0c]` for kind 2 (`c:0x81cd20`), `[2][0x2c17]` for kind 3
     (`c:0x81cef0`);
   - **silently drops the invitation unless the inviter is spawned in the invitee's client as a
     player** (`c:0x88ae1c cmp edi,ebx; je`, `c:0x88ae2b call 0xb94b90` with class `0xef1bc0`,
     `je`). Nothing is answered, so the server times out after 30 s and both sides get `0x2c10`;
   - otherwise queues HUD request kind 6 (`c:0x6ec5d0`, a 308x160 popup) carrying the inviter's
     name and the flags repacked as `anyone<<2 | exp<<1 | item`. The popup is `party_gui.md` §1b.
   READ (review of round 709).
4. The answer `0x3080 [1][1]` or `[2][code]` reaches `gs:0x46cb30` -> `gs:0x5be350`, which
   tests in this order (round 710's second review; the codes are register arguments, read in asm):
   - a vanished inviter gives `0x2c0e` (`0x5be45b`);
   - an invitee not found gives 3 (`0x5be46f`);
   - an invitee whose state byte is not 1 gives 2 (`edx = 2` at `0x5be370`, `0x5be474`);
   - only then the answer: a decline gives `0x2c0c` (`0x5be420`);
   - a failure to post gives 2.

   **Which byte declines.** The answer byte reaches `0x5be350` in `AL` (`gs:0x46cbef` reads one
   u8). A join (kind 3) accepts on `cmp bl,1; jne` (`0x5be39f`), but a formation (kind 2) accepts
   on `test bl,bl; jne` (`0x5be41c`). So with this GameServer any non-zero byte forms the party,
   the stock client's "no" (`[2][0x2c0c]`, `c:0x81cd9b`) included: READ, and a bug in this
   private-server build or a 0 the client never sends. **OURS (round 710): OpenSRO accepts only 1,
   for both kinds** (`party.DecodeAnswer`).

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
   - `IsWithinInteractionRange`: 3 / 4 (600.0, 3D) / 0, as above;
   - PC check;
   - `CheckTargetAvailable`;
   - `Party_SendInvitation` (`trs_wait_response` kind 3): `0x3080 [3][inviter id][flags]`. If it
     cannot post the wait transaction it returns 2, and that refusal goes out as **`0xb060
     [2][2]`**, not `0xb062` (`gs:0x5146bb`).
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
  member: kick if I am the leader, leave otherwise (READ).
- **"Dismiss" is leave.** The leader-row button (`c:0x6d5a00 -> jmp 0x81cad0`) sends `0x7061`.
  A party of 3 or more is therefore **not** disbanded by its leader's Dismiss: leadership passes
  on. Only a party of two dissolves (`sm:0x44f5c1 cmp eax,2 -> 0x44eb30`). There is no disband
  message; an implementation must not invent one (READ, review of round 709).
- **The kick target is member-list index row + 1** (`c:0x6d5a6b add esi,1; push esi; call
  0x992380`, then `[eax+0x3c]`, the JID). It assumes the leader is member 0 of the list that the
  quick-party drag reorder (`c:0x992490`) changes. READ; an implementation keeps the leader at
  index 0 of that list.

### Party matching

- **Register** `0x7069`. GameServer checks, `gs:CParty::CheckCanCreateForMatch 0x514170`:
  - `0x2c09`: locked or not alive;
  - `0x2c26` (`JOBITEM_WEAR_ERR_PARTYMATCH`) when `chardata+0x13` is non-zero (`gs:0x514196`).
    What `+0x13` holds is OPEN. It is **not** the worn job suit: the job state the purpose table
    needs (`+0xf`) is derived from that suit (`gs:0x4e124e..0x4e12cc`), so if `0x2c26` meant "a suit
    is worn" no trade or thief listing could ever be registered (review of round 709);
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

  An error reaches the requester as `0xb06d [2][code]` through the relay error path. The client's
  error branch calls `c:0x778190`, which takes child `0x44` (`GDR_SYSTEM_MESSAGE_VIEW`,
  `c:0x778192 push 0x44`) and jumps to the code-to-text table at `0x7b8b40`: the refusal is drawn
  in the **bottom-right system message window**, the "refused, and it says why" the user
  described. READ (review of round 709).
- Otherwise the ShardManager marks the entry busy and relays `0x706d` to the leader with a
  **15.0 s** timeout (the float at `sm:0x79b018`, stored at the transaction's `+0x2c` by
  `sm:0x4206f0`; the tick `sm:0x421de0` adds GetTickCount ms / 1000.0 to `+0x30` and fires past
  `+0x2c`: seconds, READ). The requester's client shows the joining progress window, a **10 s
  bar that is display only** and closes itself (`c:0x7322e0`; `party_gui.md` §5).
- **Two timers, and the client's decides** (review of round 709):
  - the leader's popup arms timer 1 at **10 s** (`c:0x7406de push 0x2710`). When it fires,
    `c:0x73fb70` sends `0x306e [job][requester][2]`, so with a stock client the leader's own
    client answers "no reply" after 10 s;
  - the ShardManager's 15.0 s is the **backstop** for a leader client that never answers. Its
    timeout gives the same answer 2 (`sm:0x420e10`, job opcode `0x706d`, `0x44fbe0(.., 2)`).

  So "no reply" (`0xb06d [1][2]`) normally reaches the requester about 10 s after the request.
- The leader answers `0x306e [job][requester][answer]` (`sm:0x420e50`).
- Results (`sm:0x44fbe0` -> GameServer kind 0x11 -> `0xb06d`):
  - answer 0: the requester gets `[1][0]`, "refused";
  - answer 2: `[1][2]`, "no reply";
  - answer 1: if the leader has no party yet, a party is created with the entry's flags and the
    leader first (`sm:0x44e9c0`); otherwise the requester is added (`sm:0x44e140`). Then two
    `0xb06d [1][1]` sends, READ in two cases (round 713): for a **party-less entry**
    (`sm:0x44ffb3..0x4500a1`) both carry the **requester's** JID (`[ebx+0x78]` at `0x44ffc6` and
    `0x45003d`); the second goes to the leader's GameServer (`0x450081`), which finds the requester
    by JID, so with one GameServer the requester gets it twice and the leader none. For an **entry
    with a party** (`0x450333 mov ebx,[esp+0x10]`) the second copy is the leader's.
    The usual `0xb060`/`0xb067` acks, kind 2 and `0x3065` follow (kinds 0xf / 0x10);
  - an accept that fails gives `[2][code]` (`0x2c0f`, `0x2c1c`, `0x2c0d`, `0x2c12`-`0x2c14`), to the
    requester and then the leader (`sm:0x44fe3b`).
- **The answer is authorized** (round 713): `sm:0x421ec0` requires the echoed requester JID to be
  the job's requester (`0x421f3f cmp [ebx+0x8],esi`); a mismatch is dropped with no reply.
- **Change** (`0x706a`) looks up the entry number the request names (`sm:0x4513c0`): not found is
  `0x2c1c`, another owner's entry `0x2c1d` (round 713).
- **Expiry** (round 713): every 60 s (`sm:0x40c703` 60 000 ms timer -> `0x40dd10` -> `0x4504c0`) an
  entry with no pending request whose age `(now - entry+0x30)/60` is over 60 whole minutes
  (`cmp eax,0x3c; jle` at `0x45055c`) is deleted. The engine sends `0x386f [owner JID]` to the
  owner's GameServer, which has no case for it, so the client is never told.
- **A party fill does not remove an entry**: `sm:0x451490` has three callers only (dissolve, delete,
  the sweep). The leader's client deletes it.
- **Auto match** has no opcode of its own. The client sends `0x706d` to successive entries
  (`c:FUN_00786e70` calls the `0x706d` sender) and continues after each refusal or no-reply
  (`c:0x8847d0`, `UIIT_MSG_PARTYMATCH_AUTO_PROGRESS`/`_FAILURE`). READ that the loop is
  client-side; how it steps is lane party709c's.
- **Whisper** in the match window is ordinary whisper chat (INFERRED; lane party709c).

### Job rules (the "user mismatch" refusals)

`GetJobState` (`chardata+0xf`): 1 trader, 2 thief, 3 hunter (the labels `jobs.md` reads for the
same slot), **4 = not in job mode, and 0 is not a valid value**. READ in all three binaries
(review of round 709):
- GameServer: `Party_UserMatches 0x5bf240` handles 1..4 only (`add eax,-1; cmp eax,3; ja` → the
  assert `0x964b60`, then refused); the character initializer writes 4 (`gs:0x4de3eb`); the worn
  job suit in equipment slot 8 sets 1/2/3 (`gs:0x4e124e..0x4e12cc`). The party name selection
  (`gs:0x5bae80`), guild creation (`guild.md`) and teleports (`teleport_network.md`) all test
  `!= 4`.
- ShardManager: `sm:0x44ed20` and `sm:0x44f7f0` use the same 1..4 tables.
- Client: the player's job byte (`+0x50d`) is worked out from the item in equip slot 8
  (`c:0x9dbcc0` → `c:0x9db8b0`): empty → 4, TID mask `0xf800 == 0x1800` → 3, TID4 = 1 → 1, TID4 =
  2 → 2, anything else 4. The reset writes 4 (`c:0x9d2d97`); the setter is `c:0x9c7a50`.
  `c:0x986f60` sets the party's `*name`/no-guild flag to `job != 4` (`c:0x986f96`).

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
| `0x2c06` | `UIIT_MSG_PARTYMATCH_ERROR_BUSY` (the party category's direct compare, `c:0x7b96ae`; round 711's review) |
| `0x2c07` | `UIIT_MSG_PARTYERR_OUT_OF_LEVEL` (plus a call to `0x77b580`, `c:0x7b9719..0x7b9742`) |
| `0x2c11` | `UIIT_MSG_PARTYERR_CREATER_LEFT_PARTY` |
| `0x2c29` | `UIIT_MGS_ARENA_ERR_FREGIST_PARTY_IN_BATTLE_ARENA` |
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
| 2, 3, 4, 5 | `UIIT_MSG_PARTYERR_UNKNOWN_ERROR`, `_INVALID_TARGET`, `UIIT_STT_ERR_COMMON_TOO_FAR`, `UIIT_MSG_PARTYERR_UNKNOWN_OPERATION` (corrected in round 711's review: every party ack calls `0x778190(2, code, ...)`, the error dispatcher `0x7b8b40`'s party category, whose table `c:0x7bb7cc` names codes 2..5; `0x7bb7dc` covers `0x2c07..0x2c29`). Codes `0x2c09, 0x2c0b, 0x2c15, 0x2c16, 0x2c19, 0x2c1a, 0x2c20..0x2c22, 0x2c27` go to `0x7b913a` and show nothing |

## Timers

| what | value | evidence |
|---|---|---|
| invitation wait (`0x3080` box) | 30 s | the float `gs:0xb45b48` stored at `trs_wait_response+0x1c` by `gs:0x46c7e0` (`gs:0x46c817`); the GameServer's transaction tick `CMainProcess::FUN_0046f1e0` adds GetTickCount ms / 1000.0 to `+0x20` and fires OnTimeout past `+0x1c`. Seconds, READ (`party_rules.md`, verified by the rules review) |
| party-match join request, the leader's client | **10 s**, then answer 2 | `c:0x7406de push 0x2710`; `c:0x73fb70` sends `0x306e [..][2]`. READ. This is what decides with a stock client |
| party-match join request, the ShardManager | 15 s, backstop | `sm:0x79b018` = 15.0, stored at `+0x2c` by `sm:0x4206f0`, ticked by `sm:0x421de0` (ms / 1000.0). Seconds, READ. Fires only when the leader's client sends nothing |
| the requester's join progress bar | 10 s, display only | `c:0x7322e0`: 200 ms ticks, `elapsed / 10000.0` (`c:0xdb3720`); fills and closes itself. The result arrives separately as `0xb06d` |

## Gap list: OpenSRO today

| area | OpenSRO | retail |
|---|---|---|
| opcodes | `session/party.go` and `client/scripts/net/party.gd`: `0x0080`..`0x0089` (create, join, leave, member joined/left, info), all OURS | everything in the opcode table above. **None of OpenSRO's party messages is retail.** |
| payloads | names as strings and 64-bit character ids; create/leave send the character name | JIDs (u32), world object ids, the masked member record |
| invitation | none: `Join(partyID)` joins directly by party id | `0x7060`/`0x7062` -> `0x3080` box -> answer -> `0xb060`/`0xb062`/`0xb067` -> `0x3065`/`0x3864` |
| party types | none: EXP is shared unconditionally, cap 8 (`party.go` MaxSize; `MaxSizeNotShared` unused) | flags byte: exp share (cap 8/4), item share, anyone may invite |
| leader rules | creator level 5 (`CanCreate`) | the same, plus: leader-only kick; leadership passes to the oldest member; a party of 2 dissolves when one leaves |
| member updates | none | `0x3864` kind 6 with the masked record (HP/MP tenths, level, position, guild, masteries) |
| party matching | none | `0x7069`..`0x706d`, `0x306e`, the `0xb069`..`0xb06d` replies, paging, job and level gates, the join request (leader client 10 s, server backstop 15 s) |
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
| `jobs.md` | slot 71 is `GetJobType` with "0 no job" | **Wrong for this slot** (resolved by the round-709 review): the job state runs 1..4 with **4 = not in job mode**, and 0 is not a valid value (GS `0x5bf240` asserts on it; SM `0x44ed20`/`0x44f7f0`; client `0x9db8b0` returns 4 with no job item). See "Job rules" |
| `party.md`, "The invite ladder" step 5 | "the target is within **`0x26` = 38** of the caller" | `0x26` is a TypeID filter (mismatch 3). The range is **600.0** for a PC target, 320.0 by default, 3D; out of range is the bare code 4 (Identifiers, above) |
| `party.md`, "Party matching", and this page's first draft | "`0x2c26`: a job item is worn" | `0x2c26` is refused when `chardata+0x13` is non-zero; what that byte holds is OPEN, and it is not the worn job suit (Party matching, Register) |

## OPEN, and what each one blocks

Closed by the round-709 review: purpose values 0/1 (READ, 0 combat, 1 quest), the two timeouts
(seconds, READ; the leader client's 10 s decides), the join bar's duration (10 s), and where the
client draws a server refusal (the system message window). The client-side search and auto match
are READ in `party_gui.md` §3. What is left:

1. **The `0x3068` gold branch**: the client reads 8 bytes, this GameServer writes 4. **OURS: send
   8**, because the client is the retail consumer and a short message would make its read run past
   the end. Not a recovery; a decision recorded as such.
2. **The list entry's second u32** (`entry+0x30`): **READ as `_time32` seconds (round 713)**. Only
   the client's use is OPEN: it stores it at `+4` and no use was found. Send the registration time.
3. **The second byte of the `0x3080` "yes"** (`[1][1]`). This GameServer does not read it. Send it as
   the client does.
4. **How often a position update (`0x3864` kind 6, bit `0x20`) is sent**: the callers are known, the
   cadence is not.
5. **How the client links a party member (JID) to a world object** for selection, distance and the
   portrait. The client looks members up **by name** for click-to-select (`party_gui.md` §7,
   `c:0x9c3640`) and by id for buffs (`c:0x9c35e0`); which id space that second lookup uses
   against OpenSRO's spawns is for lane C3 to settle.
6. **Handler 0x06f's sender** (no client sender exists; harmless to leave unimplemented).
7. **Logout and server migration**: the client shows reasons 1 and 3; the GameServer paths that
   send them were not read (`party_rules.md` reads the call sites as world exits, INFERRED).
8. ~~**Where the client's member "max" HP/MP slots come from**~~ **CLOSED (round 710's second
   review, client asm).** A full record (kind 2 `c:0x886b88`, `0x3065` `c:0x883e87`) stores the HP
   and MP nibbles raw with a max of 10 each (`push 0xa; push 0xa` before `0x99a2e0`): n/10. A
   kind-6 update calls `c:0x991f60(jid, hp, 10, mp, 10)`: an HP nibble of 0 sets the dead flag
   (`+0x60 = 1`) and HP 0; any other n gives HP (n-1)/9 (`c:0x991fd1 lea ecx,[ebx-1]`, `lea
   edx,[ebp-1]`); MP is n/10. So the update's `1 + trunc(10 r)` is a 0-means-dead encoding, and a
   full bar (11) reads 10/9. Whether the gauge clamps above 1 was not traced.

## Implementation lanes

Written by the round-709 fix-up pass against the code at `dev` `cae9bf45`. The lanes build against
the three round-709 docs. A lane that needs a value still OPEN leaves it out and says so, as the
hard rules require. **OURS** marks this plan's own choices.

### Ground rules for every lane (OURS)

- **Retail opcodes and layouts, on OpenSRO's game connection.**
  - Round 708 put the first retail opcodes (`0x3017`/`0x3019`/`0x3018`) on that connection beside
    OpenSRO's own; the party moves the same way.
  - OpenSRO's `0x0080`..`0x0089` party messages and the debug party panel are retired, not kept
    beside the retail ones (`feedback_match_retail_opcodes`).
  - Party chat moves when chat does. It stays on `ChatParty` over OpenSRO's current chat messages,
    with the original's delivery rule: members only; the sender gets the line back and its client
    drops it.
- **Ids.**
  - The member id on the wire is a u32 JID: one stable value per online character, the same in
    every party message.
  - The invite target is the u32 world id of the player the client selected.
  - OpenSRO's players are still spawned with OpenSRO's own messages and carry 64-bit character
    ids. So lane S1 fixes one u32 per online character, used both as the JID and as the id the
    client selects a player by (OURS, recorded in S1's round).
  - NPCs keep their own range from `npcspawn.UIDBase`.
- **One codec per side, shared by every lane.**
  - Covered: the member record (mask byte; used by `0x3065`, `0x3864` kinds 2/6 and the `0x706d`
    popup), the party-match entry, and the list entry. Each gets one encoder and one decoder.
  - Go goes in `server/internal/party/wire.go`; GDScript goes in `client/scripts/net/party.gd`.
  - Both are tested against the **same golden byte fixtures**, built from this page's tables, so
    the two sides cannot drift.
- **Live tests: several characters against one `--server`.**
  - `qa_shot.sh` stops every client on the box before it starts, so a second Godot client cannot
    run beside it today.
  - The other side is driven by a **Go bot client** (OURS, `server/cmd/partybot`, built in S1). It
    logs in, invites, answers, leaves and kicks on the real wire.
  - Lane C1 also extends the QA runner to start two clients in one run, for the pictures the user
    sees (OURS).
- **Perf gate and review.** Every round that changes the world or its drawing runs
  `perf_gate.sh`: C3 certainly, C1 and C2 if they touch World3D's frame. Every round gets an
  adversarial review.

### The lanes

| lane | owns (files) | messages and rules | acceptance | depends on |
|---|---|---|---|---|
| **S1 server core** | `server/internal/party/` (rewritten: flags byte, cap 8/4 by bit 0, leader at index 0, join order, dissolve at two, leader passing, job table, state byte), `party/wire.go` (codecs), `session/party.go` (rewritten), `session/chat.go` (party delivery), `cmd/server/main.go` wiring, new `server/cmd/partybot` | `0x7060`/`0xb060`; `0x7062`/`0xb062`, including the `0xb060 [2][2]` quirk; `0x3080` both ways, with the 30 s timeout and `0x2c10`; `0xb067`; `0x3065`; `0x3864` kinds 1/2/3/6/9. Kind 6 member updates carry level, HP/MP tenths (sent only when a tenth changes), position, guild, masteries and name/model. `0x7061`; `0x7063`. The create ladder (level 5, 600 range, PC target, `CheckTargetAvailable`), the invite ladder and the job rule `0x2c23`. Party chat to members with the sender echoed | Go: golden bytes for every message; the ladder refusal codes in the engine's order; dissolve at two; leader succession; cap 4 vs 8; the job table. Live (QA client + partybot): two characters form a party by invite; a third is refused for the cap or the job; kick and leave send the right reasons; party chat reaches members only | none (first) |
| **S2 sharing and party monsters** | `session/combat.go` (the kill distribution only), `leveldata` (the formulas), `rates` (the additive bonus), `session/grounditem.go` and `grounditem` (round robin, gold split, `0x3068`), `session/nestkill.go`, `cmd/server/nest.go` (arming), `combat` (party-monster factors) | The kill distributor: groups, kill credit, damage share. The exp-share split by level with the 10 %/20 % bonus and the 70 % damping; the free-for-all 3 %; the party-monster halving. SP alongside EXP; the rate bonus (≥ 1.01, additive, SP too); float32 rounding. Item round robin with the `EBX` fallback; the full-inventory refusal `0x18da`; the gold split; `0x3068` with 8-byte gold (OURS). Arming from the share count, and the `PARTYMONSTER_SPAWN` gate for instance worlds. Party monsters: HP ×10 (already done), EXP/SP ×7.5 and the rank factors, attack value ×1.2 | Go: `party_rules.md`'s worked examples as table tests; the round robin with a dead, other-world or distant last candidate; the gold remainder; arming only from exp-share kills. Live: two characters in an exp-share party kill a nest monster and both gain their split; a free-for-all party does not arm | S1 (party flags and members). The slot-332 EXP base stays OPEN: keep today's base and say so |
| **S3 party matching** | new `server/internal/party/match.go` (listings, counter numbers that skip 0, 23-entry pages, the requester's own entry first), new `session/partymatch.go` | `0x7069`/`0xb069`, `0x706a`/`0xb06a`, `0x706b`/`0xb06b`, `0x706c`/`0xb06c`, `0x706d` both ways, `0x306e`, `0xb06d`. The register ladder: `0x2c1b`, `0x2c20`, `0x2c1d`, `0x2c08`, level 5; `0x2c26` is left out while `+0x13` is OPEN. **Round 713:** that list is the ShardManager's half; the GameServer's `CheckCanCreateForMatch` (`gs:0x514170`) runs first: `0x2c09`, `0x2c26`, level 5, `0x2c24`, then `0x2c0a` (no party) or `0x2c1d` (in a party), `0x2c28`; then the purpose rule `0x2c23` (`gs:0x5bf2a0` kind `0xa`). The join ladder, in order: `0x2c18`, `0x2c25`, `0x2c1c`, `0x2c13`/`0x2c14`, `0x2c23` twice, `0x2c1e`, `0x2c1f`, `0x2c0e`. The 15 s backstop; the leader's answer; forming a party from a party-less listing with its flags; the listing following a new leader and vanishing with its party | Go: golden bytes; paging at 23 with the requester's entry first; every refusal; the 15 s backstop gives answer 2. Live: one character lists, the other pages, requests and is accepted; a request outside the level range is refused `0x2c1e` | S1 (party hub API, codecs) |
| **C1 client net and party window** | `client/scripts/net/party.gd` (retail codecs and handlers); `net/net_client.gd` (handler registration, signals); the party pane in `ui/hud/hud_main_popup.gd`; a new settings dialog script; the invitation popup; the `CIFCheckBox` and CIFSubFrame-text builders it needs in `ui/ui_builder.gd`. Retires World3D's debug party panel and `OPENSRO_QA_PARTY`, replaced by a retail-path QA hook | `party_gui.md` §1, §1b, §2, §6. The caption with the anyone-invite suffix; the type line and its colours. The leader row and seven rows: race from the model id, guild, HP/MP tenths, the Banish/Leave rule. The Invite/Set/Party match enable rules and the pet-to-owner invite; Dismiss = leave; the kick by row + 1. The settings block that the next create sends. The invitation popup, with the spawned-inviter rule and the auto-decline option. Refusals go to the system message window, type 4 | GD tests on the same golden fixtures as S1; window state tests. Live, with S1: the user's screenshots 01, 05 and 12 reproduced at the same layout | S1's codecs and fixtures (can start in parallel from this page; merges after S1) |
| **C2 party matching windows** | a new matching-window script (`GDR_PARTY_MATCH`); the register/modify, auto-match and delete-confirm dialogs; the leader's join popup; the join progress window; `net/party_match.gd` (OURS file split, registered from `net_client.gd`) | `party_gui.md` §3, §4, §5. 12 rows; the own entry pinned in light blue; the gold selection bar; Race and Purpose **as text** (user decision); level boxes 1..110. Client-side Search; the 2 s Refresh cooldown; the page spin; the enable rules; the job restriction on the objective radio; default titles. Auto match (client-side, up to 10). The popup's 10 s auto-answer 2 and the 10 s bar | GD tests: list fill, the search filter, the enable rules, the popup's timeout answer. Live, with S3: screenshots 02/06/07 (as text), 08 and 09 reproduced | S3 for live tests; C1 for the shared net registration |
| **C3 HUD member boxes** | a new `ui/hud/hud_quick_party.gd` (`CIFQuickPartyWnd`); `hud_player_info.gd` (the yellow self-select glow and the leader flag); `ui/keymap.gd` (Ctrl+2..8); the target hand-off in World3D | `party_gui.md` §7. Slots at 4,137 with the column wrap. The 3D portraits (the PMI's constants). The five-step faraway overlay (exp-share only). HP/MP tenths and the caution effects. The leader flag and two mastery icons. Buffs only for spawned members. The teal select glow following the world target; click-to-select by name. The lock and drag reorder, shown above two members | GD tests: the overlay step by distance; the glow follows the target. Live: screenshots 03, 04, 10 and 11 reproduced. Perf gate | C1 (party state in the client) |

### Shared hot files

- **`server/internal/session/party.go`** belongs to S1. S3 adds `session/partymatch.go` and reaches
  the party only through `party.Hub` methods that S1 publishes first. S2 does not touch
  `party.go`; it reads the party through the hub.
- **`server/internal/session/combat.go`** is S2's alone (the kill-reward block). S1 changes no line
  there except what removing `inPartyWithOthers`'s callers forces, and coordinates that with S2.
- **`server/cmd/server/main.go`**: wiring lines only, one block per lane. Merge conflicts there are
  resolved by keeping both blocks.
- **`client/scripts/net/net_client.gd`**: C1 adds the party handlers and a one-line hook through
  which C2's `party_match.gd` registers its own. C2 touches nothing else there.
- **`client/scripts/ui/hud/hud_main_popup.gd`** is C1's alone (the party pane). The matching
  window is a separate top-level window (C2).
- **`client/scripts/World3D.gd`**: C1 removes the debug party panel and the old QA hook; C3 adds the
  target hand-off. Keep each to its own functions; the QA-hook doc block merges.
- **`docs/WORLD_ISSUES.md`**: lanes write `docs/rounds/<lane>.md`; the coordinator numbers and
  inserts them.

### Order

1. **S1** and **C1** start together. C1 builds against the golden fixtures and merges after S1.
2. **S2** and **S3** start once S1 has merged. **C2** and **C3** start once both S1 and C1 have
   merged.
3. Release after each pair the user can see working: S1+C1, then S3+C2, then S2+C3.
