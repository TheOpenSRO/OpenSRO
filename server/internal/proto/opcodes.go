package proto

// Opcode values confirmed in docs/protocol/opcodes/. Only opcodes we've
// actually verified go here — see each doc file's Status section for what's
// confirmed vs. still guessed at. Deliberately not a big speculative table.
//
// The gateway-login group below is confirmed via public private-server
// community documentation (see docs/protocol/opcodes/login.md's "real,
// complete wire sequence" section and docs/LEGAL.md point 3), independently
// cross-validated against this project's own binary opcode harvest
// (docs/protocol/opcodes/observed_opcodes.md) and, for OpAgentLoginAuthAck,
// this project's own decompiled findings. Payload layouts are documented in
// login.md, not encoded here yet — these are just the wire numbers.
const (
	// OpHandshakeRequest is sent client -> server to start the handshake.
	// See docs/protocol/opcodes/handshake.md.
	OpHandshakeRequest uint16 = 0x5000

	// OpHandshakeAccept is sent server -> client in response, and also
	// checked for on a later leg of the same exchange.
	OpHandshakeAccept uint16 = 0x9000

	// OpGatewayPatchRequest is sent client -> gateway to check for a
	// client update before login.
	OpGatewayPatchRequest uint16 = 0x6100
	// OpGatewayPatchAck is the gateway's response.
	OpGatewayPatchAck uint16 = 0xA100

	// OpGatewayShardListRequest is sent client -> gateway to fetch the
	// real shard/server list.
	OpGatewayShardListRequest uint16 = 0x6101
	// OpGatewayShardListAck is the gateway's response.
	OpGatewayShardListAck uint16 = 0xA101

	// OpGatewayShardListPingRequest is sent client -> gateway once per
	// shard, to measure latency for the shard-select UI.
	OpGatewayShardListPingRequest uint16 = 0x6106
	// OpGatewayShardListPingAck is the gateway's response.
	OpGatewayShardListPingAck uint16 = 0xA106

	// OpGatewayLoginRequest is sent client -> gateway with credentials
	// and the chosen shard ID.
	OpGatewayLoginRequest uint16 = 0x6102
	// OpGatewayLoginAck is the gateway's response — on success, hands
	// back a QueueID and the real AgentServer IP/port the client should
	// connect to next.
	OpGatewayLoginAck uint16 = 0xA102

	// OpGatewayLoginIBUVChallenge is a real CAPTCHA-style image challenge
	// sent gateway -> client during login.
	OpGatewayLoginIBUVChallenge uint16 = 0x2322
	// OpGatewayLoginIBUVConfirmRequest carries the user's typed answer.
	OpGatewayLoginIBUVConfirmRequest uint16 = 0x6323
	// OpGatewayLoginIBUVConfirmAck is the gateway's response.
	OpGatewayLoginIBUVConfirmAck uint16 = 0xA323

	// OpAgentLoginAuthRequest is sent client -> agent (the server the
	// client connects to next, using GatewayLoginAck's IP/port), carrying
	// the QueueID the gateway issued plus credentials again.
	OpAgentLoginAuthRequest uint16 = 0x6103
	// OpAgentLoginAuthAck is the agent server's response — already
	// independently confirmed via decompilation as the real Gateway-to-
	// Agent login hand-off response before its payload was known.
	OpAgentLoginAuthAck uint16 = 0xA103
)

// How the retail server routes a message, recovered 2026-09-17 from
// CGObjPC::vslot_376 (0x0050eee0). See docs/protocol/server_dispatch.md.
//
//	50ef13  and eax,0x7ff                    ; the index
//	50ef1e  cmp cx,ax                        ; bit 0x800 set -> a fallback path
//	50ef44  mov edx,[eax*8+0xcd3d08]         ; the handler
//
// The server picks a handler with the LOW ELEVEN BITS of the opcode and ignores
// the top five, which is why a request and its reply reach the same slot.
const DispatchMask uint16 = 0x7ff

// DispatchIndex is the handler slot a given opcode reaches on the retail server.
// Opcodes with bit 0x800 set never reach the table: the dispatcher compares the
// 11-bit and 12-bit maskings and takes a different path when they differ.
func DispatchIndex(op uint16) (index uint16, dispatched bool) {
	return op & DispatchMask, op&0x800 == 0
}

