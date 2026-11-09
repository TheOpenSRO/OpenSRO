package session

// The cluster's operations on this process (round 869 lane W2, OURS,
// docs/protocol/game_worlds.md 12.4): the drain's notice, a dead host's
// characters let go, the counts a beat reports.

import (
	"log/slog"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/gameworld"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/party"
	"github.com/TheOpenSRO/OpenSRO/server/internal/registry"
)

// SeedBuffTokens starts this process's buff tokens in its own range (a
// buff carried to another process keeps its token there).
func SeedBuffTokens(base uint32) { buffBooks.SeedTokens(base) }

// LocalPlayers is the characters in every world of this process.
func LocalPlayers() int { return len(localEveryone()) }

// NoticeDrain tells everyone in this process's instances that their layer
// closes in left (the drain's deadline): the close warning 0x300C {0x0C1A, u8
// minutes} (OURS reuse: the original warns of a layer's end with it; a drain
// ends the layer early).
func NoticeDrain(m *gameworld.Manager, left time.Duration) {
	if left < time.Minute {
		left = time.Minute
	}
	pkt := noticePacket(gameworld.EncodeCloseWarning(left))
	for _, w := range m.Local() {
		for _, e := range w.Hub.AllEntities() {
			if e.Session != nil {
				e.Session.Send(pkt)
			}
		}
	}
}

// hostDeadGrace is how long a dead host's characters have to be recovered
// on the open world's host before their memberships are let go (OURS).
var hostDeadGrace = 15 * time.Second

// ClusterHostDead is the node's OnHostDead on a world process: the logins a
// remote session of the dead host held are let go (a recovery has already
// rebound the ones it saved), and on the open world's host the party
// members that were there and did not come back are removed (logout).
func ClusterHostDead(h registry.Host) {
	cs := clusterRT.Load()
	if cs == nil {
		return
	}
	if o := loginOnline.Load(); o != nil {
		n := o.ReleaseHost(func(s *gateway.Session) (string, bool) {
			sk, ok := stubSinkOf(s)
			if !ok {
				return "", false
			}
			return sk.host, true
		}, h.ID)
		if n > 0 {
			slog.Info("logins of a dead host released", "host", h.ID, "accounts", n)
		}
	}
	if !cs.home {
		return
	}
	ph := clusterParties.Load()
	if ph == nil {
		return
	}
	var stranded []int64
	for _, p := range ph.All() {
		for _, m := range p.Members {
			if sk, ok := stubSinkOf(m.Session); ok && sk.host == h.ID {
				stranded = append(stranded, m.CharacterID)
			}
		}
	}
	if len(stranded) == 0 {
		return
	}
	time.AfterFunc(hostDeadGrace, func() {
		d := partyDepsBox.Load()
		if d == nil {
			return
		}
		for _, id := range stranded {
			if _, ok := cs.node.Lookup(id); ok {
				continue // recovered somewhere
			}
			if _, ok := localSession(id); ok {
				continue
			}
			d.removeMember(id, party.ReasonLogout)
		}
	})
}

// clusterStats is what a beat reports: the players and the live instances.
func ClusterStats() (players, live int) {
	players = LocalPlayers()
	if m := GameWorlds(); m != nil {
		live = len(m.Local())
	}
	return players, live
}
