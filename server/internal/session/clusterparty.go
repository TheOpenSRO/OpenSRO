package session

// Parties across processes (round 869 lane W2, OURS; party/cluster.go): each
// process's party hub tells its changes to every process (a snapshot on the
// bus) and applies theirs; a member playing elsewhere is held with its
// remote session. A member's record (the 0x3864 kind 6 sampler's) is kept
// only where it plays, so exactly one process samples and sends its updates.

import (
	"context"
	"hash/fnv"
	"sync/atomic"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/party"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

var clusterParties atomic.Pointer[party.Hub]

// SetClusterParties joins the party hub to the cluster (after SetCluster):
// its ids come from this host's range, its changes go to every process.
func SetClusterParties(h *party.Hub) {
	cs := clusterRT.Load()
	if cs == nil || h == nil {
		return
	}
	clusterParties.Store(h)
	h.SetCluster(cs.node.ID(), hostBase(cs.node.ID()), func(s party.Snapshot) {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		cs.node.Broadcast(ctx, kindParty, s)
	})
}

// hostBase is a host's id range (OURS): the top byte from its id's hash, so
// two hosts' party ids and buff tokens do not meet (1 in 255 hosts share a
// range; the counters then start apart by their own use).
func hostBase(id string) uint32 {
	f := fnv.New32a()
	f.Write([]byte(id))
	b := f.Sum32()%255 + 1
	return b << 24
}

// HostBase is hostBase for cmd/server (the buff tokens' range).
func HostBase(id string) uint32 { return hostBase(id) }

// sessionOfMember is a member's session here: its local one, else a remote
// one where the directory has it, else none (offline).
func sessionOfMember(id int64) *gateway.Session {
	if s, ok := localSession(id); ok {
		return s
	}
	if e, ok := remoteEntity(id); ok {
		return e.Session
	}
	return nil
}

func onPartySnapshot(_ context.Context, m clusterMsg) (any, error) {
	cs := clusterRT.Load()
	h := clusterParties.Load()
	if cs == nil || h == nil || m.From == cs.node.ID() {
		return nil, nil
	}
	var s party.Snapshot
	if err := m.Decode(&s); err != nil {
		return nil, err
	}
	if !h.Apply(s, sessionOfMember) {
		return nil, nil
	}
	// A member who left on another process is no longer sampled here.
	in := map[int64]bool{}
	for _, mm := range s.Members {
		in[mm.CharacterID] = true
	}
	for id := range partyRecords.ids() {
		if !in[id] {
			if p, ok := h.Get(id); !ok || p.ID == s.ID {
				partyRecords.forget(id)
			}
		}
	}
	return nil, nil
}

// partyMemberArrived is a member arriving on this process: its membership
// takes its local session, and its record is sampled here from now on.
func partyMemberArrived(e world.Entity) {
	h := clusterParties.Load()
	if h == nil || e.Session == nil {
		return
	}
	p, ok := h.Get(e.CharacterID)
	if !ok {
		return
	}
	h.Rebind(e.CharacterID, e.Session)
	for _, m := range p.Members {
		if m.CharacterID == e.CharacterID {
			m.Session = e.Session
			if d := partyDepsBox.Load(); d != nil {
				d.fullRecord(context.Background(), m)
			}
		}
	}
}

// partyMemberMoved is a member now on another process: its membership here
// takes the remote session, and its record is that process's to sample.
func partyMemberMoved(id int64, remote *gateway.Session) {
	h := clusterParties.Load()
	if h == nil {
		return
	}
	if _, ok := h.Get(id); !ok {
		return
	}
	h.Rebind(id, remote)
	partyRecords.forget(id)
}

// partyLocalMember reports whether the member plays on this process (with
// several processes only its own process samples it).
func partyLocalMember(id int64) bool {
	if !clusterOn() {
		return true
	}
	_, ok := localSession(id)
	return ok
}

// partyDepsBox is the party handler's deps, for a member's record at a
// hand-off in.
var partyDepsBox atomic.Pointer[PartyDeps]
