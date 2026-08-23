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