// The academy (the engine calls it the training camp). The requests are read
// from the client's own senders, which pass the opcode to its packet builder:
//
//	00821e40  FUN_00841780(0x7470, ...)   open
//	008220e0  FUN_00841780(0x7471, ...)   disband
//	00821f00  FUN_00841780(0x7472, ...)   invite -- it shows UIIT_STT_TC_PROPOSAL_PENDING
//	00822180  FUN_00841780(0x7475, ...)   graduation
//
// The replies are read from the server's senders (docs/protocol/academy.md), and
// each request reaches the handler the server's table holds at its index:
// 0x470 TrainingCamp_HandleOpen, 0x471 HandleDisband, 0x472 HandleInvite,
// 0x475 HandleGraduation.
//
// Ban and leave are NOT here. The server has handlers at 0x473 and 0x474 and
// answers on 0xb473/0xb474, but the client senders that would give their request
// opcodes have not been read, and 0x7473/0x7474 would be a guess from the shape.
const (
	OpAcademyOpenRequest       uint16 = 0x7470
	OpAcademyOpenAck           uint16 = 0xB470
	OpAcademyDisbandRequest    uint16 = 0x7471
	OpAcademyDisbandAck        uint16 = 0xB471
	OpAcademyInviteRequest     uint16 = 0x7472
	OpAcademyInviteAck         uint16 = 0xB472
	OpAcademyGraduationRequest uint16 = 0x7475
	OpAcademyGraduationAck     uint16 = 0xB475
)

// ReplyOpcode is the opcode the retail server answers a request with. Measured,
// not assumed: every handler in the server's dispatch table was walked in
// assembly for the opcodes it hands its send helper (`mov ecx,<op>; call
// 0x4e7250`) or its message builder (`push <op>; call [this+0x278]`). 98 of the
// 162 handlers name an opcode, and **96 of those answer on 0xB000 | index**,
// with no other high nibble appearing.
//
// The two that do not are read, not swept under the rule:
//
//	index 0x0c4 (0x0050faf0) answers on 0xb045, another operation's opcode
//	index 0x4a9 (0x005079c0) answers on 0x34aa, which is not a 0xBxxx reply
//
// The academy has its own crossed channels of the same kind (its disband
// handler sends plain refusals on open's opcode), so a request answering
// somewhere else is a real pattern in this engine, not a decoding error.
// ok is false when the request carries bit 0x800 and never reaches the table.
func ReplyOpcode(request uint16) (reply uint16, ok bool) {
	index, dispatched := DispatchIndex(request)
	if !dispatched {
		return 0, false
	}
	return 0xB000 | index, true
}

// Spending a stat point, read from both sides on 2026-09-18.
//
// The client's sender picks the opcode by a selector:
//
//	0078f4e0  if (selector == 1) FUN_00841780(0x7050, ...)
//	          if (selector == 2) FUN_00841780(0x7051, ...)
//
// and the server's handlers sit at the matching dispatch indices 0x050 and
// 0x051. Which is which is settled by what each handler does, not by the order:
// GObjPC_HandleIncreaseStr calls GObjPC_SpendStatPoints(1, 0) and logs event
// 0x18 with charData+0x74, the field the server's own SQL DDL names Strength;
// GObjPC_HandleIncreaseInt calls (0, 1) and logs event 0x19 with +0x76.
const (
	OpIncreaseStrRequest uint16 = 0x7050
	OpIncreaseStrAck     uint16 = 0xB050
	OpIncreaseIntRequest uint16 = 0x7051
	OpIncreaseIntAck     uint16 = 0xB051
)

// Movement, read from BOTH binaries on 2026-09-21 (round 364).
//
// 0x7021 is what the client sends to move a player, and it is also what the
// original server's own monster AI composes to move a monster: the wander
// state's destination setter (0x00540f70) builds a 0x7021 message and sends
// it. Player and monster movement are one path, not two.
//
// The client half was already harvested independently -- client_senders.tsv
// recorded FUN_009ebd10 sending it in round 336, before this project knew what
// it carried. The payload layout IS encoded here, in movement.go, unlike the
// gateway-login group above: see docs/protocol/opcodes/movement.md.
// OpMovementResponse was left OUT of this file in round 365 -- 0xB021 is the
// conventional pairing for a 0x7021 request, and conventional is not evidence.
// Round 366 found it in the binary: GObjPC::FUN_004b0ea0 (0x004b0ea0) begins a
// message with it through FUN_00430a00, which writes the MsgBuf opcode field at
// +0x1050, and then appends the SAME movement destination this package encodes
// (via the 0x0048bad0 serialiser, with no optional extra byte). The client
// names it once too.
//
// Whether it is a per-request acknowledgement, a broadcast to observers, or
// both, is NOT read -- only that the server composes it and that it carries a
// movement destination after one leading field this project has not identified.
const (
	OpMovementRequest  uint16 = 0x7021
	OpMovementResponse uint16 = 0xB021
)

