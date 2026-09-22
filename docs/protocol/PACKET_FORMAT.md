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
handler `0x51d` (`FUN_0051c050`) at two more, each immediately before a
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

## Round 329: every handler's payload, in one pass

Round 328 identified the reader family and the traps around it. This round spends
that: **103 of the 163 real handlers now have a decoded field sequence**, in
`docs/protocol/handler_payloads.tsv`. It replaces 93 separate readings with one
pass, which is what round 327 promised and round 328 made possible.

### The family is complete and symmetric

Enumerated **by shape, not by the addresses already known** -- any function that
references `+0x1034` and advances either the cursor `+0x103c` or the size
`+0x103e`. Twenty-three primitives, paired front/tail at every width:

| width | front (at the cursor) | tail (off the end) |
|---|---|---|
| 1 | `0x00404f80`, `0x00521750` | `0x005217a0` |
| 2 | `0x004263c0`, `0x0048ba70`, `0x005e32b0` | `0x00409910` |
| 4 | `0x00403f60`, `0x00404e00`, `0x00423f20`, `0x005e3200` | `MsgBuf_ReadUInt32FromTail` `0x005216c0`, twin `0x00423f70` |
| 8 | `0x0042c6e0`, `0x00969830` | `0x0042c740`, `0x00969890` |
| 12/16/24 | `0x005b8520`, `0x005e2c20`, `0x004b22b0` | -- |
| 256/272 | `0x004a1b40`, `0x00438e80` | -- |
| variable | `0x00404c20` (length in DI) | -- |

The 32-bit tail pair was enumerated here in round 329 and only FILED as a name in round 336b -- a reminder that appearing in a published table is not the same as being named, the same gap recorded in the naming-coverage memory.

The duplicates per width are COMDAT twins, which is exactly why round 328's grep
for two known addresses came back empty on a handler that reads two fields.

**The enumeration took three attempts, and both failures were the probe.** The
first required `in_EAX` and so missed every primitive taking the buffer as an
ordinary parameter. The second still missed `MsgBuf_ReadUInt8` because the cursor
advance is written `*(ushort *)` there and `*(short *)` elsewhere, and the regex
allowed only the latter. An empty result was a fact about the regex both times;
the tell was that primitives *already named in this repo* were absent from a list
claiming to be complete.

### Reading a pair as one field

A handler selects front or tail on the session's `+0x1048`, so a single wire
field decompiles as two calls:

	if (*(int *)(session + 0x1048) == 0) ReadUInt8FromTail(&slot);
	else                                 ReadUInt8(&slot);

These collapse to one field when both calls share a width and an out-argument.
**The collapse was verified, not assumed**: 66 of 69 collapsed pairs have a
`0x1048` test within the six preceding lines. The three that do not are flagged
`check-pair` in the table rather than trusted -- a wrong collapse is a wrong
layout, so they are marked, not quietly counted.

### What the table said, and what it does not

**Superseded by round 330 below.** The counts here describe this round's
single-sided pass; the shipped `handler_payloads.tsv` now carries two derivations
per row and a different set of columns. The confidence reasoning below still
holds -- it is why the `direct` rows survived the cross-check intact.

| | handlers |
|---|---:|
| decoded field sequence | **103** |
| of those, `linear` (all reads at function top level) | 74 |
| of those, `branched` (reads inside conditionals) | 26 |
| of those, `check-pair` (collapse unverified) | 3 |
| no reader calls -- inlined or delegated to a callee | 60 |

**`branched` is a real caveat, not a formality.** The sequence is *source* order,
which is wire order only when the reads are unconditional. Where reads sit inside
branches the order still needs a human; those 26 are marked so nobody reads the
column as settled.

The 60 with no reader calls are not failures of the method -- eleven of them
inline the reads outright (`GObjPC_HandleGuildMsg_104`,
`CGObjPC::vslot_291`, both Temple gate handlers, and seven more), and the rest
hand the buffer to a callee. Both are tractable; neither is done here.

### The cross-check that matters

