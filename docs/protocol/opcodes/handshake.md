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

## Per-packet security byte

Separately from the frame header's security bit(s) already described in `PACKET_FORMAT.md`, the
server computes a single extra "security byte" for each packet it sends, appended to the header
near the size/opcode fields. Observed algorithm, in plain terms:

1. It's a table-driven checksum in the same family as CRC-32: an accumulator is updated one input
   byte at a time as `acc = (acc >> 8) XOR table[(byte ^ acc) & 0xFF]`, where `table` is chosen
   from a small set of lookup tables (selected per-session by an index stored on the session
   object — i.e. not a single global table, several candidate tables exist and one is picked per
   connection).
2. After processing all input bytes, the 32-bit accumulator is folded down to a single byte by
   summing its four constituent bytes (with carry ignored — plain 8-bit addition).
3. Separately, the session also tracks a rolling one-byte value across packets, updated each send
   as `next = ((~prev1 + prev2) * prev3) `, then `next = (next >> 4) XOR next` — i.e. each packet's
   security byte also folds in state left over from the previous one or two packets sent on that
   session, not just the current packet's contents.

This is consistent with the long-publicly-documented "security byte" / count-byte scheme used by
this MMO family (independent private-server projects have described equivalent table-driven
per-packet checksums for ~two decades) — nothing above is claimed as novel or exclusive to this
particular binary.

## Encryption

The handshake object referenced during this exchange carries a same-typed member used later for
send/receive encryption — consistent with the client<->server link switching to a negotiated
block cipher (publicly documented elsewhere as Blowfish) once the handshake completes. The actual
key derivation/exchange has not been pulled apart yet; that's the next piece needed before
`server/internal/proto` can speak encrypted frames.

## Status / next steps

- [x] Confirm handshake opcodes exist and roughly which direction/role each plays
- [x] Confirm a per-packet security byte is computed via table-driven checksum + rolling state,
      not just a static CRC
- [ ] Pull exact payload layout for `0x5000` / `0x9000`
- [ ] Pull key derivation for the session cipher
- [ ] Implement handshake state machine in `server/internal/proto` from this doc (separately,
      as original Go code — not a transliteration of anything binary-derived)
