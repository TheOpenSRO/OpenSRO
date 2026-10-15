package session

import (
	"context"
	"errors"
	"net"

	"github.com/OpenSRO/OpenSRO/server/internal/account"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
)

// LoginAttempt is one login as any front door sees it: OpenSRO's own
// 0x0001 or 0x6102, or the retail listener's 0x6102 / 0x6103.
type LoginAttempt struct {
	Username string
	Password string
	// Remote is the client's address (the per-IP limit).
	Remote net.Addr
	// Session is the connection the login came in on. On success the
	// service marks it authenticated and remembers it for the account until
	// it ends ("already connected"). nil only in tests that check a decision.
	Session *gateway.Session
}

// LoginOutcome is the service's decision: the 0xA102 the client is sent
// (Ack; for OpenSRO's own connection the agent fields stay empty), the
// account on success, and whether the connection must be closed after the
// reply is sent (READ: the gateway closes after every GlobalManager refusal
// and after the last allowed wrong password).
type LoginOutcome struct {
	Ack     LoginAck
	Account *account.Account
	Close   bool
}

// LoginService is the one place a login is decided (round 788): every front
// door asks it, so the rules -- wrong-password counting and the automatic
// block, punishments, already connected, inspection, full, the per-IP limit
// -- are the same whichever wire the client speaks. See
// docs/protocol/opcodes/login.md, "The login reply, READ (round 788)".
type LoginService struct {
	Accounts account.Store
}

// Login decides one attempt.
func (s *LoginService) Login(ctx context.Context, a LoginAttempt) LoginOutcome {
	acc, err := s.Accounts.Authenticate(ctx, a.Username, a.Password)
	switch {
	case err == nil:
		if a.Session != nil {
			authenticate(a.Session, acc.ID, acc.Username)
		}
		return LoginOutcome{Ack: LoginAck{OK: true}, Account: acc}
	case errors.Is(err, account.ErrBlocked):
		return LoginOutcome{Ack: LoginAck{Code: LoginErrBlocked, BlockKind: LoginBlockPunished, BlockReason: ""}}
	case errors.Is(err, account.ErrInvalidCredentials):
		return LoginOutcome{Ack: LoginAck{Code: LoginErrPassword}}
	default:
		return LoginOutcome{Ack: LoginAck{Code: LoginErrFailed}}
	}
}
