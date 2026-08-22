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
short one real byte.**

**A well-supported real hypothesis for the full 6-byte breakdown**, not yet 100% confirmed by
finding the literal header-serialization function itself, but the arithmetic lines up exactly with
independently-confirmed real fields: `ACTIVE_SESSION` (the same real class this whole investigation
traces through, see `handshake.md`) stages a real 2-byte `MsgID`/opcode field and a real 2-byte
size field (mask `0x7fff`, top bit unconfirmed but plausibly a real flag) on the message object
*before* it's serialized, and separately carries the two real per-packet security bytes
(`RollingByte`, `PacketChecksum`) this project already reverse-engineered and implemented. `2 + 2 +
1 + 1 = 6` -- exactly the confirmed real header size, with no field left unaccounted for and no
padding needed. If this holds, the real header's four fields are **`Opcode(2) + Size(2, high bit
likely a real flag) + RollingByte(1) + ChecksumByte(1)`**, with both security bytes present
unconditionally on every packet's base header, not gated behind an optional trailer the way this
project's own `Security`-flags-byte design assumed. **The real wire order is now confirmed (2026-08-22).** Found a real per-message buffer-setup
function (`FUN_0046d5d0` in `GatewayServer.exe`) that, given a fresh output buffer pointer
(`in_EAX`), stores four byte-offset-adjusted pointers into that *same* buffer directly into the
object's already-confirmed four header fields:

```
*(this + 0x1054) = in_EAX + 0   // Size field's real storage location: buffer offset 0
*(this + 0x1050) = in_EAX + 2   // MsgID/Opcode field's real storage location: buffer offset 2
*(this + 0x1058) = in_EAX + 4   // RollingByte field's real storage location: buffer offset 4
*(this + 0x105c) = in_EAX + 5   // ChecksumByte field's real storage location: buffer offset 5
```

Since `+0x1050`/`+0x1054`/`+0x1058`/`+0x105c` were already independently confirmed (see
`handshake.md`) to be the object's staged MsgID/Size/RollingByte/ChecksumByte fields respectively,
this function is real, direct proof of each field's exact byte offset in the serialized 6-byte
header buffer. **Real confirmed wire order: `Size(2) @0, Opcode/MsgID(2) @2, RollingByte(1) @4,
ChecksumByte(1) @5`** -- matching the original public documentation's `Size` then `Opcode` field
order exactly, with the two real security bytes appended unconditionally after them rather than
gated behind an optional trailer.

(This project's own header implementation in `server/internal/proto` still uses its own,
not-yet-updated 5-byte `Size(2)+Opcode(2)+Security(1)` layout -- bringing it in line with this real
6-byte, four-field layout is next up now that both size and order are confirmed.)

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
- [x] Confirm the real wire *order* of the header's four fields -- **found** via `FUN_0046d5d0`'s
      real per-buffer field-offset setup (see above): `Size(2) @0, Opcode/MsgID(2) @2,
      RollingByte(1) @4, ChecksumByte(1) @5`. Both field set and order are now confirmed real facts.
- [x] Update this project's own `server/internal/proto` header read/write to the real confirmed
      6-byte, 4-field layout above -- **done** (2026-08-22): `Read`/`Write` now use `Size(2)@0,
      Opcode(2)@2, RollingByte(1)@4, ChecksumByte(1)@5`, with `RollingByte`/`PacketChecksum` threaded
      through as optional (nil-safe) per-session generators via `gateway.Session.SetSecurity` rather
      than requiring session crypto to exist first. The old placeholder `Security`-flags byte is
      gone; the real confirmed Size-field top bit now gates `ErrEncrypted` instead.
- [ ] Real fact found (`handshake.md`): the original's checksum covers the *entire* packet (header,
      with the checksum byte field itself zeroed for the run, plus payload) -- `size + 6` bytes, not
      the payload alone. This project's own `PacketChecksum` usage in `proto.Read`/`Write` currently
      only feeds it the payload; bringing that in line with the real usage pattern (still with our
      own from-scratch table, per `docs/LEGAL.md` policy #2) is real, not-yet-done wire-compat work.
- [ ] Session key exchange / encrypted packets -- the plumbing to *carry* real per-session
      `RollingByte`/`PacketChecksum` state now exists (`SetSecurity`), but nothing populates it yet
      outside tests; needs the handshake (`0x5000`/`0x9000`) payload layout and key derivation
      pulled first (see `handshake.md`).
- [ ] Massive-packet reassembly -- `handshake.md` found a real, not-yet-fully-traced lead
      (`FUN_0046ed40`'s `+0x16f & 2` branch) tying the Size field's top bit to a queue/backpressure
      check rather than confirming it as an "encrypted" flag; worth revisiting before assuming
      `ErrEncrypted`'s current trigger condition is the real, final answer.
- [ ] Opcode table (`docs/protocol/opcodes/`) — starts empty, grows one documented opcode at a
      time as we implement against it, not speculatively. `observed_opcodes.md` now has ~150 real
      opcode *values* across four binaries; payload layouts are the next tier of work.
