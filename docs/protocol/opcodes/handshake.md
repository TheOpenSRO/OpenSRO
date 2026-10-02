# Handshake sequence

Findings from independent RE work against a legally-obtained private-server package, run on
infrastructure we control (see `docs/LEGAL.md` policy #2 — this file contains only plain factual
descriptions of observed behavior, no decompiler output/pseudocode/binary-derived code).

## Opcodes observed

| Opcode   | Direction       | Role                                                            |
|----------|-----------------|------------------------------------------------------------------|
| `0x5000` | both ways       | The server's hello (flags, keys, seeds, key exchange), the client's 12-byte reply, the server's 0x10 challenge. |
| `0x9000` | client → server | The client's accept, after the challenge checks out (or at once when there is no key exchange). |

**CORRECTED (round 681):** this table said 0x5000 was client -> server and 0x9000 server -> client.
Read from the CLIENT's side of the same function (`ACTIVE_SESSION::_OnMsgReceivedBeforeHandshake`,
sro_client 0x4b1da0, mode 1), the server speaks first with 0x5000 and the client sends 0x9000
(0x4b1eb1); the server's side below (mode 0) receives the client's 12-byte 0x5000 and its 0x9000.
The full exchange is in "The client's side, READ (round 681)" below and in `gateway.md`.

Confirmed directly in `GatewayServer.exe` (2026-08-22, real dedicated server binary from the same
obtained package, not just inferred from the client): both values are checked as literal 16-bit
comparisons against a real per-connection object's own message-opcode field, inside a real,
named method — **`ACTIVE_SESSION::_OnMsgReceivedBeforeHandshake()`** (the class and method names
are both real, read directly from the binary's own embedded debug/log strings, e.g.
`"ACTIVE_SESSION::_OnMsgReceivedBeforeHandshake() - Handshake ServerSignature Error[MsgID: 0x%x]"`
— note the real internal name for the wire opcode field itself is **"MsgID"**). Real per-object
field offsets found (all offsets are from the start of one `ACTIVE_SESSION` instance):

