# Round 709 review: `party_protocol.md` and `party_gui.md` (adversarial)

Scope: `docs/protocol/party_protocol.md` (lane party709a) and `docs/protocol/party_gui.md` (lane
party709c). `party_rules.md` was read only for cross-checks. Every finding below was checked against
the binaries on the render box: `/var/tmp/sro_client.asm` (client), `/var/tmp/srgs.asm`
(GameServer, md5 equal to the package's `SR_GameServer.exe`), and a fresh `objdump` of
`SR_ShardManager.exe` (byte-identical to `/var/tmp/party709a/SR_ShardManager.exe`). Constants were
read from the PE images by operand size (`/var/tmp/r709review/rd.py`). Address prefixes:
`c:` client, `gs:` GameServer, `sm:` ShardManager. The spec docs were not edited.

Severity: **WRONG** (states something false), **UNSUPPORTED** (labelled stronger or weaker than the
evidence), **CONTRADICTION** (docs disagree), **MISSING** (absent).

## Findings, most severe first

### 1. WRONG: the invite range is 600 units, not 38 (`party_protocol.md` lines 80-81, 246, 289)

The doc reads the `0x26` passed to `GObjPC::IsWithinInteractionRange` as a range ("range 38"). It is
an object-type filter. The range is a float chosen by the caller's type.

- The caller pushes the word `0x26` (`gs:0x514445 mov WORD PTR [esp+0x14],0x26`; the same at
  `gs:0x514620` for `0x7062`). The target id travels in `EAX`, which Ghidra drops.
- Inside `gs:0x4a8e10` the word reaches `gs:0x4a8d90` with the target's type word. That function
  compares bit fields `(x>>2)&7`, `(x>>5)&3`, `(x>>7)&0xf` and `x>>11`. That is a TypeID match:
  `0x26` means character/player. A mismatch returns **3** (`gs:0x4a8eb2 mov ax,0x3`).
- The distance threshold: `gs:0x4a8eea fld [0xb460dc]` = **320.0** by default; when the caller's
  vslot `0x1c` returns 1 (a PC), `gs:0x4a8f00 fld [0xb46198]` = **600.0**. Other caller types load
  300.0, 1500.0, 800.0, 10.0 or 500.0.
- The distance is 3D: positions `+0x88/+0x8c/+0x90` of both objects through the region-aware delta
  `gs:0x430ba0`, then a sum of squares and `sqrt` (`gs:0x405250`).
- Out of range returns **4**: `fcompp; test ah,5; mov eax,4; jnp` (`gs:0x4a902f..0x4a903b`). In range
  returns 1. "Not found" or the different-world test returns 0 (`gs:0x4a8e2b`).
- The handler sends any non-1 result as `0xb060 [2][code]` (or `0xb062` for `0x7062`).

**Correction:** "range 600.0 (3D; `gs:0xb46198`, PC caller); `0x26` is a TypeID filter whose
mismatch gives 3; out of range gives the bare code 4." `party_rules.md` already says 600 and is
right. `party.md`'s 38 should be added to the protocol doc's "Corrections to existing records".

### 2. WRONG: the client's job byte is not written "from the wire" (`party_gui.md` lines 102-105)

`c:0x9cd235` is inside the equip-change routine `0x9cd090`. It restores a value saved on entry
(`9cd096 mov al,[esi+0x50d]` ... `9cd235 mov [esi+0x50d],cl`); `0x9ca6a6` is the same pattern. The
real writers are:
- the setter `c:0x9c7a50` (`mov [ecx+0x50d],al`);
- the reset `c:0x9d2d97`, which writes 4;
- for the player, `c:0x9dbcc0`: `+0x50d = c:0x9db8b0(item in equip slot 8)`. An empty slot gives 4
  (`9db92d mov al,4`). TID mask `0xf800 == 0x1800` gives 3. `c:0x9c8440` (TID4 = 1) gives 1.
  `c:0x9c8480` (TID4 = 2) gives 2. Anything else gives 4.

**Correction:** cite `0x9c7a50`/`0x9dbcc0`/`0x9db8b0` and drop "the spawn parse writes it from the
wire". The client works out its own job state from the job suit it wears.

### 3. CONTRADICTION, resolved: "no job" is 4, not 0 (`party_protocol.md` line 516; `party_gui.md` OPEN 2; `jobs.md`)

Three binaries agree that job state runs 1..4, with **4 = not in job mode**, and that 0 is not a
valid value:
- `gs:Party_UserMatches 0x5bf240`: `add eax,-1; cmp eax,3; ja -> call 0x964b60` (assert), then
  return 0. Jump table `0x5bf284`: job 1 -> purpose == 2, job 2 -> purpose == 3, job 3 -> purpose
  == 2, job 4 -> purpose not 2 and not 3. `sm:0x44f7f0` is byte-for-byte the same rule.
- `sm:0x44ed20` (person to person), table `0x44ed58`: job 1 or 3 -> the other is 1 or 3; job 2 ->
  the other is 2; job 4 -> the other is 4.
- The client: `c:0x9db8b0` returns 4 with no job item (finding 2). `c:0x986f60` sets the
  `*name`/no-guild flag to `(job != 4)` (`986f96 cmp al,4; setne al`). The register dialog tests 1,
  3 and 2 (`c:0x73f96a`, `0x73f97e`, `0x73f992`).

**Correction:** the protocol doc's line 516 should say that `jobs.md`'s "0 no job" is wrong for
this slot. The GUI doc's OPEN 2 is closed: the client and server enums are the same (1 trader,
2 thief, 3 hunter, 4 none).

