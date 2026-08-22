# Real opcodes observed being sent (harvested 2026-08-22)

A real, concrete opcode catalog, found by a new technique that came out of `dispatch.md`'s
"header-size discrepancy" trace: this project's own confirmed real per-message header field
(`MsgID`, at a `+0x1050`-relative offset on the outgoing message object -- see `handshake.md`)
gets written via a real, consistent two-instruction shape: an address computation
(`LEA reg, [base+0x1050]` or equivalent), then a plain `MOV word ptr [reg], <opcode>` with no
visible displacement. Scanning for that two-instruction shape across a whole binary harvests every
literal opcode value the binary writes into an outgoing message, in bulk, instead of one at a time.

**What this confirms and doesn't**: every value below is a real, literal 16-bit constant the
binary writes into a message's `MsgID` field before sending it -- i.e. confirmed real opcodes,
server -> client (or gateway -> agent, for `AgentServer.exe`). It does **not** confirm payload
layout, does not confirm a *client -> server* direction for any of these (only that something
sends them), and a few low values (`0x0004`, `0x0008`, `0x0020`, `0x0028`) are likely false
positives -- register reuse for something unrelated shortly after the `+0x1050` load, not real
short opcodes; kept in the raw list below for completeness but flagged as suspect.

**Validation**: this technique re-found all four opcodes already independently confirmed by other
means this session (`0x5000`, `0x9000` -- real handshake, `handshake.md`; `0x6201`, `0xa103` --
real Gateway-to-Agent login hand-off, `dispatch.md`) at the exact same values, in the expected
binaries. That gives real confidence the rest of this harvest is genuine too, not noise.

## `AgentServer.exe` (33 unique values)

`0x1001`, `0x1060`, `0x2001`, `0x2007`, `0x200a`, `0x200c`, `0x2113`, `0x2311`, **`0x5000`**
(handshake, confirmed), `0x6004`, `0x6008`, `0x6009`, `0x600d`, **`0x6201`** (login hand-off,
confirmed), `0x6204`, `0x6205`, `0x6208`, `0x6902`, **`0x9000`** (handshake, confirmed), `0xa004`,
`0xa008`, `0xa009`, **`0xa103`** (login hand-off, confirmed), `0xa203`, `0xa207`, `0xa20d`,
`0xa300`, `0xa303`, `0xa902`, `0xa905` -- plus the suspect low values `0x0004`, `0x0008`, `0x0028`.

## `GatewayServer.exe` (36 unique values)

`0x1001`, `0x1060`, `0x2001`, `0x2007`, `0x200a`, `0x200c`, `0x2311`, `0x2322`, **`0x5000`**
(handshake, confirmed), `0x6004`, `0x6008`, `0x6009`, `0x600d`, `0x6111`, `0x6112`, `0x6200`,
`0x6203`, `0x6321`, **`0x9000`** (handshake, confirmed), `0xa004`, `0xa008`, `0xa009`, `0xa101`,
`0xa102`, `0xa106`, `0xa300`, `0xa303`, `0xa307`, `0xa309`, `0xa312`, `0xa321`, `0xa323` -- plus
the suspect low values `0x0004`, `0x0008`, `0x0020`, `0x0028`.

Real overlap between the two binaries (`0x1001`, `0x1060`, `0x2001`, `0x2007`, `0x200a`, `0x200c`,
`0x2311`, `0x5000`, `0x6004`, `0x6008`, `0x6009`, `0x600d`, `0x9000`, `0xa004`, `0xa008`, `0xa009`,
`0xa300`, `0xa303`) is itself a real, useful signal -- these are plausibly generic/shared
`ServerFramework` infrastructure messages (the same shared codebase both binaries are built from,
confirmed in `dispatch.md`), not gameplay-specific ones. The non-overlapping values are more likely
each binary's own real, specific traffic: `GatewayServer.exe`'s `0x61xx`/`0x62xx`/`0x63xx` cluster
(`0x6111`, `0x6112`, `0x6200`, `0x6203`, `0x6321`) sits in the address range publicly documented by
the private-server community for this MMO family as the real login/server-list/shard-select
sequence -- consistent with `GatewayServer.exe` being exactly where that traffic terminates
(`dispatch.md`).

## How to extend this

Re-run the same harvest against a different real per-object offset once one is confirmed for a
different message-carrying class (e.g. if `CSession`/`ACTIVE_SESSION` turn out to have a different
relative offset than `+0x1050` once that's nailed down), or against `SR_GameServer.exe`/
`SR_ShardManager.exe` (same package, not yet imported) for real world/gameplay-specific opcodes
beyond login. None of these opcodes' payload layouts are pulled yet -- that's real, separate,
per-opcode work, same as `0x5000`/`0x9000` still need before `handshake.md`'s own status section
is fully checked off.
