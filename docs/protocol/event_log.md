# The server's event-record formatters

Recovered 2026-09-20 (rounds 338–340). The server keeps a human-readable record
of what happens in the world — kills, guild wars, job rewards, item drops, token
spends. Three functions carry it, and they sit next to each other in the image.

| address | name | what it does |
|---|---|---|
| `0x00936640` | `CGameServer::LogFormatted` | the sink: `__vsnprintf_s` into an 8,191-byte buffer, first argument a category mask |
| `0x00467100` | `GameEventLog_FormatRecord` | 5,067 B. Character and world events |
| `0x00469100` | `ItemEventLog_FormatRecord` | 7,622 B. Item and currency events |

Both formatters are a `switch` over an event kind that builds text and hands it
back through out-parameters. **Neither logs directly** — `ItemEventLog_FormatRecord`
makes zero calls to `LogFormatted` — so where the records finally go is not
established here and is not claimed.

## What each one is, from its own strings

`GameEventLog_FormatRecord` — guild war outcomes
(`GuildWar Guild[%d,%d] Winner[%s]`, `... Surrendered Guild[%d]`), guild
investment (`Invested %d SP to guild [%s]`), the trade-route jobs
(`Trader Contributed to hunter guild: %u gold`, `Trijob Reward Received: %u gold`),
`Mercenary Count[%d]`, `Starvation`, `CampID : %d`, and PvP kill records
(`%s,%s,%s vs %s(PC),%s,%s,%s`, the same with `(PET)`, and
`[%s vs %s(victim: %s)]`). It calls `JobTypeName` ten times.

`ItemEventLog_FormatRecord` — item serial changes
(`%d : Serial Change %I64d -> %I64d`), drops and pickups
(`%I64d, %I64d -> %I64d, %s, %s, picker[%s]`, `0,failed to drop item`,
`0,Unknown,picked item == NULL`), the four arena token currencies
(`Remain TokenGold / TokenSilver / TokenBrass / TokenMedal : %d ==> %d`) and
`%I64d, Trader JobLvl: %d`. It calls `GObjPC::DumpItemWithOptions` eleven times.

**`ItemEventLog_FormatRecord` was characterised before it was named.** The
2026-09-17 entry in `RE_COMPLETION.md` already described this address as "a
7,622-byte logging function full of item-serial, drop, gold and token messages",
reached by a different pass while disproving a label-based naming rule. It was
never filed as a name until round 340 — the same gap as
`MsgBuf_ReadUInt32FromTail`, which sat identified in a published table for eleven
rounds. **Being characterised in prose is not being named.**

## An open lead, and why it is not taken

`0x00468a80` calls `ItemEventLog_FormatRecord` and is itself called from **50
sites**, each passing a distinctive small constant — `0x9f`, `0x83`, `0x50`,
`0xaa`, `0xa9`, `0xa0`, `0x99`, `0x94` … That looks like a vocabulary of item
event kinds, and recovering it would label fifty call sites at once.

**It is not taken here, because the argument order is not trustworthy.** Ghidra
types the first parameter as `int *` and the body immediately uses it as an
object with a vtable (`(**(code **)(*param_1 + 0x1c))()`), yet the call sites
read `FUN_00468a80(0x9f, …)`. Both cannot be the first argument. This is exactly
the shape that forced round 323's retraction, where Ghidra's argument for
`Msg_SendTwoFieldReply` was wrong and a whole conclusion rested on it — the real
operands were an immediate pushed on the stack and a value in ECX, readable only
from disassembly.

So the next step for this lead is to read the call sites in `srgs.asm` and settle
which operand is the kind, before any of the fifty is labelled.
