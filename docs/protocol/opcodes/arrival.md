# The arrival: 0x34B5, 0x34B6, 0x3012

Round 786 (part). The full sequence, both binaries, is `docs/protocol/arrival_guard.md`.

| Opcode | Direction | Retail (READ) | OpenSRO |
|---|---|---|---|
| `0x34B5` SR_RESET_CLIENT | S->C | sent by `CMainProcess::CharDataSavingCompleted` (0x437de0) with the arrival's region WORD; the client's `FUN_0086e100` answers 0x34B6 at once and runs `OnResetClient` (0x86dab0): zone reset, loading screen | not sent: OpenSRO's arrival is its own `OpChangeZoneResult` 0x0027 / `OpEnterWorldResult` 0x0021 (placeholders, PROTOCOL_DECISION.md) |
| `0x34B6` | C->S | an acknowledgement of the reset, sent before any loading (0x86e100); the server's `FUN_00402e60` -> 0x437e80 re-logs the entry (0x7005) | not used |
| `0x3012` SR_READY_TO_PLAY | C->S, **empty** | sent by `FUN_0084c060` as the loading screen comes down, once the zone is in (0x84c1b1..0x84c208); the server's `Game__EnterWorld` (0x403350) -> `CGame::EnterWorld` (0x417240) puts the PC into its block (the 0x3015 to the watchers) and then sets body mode 2 (`CGObjPC::vslot_391`) | **used, retail's number and payload** (`session.OpReadyToPlay`, `WorldNet.OP_READY_TO_PLAY`). OURS framing: it answers OpenSRO's own arrival message rather than 0x34A6; the client sends it from `World3D._drain_initial_load`'s end (`ArrivalGuard.ReadyReport`); the server's `releaseArrival` does what `CGame::EnterWorld` does. A 0x3012 when nothing is held does nothing (OURS). |

Server-side: a held arrival with no 0x3012 for 300.0 s is cleared (READ:
`CLobby_RemoveStalePlayers` 0x437a50, 0xb45c40) -- OpenSRO closes the session.
