package session

import (
	"context"
	"errors"
	"fmt"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
)

// Opcodes for account registration, our own protocol (see login.go).
const (
	OpRegister       uint16 = 0x0003 // client -> server
	OpRegisterResult uint16 = 0x0004 // server -> client
)

// RegisterRequest is the OpRegister payload. Same shape as LoginRequest
// today, kept as a distinct type since registration will likely grow fields
// (email, etc.) that login never needs.
type RegisterRequest struct {
	Username string
	Password string
}

func (r *RegisterRequest) Encode() []byte { return encodeStrings(r.Username, r.Password) }

func DecodeRegisterRequest(data []byte) (*RegisterRequest, error) {
	fields, err := decodeStrings(data, 2)
	if err != nil {
		return nil, err
	}
	return &RegisterRequest{Username: fields[0], Password: fields[1]}, nil
}

// RegisterResult is the OpRegisterResult payload. Same shape as LoginResult;
// kept distinct for the same reason as RegisterRequest.
type RegisterResult struct {
	OK     bool
	Reason string
}

func (r *RegisterResult) Encode() []byte { return encodeOKReason(r.OK, r.Reason) }

func DecodeRegisterResult(data []byte) (*RegisterResult, error) {
	ok, reason, err := decodeOKReason(data)
	if err != nil {
		return nil, fmt.Errorf("session: decoding RegisterResult: %w", err)
	}
	return &RegisterResult{OK: ok, Reason: reason}, nil
}

// RegisterHandler returns a gateway.Handler implementing account
// registration against reg. Unrecognized opcodes are ignored, same
// convention as LoginHandler.
func RegisterHandler(reg account.Registerer) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		if p.Opcode != OpRegister {
			return nil
		}

		req, err := DecodeRegisterRequest(p.Data)
		if err != nil {
			return sess.Send(&proto.Packet{
				Opcode: OpRegisterResult,
				Data:   (&RegisterResult{OK: false, Reason: "malformed request"}).Encode(),
			})
		}

		result := &RegisterResult{OK: true}
		if _, err := reg.Register(ctx, req.Username, req.Password); err != nil {
			result.OK = false
			switch {
			case errors.Is(err, account.ErrUsernameTaken):
				result.Reason = "username already taken"
			default:
				result.Reason = "registration failed"
			}
		}

		return sess.Send(&proto.Packet{Opcode: OpRegisterResult, Data: result.Encode()})
	}
}