### 4. CONTRADICTION, resolved: the join-request timeout (`party_protocol.md` lines 380-384, 483, 532; `party_gui.md` line 365; `party_rules.md`)

The two numbers belong to two different timers. Neither doc is wrong about its own number, but the
protocol doc's flow and Timers table leave out the timer that normally decides the outcome.

- **The leader's client answers for the leader after 10 s.** The popup sets timer 1 at `0x2710` ms
  (`c:0x7406de push 0x2710; push 1; call 0xb93320`). When it fires, `c:0x73fb70` sends
  `0x306e [job][requester][2]` (`73fb81..73fb8d push 2; ... call 0x81d210`).
- **The ShardManager's 15.0 s** (`sm:0x79b018`, loaded at `sm:0x44fb15`) is a backstop. If no
  `0x306e` arrives, `sm:0x420e10` (job opcode `0x706d`) calls `0x44fbe0(.., 2)`. That is the same
  answer 2.
- **The requester's 10 s bar is visual only.** `c:0x7322e0`: 200 ms ticks, `elapsed / 10000.0`
  (`c:0xdb3720`); at 10 s it fills and closes on its own. The result arrives later as `0xb06d`.

With a stock client, "no reply" (`0xb06d [1][2]`) arrives about 10 s after the request. 15 s is
reached only when the leader's client never answers. **Correction:** add the leader client's 10 s
auto-answer to the protocol doc's flow and Timers table, and close its OPEN 6 second half ("the
join progress bar's own duration": 10 s). `party_rules.md`'s "times out after 15.0 s" is true of the
ShardManager only.

### 5. CONTRADICTION, resolved: the purpose enum (`party_protocol.md` line 202 and OPEN 2)

The protocol doc lists 0 and 1 as OPEN. The rules doc (0 combat, 1 quest, 2 trade, 3 thief) and
the GUI doc (Hunting, Quest, Trade, Thief, then All) agree, and the client settles it:
- The register OK handler stores the objective radio's index as the purpose byte, unmapped:
  `c:0x73f370`: `push 0x28; call 0x8b51f0; call 0x657a10; mov [esp+0x49],al`.
- The radio's items are, in order, `UIIT_CTL_PARTYMATCH_PSEARCH_OBJECTCOMBAT` (shown as "Hunting"),
  `UIIT_STT_QUEST`, `_FIND_OBJECTTRADER`, `_FIND_OBJECTTHIEF` (`c:0x73f820`). The label table
  `c:0x740910` / `0x740a2c` maps 0..3 the same way.
- "All" exists only as index 4 of the search combo (`c:0x73b12e push 4`). The client-side filter
  skips the purpose test for it. It is never sent.

**Correction:** purpose 0 = combat ("Hunting"), 1 = quest, 2 = trade, 3 = thief (READ). OPEN 2 is
closed.

### 6. WRONG (count): the GameServer writes five `0x706d` fields, not six (`party_protocol.md` line 171)