| Offset   | Real meaning (confirmed)                                                    |
|----------|------------------------------------------------------------------------------|
| `+0x1050`| The just-received message's real 16-bit `MsgID` (wire opcode)               |
| `+0x1054`| A size/length field, masked with `0x7fff` when read — top bit plausibly a real flag (this project's own `secMassive`-style bit is a real candidate, not yet confirmed to be the same one) |
| `+0x1058`| The outgoing rolling security byte (point 2 below), written per reply       |
| `+0x105c`| The outgoing multi-table CRC-style byte (point 3 below), written per reply  |
| `+0x164` | The CRC state object passed into the checksum function (see point 3)        |
| `+0x16c..0x16e` | The three rolling-byte generator state bytes (matches `RollingByte`'s own 3-byte state exactly) |

Exact full payload field layouts for these two opcodes (beyond the security-byte fields above) are
still not documented here — real next step if wire compatibility work continues on this specific
opcode pair.

## Per-packet security state (revised — first pass below was incomplete)

An earlier pass through this described a single self-contained "security byte" formula. Going one
level deeper into where its inputs come from shows that was incomplete, so revising rather than
leaving a description we don't actually believe is right:

1. At handshake time, a per-session seed is expanded into several derived byte values via a
   32-round single-bit-feedback shift register (LFSR): each round shifts a 32-bit register right
   by one, feeding back a bit computed by XORing several tapped bit positions together. This is
   consistent with the "security byte" / count-byte generator long documented by the private
   server community for this MMO family (an LFSR-based per-session keystream, not a simple static
   CRC).

   The tap/feedback computation, confirmed by direct observation, one round: given the current
   32-bit register value `v`, XOR five progressively-shifted taps together — shift amounts
   2, 2, 1, 1, 1, each result re-XORed against `v` again before the next shift — and take bit 0 of
   the final result as the feedback bit. Separately, the *old* bit 0 of `v` moves up to become the
   *new* bit 31 (a rotate), and the new bit 0 becomes the feedback bit just computed; bits 1-30 of
   the new value are bits 2-31 of the old one, shifted down. Run 32 times per derived byte. This is
   an algorithm/method, not a literal data table, so — unlike the CRC table in point 3 below —
   there's no concern about reproducing it in an original implementation (see `docs/LEGAL.md`
   policy #2: facts about behavior, including precise algorithms, are fair game to document and
   reimplement; it's copying literal proprietary *data* or *source text* that isn't).
   Four such derived bytes get combined (XORed pairwise, with a `0 -> 1` substitution to avoid a
   degenerate zero state) into the three seed bytes that feed the rolling generator in point 2.
   Implemented as `server/internal/proto.lfsrByte` / `DeriveSeed`.
2. Those derived bytes seed a small rolling one-byte generator used once per outgoing packet:
   `next = ((~prev0 + prev1) * prev2)`, then `next = (next >> 4) XOR next`, where only one of the
   three state bytes updates per packet (the other two stay fixed for the life of the session,
   set once at handshake time) — so this is a per-session keystream advancing by one step per
   packet, not something that mixes in each packet's actual contents.
3. There's a second, genuinely independent piece — not combined with point 2, confirmed by seeing
   both written to two different single-byte fields (`+0x1058` and `+0x105c` on `ACTIVE_SESSION`,
   see above) in the same outgoing packet header. It's a classic reflected CRC-32-style running
   checksum: a 32-bit accumulator seeded to `0xFFFFFFFF`, updated one byte at a time as
   `acc = (acc >> 8) XOR table[(byte XOR acc) & 0xFF]`, then folded down to one byte by summing the
   accumulator's four constituent bytes (plain 8-bit addition, no carry). The twist: `table` isn't
   the single standard CRC-32 table — a small per-session index selects among several candidate
   tables. **Confirmed directly (2026-08-22, `GatewayServer.exe`): the real selection formula is
   `table_offset = table_index * 256`** — i.e. one big backing array holds every candidate table
   back-to-back, 256 `uint32` entries each, and `table_index` (an int, stored at the start of the
   same small object that carries the running accumulator) picks which 256-entry slice to use.
   This is a fact about behavior/method (an offset-selection formula), not literal table data, so
   documenting it doesn't run into `docs/LEGAL.md` policy #2's line the way the actual table
   *contents* would. We still have not pulled (and still don't intend to pull) the actual table
   values themselves — hardcoding those verbatim from the binary would be exactly the kind of
   literal copying policy #2 exists to avoid, so the real table's byte contents stay undocumented
   until/unless they turn out to match something independently, publicly documented.

So: two independent one-byte fields per outgoing packet header — an LFSR-seeded rolling byte
(point 2) and a multi-table CRC-32-style byte (point 3) — not a single fused "security byte" as
an earlier pass through this doc assumed.

**New real fact (2026-08-22): the checksum covers the whole packet, not just the payload.** Found
the real per-packet send-finalization function (`FUN_0046ed40` in `GatewayServer.exe`, reached
while chasing `PACKET_FORMAT.md`'s header-order question). Real, directly observed sequence,
gated behind a real per-session flags-byte bit (`+0x16f & 4`, only when a separate mode field
equals `1`):

1. Compute and store the rolling byte (point 2's exact formula, confirmed identical here again)
   into the header's `+0x1058` field.
2. **Zero the checksum byte field (`+0x105c`) first**, then run the checksum function over
   `(Size & 0x7fff) + 6` bytes -- i.e. the *entire* packet length including the real 6-byte header,
   not the payload alone -- and only then store the real computed result into `+0x105c`.

This means the real checksum is computed over the complete on-wire packet (header, with its own
checksum byte field zeroed out for the computation, plus the full payload), not just the payload
bytes the way `PacketChecksum` currently gets fed in `server/internal/proto`. A real, concrete
correction to make whenever this project's own checksum usage is brought in line with the original
for actual wire compatibility (not done yet -- `PacketChecksum` remains this project's own
originally-designed stand-in either way, per policy #2, but its *usage pattern* should match this
real fact once real interop is attempted).

Also observed in the same function: a second real branch gated on a different flags-byte bit
(`+0x16f & 2`) together with the Size field's top bit (`0x8000`), which real-checks a length against
`0x1001` (4097) before either enqueueing the packet for send or raising a real logged error and
clearing that top bit back off -- consistent with `dispatch.md`'s already-found queue-overflow
error path (real opcode `0x1001`). Not fully traced this pass; noted as a real, concrete lead for
whoever picks up the massive/split-packet reassembly item next, since it's the first real code
this project has found that treats the Size field's top bit as a queuing/backpressure signal
rather than confirming or ruling out "encrypted" as its meaning.

## The real handshake state machine (2026-08-22, from decompiling `_OnMsgReceivedBeforeHandshake` in full)

Real, concrete facts about the multi-step exchange this doc's opcode table already flagged as
"not a single request/response":

- `ACTIVE_SESSION` carries a real one-byte handshake-progress field at `+0x200`. `0` means
  "not yet initialized" -- any message received in that state is rejected with a real logged error
  (`"_OnMsgReceivedBeforeHandshake() - Initialize [MsgID: 0x%x]"`) rather than processed. Once
  initialized, it's read as a real bitfield: three low bits (`0x2`, `0x4`, `0x8`) must *all* be set
  for a `0x5000` to be accepted at all (else a real `"Handshake Failed:%d"` error/reject), and a
  separate `0x10` bit marks a later stage of the exchange (see below) once reached.
- **Real confirmed payload size for the client's first `0x5000`**: exactly 12 bytes (`0xc`) -- an
  explicit real length check (`"Handshake Recipient Size:%d [MsgID: 0x%x]"` on mismatch) gates
  acceptance. This is the first hard fact about `0x5000`'s actual payload beyond the security-byte
  fields already documented above.
- After that first `0x5000` passes a real "recipient info" validation step, the real reply is
  **another `0x5000`** (not `0x9000`) -- confirming this is genuinely multi-step and the two
  opcodes aren't simply a one-shot request/reply pair. That reply's real payload starts with a
  literal flag byte `0x10` (three padding bytes follow it in the same 4-byte field), then a second
  4-byte field. Successfully reaching this point sets the real `0x10` progress bit on `+0x200`.
- Once the `0x10` progress bit is set, a further `0x5000` arriving is instead run through a real
  signature-verification step (`"Handshake ServerSignature Error[MsgID: 0x%x]"` on failure); on
  success, this is the real path that finally replies with `0x9000` (or, in a separate real
  sub-case gated by a decoded flag bit, with yet another `0x5000` carrying a different payload) --
  matching this doc's original observation that `0x9000` gets "checked for on a later leg", not
  sent immediately off the first `0x5000`.
- A completely separate real branch handles receiving `0x9000` (rather than `0x5000`) in the
  not-yet-fully-initialized state, running it through its own real verification step
  (`"SecurityModeCheck - Mode:%d, Handshake:%d"` on failure) -- consistent with `GatewayServer.exe`
  playing *both* roles at different times (responder to a connecting game client, and initiator
  toward another internal server such as `AgentServer.exe`), not just one fixed direction for this
  opcode pair.
- Real, not yet decoded: the exact byte-for-byte contents of the 12-byte first `0x5000` payload,
  the two 4-byte fields in the state-machine's own `0x5000` replies, and the "recipient info"/
  "signature" validation steps' own real input formats. Each is a distinct real function
  (unnamed here) that would need its own decompilation pass -- real, concrete next steps, not
  guessed at.

## Encryption

The handshake object referenced during this exchange carries a same-typed member used later for
send/receive encryption — consistent with the client<->server link switching to a negotiated
block cipher (publicly documented elsewhere as Blowfish) once the handshake completes. Round 681
read the key exchange and the cipher: next section.

## The client's side, READ (round 681)

From sro_client (`/var/tmp/decomp_client`, `/var/tmp/sro_client.asm`), the CLIENT branch (mode 1,
`ACTIVE_SESSION+8 == 1`) of the same code; the server branch agrees wherever it was read.
Implemented in `server/internal/proto/retail_security.go` + `retail_frame.go` and
`client/scripts/net/retail/retail_security.gd`; the exchange around it is `gateway.md`.

**The server's hello** (0x5000; read at 0x4b1deb..0x4b1e3a, 0x4b3c60 -> 0x4b3eb0; written by
SR_GameServer's `CNetEngine::FUN_00965c20`): u8 flags; flag 2: 8 bytes, the Blowfish key; flag 4:
u32 count seed, u32 crc seed; then flag 0x10: an 8-byte challenge, else flag 8: 8 bytes
"handshake key", u32 G, u32 P, u32 A. Retail sends flags 0x0E. The server makes G and P two random
primes, the smaller G (`FUN_004c6fc0` / 0x4c6ef0, 31-bit, odd, a 5-round probabilistic test); its
private value is a GUID's first dword & 0x7fffffff (0x4c6ff0) and A = G^y mod P.

**Set-up on the hello** (`CNetEngine::FUN_004b0cc0`): flags are kept at +0x16f; flag 1 skips
everything (not supported by our client, OURS); flag 2 keys Blowfish (+0x158) with the 8 bytes;
flag 4:

- the count seed (0 -> 0x9abfb3b6, 0x4b0cf7) runs the 32-round generator of point 1 FOUR TIMES ON
  ONE REGISTER (0x4afb80 updates its argument in place): v1..v4; a = low(v1) ^ low(v2), b = low(v4)
  ^ low(v3), each 0 -> 1; the rolling byte's state is {a ^ b, a, b} (+0x16c..+0x16e).
  **CORRECTED:** `proto.DeriveSeed` ran the generator on seed, seed+1, seed+2, seed+3; it now
  chains (`CountSeeds`).
- the crc seed's low byte (0 -> 1) is the checksum table index (0x4bf9c0); the accumulator starts at
  0xffffffff for every frame (0x4bf9e0, which `PacketChecksum` did not do -- its running
  accumulator is noted in its comment; the new code uses `CheckByte`).

**The key exchange** (0x4c45f0, 0x4c7060, 0x4c70c0, 0x4c42b0, 0x4c4300, 0x4c4330, 0x4c4410;
`ModPow` = 0x4c6e50, 64-bit square-and-multiply; `T(v, key, b)` = 0x4c4230, which replaces each
byte v[i] of an 8-byte value with v[i] ^ (v[i] + keybyte[i % 4] + b), key bytes little-endian;
`(lo, hi)` = two u32s little-endian in 8 bytes):

| Step | Value |
|---|---|
| client private x | a fresh GUID's first dword & 0x7fffffff (CoCreateGuid, 0x4c7078) |
| B | G^x mod P |
| K | A^x mod P (the server: B^y mod P) |
| key1 (a second Blowfish, +0x1b8+0x20) | T((A, B), K, K & 3) |
| the client's challenge | key1-encrypt T((B, A), K, B & 7) |
| the client's 0x5000 | u32 B, the 8-byte challenge (12 bytes, plain, with count and check) |
| the server's 0x10 challenge, checked by the client | key1-encrypt T((A, B), K, A & 7) -- a mismatch is "Handshake ServerSignature Error" |
| the session key (+0x158) | T(handshake key, K, 3) |
| the client's 0x9000 | empty, plain, with count and check |

Without flag 8 the client sends 0x9000 at once (0x4b1f92..0x4b20b1).

**Blowfish** (`FUN_004aa4c0` key schedule, `FUN_004a9d40`/`FUN_004aa100` block, `FUN_004aa8d0` /
`FUN_004aaa20` buffers): the standard cipher -- its P-array and S-boxes MEASURED in the exe equal to
the published pi digits (P[0] 0x243f6a88, S0[0] 0xd1310ba6), the key bytes taken big-endian -- with
each 8-byte block's halves loaded as LITTLE-endian u32s; a buffer is zero-padded to whole blocks.

**The frame both ways** (`CNetEngine::FUN_004b0d70` send, `FUN_004b0f60` receive): u16 size (bit 15
= encrypted), u16 opcode, u8 count, u8 check, payload. A client with flag 4 writes the next rolling
byte, zeroes check, checksums the whole plain frame (header included, size word as sent, bit 15
too) and stores the result; with flag 2 and bit 15 it then encrypts bytes 2.. (opcode onward)
padded to 8, so an encrypted frame is 2 + pad8(size + 4) bytes. A server writes count and check 0.
A receiver: bit 15 without flag 2 is error 0x8011; an encrypted frame over 0x1000 bytes is 0x800d;
with flag 4 a server checks count (0x800b) then check (0x800c) and a CLIENT requires both 0 (except
an unencrypted 0x1001). Who sets bit 15: the sender, per packet (the allocator `vslot_018`
0x4a0930).

### The checksum tables, and why 37 of 255 are not reproduced (the LEGAL check)

- **READ (`CClientNet::FUN_004bf900`):** at start-up the client builds 256 tables of 256 u32s
  (0x111b0b0, .bss) from a list of 256 u32 polynomials in .data (0xee44a0..0xee48a0): table s, entry
  i is the textbook reflected-CRC table step -- v = i, eight times `v = v & 1 ? v >> 1 ^ poly[s] :
  v >> 1`. The table index is never 0 (0x4bf9c0).
- **MEASURED (round 681, on the render box, by comparison only):** entry s of that list equals entry
  s of the standard CRC-32 table (the one generated from the public polynomial 0xedb88320) for 218
  of the 255 usable indices. The other 37 -- 18, 19, 55, 58, 73, 88, 121, 123, 125, 145, 175, 176,
  177, 182, 184, 192, 193, 198, 199, 200, 208, 216, 217, 240, 241, 242, 243, 244, 245, 246, 248, 250,
  251, 252, 253, 254, 255 (and 0, unused) -- differ from it by a few bits each. GatewayServer.exe
  (file offset 0xf6cd0) and SR_GameServer.exe hold a byte-identical list (compared on the box).
- **What the implementation does:** it GENERATES the 218 tables -- the public CRC-32 table from
  0xedb88320 gives the polynomials, the read builder gives the tables (the Go side checks every one
  against `hash/crc32.MakeTable`). No byte of the client's list or tables is in this repository or
  was copied into code; for the 37 the values were not looked at beyond "differs", and the
  index list above is the only thing recorded about them. A session whose crc seed selects one of
  the 37 cannot be checksummed: the client hangs up before sending anything and connects again (the
  gateway draws a new seed per connection), up to three times within its 4 s (OURS). A proxy or
  emulator that uses a FIXED crc seed whose index is one of the 37 fails every time, not 0.3 % of
  the time (OPEN).
  `docs/LEGAL.md` policy #2 is kept: the algorithm is the client's (READ, described in prose) and
  the CRC-32 polynomial is public; the 37 entries would need the binary's bytes, so they are not
  reproduced. Reading them at run time from a player's own sro_client.exe would be possible
  without putting them in the repository; that is the user's call, not done (OPEN).

## Status / next steps

- [x] Confirm handshake opcodes exist and roughly which direction/role each plays
- [x] Confirm the session security state involves an LFSR-seeded rolling generator, seeded once
      at handshake and advanced once per packet — corrected from an earlier, less accurate pass
- [x] Confirm the two security-related bytes (LFSR-seeded rolling byte, multi-table CRC-32-style
      byte) are independent fields, not fused into one — corrects a second, earlier mistaken pass
      that had them combined via XOR (see PROGRESS.md; that version was reverted before landing)
- [x] The rolling-byte generator (point 2) is fully confirmed and implemented
      (`RollingByte`/`DeriveSeed`) -- and, as of 2026-08-22, confirmed bit-for-bit correct not just
      against the client but against real `GatewayServer.exe` code computing it live in
      `ACTIVE_SESSION::_OnMsgReceivedBeforeHandshake()`.
- [x] The multi-table CRC-style byte (point 3)'s table-*selection* formula (`table_index * 256`
      into one shared backing array) is now confirmed too (2026-08-22) -- only the actual table
      *contents* remain deliberately unpulled, per policy #2. `PacketChecksum` currently implements
      this shape with its own from-scratch table family rather than the original's table contents
      -- worth revisiting once real wire compatibility work reaches this opcode pair, since the
      selection *formula* is now real and could be matched exactly even while keeping the table
      contents original.
- [ ] Pull exact payload layout for `0x5000` / `0x9000` beyond the security-byte fields already
      found (see the offset table above) -- the real next step for this specific opcode pair now
      that `docs/protocol/PROTOCOL_DECISION.md` has reversed course to target actual wire
      compatibility.
- [x] Found the real per-packet send-finalization function (`FUN_0046ed40`) and confirmed the
      checksum runs over the whole packet (header + payload, checksum byte zeroed during the run),
      not the payload alone -- see the new section above. Also surfaced a real, not-yet-fully-traced
      lead on the Size field's top-bit meaning (queue/backpressure related, not confirmed
      encrypted-vs-something-else yet).
- [x] Pull key derivation for the session cipher (round 681: the client's side, READ, above).
- [ ] Wire this into `server/internal/proto`/the real gateway, now that the goal is genuine wire
      compatibility rather than a reference implementation -- see
      `docs/protocol/PROTOCOL_DECISION.md`'s 2026-08-22 reversal. Round 681 wired the CLIENT side
      into the server list (`type: legacy`) and built the server side as a test fake
      (`server/internal/retailgw`); our own server does not speak it yet.
