package proto

// Opcode values confirmed in docs/protocol/opcodes/. Only opcodes we've
// actually verified go here — see each doc file's Status section for what's
// confirmed vs. still guessed at. Deliberately not a big speculative table.
const (
	// OpHandshakeRequest is sent client -> server to start the handshake.
	// See docs/protocol/opcodes/handshake.md.
	OpHandshakeRequest uint16 = 0x5000

	// OpHandshakeAccept is sent server -> client in response, and also
	// checked for on a later leg of the same exchange.
	OpHandshakeAccept uint16 = 0x9000
)