`gs:0x5c2db0` writes u32 `[+0]` entry number, u32 `[+4]` mastery 1, u32 `[+8]` mastery 2, u8
`[+0xc]` job state, then the record with mask `0xff` (`gs:0x5c2db4..0x5c2dfb`). The ShardManager
relay `sm:0x422230` writes u16 opcode, u32 target, u32 `job+4`, u32 `job+8` (call site
`sm:0x421307..0x421318`). The GameServer `0x7c00` handler strips the opcode and target. The client
gets 4, 4, 4, 4, 4, 1 and the record (`c:0x8846b8..0x88471c`), so the layout in the table is right;
only "the last six" is wrong. **Correction:** "`gs:0x5c2db0` writes the last five (entry, m1, m2,
job state, record)".

### 7. MISSING: `0x7062` can be refused on `0xb060` (`party_protocol.md` opcode table line 154, flow lines 286-292)

In `gs:CParty::CheckCanJoin 0x514560` the failure of `Party_SendInvitation 0x5be2f0` (code 2: the
wait transaction could not be posted, `gs:0x5be33c`) is sent with `gs:0x5146bb mov ecx,0xb060;
call 0x4e7250`, which is `0xb060 [2][2]`. Range, type and availability failures go out on
`0xb062` (`gs:0x51465e`). The table row's "`0xb062` ... (errors only)" hides this.
`server_handlers.tsv` already lists `0x062` as replying on `0xb060,0xb062`. The quirk is retail
behaviour to copy as is, or an OURS decision to fix. Either way it should be written down.

### 8. MISSING: the invitee's invitation UI (`party_gui.md`, whole doc; `party_protocol.md` flow step 3, lines 254-256)

The GUI doc never describes what the invitee sees. `c:0x88aa60` is a `0x3080` handler shared by
request kinds 1..10 (jump table `c:0x88b1d4`); kinds 2 and 3 go to `c:0x88ad8a`:
1. It reads the flags byte and auto-declines when option byte `+1` of `0x4f9d00` is 0 (kind 2
   calls `0x81cd20`, kind 3 calls `0x81cef0`).
2. **It silently drops the invitation unless the inviter is spawned in the invitee's client as a
   player** (`88ae1c cmp edi,ebx; je`, `88ae2b call 0xb94b90` class `0xef1bc0`, `je`). The server
   then times out after 30.0 and both sides get `0x2c10`.
3. Otherwise it queues HUD request kind 6 (`c:0x6ec5d0`, a 308x160 popup for kind 6) with the
   flags repacked as `anyone<<2 | exp<<1 | item` and the inviter's name.

**Correction:** add a GUI section for the invitation request: the request-queue entry, the
spawn requirement, the auto-decline option, and Yes/No -> `0x81cc30`/`0x81ce00` and
`0x81cd20`/`0x81cef0`. Its text keys and any timer of its own are OPEN. The protocol doc's step 3
should mention the silent drop.

### 9. UNSUPPORTED, now READ: which server field holds the `0x3080` flags (`party_protocol.md` line 155)

The doc labels it INFERRED. It can be read:
- `gs:0x5be2a5` and `gs:0x5be311` load the flags into `EDI` (`movzx edi,BYTE PTR [esp+..]`).
- `gs:0x4ea0d0` stores `EDI` at `trs+0x34` for kinds 2, 3 and 7 (jump table `gs:0x4ea1cc` ->
  `gs:0x4ea150 mov [esi+0x34],edi`).
- The writer `gs:0x46c8e0` sends `[u8 +0x28 kind][u32 +0x2c inviter world id]`, then for kinds 2/3
  `[u8 +0x34]` (`gs:0x46c986`, `0x46c9a3`).

The kind-3 transaction also holds the party id at `+0x24` (`gs:0x5be305`), which is not sent.

### 10. UNSUPPORTED, now READ: the leader popup's "second id" and "kind byte" (`party_gui.md` line 332, OPEN 4)

`c:0x884660` passes (job id, requester JID, struct) to `c:0x7403f0`, which stores `+0x7b8` job id,
`+0x7bc` requester JID, `+0x7c0` entry, `+0x7c4`/`+0x7c8` masteries, `+0x7cc` the u8 job state and
`+0x7d0` the record (`740425..740462`). The answers send `0x81d210(+0x7b8, +0x7bc, code)`. The
guild line shows only when `+0x7cc == 4` (`c:0x74064d`), that is, when the requester is not in job
mode. The popup's mastery icons come from the `0x706d` mastery fields (`+0x7c4/+0x7c8`), not from
the record's. **Correction:** close OPEN 4 with this, and rename the "kind byte" to "job state".