A server-side decode is one probe. The **client's encoder is an independent one**,
in a different binary, and the two must describe the same wire. For `OpUseItem`
(`0x704c`) the client does:

	local_49 = (char)param_1 + '\r';       // bag index + 13
	FUN_00508fe0(&local_49,1);             // write 1 byte
	uVar6 = FUN_008ba440();                // the item's refdata record
	FUN_00508fe0(uVar6,2);                 // write 2 bytes

**`u8` then `u16`** -- exactly what the server-side pass derived, without
reference to the client. And `+ '\r'` is **+13**, the same constant as the
server's range check `(byte)(slot - 0x0d) < 99`, reached from the opposite side.
Two binaries, two derivations, one layout and one constant.

It also improves round 328's reading of the second field. `FUN_008ba440` looks
the item up in `GlobalDataManager` by its `+0x34` and the client writes the first
`u16` of that reference-data record, having bit-tested it as a discriminator
(`& 0x1c == 0xc`, `& 0x780 == 0x180`, `& 0xf800 == 0x2800`). So the field is the
item's **packed type code**, sent so the server can check the client's claim
against the item actually in the slot -- which is what "matched against a list
derived from the item, then echoed" meant. **It still gets no name**: the refdata
field's own identity has not been confirmed, and a consistent story is not a
citation.

## Round 330: reading the other side, and throwing away a third of the answers

Round 329 decoded 103 handlers from the server's readers and noted two obvious
next levers: the 60 handlers that call no reader (they delegate to a callee), and
a proper cross-check. Doing the second **killed** the first, which is the useful
part of this round.

### Following the delegation looked like it worked

Expanding each handler's callees one and two levels deep and splicing the
callee's reader sequence in at the call site raised coverage from 103 to **133 of
163**. Nothing about the output looked wrong: plausible field counts, sensible
widths, no obvious garbage in most rows.

### The client says a third of those are wrong

The client must write the wire the server reads, so its encoder is an independent
derivation in a different binary. `CMsgStreamBuffer_Construct(<opcode>)` opens a
request and `FUN_00508fe0(src, len)` -- the client's chunked stream write, `len`
in the second visible argument -- appends each field. That gives a write sequence
for **121 request opcodes**, derived without reference to the server at all.

Comparing the two, **split by how the server side was derived**:

| server-side method | agrees with client | mismatches |
|---|---:|---:|
| `direct` (reads in the handler itself) | **90** | **0** |
| `inline` | 1 | 0 |
| `delegated` (one level) | 8 | 4 |
| `delegated2` (two levels) | 2 | 2 |

**The direct decode is 90 for 90 against an independent binary.** The delegation
expansion is 10 of 16 -- at two levels it is barely better than a coin flip. Every
single mismatch in the whole comparison came from delegation, and some are plainly
nonsense in hindsight (`Guild_HandleWarDeclaration` acquired three
`bytes(DI)` fields of unknown length from a spliced helper; `0x706c` gained a
`u32` the client never sends).

So the 30 extra layouts are **not published as decoded**. A method that produces
confident, well-formed, wrong answers two times in six is worse than no method,
and the only reason this is known is that a second probe with a different failure
mode was run before shipping.

**The delegated rows are kept only where the client confirms them exactly.** That
is not circular: the expansion and the client encoder fail in unrelated ways, so
exact agreement between them is real evidence even though the expansion alone is
not. Ten rows survive that way and say so in their `note`.

### What the table holds now

`docs/protocol/handler_payloads.tsv`, 163 rows, two independent derivations per
row where both exist:

| | handlers |
|---|---:|
| **cross-confirmed by both sides** | **98** |
| server-side decoded (trusted methods) | 110 |
| client-side layout available | 110 |
| at least one side | 122 |
| neither side | 41 |
| unresolved mismatches | **0** |

`agreement` says which: `exact` (81), `server-prefix` (14, the handler reads the
first fields and delegates the rest), `client-prefix` (3, the handler reads a
sub-command then branches -- `0x010` is the clear case, one `u16` selector and ten
client variants behind it), `server-only`, `client-only`.

