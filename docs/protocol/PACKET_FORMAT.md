# Wire packet framing

This describes the transport-level framing used for client<->server messages, as long
documented publicly by the private-server community (many independent open-source gateway/agent
server projects implement compatible framing). It is a description of a wire format, implemented
here from that public documentation — not from disassembling any client/server binary.

We are deliberately starting with **just the framing layer** (how bytes on the wire are split
into discrete packets) and leaving actual opcode-by-opcode payload definitions as a growing,
versioned table under `docs/protocol/opcodes/` as they're documented/implemented — not
guessing ahead of what we can actually verify.

## Frame layout

Each packet on the wire:

| Field       | Size    | Notes                                                             |
|-------------|--------:|--------------------------------------------------------------------|
| Size        | 2 bytes | LE uint16. Byte length of `Data`, *not* including this header.     |
| Opcode      | 2 bytes | LE uint16. Identifies the message type.                            |
| Security    | 1 byte  | Bitflags: bit0 = encrypted, bit1 = has 4-byte CRC+count trailer, bit2 = massive/continuation packet. |
| Data        | Size    | Payload bytes (opcode-specific; encrypted with the session's negotiated cipher when the encrypted bit is set). |
| CRC+Count   | 4 bytes | Present only when the security byte's trailer bit is set: 1-byte CRC over `Data` + 3-byte monotonic packet count, both used as replay/tamper mitigation, not real integrity guarantees. |

"Massive" packets split a single logical message across multiple frames when it doesn't fit in
one; that reassembly is not yet implemented (`server/internal/proto` handles single-frame packets
only for now — see code comments).

## Session crypto

The original protocol negotiates a per-session key exchange (documented publicly as a
Diffie-Hellman-ish handshake feeding into a Blowfish-based stream/block cipher for the encrypted
bit above) before any encrypted packets are sent. **Not implemented yet.** Until it is, our
server scaffold only speaks the unencrypted framing shape — enough to build tooling and tests
against, not enough to talk to a real original client. Session crypto is next up after framing +
a couple of real opcodes are solid.

## Status

- [x] Frame header parsing/writing (`server/internal/proto`)
- [ ] Session key exchange / encrypted packets
- [ ] Massive-packet reassembly
- [ ] Opcode table (`docs/protocol/opcodes/`) — starts empty, grows one documented opcode at a
      time as we implement against it, not speculatively
