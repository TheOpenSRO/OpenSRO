# Real opcodes observed being sent (harvested 2026-08-22)

## Real names found via public documentation (2026-08-23)

Cross-referenced every harvested opcode below against public private-server community
documentation ([`JellyBitz/srodevs-docs`](https://github.com/JellyBitz/srodevs-docs) -- the same
source that solved this project's `.m`/`.t`/`tile2d.ifo` formats; fair game per
[`docs/LEGAL.md`](../../LEGAL.md) point 3). **13 real, exact matches**, each a genuine
cross-validation (independent binary opcode-harvest agreeing with independent public
documentation, not one source trusted blindly):

| Opcode | Real name | Direction |
|---|---|---|
| `0x1001` | `DOWNLOAD_FILE_CHUNK` | S→C |
| `0x2001` | `GLOBAL_MODULE_IDENTIFICATION` | S→C |
| `0x2322` | `GATEWAY_LOGIN_IBUV_CHALLENGE` | S→C |
| `0x3026` | `AGENT_CHAT_UPDATE` | S→C |
| `0x5000` | `GLOBAL_HANDSHAKE_CHALLENGE` | (already confirmed, `handshake.md`) |
| `0x6004` | `DOWNLOAD_FILE_REQ` | C→S |
| `0x7005` | `AGENT_GAME_LOGOUT_REQ` | C→S |
| `0xa004` | `DOWNLOAD_FILE_COMPLETE` | S→C |
| `0xa101` | `GATEWAY_SHARD_LIST_ACK` | S→C |
| `0xa102` | `GATEWAY_LOGIN_ACK` | S→C |
| `0xa103` | `AGENT_LOGIN_AUTH_ACK` | S→C (already confirmed via decompilation, see `login.md`) |
| `0xa106` | `GATEWAY_SHARD_LIST_PING_ACK` | S→C |
| `0xa323` | `GATEWAY_LOGIN_IBUV_CONFIRM_ACK` | S→C |

See `login.md`'s new "The real, complete wire sequence" section for the full real gateway login
flow (including several more opcodes this public source names and gives real payloads for that
weren't in this project's own harvested list at all, e.g. `0x6100`-`0x6106`/`0x6102`-`0x6103`
being real *client-sent* requests this harvest technique — which only finds opcodes a binary
*writes*, i.e. sends — could never have found on its own).

Cross-referenced against every `packets/agent/`, `packets/gateway/`, and `packets/global/` file
this public source has (~30 agent-side packets covering login/character-select/movement/chat/
logout/skill-buff traffic) -- the 13 matches above are everything this source and this project's
own harvest currently have in common. The other ~85 harvested-but-unnamed values below aren't a
gap in this cross-check; this public source simply doesn't document that many distinct real
gameplay opcodes yet (its own coverage is real but partial, weighted toward login/character-select
over deep gameplay systems like inventory/trade/party/guild). Re-checking this cross-reference if
the source ever adds more `packets/agent/` pages is a real, cheap, well-scoped future step.


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

## `SR_GameServer.exe` (79 unique values) — the real gameplay-opcode surface

Imported and ran the same harvest against `SR_GameServer.exe` (same package, ~9x larger than the
other two binaries -- the real main world/gameplay server, not just login/relay). Re-found
`0x5000`/`0x9000` (handshake) and `0x6004`/`0x6008`/`0x6009`/`0x600d`/`0xa004`/`0xa008`/`0xa009`/
`0xa300`/`0xa303` (the shared `ServerFramework` infrastructure cluster already seen in both other
binaries) at the same values -- consistent, real cross-binary validation again.

New, real, gameplay-specific opcode families not seen in the other two binaries at all:

- **`0x30xx`**: `0x300c`, `0x3026`
- **`0x34xx`**: `0x34b1`, `0x34ba`, `0x34bb`, `0x34d2`, `0x34f2`
- **`0x35xx`/`0x38xx`/`0x3cxx`**: `0x3510`, `0x385f`, `0x3864`, `0x3c80`, `0x3cf1`, `0x3d02`
- **`0x22xx`/`0x23xx`**: `0x2001`, `0x2007`, `0x200a`, `0x200c`, `0x2209`, `0x220a`, `0x220e`,
  `0x220f`, `0x2311`
- **`0x69xx`/`0x70xx`/`0x71xx`**: `0x6904`, `0x7005`, `0x711b`
- **`0x74xx`/`0x78xx`/`0x7bxx`/`0x7cxx`** (the largest cluster -- plausibly world/entity/chat
  traffic): `0x74b0`, `0x74d0`, `0x74db`, `0x7808`, `0x7866`, `0x78f7`, `0x78fe`, `0x7908`,
  `0x7b06`, `0x7c00`, `0x7c10`, `0x7c14`, `0x7c16`, `0x7c80`, `0x7c81`, `0x7c84`, `0x7cdc`, `0x7ce6`
- **`0xa2xx`**: `0xa208`
- **`0xb0xx`/`0xb4xx`/`0xb8xx`/`0xbcxx`** (plausibly guild/social traffic, matching the real `0xB0xx`
  range long documented by the private-server community for this): `0xb002`, `0xb003`, `0xb004`,
  `0xb4b7`, `0xb4d1`, `0xb80b`, `0xbc00`

These real address ranges (`0x30xx`-`0x3Cxx`, `0x74xx`-`0x7Cxx`, `0xB0xx`-`0xBCxx`) line up with
the general opcode-family layout long documented by the private-server community for this MMO
family (character/inventory-ish low ranges, world/entity-ish `0x7xxx`, guild/social-ish `0xBxxx`)
-- a real, independent cross-check that this harvest found genuine gameplay opcodes, not noise.
None of these are named or have a pulled payload yet -- this is a real, concrete list of opcode
*numbers* to target for future per-opcode RE passes, the same honest confidence level this project
already applies to other found-but-unparsed opcodes.

**Higher false-positive rate here, noted honestly**: this larger, more complex binary produced far
more small-value hits (`0x0004` through `0x0380`, `0xffff`) than the other two -- 15 values under
`0x400`, versus 3-4 in the smaller binaries. `+0x1050` is plausibly reused as a generic small
struct-field offset elsewhere in this bigger codebase, unrelated to message headers, more often
than in the smaller ones. Treat every value below `0x1000` from this specific binary as unconfirmed
noise unless independently corroborated, more so than the equivalent caution already applied to
the other two binaries' small-value hits.

## How to extend this

Re-run the same harvest against a different real per-object offset once one is confirmed for a
different message-carrying class (e.g. if `CSession`/`ACTIVE_SESSION` turn out to have a different
relative offset than `+0x1050` once that's nailed down), or against `SR_ShardManager.exe`
(same package, not yet imported) for whatever real cross-shard traffic that binary carries. None
of these opcodes' payload layouts are pulled yet -- that's real, separate, per-opcode work, same as
`0x5000`/`0x9000` still need before `handshake.md`'s own status section is fully checked off.