### Reading this table honestly

- **`exact` is a genuine two-binary fact.** Two derivations, no shared code path,
  same answer.
- **`client-only` is one-sided evidence**, and it is the *encoder*, so it is good
  evidence about the wire -- but the server may read those bytes differently, and
  nothing here proves it does not.
- **`server-prefix` is expected, not a defect.** A handler that reads a header and
  hands the rest to a subsystem genuinely reads a prefix.
- **41 handlers have neither side.** They are not attempted here, and no row
  pretends otherwise.


## The failure-reply shape, read out of its helper (round 443)

`Msg_SendTwoFieldReply` (`0x4e7250`, 74 bytes) is used by **38+ call sites**
across the server, and its name understates it: it does not send two arbitrary
fields, it sends a **refusal**. Its own instructions give the layout:

	4e725a:  push ecx                     ; ECX = the reply opcode
	4e725d:  call [esi+0x278]             ; open the message
	4e7261:  lea  eax,[esp+0x7]
	4e726d:  mov  BYTE PTR [esp+0xb],0x2  ; the helper WRITES the 2 itself
	4e7272:  call append(len = 1)         ; field 1: u8, constant 0x02
	4e7277:  lea  ecx,[esp+0xc]           ; the caller's single pushed dword
	4e727c:  mov  eax,2
	4e7283:  call append(len = 2)         ; field 2: u16, the refusal code
	4e7293:  call [edx+0x27c]             ; send
	4e7297:  ret  0x4                     ; exactly ONE stack argument

So every reply it sends is:

	u8   0x02      -- constant, written by the helper, never by the caller
	u16  code      -- the caller's one pushed word

**`ret 0x4` is the control**: the helper takes exactly one stack argument, which
is why round 442 found every path in the berserk handler pushing exactly one
word. A reading that assigned the caller two fields would contradict the
callee's own stack cleanup.

**And the `0x02` is the answer to a question this file did not know it had.** It
is not data the caller chose; it is a literal the helper stores, so **every
refusal in the game carries a leading `0x02`** — the conventional
"result = failure" byte, with success replies built elsewhere.

**Read the opcode from ECX, never from the decompiled argument.** That is
already recorded on the function (Ghidra "names sometimes the opcode and
sometimes the payload", the error that invalidated round 323's sweep and was
withdrawn in round 325); the disassembly above shows why — the opcode arrives in
`ECX` and the payload on the stack, and Ghidra's single `param_1` collapses
them.

### What it completes for `0xb0a7` (berserk)

	request  0x70a7   u8   1 = activate                       (round 441)
	refusal  0xb0a7   u8 = 2, u16 = code in {1, 3, 4, 5}      (rounds 442, 443)

with the guards for each code in `server/internal/proto/opcodes.go`. **The
SUCCESS reply is still unread** — the success path does not call this helper at
all, it falls through to `SetBodyMode`, so whatever the client learns on success
arrives by another route. Until that is read, `session.OpBerserk` (`0x0068`)
stays the live placeholder, per `PROTOCOL_DECISION.md`.

## The message helpers, censused by caller count (round 447)

Rounds 443 and 444 each found that a *shared* helper explained far more than the
opcode that led to it. The systematic form is to census every function that both
**opens** a message (vtable slot `0x278`) and **sends** it (`0x27c`). There are
**327** of them. Ranked by callers, with full-name matching:

| helper | callers | bytes |
|---|---:|---:|
| `Msg_SendTwoFieldReply` | **160** | 74 |
| `CTradeMgr::SendItemExchangeResult` (`0x4806d0`) | **15** | 511 |
| `CGObjPC::FUN_004f0a00` | 12 | 197 |
| `FUN_0059ad90` | 11 | 123 |
| `FUN_005107c0` | 7 | 447 |

**`Msg_SendTwoFieldReply`'s 160 callers confirm round 443's leverage claim** —
its own note said "over 38 resolvable sites", which was a subset. One 74-byte
function shapes the refusal reply for a sixth of the server's message traffic.

