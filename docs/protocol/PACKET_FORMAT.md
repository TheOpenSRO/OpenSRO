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

**Real, first-party confirmation the real header is 6 bytes, not 5 (2026-08-22)**, from directly
analyzing `GatewayServer.exe` (see `docs/protocol/opcodes/handshake.md`/`dispatch.md`) rather than
the public documentation this whole file was otherwise written from. Seen four independent times
now, the last of which is about as authoritative a source as exists for this specific fact: the
real generic "append raw bytes to an outgoing message's payload" primitive every other real
message-building function in this binary calls through -- its own write-cursor field starts at a
literal `6` and every appended byte simply advances it, with the running payload length always
computed as `cursor - 6`. That's the real header size baked directly into the one shared function
that builds every payload, not an indirect inference. **This project's own 5-byte header above
(`Size(2)+Opcode(2)+Security(1)`), taken from public private-server documentation, is therefore
short one real byte** -- plausibly a `Security`-adjacent flags/checksum byte this project hasn't
identified yet, given the two real independent per-packet security bytes `handshake.md` already
found (`RollingByte`/`PacketChecksum`) would need to live somewhere in the real header too. Not
fully resolved into a revised field table yet -- recorded as a confirmed real header *size*, with
the *field breakdown* still open, rather than guessing at which extra byte it is.

## Session crypto

The original protocol negotiates a per-session key exchange (documented publicly as a
Diffie-Hellman-ish handshake feeding into a Blowfish-based stream/block cipher for the encrypted
bit above) before any encrypted packets are sent. **Not implemented yet.** Until it is, our
server scaffold only speaks the unencrypted framing shape — enough to build tooling and tests
against, not enough to talk to a real original client. Session crypto is next up after framing +
a couple of real opcodes are solid.

## Status

- [x] Frame header parsing/writing (`server/internal/proto`) -- for this project's own,
      admittedly-not-wire-compatible protocol. Real confirmation the *original* header is 6 bytes,
      not the 5 this was built from, is above -- revisiting this project's own header to actually
      match is real work for when `PROTOCOL_DECISION.md`'s wire-compatibility goal reaches this
      layer, not done yet.
- [x] TCP accept loop dispatching decoded packets (`server/internal/gateway`, wired into
      `cmd/server`) — no opcode table yet, just logs what it sees
- [ ] Session key exchange / encrypted packets
- [ ] Massive-packet reassembly
- [ ] Identify the real header's 6th byte (see above) -- the concrete next step for actually
      revising the field table, rather than just knowing the total size is wrong
- [ ] Opcode table (`docs/protocol/opcodes/`) — starts empty, grows one documented opcode at a
      time as we implement against it, not speculatively. `observed_opcodes.md` now has ~150 real
      opcode *values* across four binaries; payload layouts are the next tier of work.
