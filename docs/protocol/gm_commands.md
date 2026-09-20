# The GM / special-command vocabulary (opcode 0x7010)

Recovered 2026-09-20 (round 339). `GObjPC_MsgHandler_SpecialCommand::DispatchCommand`
(`0x0051de90`) is the **largest handler in the server at 9,173 bytes**, and it is
large because it is not one command: its body is a single
`switch (selector & 0xffff)` over **35 sub-commands**. One opcode, a whole
vocabulary.

This is why `handler_payloads.tsv` records `0x010` as `client-prefix` with ten
client variants behind one `u16` — that `u16` is the selector below.

## What identifies it

Its own format strings, and one independent corroboration:

	"MoveTo: [%d, (%f, %f, %f)]"
	"MoveToPlayer: %s [%d, (%f, %f, %f)]"
	"Pos of %s: %s (%.2f, %.2f, %.2f)"
	"ShowMeStatistics: [PC: %d, NPC: %d, ItemOnGrd: %d"

**Case `0x1f` calls `CGObjPC__OnCommandMoveToNpc`** — a name recovered in an
earlier pass, from a different lever, whose own wording says these are commands.
That is the check that makes the reading more than a guess about four strings.

## The table

`identified` means the case names itself, through a format string or a call to an
already-named function. `attributed` means the only evidence is which singleton
it reaches — the subsystem, not the action, and by this project's own rule that
is **not a name**. `unidentified` means neither.

| selector | evidence | reading |
|---|---|---|
| `0x01` | `"Pos of %s: %s (%.2f, %.2f, %.2f)"` | **identified** — report a position |
| `0x04` | `"ShowMeStatistics: [PC: %d, NPC: %d, ItemOnGrd: %d"` | **identified** — server object census |
| `0x08` | `"MoveToPlayer: %s [%d, (%f, %f, %f)]"` | **identified** — teleport to a player |
| `0x10` | `"MoveTo: [%d, (%f, %f, %f)]"` + `GetSingleton_CGameWorldMgr` | **identified** — teleport to a coordinate |
| `0x1f` | calls `CGObjPC__OnCommandMoveToNpc` | **identified** — move to an NPC |
| `0x12` | `GetSingleton_CGuildManager` | attributed — a guild command |
| `0x15`, `0x16` | `GetSingleton_CEventDaemonMgr` | attributed — event-daemon commands |
| `0x13`, `0x37` | `GetSingleton_CGameWorldMgr` | attributed — world-manager commands |
| `0x04`, `0x0d` | `GetSingleton_00d6a8e8` | attributed — the unnamed singleton at `0xd6a8e8` |
| `0x07`, `0x26` | `GetSingleton_00d6aa14`, `CLAMP` | attributed — a clamped numeric setter |
| `0x02` `0x03` `0x05` `0x0a` `0x11` `0x14` `0x1b`–`0x1e` `0x20` `0x21` `0x30` `0x32` | reply only | unidentified |
| `0x06` `0x0c` `0x0e` `0x0f` `0x19` `0x1a` `0x2a` `0x2b` | no call, no string | unidentified |
| `default` | `Msg_SendTwoFieldReply` | refuses an unknown selector |

**Five of thirty-five are identified, and that is the honest count.** Most cases
do nothing but read a field and append a reply, so they carry no text and no
distinctive callee; naming them needs their payload read, which is a per-case job
rather than a lever.

## What this does NOT say

The selector numbers are the server's own switch labels. **Nothing here claims a
mapping to whatever the GM client types**, because the command *names* are not in
this binary — only their effects. The four format strings are log output, not a
command table.