**A probe defect worth recording.** The first run matched callers by *bare* name
and reported four different functions with exactly 180 callers each — the tell
that `vslot_002` is a bare name shared by dozens of classes, so every call to any
of them matched all of them. That is the spurious-edge error round 408 recorded
about its own bare-name fallback, reintroduced here and caught by the
suspiciously identical counts. **Full-name matching only.**

## The 32-bit timestamp the protocol carries (round 448)

`CGObjPC::PackSystemTime` (`0x4f8860`, 71 bytes) packs a Win32 `SYSTEMTIME` into
one dword:

	bit  0.. 5   (wYear - 0x10) & 0x3f      -- equals wYear - 2000 near the epoch
	bit  6.. 9   wMonth  & 0x0f
	bit 10..14   wDay    & 0x1f
	bit 15..19   wHour   & 0x1f
	bit 20..25   wMinute & 0x3f
	bit 26..31   wSecond

**Two things prove it is a `SYSTEMTIME` rather than a guess at a date layout.**
The widths total **exactly 32** (6+4+5+5+6+6). And it reads `ushort` indices
0, 1, 3, 4, 5, 6 — **skipping index 2**, which in a `SYSTEMTIME` is
`wDayOfWeek`, the one redundant field a packer drops. `(wYear - 16) & 0x3f`
equals `wYear - 2000` because `2000 - 16` is a multiple of 64.

Reached from `CGObjPC::FUN_004f0a00`, which sends opcode **`0x3405`** as
`{mode byte, packed timestamp}` behind a capability gate. That helper has
**twelve callers spanning unrelated subsystems** — trade, flea market, guild
notice, messenger, training-camp notice — which is what a generic
timestamp-bearing notice looks like.

**A hypothesis refuted on the way.** Those cross-subsystem callers all put a
player into an *interaction* state, so `0x3405` looked like the broadcast of
`chardata+6`'s INTERACTMODE (round 426). Reading the payload killed it: the
second field is a packed date, not a mode. The better finding was underneath the
wrong one.
## The read cursor, and the rewind idiom (round 449)

Two `ushort` fields sit at the end of the server's inbound message object:

	msg + 0x103c    the current read cursor
	msg + 0x103e    the payload base

and the whole dump contains exactly one idiom over them:

	*(undefined2 *)(msg + 0x103c) = *(undefined2 *)(msg + 0x103e);

**About 300 sites, and the assignment never appears in the other direction.**
`+0x103e` is written only by one other form, `*(ushort *)(msg + 0x103e) -= 6`
(7 sites), which backs the base up over a six-byte header. So the idiom is a
**rewind**: put the cursor back to the start of the payload.

Handlers use it when they are abandoning a read — `GObjPC_HandleShopMsg_046`
rewinds on both of its early refusals, before it has read anything, and
`GObjPC_HandleEndInteractionMsg_04b` rewinds at entry and then reads nothing at
all. That last one is worth noting against `handler_payloads.tsv`, which records
opcode `0x04b` as carrying a `u32`: the client does send it, and **the server
discards it**.

A third field, `msg + 0x1048`, selects which reader family runs — every field
read in the server is shaped

	if (*(int *)(msg + 0x1048) == 0)  MsgBuf_Read<T>FromTail(&out);
	else                              MsgBuf_Read<T>Into(&out);

so the same handler code serves two buffer layouts.

## Reading a payload at all: the length is in AX (round 461)

`SYSTEMS.md`'s Packet-protocol row asks for one named handler's payload, on the
grounds that "a real opcode number without the real layout is worse than a
placeholder". The reason payloads had not been read in bulk is mechanical:

	MsgBuf_AppendBytes(0x404090):  length in AX, source in the second argument

**AX is a register Ghidra drops**, so every append in the decompiled C looks
size-less — `MsgBuf_AppendBytes(&uStack_19)` says nothing about whether that is
one byte or four. The sizes are all there in the disassembly as a `mov eax,N`
immediately before the call.

`tools/payload_layout.py` does this: give it an address range and it lists every
append with the length set before it, marking `VAR` when a call intervenes and
eax cannot be trusted. **It declines rather than guesses**, which is what makes
its output usable.

