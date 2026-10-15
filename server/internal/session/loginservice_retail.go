package session

// The retail agent's half of a login (round 788, lane R). On the retail wire
// the login is decided on one connection -- the gateway's 0x6102, through
// LoginService.Login with no session -- and played on another: the client
// closes the gateway connection and presents a token on the agent's 0x6103
// (docs/protocol/opcodes/gateway.md, "OpenSRO's retail listeners"). Kept in
// its own file because loginservice.go belongs to the login-rules lane.

import (
	"github.com/OpenSRO/OpenSRO/server/internal/account"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
)

// AdmitSession marks sess as logged in to acc for a login Login already
// decided (the retail agent, once the token checks out): the same session
// keys a login on OpenSRO's own connection sets, so the lobby handler sees
// AuthenticatedAccountID. Whatever "already connected" bookkeeping Login keeps
// for its own sessions must be kept here too (the coordinator merges the
// login-rules lane's registry into this function).
func (s *LoginService) AdmitSession(sess *gateway.Session, acc *account.Account) {
	authenticate(sess, acc.ID, acc.Username)
}