### 11. UNSUPPORTED, now READ: smaller INFERRED labels that the binaries settle

- `party_gui.md` lines 104-105: "+0x0c marks a job-mode party" is READ: `+0x0c = (job != 4)`
  (finding 3).
- `party_protocol.md` lines 377-379 and `party_gui.md` lines 376-377: server refusals are drawn in
  the bottom-right system message view. The `0xb06d` error branch calls `c:0x778190`, which takes
  child `0x44` (GDR_SYSTEM_MESSAGE_VIEW, `778192 push 0x44`) and jumps to `0x7b8b40`.
- `party_gui.md` OPEN 3 (whether HP/MP arrive as values or as ratios): the wire carries only the
  tenths byte. That is READ on both sides (`gs:0x470c16`, `c:0x883684`, size 1). The client splits
  the byte into the member object's HP and MP slots at `c:0x99a34b..0x99a36a` (`and ecx,0xf` /
  `shr eax,4`). So the `+0x44/+0x48`, `+0x4c/+0x50` ratios the window draws are tenths. Where the
  "max" slots come from was not traced.

### 12. MISSING (minor), implementation-relevant details

- `party_protocol.md` flow step 2 (line 245): `0x7060` targeting oneself returns silently with no
  reply (`gs:0x514438 cmp eax,[edi+0x8]; je 0x5144cb`). The doc says this only for `0x7062`.
- `party_gui.md` lines 273, 280, 283: Join, Refresh and the page-0 request on opening run only when
  the HUD request queue is empty (`c:0x6ec4b0(..) == 0` in `0x739500`, `0x732a80` and
  `0x73ae90`).
- `party_gui.md` line 167: for the leader, "Dismiss" sends `0x7061` leave (`c:0x6d5a00 -> jmp
  0x81cad0`). A party of 3 or more is not disbanded: leadership passes on. Only a party of two
  dissolves (`sm:0x44f5c1 cmp eax,2 -> 0x44eb30`). The implementation must not treat Dismiss as a
  disband message.
- `party_gui.md` line 168 / `party_protocol.md` line 322: a row's kick target is member-list index
  row + 1 (`c:0x6d5a6b add esi,1; push esi; call 0x992380`, then `[eax+0x3c]`). It assumes the
  leader is member 0 of the list that the quick-party drag (`0x992490`) reorders.
- `party_gui.md` line 446: the five thresholds are a mix of floats and doubles. `0xda98fc`,
  `0xda9908` and `0xda990c` are floats; `0xda9900` (490000) and `0xda9910` (1e6) are doubles. This
  is why `0xda9904` is skipped. The values are right.

### 13. Noted, not a finding

- `0x7067` appears in the GameServer's `RegisterValueListFilters` list next to `0x7060..0x7063`
  (`gs:0x427f0d`). It has no dispatch handler (index 0x067 is absent from `server_handlers.tsv`)
  and no client sender (sweep below). The protocol doc's claim that there is "no change-type or
  change-leader message" still holds. The doc could mention the filter entry so nobody re-derives
  it.
- `0x3068`, the gold branch: confirmed exactly as the doc says. Both sides apply the same
  item-class test (`gs:0x42fe10` = `c:0x873a2b..0x873a73`: TID bits `0x1c==0xc`, `0x60==0x60`,
  `0x780==0x280`, `0xf800!=0x800`). The client reads 8 bytes (`c:0x873a75 mov ebp,8; push ebp`).
  The GameServer writes 4 (`gs:0x5bdd1c push edi; mov eax,4`). The recommendation to follow the
  client is a decision, not a finding, and should be labelled OURS.

## Cross-doc summary