**Two controls, both reproducing a packet documented from a different route:**

	Msg_SendTwoFieldReply (0x4e7250)   ->  len 1, len 2    = {u8, u16}   (round 443)
	CGObjPC::FUN_004f0a00              ->  len 1, len 4    = {u8, u32}   (round 448)

## `0xb045`, the select-entity reply

The packet the client gets when it selects an NPC or a monster — and the one
that carries the interaction ids (`docs/protocol/character_state.md`). Built by
`FUN_0050faf0` (dispatch index `0x0c4`); `FUN_0050fe50` (index `0x045`) resolves
the entity and delegates to a per-type builder through slot `0x34`.

	u8    status          0x50fc3c
	u32   entity id       0x50fc4d
	u8                    0x50fc82   -- only on the branch where the target
	                                    carries no extended data
	  ... otherwise slot 0x38c (CGObjChar::PublishAvailableInteractions,
	      called at 0x50fca4) appends, in its place:
	u8    count           0x4a975f   -- the size of the interaction set
	u8  x count           0x4a97ae   -- one interaction id each, from the loop
	u16                   0x4a97ed   -- conditional
	u8                    0x4a982e   -- conditional

**The two appends after the slot call are NOT part of this payload.** They sit
past a `ret 0x4` on a separate branch and write `{u8 = 2, u16}` — the standard
two-field refusal, inlined rather than called. Reading them as trailing fields
is the mistake the address ordering invites, and the `ret` is what rules it out.

The three conditional trailers are ordered here by address, not by source order;
which branch reaches which was not traced.

## The sweep: 312 senders' payload layouts (round 462)

Round 461 turned the payload problem from a dig into a sweep. `tools/payload_sweep.py`
runs it over the whole server and writes `docs/protocol/payload_layouts.tsv`.

**How a sender is found.** A message is opened through vtable slot `0x278`, and
the opcode is a plain push:

	mov eax,DWORD PTR [edx+0x278]
	push 0xb045
	mov ecx,<this>
	call eax

so the opcode is recoverable without reading the function. Each field is then a
`MsgBuf_AppendBytes` whose **length is in AX** (round 461).

**Coverage: 312 senders, 296 with at least one field, 264 fully fixed** (no
field whose length a call clobbered). By shape, the protocol is mostly small:

| layout | senders |
|---|---:|
| `1` | 52 |
| `1,1,2` | 25 |
| `1,1` | 25 |
| `1,2` | 17 |
| (no appends) | 16 |
| `1,4` | 14 |

**Four controls, each a packet read by hand in an earlier round, all reproduced
exactly:**

	0xb045  FUN_0050faf0             1,4,1,VAR,2   round 461
	0xb04b  GObjPC::EndInteraction   1             round 449
	0x3405  CGObjPC::FUN_004f0a00    1,4           round 448
	0xb046  GObjPC_HandleShopMsg_046 1,1,1         round 449

**`1,1,2` is the shared refusal tail**, not 25 coincidences: every one of the
seventeen `SiegeFortressMgr::Handle*` functions ends in the same
`{u8, u8 = 2, u16 code}` reply on `0xb05e`, which is what round 452 read by hand
in the dispatcher.

### What this table is not

- **`VAR` means the tool declined**, because a call between the `mov eax,N` and
  the append may have clobbered eax. 32 senders have at least one.
- **23 senders open more than one opcode** and are listed with both, because the
  appends cannot be attributed between them without reading the branches.
- **The appends are the function's own.** A payload continued in a callee is
  missing — `0xb045` is exactly this case, its interaction block appended by
  slot `0x38c` and so absent from its row.
- **A `mov eax,N` could in principle set a value rather than a length.** In
  `0xb045` the status byte's value and its length are both 1 and share the one
  instruction. The four controls are the reason to trust the reading, not the
  pattern alone.

So the table is a **starting map, not a spec**: it says how many fields a packet
has and how wide each is, which is what was missing, and it does not say what
any field means.
