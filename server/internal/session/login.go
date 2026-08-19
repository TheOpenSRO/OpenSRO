// Package session implements this project's own client<->server login
// exchange: opcodes, payload encoding, and a gateway.Handler that wires it
// to an account.Store. See docs/protocol/PROTOCOL_DECISION.md for why this
// is a fresh design rather than a clone of the original game's wire
// protocol.
package session

import (
	"context"
	"errors"
	"fmt"

	"github.com/OpenSRO/srrevamp/server/internal/account"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
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

// LoginHandler returns a gateway.Handler implementing the login exchange
// against store: on OpLogin, authenticate and reply with OpLoginResult.
// Unrecognized opcodes are ignored (left for other handlers layered on top
// later), not treated as errors.
func LoginHandler(store account.Store) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		if p.Opcode != OpLogin {
			return nil
		}

		req, err := DecodeLoginRequest(p.Data)
		if err != nil {
			return sess.Send(&proto.Packet{
				Opcode: OpLoginResult,
				Data:   (&LoginResult{OK: false, Reason: "malformed request"}).Encode(),
			})
		}

		result := &LoginResult{OK: true}
		acc, err := store.Authenticate(ctx, req.Username, req.Password)
		if err != nil {
			result.OK = false
			switch {
			case errors.Is(err, account.ErrBlocked):
				result.Reason = "account blocked"
			default:
				result.Reason = "invalid username or password"
			}
		} else {
			authenticate(sess, acc.ID)
		}

		return sess.Send(&proto.Packet{Opcode: OpLoginResult, Data: result.Encode()})
	}
}
