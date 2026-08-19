# Handshake sequence

Findings from independent RE work against a legally-obtained private-server package, run on
infrastructure we control (see `docs/LEGAL.md` policy #2 — this file contains only plain factual
descriptions of observed behavior, no decompiler output/pseudocode/binary-derived code).

## Opcodes observed

| Opcode   | Direction       | Role                                                            |
|----------|-----------------|------------------------------------------------------------------|
| `0x5000` | client → server | Initial handshake / hello message. Triggers the handshake state machine. |
| `0x9000` | server → client | Handshake challenge/accept. Sent by the server as a reply to `0x5000`, and also checked for on a later leg of the exchange (the handshake appears to be multi-step, not a single request/response). |

Exact payload field layouts for these two opcodes are not yet documented here — next step is to
pull the payload structure (not just the fact that these opcodes exist) before implementing the
handshake state machine in `server/internal/proto`.

## Per-packet security state (revised — first pass below was incomplete)

An earlier pass through this described a single self-contained "security byte" formula. Going one
level deeper into where its inputs come from shows that was incomplete, so revising rather than
leaving a description we don't actually believe is right:

1. At handshake time, a per-session seed is expanded into several derived byte values via a
   32-round single-bit-feedback shift register (LFSR): each round shifts a 32-bit register right
   by one, feeding back a bit computed by XORing several tapped bit positions together. This is
   consistent with the "security byte" / count-byte generator long documented by the private
   server community for this MMO family (an LFSR-based per-session keystream, not a simple static
   CRC) — we're not yet confident enough in the exact tap positions to state them as fact.
2. Those derived bytes seed a small rolling one-byte generator used once per outgoing packet:
   `next = ((~prev0 + prev1) * prev2)`, then `next = (next >> 4) XOR next`, where only one of the
   three state bytes updates per packet (the other two stay fixed for the life of the session,
   set once at handshake time) — so this is a per-session keystream advancing by one step per
   packet, not something that mixes in each packet's actual contents.
3. There's a second, genuinely independent piece — not combined with point 2, confirmed by seeing
   both written to two different single-byte fields in the same outgoing packet header. It's a
   classic reflected CRC-32-style running checksum: a 32-bit accumulator seeded to `0xFFFFFFFF`,
   updated one byte at a time as `acc = (acc >> 8) XOR table[(byte XOR acc) & 0xFF]`, then folded
   down to one byte by summing the accumulator's four constituent bytes (plain 8-bit addition, no
   carry). The twist: `table` isn't the single standard CRC-32 table — a small per-session index
   (1-255) selects among several candidate tables, so this is a keyed/multi-table CRC variant, not
   plain CRC-32. We have not pulled the actual table contents; doing so from the binary and
   hardcoding them verbatim would be exactly the kind of literal copying `docs/LEGAL.md` policy #2
   exists to avoid, so this stays undocumented until/unless the table turns out to match something
   independently, publicly documented.

So: two independent one-byte fields per outgoing packet header — an LFSR-seeded rolling byte
(point 2) and a multi-table CRC-32-style byte (point 3) — not a single fused "security byte" as
an earlier pass through this doc assumed.

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
- [ ] The rolling-byte generator (point 2) is fully confirmed and implementable now. The CRC-style
      byte (point 3) is understood algorithmically but its actual table contents are deliberately
      not being pulled from the binary (see point 3's note) — needs either an independently
      published source for the table, or a decision to derive our own equivalent-purpose table
      instead of matching the original bit-for-bit (breaks wire compatibility with the original
      client; fine if the whole point is a from-scratch protocol, not fine if BYO-client
      compatibility matters — worth a decision from OpenSRO/OpenSRO)
- [ ] Pull exact payload layout for `0x5000` / `0x9000`
- [ ] Pull key derivation for the session cipher
- [ ] Implement handshake state machine in `server/internal/proto` from this doc (separately,
      as original Go code — not a transliteration of anything binary-derived)
