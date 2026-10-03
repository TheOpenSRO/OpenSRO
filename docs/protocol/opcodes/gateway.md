# The gateway, as far as the server list (round 681)

The original protocol's exchange between a client and a GatewayServer, from the TCP connect to
the shard list, as the retail client and server run it. Login is not covered: nothing here was
built to send one. Plain descriptions only (docs/LEGAL.md policy #2); the security bytes and the
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

- **Which client handler takes which reply** is INFERRED from what each reads, the client's
  opcode-to-handler table not having been found (no 0xa100/0xa101 immediate, no opcode/handler
  pairs in .data): `vslot_015` reads a result byte through the massive-message reader and sends
  0x6104 or reports success (0xA100); `FUN_004cda30` reads exactly what GatewayServer writes for
  0xA101. The parsers themselves are READ.
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
  find any available patch server" when there is none). The exact codes of each refusal beyond
  [2, 4] are OPEN.

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
  exactly (OURS).
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

## Status

- [x] The client's sequence to the list, with the framing, encryption and key exchange (READ).
- [x] 0xA101 from both sides; 0xA100's massive wrapping; the 0x6100 values and where they come from.
- [x] Implemented in GDScript and Go; byte-identical on 20 transcripts; 200 live queries against the
      Go fake with random primes, keys and seeds (MEASURED, round 681).
- [ ] The client's farm-byte mode word's writer (OPEN).
- [ ] Whether a GatewayServer accepts 0x6101 before 0x6100 (OPEN; the client never does it).
- [ ] The refusal codes of 0xA100 other than [2, 4] (OPEN).
- [ ] Tested against a real private server: the user's (OPEN).
- [ ] A proxy or emulator that uses a FIXED crc seed whose table index is one of the 37 unknown ones
      (handshake.md) fails EVERY time, not 0.3 % of the time: three reconnects draw the same seed.
      The row is Closed with "the session's checksum table N is not a standard one" in the log
      (OPEN; only reading the 37 from the player's own exe would answer it).
