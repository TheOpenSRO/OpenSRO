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
