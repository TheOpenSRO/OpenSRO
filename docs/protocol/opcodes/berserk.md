# Berserk (Hwan): `0x70a7` / `0xb0a7` / `0x30bf`

Recovered over rounds 440–445. The handler is `GObjPC_HandleBerserkMsg_0a7`
(`0x00515b30`, 472 bytes), index `0x0a7` in `server_handlers.tsv`.

## Why this is berserk

Four signals agree, which is what makes it a reading rather than a plausible
guess at an opcode:

- it reads `chardata + 0x86`, `_CHAR.RemainHwanCount` — the orb count
  `server/internal/berserk` persists;
- it calls `GObjPC::AddHwanCount`;
- it refuses when `IGObj::GetBodyMode` (vtable slot 64) reads 3 or 4, which the
  engine's own name table calls `BODYMODE_INVISIBLE` and `BODYMODE_BERSERKER`;
- it ends by calling `SetBodyMode(1, 0, duration, 0)` — body mode **1** is
  `BODYMODE_HWAN`, and Hwan is this game's berserk — with the duration built
  from three `ParamKeeper` reads, the shape already recorded for berserk's 60 s.

## The exchange

	request   0x70a7   u8   1 = activate
	refusal   0xb0a7   u8 = 2, u16 = code
	success   0x30bf   broadcast, not a reply

### Request

One byte. `MsgBuf_ReadUInt8`, or `MsgBuf_ReadUInt8FromTail` when the session
field at `+0x1048` is zero. Value `1` takes the activation path.

### Refusal — `0xb0a7`

Built by `Msg_SendTwoFieldReply` (`0x4e7250`), whose own instructions give the
shape: it writes the leading byte itself (`mov BYTE PTR [esp+0xb],0x2`) and
appends the caller's single pushed word as a `u16`. Its `ret 0x4` confirms one
stack argument.

	u8   0x02      -- "failure", written by the helper, shared by 38+ call sites
	u16  code

| code | guard |
|---:|---|
| 1 | the `[ebp+0x34]` comparison at `0x515c07` not taken |
| 3 | three paths, all `je 0x515bd4` |
| 4 | `GetBodyMode() == 2` — `BODYMODE_INVINCIBLE` |
| 5 | skill param `[eax+0x4a4]` in 1..4, or `GetBodyMode()` 6 or 7 |

**Read the reply opcode from `ECX`, never from the decompiled argument** —
`0x515bd6: mov ecx,0xb0a7`. Ghidra names that helper's argument sometimes the
opcode and sometimes the payload; that error invalidated round 323's sweep.

### Success — `0x30bf`, a broadcast

There is **no point-to-point success reply**. The success path falls through to
`CGObjChar::SetBodyMode`, which reaches `GObjPC::BroadcastStateChange`
(`0x4a8340`) — the shared state-change broadcast used by `SetLifeState`,
`SetBodyMode`, `SetBattleState` and three `SetCharacterState` kinds.

	guard    obj+0x188 != 0
	field 1  obj+8          -- the object id
	field 2  u8  kind       -- 4 for body mode (in EBX at the call site)
	field 3  u8  value      -- 1 for BODYMODE_HWAN
	field 4  u8  chardata[5]   -- appended ONLY when kind == 4 and value == 1

**That fourth field is the berserk case specifically.** The broadcaster's one
special branch triggers on exactly `kind == 4 && value == 1`, which is body mode
set to Hwan. What `chardata + 5` holds is **not read**; `_CHAR` carries a
`HwanLevel` column and that is the obvious candidate, but the low chardata bytes
are the runtime-state block (`+0` life, `+2` motion, `+4` lock, `+6` interact,
`+7` group, `+0xc` PvP, `+0xd` battle), not the DB block, so it is recorded as a
candidate and not promoted.

## Status

**Recovered, deliberately NOT wired.** `server/internal/session.OpBerserk`
(`0x0068`) is still the live placeholder. `docs/protocol/PROTOCOL_DECISION.md`
says the own-designed opcodes "stay functional (and tested) while the real
opcode-by-opcode RE work happens in parallel" — and swapping this one needs the
Godot client changed in the same step, which is a coordinated change rather than
a server edit. The constants sit in `server/internal/proto/opcodes.go` with the
evidence beside them, exactly as round 365 left `OpMovementRequest`.