| question | protocol | GUI | rules | resolved as |
|---|---|---|---|---|
| join timeout | 15.0 (SM) | 10 s, both windows | 15.0 s | two timers; the leader client's 10 s auto-answer 2 normally decides; the SM's 15 s is a backstop with the same answer (finding 4) |
| invite range | 38 | — | 600 | **600.0**, 3D, PC caller; `0x26` is a type filter (finding 1) |
| purpose 0/1 | OPEN | Hunting/Quest | combat/quest | 0 combat ("Hunting"), 1 quest; All is client-only index 4 (finding 5) |
| no-job value | flags 0 vs 4 | OPEN | — | **4**; 0 asserts in the GameServer (finding 3) |
| `0x3068` gold | client 8 / server 4 | — | — | confirmed as stated; the choice is OURS |
| popup kind byte | job state (u8 6th field) | "kind byte +0x7cc" | — | the same field; 4 = no job -> guild shown (finding 10) |
| member HP/MP | tenths nibbles | "values or ratios?" | tenths | tenths only (finding 11) |

## Completeness sweep

- **Client senders.** `push`/`mov` immediates in `0x7060..0x706f`, `0x3060..0x306f` and
  `0x7080..0x708f` over the whole client asm: `0x7060..0x7063`, `0x7069..0x706d` and `0x306e` only.
  There is no `0x706f`/`0x306f`. `0x7081..0x7084` are the exchange messages (`SendTradeMsg_081`,
  `client_senders.tsv`).
- **Client handlers.** The 219 calls to the registrar `c:0x86f740`, filtered to the party range:
  `0x3068`, `0xb060`, `0x3864`, `0x3065`, `0xb062`, `0xb067`, `0xb069..0xb06d`, `0x706d` and
  `0x3080`. Every one is in the opcode table. There is no `0xb061` or `0xb063`: leave and kick get
  no acknowledgement. The `0x308x`/`0xb08x` handlers are exchange.
- **GameServer.** Party-range immediates: the documented set, plus `0x3064` (a `chkstk` size at
  `gs:0x43d2ce`, not an opcode) and `0x7067` (item 13).
- **User request not covered by either doc:** the invitee's invitation UI (finding 8). Also absent,
  and outside these two docs' stated scope: the party-monster emblem on the target window (only
  the rules doc mentions it), the party chat tab and prefix UI (in `chat.md`), the minimap and
  world-map party markers (noted as out of lane), and the selection ring under a target (general
  targeting).

## Claims verified correct (and how)

`party_protocol.md`:
1. `0x7060` = u32 target id, u8 flags. Client `c:0x81c87c push 4` / `c:0x81c88c push 1`; the flags
   byte is `exp | item<<1 | anyone<<2` from `0x986f50`'s block (`c:0x81c7f0..0x81c82e`). The
   GameServer reads u32 then u8 (`gs:0x5143fb..0x514433`, `0x403f60`/`0x5216c0` and
   `0x521750`/`0x5217a0`).
2. A pet or transport target is replaced by its owner: `c:0x81c782 mov edi,[eax+0xf8]` after
   `0x9ce910`, taken only when the target is not a `CICPlayer` (`c:0x81c741..0x81c74f`).
3. `0xb060`/`0xb062`/`0xb067` errors are `[u8 2][u16 code]`: `gs:Msg_SendTwoFieldReply 0x4e7250`
   writes 1 then 2 bytes. The clients read u8, then u32 on 1 or u16 on 2 (`c:0x880010`,
   `0x8800b0`, `0x880120`).
4. `CheckCanJoin`: no party, not leader without bit 2, and self are silent
   (`gs:0x514590..0x5145c6`). Full is `0x2c13` with bit 0 at 8 members, `0x2c14` without at 4
   (`gs:0x5145cc..0x514611`).
5. The `0x3080` invitation layout (finding 9) and the client reads 1, 4, then 1 for kinds 2 and 3
   (`c:0x88aaa6`, `0x88aab4`, `0x88ad8a`).
6. The `0x3080` answers. Yes is `[1][1]` (`c:0x81cc79 mov ebx,1`, two 1-byte writes). No is
   `[2][0x2c0c]` (`c:0x81cd93`) or `[2][0x2c17]` (`c:0x81cf63`). The auto-decline tests option byte
   `+1` (`c:0x88ad9d`). The GameServer reads one byte (`gs:0x46cbef call 0x404f80`).
7. The server's decline code comes from the transaction kind: `0x2c0c` for kind 2
   (`gs:0x5be420`), `0x2c17` for kind 3 (`gs:0x5be3cf`), plus `0x2c0e`, 3 and 2. They go out as
   `0xb060`+`0xb067` (`gs:0x5be9f0`/`0x5be9fe`) or `0xb062`+`0xb067` (`gs:0x5bea65`/`0x5bea6f`).
