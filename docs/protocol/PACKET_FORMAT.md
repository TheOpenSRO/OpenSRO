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
size field (mask `0x7fff`; the top bit **is** a real flag -- round 328 reads it as the
*encoded-request* marker, see below) on the message object
*before* it's serialized, and separately carries the two real per-packet security bytes
(`RollingByte`, `PacketChecksum`) this project already reverse-engineered and implemented. `2 + 2 +
1 + 1 = 6` -- exactly the confirmed real header size, with no field left unaccounted for and no
padding needed. If this holds, the real header's four fields are **`Opcode(2) + Size(2, high bit
the encoded-request flag) + RollingByte(1) + ChecksumByte(1)`**, with both security bytes present
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
- [x] Real fact found (`handshake.md`): the original's checksum covers the *entire* packet (header,
      with the checksum byte field itself zeroed for the run, plus payload) -- `size + 6` bytes, not
      the payload alone. **Matched** (2026-08-22): `proto.Read`/`Write` now feed the whole header
      (checksum byte zeroed) plus payload through `PacketChecksum`, in that order, matching the real
      usage pattern -- still with our own from-scratch table contents, per `docs/LEGAL.md` policy #2.
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


## Opcode coverage against the real space, measured (round 324)

`docs/SYSTEMS.md` has carried "opcode coverage vs the real space is unmeasured"
as this row's next probe since the row existed. Measured:

| | |
|---|---:|
| real opcodes the client registers a handler for | **318** |
| real server request indices | **162** |
| opcodes srrevamp declares | **143** |
| **srrevamp opcodes that are real ones** | **0** |

Zero is the expected answer, not a failure: `PROTOCOL_DECISION.md` reversed the
direction on 2026-08-22 to a full wire-level reimplementation and says of the
current numbers that they are "**placeholder scaffolding, not the destination**".
This is the first time the distance to that destination has been a number.

### 93 of the 162 real request handlers are already named

**57 %** of the real server-side request surface has a named function in the
dump, and 115 of 162 exist there at all. That is the adoption roadmap: for these
the handler is identified, so the remaining work per opcode is the payload
layout rather than finding the code.

Several land on systems srrevamp ships today -- `Item_HandleUseItem` is real
opcode **`0x04c`** replying **`0xb04c`**, which is the same message this project
had to relocate to `0x008a` this week after it collided with party-create.

**A number is not adoption.** Taking a real opcode number without its real
payload layout is worse than keeping a placeholder: a real client would connect,
recognise the number and misread the bytes. `PROTOCOL_DECISION.md` requires both
before an opcode moves, so nothing is changed here.

| real index | handler | reply |
|---|---|---|
| `0x031` | `GObjPC_HandleGuildSummonReqMsg_031` | `-` |
| `0x046` | `GObjPC_HandleShopMsg_046` | `0xb046` |
| `0x04c` | `Item_HandleUseItem` | `0xb04c` |
| `0x050` | `GObjPC_HandleIncreaseStr` | `-` |
| `0x051` | `GObjPC_HandleIncreaseInt` | `-` |
| `0x05e` | `SiegeFortress_DispatchCommand` | `-` |
| `0x060` | `GObjPC_HandlePartyMsg_060` | `0xb060` |
| `0x062` | `CParty::CheckCanJoin` | `0xb060,0xb062` |
| `0x063` | `GObjPC_HandlePartyMsg_063` | `-` |
| `0x069` | `OnRegisterPartyReq` | `0xb069` |
| `0x06a` | `PartyMatch_HandleModify` | `0xb06a` |
| `0x06b` | `GObjPC_HandlePartyMsg_06b` | `0xb06b` |
| `0x06c` | `GObjPC_HandlePartyMsg_06c` | `0xb06c` |
| `0x06d` | `GObjPC_HandlePartyMsg_06d` | `0xb06d` |
| `0x081` | `GObjPC_HandleTradeMsg_081` | `0xb081` |
| `0x082` | `GObjPC_HandleTradeMsg_082` | `0xb082` |
| `0x083` | `Trade_HandleExchange` | `0xb083` |
| `0x084` | `GObjPC_HandleTradeMsg_084` | `0xb084` |
| `0x0a1` | `GObjPC_HandleSkillMsg_0a1` | `0xb0a1` |
| `0x0a2` | `Skill_HandleMasteryLevelUp` | `-` |
| `0x0b1` | `FleaMarket_HandleOpenStall` | `0xb0b1` |
| `0x0b2` | `GObjPC_HandleStallMsg_0b2` | `0xb0b2` |
| `0x0b4` | `FleaMarket_HandleBuyItem` | `0xb0b4` |
| `0x0b5` | `GObjPC_HandleStallMsg_0b5` | `0xb0b5` |
| `0x0e1` | `CInstanceCharTrijob::HandleJoinJobGuild` | `0xb0e1` |
| `0x0e2` | `JobGuild_HandleWithdraw` | `0xb0e2` |
| `0x0e3` | `GObjPC_HandleAliasMsg_0e3` | `-` |
| `0x0ea` | `GObjPC_HandleEventGuideMsg_0ea` | `-` |
| `0x0f0` | `CGuildManager::HandleCreateGuild` | `0xb0f0` |
| `0x0f1` | `GObjPC_HandleGuildMsg_0f1` | `0xb0f1,0xb0f4` |
| `0x0f2` | `GObjPC_HandleGuildMsg_0f2` | `0xb0f2` |
| `0x0f9` | `Guild_HandleNoticeUpdate` | `0xb0f9` |
| `0x0fa` | `Guild_HandleLevelUpRequest` | `0xb0fa` |
| `0x0fb` | `GObjPC_HandleGuildMsg_0fb` | `0xb0fb` |
| `0x0fc` | `GObjPC_HandleGuildMsg_0fc` | `0xb0fc,0xb0fd` |
| `0x0fd` | `GObjPC_HandleGuildMsg_0fd` | `0xb0fd` |
| `0x0ff` | `GObjPC_HandleGuildMsg_0ff` | `0xb0ff` |
| `0x103` | `GObjPC_HandleGuildMsg_103` | `0xb103` |
| `0x104` | `GObjPC_HandleGuildMsg_104` | `0xb104` |
| `0x105` | `GObjPC_HandleGuildMsg_105` | `0xb105` |
| `0x106` | `GObjPC_HandleVoteMsg_106` | `0xb106` |
| `0x107` | `GObjPC_HandleVoteMsg_107` | `0xb107` |
| `0x110` | `Guild_HandleWarDeclaration` | `0xb110` |
| `0x112` | `GObjPC_HandleGuildMsg_112` | `0xb112` |
| `0x113` | `GObjPC_HandleGuildMsg_113` | `0xb113` |
| `0x114` | `GObjPC_HandleGuildMsg_114` | `0xb114` |
| `0x117` | `GObjPC::HandleNameCOS` | `0xb117` |
| `0x11a` | `GObjPC_HandleItemMallMsg_11a` | `-` |
| `0x121` | `GObjPC_HandleShopMsg_121` | `0xb121` |
| `0x150` | `GObjPC_HandleAlchemyReinforceMsg_150` | `-` |
| `0x151` | `GObjPC_HandleAlchemyReinforceMsg_151` | `-` |
| `0x157` | `GObjPC_HandleAlchemyDecompEquipmentMsg_157` | `-` |
| `0x16a` | `GObjPC_HandleSocketMsg_16a` | `-` |
| `0x202` | `GObjPC_HandleSkillMsg_202` | `0xb202` |
| `0x203` | `GObjPC_HandleSkillMsg_203` | `0xb203` |
| `0x250` | `Guild_HandleWarehouseUse` | `0xb250` |
| `0x251` | `GObjPC_HandleGuildMsg_251` | `0xb251` |
| `0x256` | `GObjPC_HandleGuildMsg_256` | `0xb256` |
| `0x258` | `GObjPC_HandleGuildMsg_258` | `0xb258` |
| `0x259` | `GObjPC_HandleGuildMsg_259` | `0xb259` |
| `0x302` | `GObjPC_HandleMessengerMsg_302` | `0xb302` |
| `0x304` | `GObjPC_HandleMessengerMsg_304` | `0xb304` |
| `0x308` | `GObjPC_HandleMessengerMsg_308` | `0xb308` |
| `0x309` | `GObjPC_HandleMessengerMsg_309` | `0xb309` |
| `0x30a` | `GObjPC_HandleMessengerMsg_30a` | `0xb30a` |
| `0x30b` | `GObjPC_HandleMessengerMsg_30b` | `0xb309,0xb30b` |
| `0x30c` | `GObjPC_HandleMessengerMsg_30c` | `0xb30c` |
| `0x470` | `TrainingCamp_HandleOpen` | `0xb470` |
| `0x471` | `TrainingCamp_HandleDisband` | `0xb470,0xb471` |
| `0x472` | `TrainingCamp_HandleInvite` | `0xb472` |
| `0x473` | `TrainingCamp_HandleBan` | `0xb473` |
| `0x474` | `TrainingCamp_HandleLeave` | `0xb473,0xb474` |
| `0x475` | `TrainingCamp_HandleGraduation` | `0xb475` |
| `0x476` | `CInstanceTrainingCamp::CheckMembershipLevel` | `0xb476` |
| `0x477` | `TrainingCamp_HandleNoticeUpdate` | `0xb477` |
| `0x478` | `GObjPC_HandleTrainingCampMsg_478` | `0xb478` |
| `0x47a` | `TrainingCamp_HandleMatchingEntry` | `0xb47a` |
| `0x47b` | `TrainingCamp_HandleMatchingCorrect` | `0xb47b` |
| `0x47c` | `GObjPC_HandleTrainingCampMsg_47c` | `0xb47c` |
| `0x47d` | `GObjPC_HandleTrainingCampMsg_47d` | `0xb47d` |
| `0x47e` | `GObjPC_HandleTrainingCampMsg_47e` | `0xb47e` |
| `0x4df` | `GObjPC_HandleAssocReputationMsg_4df` | `-` |
| `0x4e0` | `GObjPC_HandleAssocReputationMsg_4e0` | `-` |
| `0x506` | `GObjPC_HandleOpenMarketGoodsDetailReq` | `-` |
| `0x508` | `GObjPC_HandleOpenMarketPutonGoodsReq` | `-` |
| `0x509` | `GObjPC_HandleOpenMarketPutoutGoodsReq` | `-` |
| `0x50a` | `GObjPC_HandleOpenMarketPurchaseGoodsReq` | `-` |
| `0x50b` | `GObjPC_HandleOpenMarketReceiptReq` | `-` |
| `0x50c` | `GObjPC_HandleOpenMarketSearchReq` | `-` |
| `0x50e` | `GObjPC_HandleOpenMarketMsg_50e` | `-` |
| `0x516` | `GObjPC_HandleSiegeMsg_516` | `0xb516` |
| `0x51a` | `GObjPC_HandleCallUserMsg_51a` | `0xb51a` |
| `0x51c` | `GObjPC_HandleSummonPartyUserMsg_51c` | `-` |


## The server's message buffer, field by field (round 327)

`MsgBuf_ReadUInt8` already carried three of these in its annotation. Reading the
writer, `MsgBuf_AppendBytes` (`0x00404090`), completes the map:

| offset | field |
|---|---|
| `+0x1034` | buffer base |
| `+0x103c` | **read** cursor |
| `+0x103e` | size, which is also the **write** position |
| `+0x104c` | capacity -- exceeding it throws rather than truncating |
| `+0x1050` | the opcode (the dispatcher reads its first word) |
| `+0x1054` | **pointer to the on-wire header's Size word** |

The append does, after the `memcpy` and the size bump:

	*(ushort *)this[0x1054] = (*(ushort *)this[0x1054] & 0x8000) | (size - 6)

**`size - 6` is the payload length**, which confirms the **6-byte header** from
the writer's side, and shows the **`0x8000`** top bit being deliberately
*preserved* across every write -- the behaviour of a carried flag rather than of
a spare bit. Round 328 below says what the flag means. Both were already
recorded in `docs/protocol/opcodes/handshake.md`, read from the checksum side --
"`(Size & 0x7fff) + 6` bytes ... including the real 6-byte header". Two
independent routes to the same frame, which is worth more than either alone.

**This does not revive round 326's killed hypothesis.** That one read a byte at
`+6` of `this->[0x30]`, a different object entirely; the header is real, it was
simply not there. A correct constant found in the wrong place is still the wrong
place.

### Why this matters for the opcode roadmap

Round 324 listed 93 real handlers whose remaining work is "the payload layout".
Every one of them reads its payload through `MsgBuf_Read*` against this buffer,
so the layout of any handler is the **sequence of those calls** -- which is now
a greppable question rather than a reading one.

**Round 328 qualifies that claim.** It is true, but not greppable the naive way,
and the two traps below cost this round most of its time.

## Round 328: the reader families, and what `0x8000` means

### The top bit is the *encoded-request* flag

`Item_HandleUseItem` opens with this, before it touches the payload:

	if ((**(ushort **)(session + 0x1054) & 0x8000) == 0) {
	  FUN_004df050(4);
	  CGameServer::FUN_00936640(0x2000000,"Not Encoded Item Request (%s)",name);
	}

The literal **`"Not Encoded Item Request (%s)"`** names the bit. `0x8000` set
means the request is *encoded*; clear means it is not, and the server logs the
player's name and carries on. This is not an inference from a curve -- the game's
own string says what the bit is, and `MsgBuf_AppendBytes` preserving it across
every write is the corroboration.

### Two reader families: front and tail

There are **two** readers for each width, and a handler picks between them on the
session's `+0x1048`:

| width | front (read at cursor) | tail (read off the end) |
|---|---|---|
| 8-bit | `MsgBuf_ReadUInt8` `0x00404f80`, `0x00521750` | `MsgBuf_ReadUInt8FromTail` `0x005217a0` |
| 16-bit | `MsgBuf_ReadUInt16` `0x004263c0`, `0x0048ba70` | `MsgBuf_ReadUInt16FromTail` `0x00409910` |
| 32-bit | `MsgBuf_ReadUInt32` `0x00404e00`, `MsgBuf_ReadUInt32Into` `0x00403f60` | -- |
| bytes | `MsgBuf_ReadBytes` `0x00404c20` | -- |
| rest | `MsgBuf_ReadRemaining` `0x00404760` | -- |

A **front** read is the ordinary one: bounds-test `cursor + n` against size, read
at `base + cursor`, `cursor += n`.

A **tail** read runs the message backwards: `size -= n`, read at `base + size`,
then rewrite the on-wire Size word as `(Size & 0x8000) | (size - 6)`. It
*shrinks the message as it reads*, which is why it alone must rewrite Size --
and why it preserves `0x8000` while doing so.

The two are used in matched pairs, one branch each:

	if (*(int *)(session + 0x1048) == 0) MsgBuf_ReadUInt8FromTail(&slot);
	else                                 MsgBuf_ReadUInt8(&slot);

What `+0x1048` itself is has **not** been read, and is not guessed here. That it
correlates with the encoded flag is plausible and unproven; it is a separate
field from `+0x1054`, and the correlation has not been measured.

### Trap 1: the readers take the buffer in EAX

Ghidra renders every one of them as taking a single out-parameter:

	void FUN_00403f60(undefined4 *param_1) { int in_EAX; ... }

The message object arrives in **EAX**, which Ghidra did not model as a parameter.
So a reader call reads as `FUN_00403f60(&local)` with no buffer in sight, and
looks like a constructor or an unrelated helper. This is why four earlier rounds
walked past these call sites.

### Trap 2: COMDAT twins

`0x00521750` and `0x0048ba70` are byte-identical second emissions of
`MsgBuf_ReadUInt8` and `MsgBuf_ReadUInt16` -- MSVC emitted the inline in more
than one translation unit. **A handler may call either address.**
`Item_HandleUseItem` calls the twins, not the originals, so a grep for the two
known reader addresses finds nothing in it. Grep the whole family or nothing.

### The discard idiom

A handler about to refuse first does:

	*(ushort *)(session + 0x103c) = *(ushort *)(session + 0x103e);   // cursor = size

That is `MsgBuf_ReadRemaining` inlined, and it is a **discard, not a read**:
consume whatever is left so the unread payload cannot trip a later bounds check,
then send the refusal. `Item_HandleUseItem` does it at four refusal paths and
`GObjPC_HandleOpenAlchemyAtNpcMsg_51d` at two more, each immediately before a
`Msg_SendTwoFieldReply` with an error code.

**Cursor writes are therefore not evidence of payload reads.** Counting them is
how round 328 first concluded, wrongly, that the use-item handler reads nothing.

### `OpUseItem`'s payload, at last

Four rounds owed this. The real request body is two fields:

| field | width | meaning |
|---|---|---|
| 1 | `u8` | **inventory slot**, range-checked `(byte)(slot - 0x0d) < 99` -- valid slots are **13..111** |
| 2 | `u16` | matched against a list derived from the item, then echoed back in the reply |

The slot range is the bag layout stated in the server's own arithmetic: slots
`0..12` are the thirteen equipment/avatar slots, and the ninety-nine bag slots
begin at **13**. The item is then fetched with `CGStorage__GetItem(slot & 0xff)`.

Field 2 is **not named here.** It is read as a `u16`, compared against `*puVar7`
inside a loop over something belonging to the item, reassigned from that same
source on the matching branch, and appended to the reply. That is its whole
observed behaviour; what it selects has not been settled, so it gets no name.

**srrevamp does not implement this.** Its `OpUseItem` carries `(u16 name length,
name, s64 slot)`, which is its own invention -- consistent with round 324's
finding that 0 of 143 srrevamp opcodes are real. The gap is now measured rather
than suspected, and nothing was changed on the strength of it.
