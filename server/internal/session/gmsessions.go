package session

import (
	"strings"

	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// GMSessions is the GM console's hold on live connections (gm.Sessions,
// round 788): /ban ends an in-world character's, /block its account's. The
// connection is closed as a stale arrival's is (arrival_hold.go): the
// gateway's OnDisconnect then saves and removes the character as for any
// disconnect, and the client shows its own "disconnected" box -- retail's
// kicked player is sent nothing first either (INFERRED, RESEARCH section 2).
type GMSessions struct {
	Hub *world.Hub
	// Online finds an account at character select too; nil: only the world.
	Online *OnlineAccounts
}

// KickCharacter implements gm.Sessions. The name is matched exactly, then
// without case (OURS; retail's lookup by name is the game server's).
func (g GMSessions) KickCharacter(name string) (string, bool) {
	if g.Hub == nil {
		return "", false
	}
	e, ok := findByNameCluster(g.Hub, name)
	if !ok {
		for _, x := range everyoneCluster(g.Hub) {
			if strings.EqualFold(x.Name, name) {
				e, ok = x, true
				break
			}
		}
	}
	if !ok || e.Session == nil {
		return "", false
	}
	_ = e.Session.Close()
	return e.Name, true
}

// KickAccount implements gm.Sessions.
func (g GMSessions) KickAccount(accountID int64) bool {
	if sess, ok := g.Online.Session(accountID); ok {
		_ = sess.Close()
		return true
	}
	if g.Hub == nil {
		return false
	}
	for _, e := range allEntitiesAnywhere(g.Hub) {
		if id, in := AuthenticatedAccountID(e.Session); in && id == accountID {
			_ = e.Session.Close()
			return true
		}
	}
	return false
}