8. The timeout is `0x2c10` (`gs:0x46ce44 mov ebx,0x2c10`). The client's `0xb067` handler closes the
   box on `0x2c10` (`c:0x8801a4 cmp ax,0x2c10`, then `0x778b90(6)`).
9. The invitation timer is 30.0 (`gs:0xb45b48`, stored to `trs+0x1c` at `gs:0x46c817`). It is
   correctly labelled INFERRED as seconds.
10. The member record is cross-binary exact (`gs:0x470ba0` against `c:0x883620`): the order and the
    mask bits `0x10, 0x01 (name + RefObjID), 0x02, 0x04, 0x20 (u16 region; 3 x u32 when
    region & 0x8000, else 3 x u16; then u32 world id inside 0x20), 0x40, 0x80, 0x08 (2 x u32)`. The
    u16 coordinates are written x, y, z (`gs:0x470c72..0x470cbf`).
11. The HP/MP divisor is the double 10.0 at `gs:0xb45c60`.
12. `0x3065`: the server writes the party id inside `mask&1` (`gs:0x5bc674..0x5bc6a4`); the client
    reads it before the mask test (`c:0x883d1f` before `0x883d37 test bl,1`).
13. `0x3864` client kinds 1, 2, 3, 6 and 9 (`cmp al` at `c:0x886b66`, `0x886d42`, `0x886f8f`,
    `0x88711f`, `0x8871d0`). Reasons 1..4 come from the table at `c:0x8872e8` with
    `UIIT_MSG_PARTY_LOGOUT`/`_SECEDE`, the debug-only `LEAVE_PARTY_SERVER_MIGRATION` and
    `UIIT_MSG_PARTY_BOOTED`. Kind 1 is `UIIT_MSG_PARTY_BROKEN`, kind 9
    `UIIT_MSG_PARTY_HOST_ROLE_DELEGATED`, kind 2 `UIIT_MSG_PARTY_JOIN`.
14. The server kind writers: kind 1 `[1][u16]` to everyone (`gs:0x5bb68d`, exclude 0); kind 3
    `[3][u32][u8]` (`gs:0x5bc400`); kind 9 `[9][u32]` (`gs:0x5bc56f`); kind 6 `[6][u32 JID][record]`,
    broadcast excluding that JID (`gs:0x5bdc3e..0x5bdc71`).
15. `0x706d` S->C: the client reads 4, 4, 4, 4, 4, 1 and the record; the layout is right (finding 6
    covers only the field count).
16. `0x306e` = u32, u32, u8: client `c:0x81d276`/`0x81d286`/`0x81d296`. Answer codes 1/0/2 from
    the popup (`c:0x73fc68`, `0x73fca6`, `0x73fb8d`).
17. The match entry is exact: client writer `c:0x823c20` (4, 4, 1, 1, 1, 1, then a narrow string:
    a u16 length from the import at `0xd80168` and that many bytes); GameServer reader
    `gs:0x5c2e10`; client reader `c:0x883780`.
18. The `0xb06c` list entry: the writer order is `sm:0x44f640` (u32 `+0`, u32 `+0x30`, name, race,
    count, `+8` flags, `+9` purpose, `+0xa` min, `+0xb` max, title). The client stores race `+8`,
    count `+9`, flags `+0xb`, purpose `+0xa` and levels `+0xc/+0xd` (`c:0x884381..0x8843fe`).
19. Paging: 23 per page (`sm:0x4517ed cmp al,0x17`). A too-large index is clamped to 0
    (`sm:0x450f88..0x450f95`). An empty list is `[1][0][0][0]` (`sm:0x450ef3..0x450f43`).
20. The register success path: `0xb069 [1][entry]` (`gs:0x5bf815..0x5bf83c`); the state byte
    becomes 4 when there is no party (`gs:0x5bf858`); `pc+0x1cd0` takes the entry number
    (`gs:0x5bf861`).
21. The ShardManager's join-request float is 15.0 (`sm:0x79b018`, loaded at `sm:0x44fb15`). Its
    timeout gives answer 2 (`sm:0x420e17 cmp eax,0x706d` -> `push 2; call 0x44fbe0`).
