package session

// The retail agent's half of a login (round 788, lane R). On the retail wire
// the login is decided on one connection -- the gateway's 0x6102, through
// LoginService.Login with no session -- and played on another: the client
// closes the gateway connection and presents a token on the agent's 0x6103
// (docs/protocol/opcodes/gateway.md, "OpenSRO's retail listeners"). Kept in
// its own file because loginservice.go belongs to the login-rules lane.

import (
	"errors"

	"github.com/OpenSRO/OpenSRO/server/internal/account"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
)

// The late refusals AdmitSession can give.
var (
	// ErrAlreadyConnected: the account came online on another session
	// between the gateway's decision and the agent's 0x6103.
	ErrAlreadyConnected = errors.New("session: the account is already connected")
	// ErrIPLimit: the agent connection's address reached -max-users-per-ip
	// in that time.
	ErrIPLimit = errors.New("session: too many accounts from the address")
)

// AdmitSession marks sess as logged in to acc for a login Login already
// decided (the retail agent, once the token checks out): the same session
// keys a login on OpenSRO's own connection sets, so the lobby handler sees
// AuthenticatedAccountID, and the account enters the logged-in table on sess
// (round 788, lane S), which the gateway's OnDisconnect releases.
//
// Login with no session already refused an account online elsewhere and a
// full address at the gateway, as GlobalManager does before it lets the
// gateway send the client on (READ 0x401b70). The account is entered only
// here, on the session that plays; so a second login of the same account
// whose 0x6103 comes in the few seconds between can still meet the first
// one's entry, and is refused with ErrAlreadyConnected (or ErrIPLimit).
// Retail has no such window -- GlobalManager holds the JID from its admission
// -- and so AgentServer has no code of its own for it; the agent maps both to
// its "user registration failed" [2,2] (INFERRED the nearest: AgentServer's
// own registration of the user is what would fail on a duplicate; the client
// shows the same "(C10)" for 2 and 3, READ 0x4cf7a0).
func (s *LoginService) AdmitSession(sess *gateway.Session, acc *account.Account) error {
	if s.Online != nil {
		switch s.Online.admit(acc.ID, sess, ipOf(sess.RemoteAddr()), s.Rules.MaxPerIP) {
		case admitDuplicate:
			return ErrAlreadyConnected
		case admitIPLimit:
			return ErrIPLimit
		}
	}
	authenticate(sess, acc.ID, acc.Username)
	return nil
}
