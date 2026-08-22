# Handshake sequence

Findings from independent RE work against a legally-obtained private-server package, run on
infrastructure we control (see `docs/LEGAL.md` policy #2 — this file contains only plain factual
descriptions of observed behavior, no decompiler output/pseudocode/binary-derived code).

## Opcodes observed

| Opcode   | Direction       | Role                                                            |
|----------|-----------------|------------------------------------------------------------------|
| `0x5000` | client → server | Initial handshake / hello message. Triggers the handshake state machine. |
| `0x9000` | server → client | Handshake challenge/accept. Sent by the server as a reply to `0x5000`, and also checked for on a later leg of the exchange (the handshake appears to be multi-step, not a single request/response). |

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
block cipher (publicly documented elsewhere as Blowfish) once the handshake completes. The actual
key derivation/exchange has not been pulled apart yet; that's the next piece needed before
`server/internal/proto` can speak encrypted frames.

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
- [ ] Pull key derivation for the session cipher.
- [ ] Wire this into `server/internal/proto`/the real gateway, now that the goal is genuine wire
      compatibility rather than a reference implementation -- see
      `docs/protocol/PROTOCOL_DECISION.md`'s 2026-08-22 reversal.