22. `0xb06d`: the client reads u8, then u16 on 1 (`c:0x8847f8..0x88481d`); the GameServer writes
    `[u8][u16]` (`gs:0x5bfb75..0x5bfb9d`).
23. The job tables (finding 3), matching the doc's two-table summary exactly.
24. Party chat: `gs:0x5bef50` writes `0x3026 [u8 4][str][str]` and broadcasts with exclude
    `ebx = 0` (`gs:0x5bef84`, `0x5bf062`). The client's type 4 goes through jump index
    `c:0x878223` = 1 to `c:0x877dc7`. It compares the sender with its own name (`c:0x4e9530`,
    which returns 1 when they are equal) and on a match jumps to the cleanup at `c:0x877f77`,
    dropping its own line.
25. A two-member party is dissolved on removal (`sm:0x44f5c1 cmp eax,2 -> call 0x44eb30`);
    otherwise kind 3 goes out (`sm:0x44f5d8`).
26. `CheckTargetAvailable` codes `0x2c06`, 3, `0x2c25`, `0x2c28` and `0x2c1f` are present at
    `gs:0x514026`, `0x514050`, `0x514090`, `0x514125` and `0x51415a`.
27. The opcode-range sweeps (completeness section): the doc's "client sends only..." and its
    handler list are complete.

`party_gui.md` (checked with a forked reviewer against the client asm):

28. The faraway overlay: thresholds 360000/490000/640000/810000/1e6, all `>=`
    (`c:0x6db4f4..0x6db557`); applied only when exp mode = 1 (`c:0x6db4eb cmp [eax],1`); 3D
    distance (`c:0x9ed1e0`); levels 1..5 map to `_60`..`_100` through jump table `c:0x6d8850`, and
    level 0 clears.
29. Join progress: timer 1 at 200 ms (`c:0x7322b4 push 0xc8`); 10000 ms against the double
    10000.0 (`c:0x73232a`, `0x732343`, `0xdb3720`); at the cap it fills and calls `0x7390b0`.
    Kind 2 (the academy) uses 15000.
30. The leader popup: 10 s (`c:0x7406de`); the timeout sends 2, Confirm 1, Cancel 0.
31. Set is enabled only outside a party (`c:0x6d6620` checks `0x987070`; in a party control 0x15
    is set to 0).
32. Search is client-side (`c:0x73b780`): an exact whole-name `wstring::compare` (`0x47ec20`),
    skipped when the box is empty; purpose unless All; a full level-range **overlap** test.
33. The purpose combo order and default index 4 (`c:0x73b075..0x73b12e`); label table
    `c:0x740910`/`0x740a2c`.
34. Race and Purpose are drawn as text (`c:0x740870`: 0 CHN, 1 EUR; `c:0x740910`), from record
    `+8` and `+0xa`. Type comes from `+0xb` bit 0, Member from `+9`. Name is `+0x10` and is shown
    as `*%s` when the purpose is 2 or 3; Title is `+0x2c`, clipped to 302 px.
35. The max level default is 110 (`push 0x6e` at `c:0x73b030`, `0x73facc`, and four more).
36. The selection textures are named where the doc says (`c:0x740cdd`/`0x740cf6`). The fork
    re-measured the colours from the lane's extracted files: (255,178,82) rows 2 and 21; teal
    (63,164,149)/(81,255,243)/(0,255,229); yellow (255,255,0)/(169,164,77); faraway (14,96,255)
    at α 130..241.
37. The enable rules (`c:0x7384a0`). The Join handler `c:0x739500` makes no level or job check.
    Refresh has a 2 s cooldown.
38. The quick-party board is at 4,137; the y step is 73 or 56 by option `+8`; the column step is
    133; it wraps below 230 (`c:0x6dae90`).
39. Row buttons: Banish for a leader, Leave on one's own row (`c:0x6d7680`); `c:0x6d5a40` kicks
    for a leader and leaves otherwise.
40. The `c:0x986f60` setter, the reset to 4 at `c:0x9d2d97`, Ctrl+1..8 (`c:0x780c21`,
    `0x77f230`), and the lock button shown only above 2 members (`c:0x6db58a`).

**Count: 40 claim groups verified, about 90 individual READ claims checked against the asm.
12 findings: 3 WRONG, 3 CONTRADICTION (all resolved with evidence), 3 UNSUPPORTED (all now
READ), 3 MISSING (item 13 is a note).**
