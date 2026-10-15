# The gateway, as far as the server list (round 681), and OpenSRO's retail listeners (round 788)

The original protocol's exchange between a client and a GatewayServer, from the TCP connect to
the shard list, as the retail client and server run it. Round 681 stopped at the list; round 788
added the login through the AgentServer to the character list, served by OpenSRO's own server to
the ORIGINAL client ("OpenSRO's retail listeners (round 788)", at the end). Plain descriptions only (docs/LEGAL.md policy #2); the security bytes and the
key exchange are in `handshake.md`, "The client's side, READ (round 681)".

Labels: **READ** (`/var/tmp/decomp_client`, `/var/tmp/sro_client.asm`; GatewayServer.exe
disassembled with objdump into `/var/tmp/retailgw681/gw.asm`; SR_GameServer's CNetEngine in
`/var/tmp/decomp_server`; the launcher `silkroad.exe` likewise), **MEASURED** (the render box's
install), **INFERRED**, **OURS**, **OPEN**. Addresses are sro_client's unless named.

Implemented by `client/scripts/net/retail/` (RetailSecurity, RetailGatewayClient,
RetailClientInfo) and `server/internal/retailgw` (the same client in Go, `Probe`, and a fake
gateway, `Server`); `server/cmd/retailgw` runs either.

## The sequence (READ)

| # | Dir | Opcode | Payload | Encrypted | Where |
|---|---|---|---|---|---|
| 1 | S->C | 0x5000 | flags; [2] u8[8] Blowfish key; [4] u32 count seed, u32 crc seed; [8] u8[8] handshake key, u32 G, u32 P, u32 A | no | sent by `CNetEngine::FUN_00965c20` (SR_GameServer's copy of the net engine), read by `ACTIVE_SESSION::_OnMsgReceivedBeforeHandshake` 0x4b1da0..0x4b1e3a and 0x4b3c60/0x4b3eb0 |
| 2 | C->S | 0x5000 | u32 B, u8[8] challenge (12 bytes) | no (`alloc(0)`) | 0x4b1f87..0x4b2073 |
| 3 | S->C | 0x5000 | flags 0x10, u8[8] challenge | no | server branch 0x4b216d..0x4b2207; client check 0x4b1e3f..0x4b1eb1 |
| 4 | C->S | 0x9000 | (empty) | no | 0x4b1e9a..0x4b1f3a |
| 5 | C->S | 0x2001 | string "SR_Client", u8 0 | yes (`alloc(1)`) | `CClientProcess::vslot_010` 0x4ce8c0 |
| 6 | S->C | 0x2001 | string module name, u8 | as sent | read by `CClientProcess::vslot_014` 0x4ce9d0 |
| 7 | C->S | 0x6100 | u8 content id, string "SR_Client", u32 version | yes | 0x4cea72..0x4ceaba (only when step 6 named "GatewayServer") |
| 8 | S->C | 0xA100 via 0x600D | u8 result (1 = go on; 2 then u8 code) | no | GatewayServer 0x4051a0 (handler), 0x4053ab..0x4056f2 (reply); client `CClientProcess::vslot_015` 0x4cf0c0 |
| 9 | C->S | 0x6101 | (empty) | yes | `CClientNet::vslot_002` 0x4c9410 |
| 10 | S->C | 0xA101 | farms, shards (below) | no (`alloc(0)` at GatewayServer 0x405816) | GatewayServer 0x405800 + 0x412c80; client `CClientProcess::FUN_004cda30` via `vslot_016` 0x4cf320 |

- **Which client handler takes which reply** -- READ since round 788: the client's dispatch table
  is a 64K-entry array at process+0x5c filled in `CClientProcess::vslot_002` 0x4ce560 (stubs
  0x4d33c0..0x4d3540, vtable 0xe1b454): 0x2001 slot 14, 0xA100 15, 0xA101 16, 0xA102 17, 0xA103 18,
  0x600D 20, 0xA104 21, 0x2322 26, 0xA323 27 (and 0x1001..0x1006, 0xA004, 0x6902, 0x2F01..0x2F03,
  0x2012, 0x200E, 0x200F, 0x2013); every other opcode goes to slot 7 (0x4ce840), which hands it to
  the current screen. 0xA106, 0x2002, 0x2005 and 0x6005 are not in the table. (Round 681 had this
  INFERRED from what each parser reads.)
- **Encryption is the sender's choice per packet:** the packet allocator `CNetEngine::vslot_018`
  (0x4a0930, the net engine's vtable 0xe1a20c slot 0x48) sets bit 15 of the size word when called
  with 1. The client's handshake replies use 0, its 0x2001, 0x6100, 0x6101 (and 0x6103) use 1.
  GatewayServer's 0xA100 parts and 0xA101 use 0. The reader decrypts whatever has the bit (0x4b0f60).
- **Before the handshake ends only 0x5000 is taken** (READ 0x4b1dd2..0x4b1de6): any other opcode
  logs `_OnMsgReceivedBeforeHandshake` and ends the session (return 0x8010). After it, unknown
  messages are dispatched elsewhere; the implementation passes over frames it does not need (OURS),
  up to 64 frames (OURS).
- **Step 5's timing is INFERRED:** `vslot_010` is the session's connected notification (it reads two
  u32s of an internal message); it is taken to follow the accept, as the public sequence has it.
- **Step 7 needs step 6:** `CClientNet+0x2c` is set to 1 only when the server's identity is
  "GatewayServer" (0x4cea72), and `vslot_002` (0x6101) sends only when it is 1. AgentServer gets
  0x6103 instead (0x4ceb36); DownloadServer the patch path.
- **Step 9 after step 8 is INFERRED from the client's flow:** the title asks for the list (LIST,
  `CPSTitle::FUN_00864870`, and the 5 s refresh) once the A100 handler has reported success to it
  (`FUN_004d0290(1, 0)` when the net mode `CClientNet+0x28` is 2; modes 1 and 3 first send 0x6104,
  0x4cf0c0). The launcher-started client passes mode 2 (0x844ba4, `push 2` into
  `CClientNet::vslot_000`, stored at +0x28). GatewayServer's 0x6101 handler (0x405800) checks no
  session state itself; whether its dispatcher refuses 0x6101 before 0x6100 is OPEN, so the
  implementation keeps the client's order.

## Strings (READ)

A u16 length then that many bytes, no terminator: written by `CClientProcess::FUN_004cc920`
(`lstrlenA`), GatewayServer's 0x40b6b0 likewise; read by `FUN_004d36a0`. Names are the archive's
code page; the implementation keeps the first 64 bytes of a name, shows valid UTF-8 (checked by
hand, so the engine never logs a decoding error) as UTF-8 and anything else as Latin-1, and drops
control characters (OURS; round 681's review: a 32 KB name took 160 ms and printed an error per
byte before).

## 0x6100: what the client says about itself

- **The content id (READ):** the first byte of DIVISIONINFO.TXT. The launcher (`silkroad.exe`)
  opens `DIVISIONINFO.TXT` (0x436faf), reads one byte into 0x4b8f64 (0x4370a7..0x4370b0; it then
  branches on 1 and 6, the same values sro_client's +0x810 picks text folders with) and starts
  `sro_client` with `"%s %s /%d %d %d"` (0x492fd8), the first number that byte (0x4331dd).
  sro_client sscanf's it into CGame+0x810 (0x846b40) and passes the byte at 0xeed690 (CGame+0x810)
  to `CClientNet::vslot_000` (0x844b7e), which stores it at net+0 (sent in 0x6100, 0x6102, 0x6103).
  sro_client's own DIVISIONINFO reader skips the byte (server_list.md). MEASURED on the box: **22**.
- **The module name (READ):** "SR_Client" (0xdd3050), passed to the same init (0x844b8b) and kept at
  net+8.
- **The version (READ, `CGame::FUN_008469c0` 0x846b4e..0x846c52):** Media.pk2's `sv.t` (0xdd3f10),
  at most 0x400 bytes read; the first u32 is a length n; the key is "SILKROADVERSION" (0xdd3f00)
  copied into a 16-byte buffer and given to the Blowfish key schedule with length **8** (so
  "SILKROAD"); `FUN_004aaa20` decrypts ceil(n / 8) blocks from offset 4 (halves little-endian); the
  text is `atoi`'d into CGame+0x7e8 and passed to the net init (0xeed668). MEASURED on the box: the
  plaintext is `1000` and four NULs, **version 1000**.
- The client reads both from the player's archive at run time (`RetailClientInfo`): no value is
  built in. The 8-byte key is a fact READ from the binary and recorded as an interoperability fact
  (docs/LEGAL.md, the facts of policy #2 and the interoperability of #3); unlike pk2's 169841
  (PK2_FORMAT.md) no public source is cited for it, so it is not called "published" here.
- **GatewayServer's checks (READ, 0x4051a0..):** a 0x6100 too short for its three fields logs
  "certificate client module : invalid msg data (0/1/2)" and disconnects; an unknown content id or
  module logs "someone tried to login with unknown client" (0x4d9490); a version above the
  server's logs "client requested higher version ... about to exploit?" (0x4d9508); a gateway not
  in service answers [2, 4] (0x4053c8..0x4053ee); an older version takes the patch path ("can't
  find any available patch server" when there is none). The exact codes: round 788, "0x6100's
  answers" below (the content id turned out to be only logged, not checked).

## 0xA100 arrives as a massive message (READ)

GatewayServer builds the reply with its massive-message writer: 0x41f580 (+0x1c = 1, +0x1d = 0, so
unencrypted), `mov ecx,0xa100` into 0x41f960, appends with 0x41f5d0, sends with 0x41f7d0:

- a header **0x600D** `[u8 1, u16 part count, u16 opcode 0xA100]` (0x41f811..0x41f863);
- then each part **0x600D** `[u8 0, data...]` (0x41f900..0x41f939).

The client's 0xA100 handler reads through `massivemsg::FUN_004d60f0`. Implementation: parts are
gathered under the header's opcode, at most 16 parts and 32 KiB (OURS); a plain 0xA100 is taken too
(OURS). Result 1 = go on; otherwise the second byte is the client handler's switch value (READ:
3 the patch download, 4/5/6 messages; the gateway's "not in service" is [2, 4]). Meanings INFERRED.

## 0xA101 (READ)

Written by GatewayServer 0x405800 and 0x412c80, read by sro_client `FUN_004cda30`:

```
while u8 == 1:   u8 farm id, string farm name
while u8 == 1:   u16 shard id, string name, u16 current, u16 capacity, u8 state[, u8 farm id]
```

- Each loop ends at the first byte that is not 1; the server writes 0. The client stores the entry
  at +0 id, +4 name, +0x20 current, +0x22 capacity, +0x24 state, +0x25 farm (round 679's offsets,
  now with the code that fills them).
- **The farm byte is conditional on both sides.** The server appends it when its own content id
  (`[0x4f9ca8]+2`) is one of 3, 5, 9, 10, 0x15, 0x16, 0x17, 0x1a, 0x1c, 0x22 (0x412d7b..0x412daa) --
  22 is among them. The client reads it when a mode word at `CClientNet+4` (DAT_0115b0c0[1]) is 1
  or 4 (`cmp eax,0x1` / `cmp eax,0x4` at 0x4ce182 / 0x4ce187); no direct writer of that word was found (it is in .bss, and the CClientNet
  methods were searched), so which layout this client reads is **OPEN**. Implementation: the
  server's rule for the client's content id first, the other layout if that does not parse
  exactly (OURS). **Round 788:** the same word gates the client's 0x6106 (0x86c691, READ), and the
  real client MEASURED on the render box sent 0x6106 three seconds after its 0xA100 -- so the word
  is 1 at run time and this client reads the farm byte (INFERRED from the two); it showed OpenSRO's
  one-shard list, sent with the farm byte, as one row.
- **What the server hides and rewrites:** a shard whose entry flag (+0x1c of its record) is 2 is
  left out unless the caller asked for all (an argument the 0x6101 handler passes as 0); a shard
  whose flag is 1 and whose state byte (+0x22c) is 1 is sent with state **0** -- "Check" (0x412d4b..0x412d6a).
- Strict reading (OURS): a loop byte other than 0 or 1, a field past the end, or bytes after the
  last 0 make the list unreadable; at most 64 farms and 64 shards.

## What our client does with it (OURS)

`type: legacy` in `setting/config.yaml`: the server list asks the gateway with steps 1-10 on its own
connection and closes right after 0xA101. Limits: 4 s for the whole question, up to 3 connections
(a session whose checksum table cannot be built, handshake.md, is ended before anything is sent
and tried again), 64 KiB read per connection, frames of at most 4096 bytes, 64 frames. Every
failure is the row's "Closed" with a `SERVERLIST:` log line naming why. `type: opensro` keeps
round 679's 0x0007 question. Details: server_list.md, "Legacy servers".

## OpenSRO's retail listeners (round 788)

OpenSRO's server can open two more listeners that speak this wire, so the original client
(sro_client.exe, vSRO 1.188) logs in to it and reaches its character list: a **gateway**
(`-retail-gateway-addr`) and an **agent** (`-retail-agent-addr`, named to the client by
`-retail-agent-public-host`). Both off unless the gateway address is set; flags in
deploy/README.md, "The original client". Code: `server/internal/retailsrv` (the two handlers),
`server/internal/retailgw` (`ServerHandshake`, `ServerCodec`, `ClientConn`),
`server/internal/gateway` (`Codec`). Addresses are GatewayServer's / AgentServer's /
sro_client's as named.

**Two listeners, because the client makes two connections (READ):** the gateway's 0xA102 names an
agent host and port; the client closes the gateway (engine slot 0x5c) and connects there
(0x4cf500), and what it sends next hangs on the server's 0x2001 name -- "GatewayServer" gets 0x6100
(0x4cea72), "AgentServer" gets 0x6103 (0x4ceb36), compared with the NUL (exact match).

**The framing (OURS: one implementation):** `gateway.Server` takes a `Codec`; the retail one
(`retailgw.ServerCodec`) runs the server's half of the handshake (`retailgw.ServerHandshake`, the
round-681 fake gateway's own code, now shared), checks the client's count and check bytes, decrypts,
and hands the handlers an ordinary `proto.Packet` on an ordinary `*gateway.Session` -- so
`session.LobbyHandler`, `session.LoginService` and the main server's `OnDisconnect` run unchanged.
A server picks its crc seed, so it only picks one of the 218 tables it can build (handshake.md).
Session ids are now unique across listeners (the world hub keys on them). OpenSRO's own listener
is unchanged (no Codec).

### What each server sends (READ unless marked)

| Step | Server sends | Notes |
|---|---|---|
| hello | 0x5000 flags **0x0E** (both servers: engine option bytes gateway 3, agent 2; the hello writer adds 8, 0x46eab0) | key exchange required; the agent takes 0x9000 only after it |
| client 0x2001 "SR_Client" | 0x2001 `[string name, u8 0]` plain (shared net library 0x43f5a0 / agent 0x42c180) | a server sends no 0x2001 first; it answers the client's. Retail then also sends massive **0x2005** `[01 00 01, u16, u32 state 5, 02]` and **0x6005** `[03 00 02 00 02]`: **not sent by OpenSRO (OURS)** -- the client has no handler for either (dispatch table above) and the u16's meaning is INFERRED |
| 0x6100 | massive 0xA100 (0x4051a0, writer 0x41f580..0x41f7d0, frames plain) | "0x6100's answers" below |
| 0x6106 | 0xA106 plain `u8 count, {u8 farm id, u32 IPv4}` (0x405740; the request is not read) | OpenSRO: `[0]`. MEASURED: the real client sends 0x6106 after 0xA100 |
| 0x6101 | 0xA101 plain | OpenSRO: one farm (id 1) and one shard: `-retail-shard-id` / `-retail-shard-name`, current = players in the world, capacity `-max-players`, state 0 "Check" under `-inspection` else 1, farm byte by `FarmByteFor` (OURS: the values) |
| 0x6104 | massive 0xA104 `u8 count, {string subject, string article, 16-byte date}` (0x406380, 0x4013e0) | OpenSRO: `[0]`. The client sends 0x6104 only in net modes 1 and 3; the launcher's mode 2 never does (0x4cf0c0) |
| 0x6102 | 0xA102: a success **encrypted** (alloc(1), 0x405e7d), the 0x6102 handler's refusals plain | below |
| (agent) 0x6103 | 0xA103 **encrypted** on every path, never massive (0x40226a..0x40312f) | below |
| 0x2002 keep-alive | nothing (0x4405c0 / agent 0x42d2a0 discard it) | the client sends it, plain, after 5 s without a send (timer 1666 ms, 0x4cf990), on both connections |
| (agent) 0x7007 / 0x7001 | the shard's 0xB007 / 0xB001, relayed plain (0x2209 stripped, 0x403348) | before 0x6103, dropped unanswered ("unhandled msg received", 0x4315d0) |

Retail's idle limit: sessions swept every 10 s (body+0x54 = 10000), closed past 60 s idle (the
default 0xea60 at 0x43eda0; no override found -- INFERRED). OpenSRO's listeners keep no idle
limit (OURS, OPEN to add).

### 0x6100's answers (READ, 0x4051a0; the client's reading, jump table 0x4cf308, index code-1)

| Case | Reply | The client |
|---|---|---|
| version equals the server's | `[1]` | goes on (mode 2: straight to 0x6101) |
| module unknown, version 0, or version above the server's | `[2, 1]` | "Failed to connect to server.(C4)", quits |
| version below, a patch server known | `[2, 2, string ip, u16 port, u32 version, {u8 1, u32 id, string name, string path, u32 size, u8}..., u8 0]` | downloads (mode 2: `UIO_MSG_ERROR_VERSION`, quits) |
| version below, no patch server | `[2, 3]` | "(C4)", quits |
| not in service (state != 5, peer not on the official list) | `[2, 4]` | "Servers are offline", quits |
| module's own minimum (0x404f30) not met | `[2, 5]` | nothing shown |

The content id is logged, not checked (0x405508); the gateway never disconnects after a refusal
(the client quits). **OpenSRO:** `[1]` for `-retail-version`; above it or 0 `[2, 1]`; below it
`[2, 3]` (it has no patch server, so `[2, 2]` is never sent); a refused client is not given the list.

### 0x6102 -> 0xA102 on the retail gateway

`session.LoginService.Login` decides (the same service OpenSRO's own 0x6102 uses; lane S owns its
rules), with no session: the session that plays is the agent's. A shard id other than
`-retail-shard-id` is `[2, 4]` (READ, 0x40d710). On success the gateway queues the login under a
token -- the account and the ID and password the 0x6102 carried -- and answers
`[1, u32 token, string agent host, u16 agent port]`; the client closes the gateway itself (OpenSRO
does not, so as not to race its read). Token: a random non-zero u32, usable once (OURS; retail's
AgentServer hands out small sequential ids, 0x409a40 / 0x40a510), valid **10 s** (READ: "Token
Timeout!" past 10000 ms, 0x409fc9, swept every 3 s).

**IBUV skipped (OURS):** retail always sends the 0x2322 image after a right password and answers
0xA102 only after a right code. The client's 0xA102 reader checks only the result byte (READ
0x4cf500: token to net+0x38, host +0x3c, port +0x58, close, connect; no IBUV state is read), so
OpenSRO answers 0xA102 straight away. The image's blob format is not known (RESEARCH).

### 0x6103 -> 0xA103 on the retail agent (READ, AgentServer 0x402120)

`u32 token, string ID (lower-cased by the client, 0x4c9374), string PW, u8 content id, u8[6]`.
A content id other than `-retail-content-id`: no reply, disconnect (0x402225..0x40223c). A token
unknown, spent or expired: `[2, 3]`. ID or password not those of the queued login: `[2, 1]` (the
ID compared without case -- the 0x6102 carried it as typed; how AgentServer compares them was not
read, INFERRED). Each refusal ends the connection (0x402608). Success: `[1]` -- retail sends it
only after the shard (0xA201) and the game server (0xA204) accept; OpenSRO is both and answers at
once -- and `LoginService.AdmitSession` marks the session as the account's (the keys
`AuthenticatedAccountID` reads). The client shows `(C9)` for 1, `(C10)` for 2 and 3 (jump table
0x4cf874).

### After 0xA103 (READ, sro_client)

`[1]` posts WM 0x13f3 (0x4cf7b4); the title (0x86c0ac -> 0x865b10) saves RECENTSERVER, animates, and
switches to `CPSCharacterSelect` (0x865210 -> 0xeed914). Its OnCreate (0x85eb10 -> 0x8560e0) sends
**0x7007 [2]**, plain (only 0x704C is encrypted, 0x841590). Nothing else is needed: the select
screen reacts only to 0xB007, 0xB001, 0xB450 and 0x0FFC. OpenSRO answers 0x7007 with
`session.LobbyHandler`, unchanged.

### Start refused

There is no world for the original client yet. 0x7001 is answered **`[2, u16 0x40F]`**
(`UIO_SMERR_CANT_ACCESS_PARENT_SERVER`: "Character entry has failed. The GameServer is currently
offline; therefore, you cannot connect to SRO at the moment. Please contact the Administration
immediately." + "(S1039)", READ 0x861a40, index table 0x861b84) -- OURS, the choice: of the select
screen's texts it is the only one that says entering the world failed for want of a game server,
which is true here (0x409 "The server is not running.." is the runner-up).

**And then the list again, unasked (OURS):** the select screen raises its UI lock when it sends
Start (0x862410(1), 0x858770); its 0xB007 path lowers it (0x85fffa), its 0xB001 failure path does
not (0x85fd03..0x85fd1d). MEASURED with the real client: after a bare refusal no button answered
(a second Start, Delete, Cancel: no message, no change). With the list sent after the refusal the
screen stays usable (MEASURED: Start pressed again sent 0x7001; Cancel left the zoomed view).

### MEASURED: the original client against OpenSRO (render box, 2026-10-15)

sro_client_NODLL.exe from a COPY of the box's vSRO 1.188 install, under Wine 10.0 (32-bit,
`wine32:i386`, a virtual desktop on Xvfb, llvmpipe), started as `"Z:\...\sro_client_NODLL.exe" 0
/22 0 0` (the launcher's `"%s %s /%d %d %d"`: the exe path first -- without it the client's net
init fails with "connection failed (17)", an empty directory string, 0x4c9190). The archive names
its gateway `bhs1.vsroplus.com:31729` (DIVISIONINFO.TXT / GATEPORT.TXT); a private mount namespace
with its own /etc/hosts sent that name to 127.0.0.1, where OpenSRO's retail gateway listened on
31729 (the archives untouched). The client binds 15779 for its single-instance guard (0xb3eb30), so
OpenSRO's own listener ran elsewhere. The copy needed two DLLs the box's install lacks:
`GFXFileManager.dll` (the pk2 reader; the server package's copy) and `MaxiGuard.dll` (the
private server's guard, which the exe's injected stub only LoadLibrary's -- a 1 KB stand-in that
returns TRUE). The run, from the server's packet log:

```
gateway  recv 0x2001 090053525f436c69656e7400          "SR_Client", 0
gateway  send 0x2001 0d00 "GatewayServer" 00
gateway  recv 0x6100 16 0900 "SR_Client" e8030000       content id 22, version 1000
gateway  send 0xa100 01                                  (massive)
gateway  recv 0x6106 (empty)  -> send 0xa106 00
gateway  recv 0x6101 every 5 s -> send 0xa101 (one farm, one shard "OpenSRO", 0/1000, state 1)
gateway  recv 0x6102 (password withheld)
gateway  send 0xa102 01 <token> 0900 "127.0.0.1" f27b    agent 127.0.0.1:31730 (encrypted)
agent    recv 0x2001 "SR_Client" -> send 0x2001 "AgentServer"
agent    recv 0x6103 (password withheld) -> send 0xa103 01
agent    recv 0x7007 02 -> send 0xb007 020101 <OpenHero's record>
agent    recv 0x7001 0800 "OpenHero" -> send 0xb001 02 0f04, then 0xb007 (the list)
```

The server list showed "OpenSRO  Easy"; a wrong password showed "You have entered the incorrect
password! ... Out of a maximum of 0 attempts, you have used 0 attempt(s)." in the title's message
line (the base LoginService counts nothing yet; lane S); the right one went to the character select
screen with the account's character (made on OpenSRO's own wire) standing in its chosen armour,
its info panel reading Level 1, EXP 0.00 %; Start showed the 0x40F text above. Screenshots
(game art, kept off the repository): `/var/tmp/r788r-proof/` on the box.

## Status

- [x] The client's sequence to the list, with the framing, encryption and key exchange (READ).
- [x] 0xA101 from both sides; 0xA100's massive wrapping; the 0x6100 values and where they come from.
- [x] Implemented in GDScript and Go; byte-identical on 20 transcripts; 200 live queries against the
      Go fake with random primes, keys and seeds (MEASURED, round 681).
- [ ] The client's farm-byte mode word's writer (OPEN; round 788: it is 1 at run time, INFERRED
      from the MEASURED 0x6106).
- [ ] Whether a GatewayServer accepts 0x6101 before 0x6100 (OPEN; the client never does it).
- [x] The refusal codes of 0xA100 (READ, round 788: "0x6100's answers" below).
- [x] OpenSRO's server speaks the retail gateway and agent: the original client logs in to its
      character list (round 788, MEASURED under wine; below).
- [ ] Tested against a real private server: the user's (OPEN).
- [ ] A proxy or emulator that uses a FIXED crc seed whose table index is one of the 37 unknown ones
      (handshake.md) fails EVERY time, not 0.3 % of the time: three reconnects draw the same seed.
      The row is Closed with "the session's checksum table N is not a standard one" in the log
      (OPEN; only reading the 37 from the player's own exe would answer it).