// Logout, confirmed THREE independent ways.
//
// observed_opcodes.md already had 0x7005 as AGENT_GAME_LOGOUT_REQ from two:
// this project's own binary opcode harvest, and public community documentation
// agreeing with it. Round 367 adds the third, from the server's own code path:
// CMainProcess::FUN_00437e80 (0x00437e80) composes a message whose opcode field
// at +0x1050 is the literal 0x7005, and one of its two callers is
// CMainProcess::CharDataSavingCompleted -- a character's data finishing saving
// is a logout step.
//
// The reply is this project's own handler table (server_handlers.tsv row
// 0x005): the server's handler is GObjPC::FUN_0050eff0 and it answers 0xB005,
// which the client handles at FUN_0086db40.
//
// Payload: NOT fully read. It carries an id and a state byte taken from an
// object's +0x50, where 4 is forced when there is no object; any other value
// goes through CGObjMobile::vslot_292, which re-emits the byte and, WHEN IT IS
// 3, appends a movement destination WITH the optional extra byte -- the only
// place in the whole server that byte is emitted. See
// docs/protocol/opcodes/movement.md.
const (
	OpLogoutRequest  uint16 = 0x7005
	OpLogoutResponse uint16 = 0xB005
)

// Berserk activation, recovered in round 440 from the server's handler at
// 0x00515b30 -- index 0x0a7 in docs/protocol/server_handlers.tsv, so the wire
// numbers are 0x70a7 request / 0xb0a7 reply.
//
// FOUR SIGNALS AGREE that this is berserk, which is what makes it a reading
// rather than a guess about a plausible opcode:
//
//   - it reads chardata +0x86, `_CHAR.RemainHwanCount` -- the orb count
//     `internal/berserk` persists;
//   - it calls `GObjPC::AddHwanCount`;
//   - it refuses when `IGObj::GetBodyMode` (vtable slot 64) reads 3 or 4,
//     which the engine's own name table calls BODYMODE_INVISIBLE and
//     BODYMODE_BERSERKER (docs/protocol/character_state.md, round 425);
//   - it ends by calling the SetBodyMode slot (0x318) as
//     `SetBodyMode(1, 0, duration, 0)` -- body mode 1 is BODYMODE_HWAN, and
//     Hwan is this game's berserk -- with the duration built by combining
//     three ParamKeeper reads, the same shape already recorded for berserk's
//     60 s duration (`EvaluateParam(60) + EvaluateParam(195)`).
//
// THE REPLY OPCODE IS CONFIRMED A SECOND WAY (round 441). The number above came
// from the handler's index in server_handlers.tsv; the instruction stream gives
// it independently, read per call site as docs/protocol/error_codes.md requires
// for this helper:
//
//	515bcc:  push 0x5
//	515bd4:  push 0x3
//	515bd6:  mov  ecx,0xb0a7          <- the reply opcode, in the register
//	515bdd:  call 0x4e7250            <- Msg_SendTwoFieldReply
//
// THE REQUEST PAYLOAD IS ONE BYTE: the handler opens with MsgBuf_ReadUInt8 (or
// MsgBuf_ReadUInt8FromTail when the session field at +0x1048 is zero), and the
// value 1 takes the activation path.
//
// THE REPLY'S FIRST FIELD IS A RESULT CODE, and round 442 traced every path to
// the single `call 0x4e7250` at 0x515bdd. Each pushes exactly ONE word before
// reaching it, so the vocabulary and its guards are readable:
//
//	pushed  guard
//	  1     the [ebp+0x34] comparison at 0x515c07 not taken
//	  3     three paths, all `je 0x515bd4`
//	  4     GetBodyMode() == 2, i.e. BODYMODE_INVINCIBLE
//	  5     skill param [eax+0x4a4] in 1..4, or GetBodyMode() 6 or 7
//
// The success path does not reply here at all: it falls through 0x515c38 into
// GObjPC::FUN_005a16c0(this+0x28c, 4, 0) and the SetBodyMode call.
//
// STILL NOT WIRED, AND DELIBERATELY SO. `docs/protocol/PROTOCOL_DECISION.md`
// says a placeholder is replaced "once that opcode's real wire number AND
// PAYLOAD LAYOUT are confirmed". The reply's SECOND field is still unread --
// only one word is pushed per path, while `Msg_SendTwoFieldReply` appends two,
// reading two adjacent stack slots -- and that helper's own note warns Ghidra
// names its argument sometimes the opcode and sometimes the payload, the error
// that invalidated round 323's sweep. So `session.OpBerserk` (0x0068) stays
// live and these sit beside it, exactly as round 365 left `OpMovementRequest`.
const (
	OpBerserkRequest  uint16 = 0x70A7
	OpBerserkResponse uint16 = 0xB0A7
)
