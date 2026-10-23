// Package session implements this project's own client<->server login
// exchange: opcodes, payload encoding, and a gateway.Handler that wires it
// to an account.Store. See docs/protocol/PROTOCOL_DECISION.md for why this
// is a fresh design rather than a clone of the original game's wire
// protocol.
package session

import (
	"fmt"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
)

// Opcodes for this project's own protocol. Unrelated to (and much simpler
// than) the original game's opcode numbering documented in
// docs/protocol/opcodes/ for historical reference.
const (
	OpLogin       uint16 = 0x0001 // client -> server
	OpLoginResult uint16 = 0x0002 // server -> client
)

// LoginRequest is the OpLogin payload.
type LoginRequest struct {
	Username string
	Password string
}

// Encode serializes a LoginRequest: for each field, a uint16 LE byte length
// followed by that many UTF-8 bytes.
func (r *LoginRequest) Encode() []byte {
	return encodeStrings(r.Username, r.Password)
}

// DecodeLoginRequest parses an OpLogin payload.
func DecodeLoginRequest(data []byte) (*LoginRequest, error) {
	fields, err := decodeStrings(data, 2)
	if err != nil {
		return nil, fmt.Errorf("session: decoding LoginRequest: %w", err)
	}
	return &LoginRequest{Username: fields[0], Password: fields[1]}, nil
}

// LoginResult is the OpLoginResult payload.
type LoginResult struct {
	OK     bool
	Reason string // human-readable; empty when OK
}

// Encode serializes a LoginResult: one byte (0/1) then the Reason field.
func (r *LoginResult) Encode() []byte { return encodeOKReason(r.OK, r.Reason) }

// DecodeLoginResult parses an OpLoginResult payload.
func DecodeLoginResult(data []byte) (*LoginResult, error) {
	ok, reason, err := decodeOKReason(data)
	if err != nil {
		return nil, fmt.Errorf("session: decoding LoginResult: %w", err)
	}
	return &LoginResult{OK: ok, Reason: reason}, nil
}

// LoginHandler answers OpLogin against store through a LoginService of its
// own (round 788): the wrong-password count at the default tolerance and the
// account's punishments, but no automatic block, no already-connected table
// or IP limit, no inspection or capacity. The server builds one LoginService
// for every front door and uses LoginHandlerFor (loginservice.go); this stays
// for tests and tools. Unrecognized opcodes are ignored.
func LoginHandler(store account.Store) gateway.Handler {
	return LoginHandlerFor(&LoginService{Accounts: store})
}
