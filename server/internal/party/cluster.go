package party

// Parties across processes (round 869 lane W2, OURS,
// docs/protocol/game_worlds.md 12.3): every process keeps every party. A
// change made on one process (a formation, a join, a leave, a kick, a
// logout) is told to the others as the party's whole new state with a
// sequence number (Snapshot, through OnChange); each applies the newest it
// has heard (Apply). A member playing on another process is held with a
// remote session (the cluster layer's), so what the party code sends to "a
// member's session" reaches it there; Rebind moves a member's session when
// it changes process. Party ids carry the forming process's base
// (SetIDBase), so two processes never mint the same id.
//
// Two processes changing one party in the same instant keep the change of
// the higher (sequence, origin): the other is lost (disclosed: changes come
// from the members' own requests, which a player makes one at a time).
// Invitations stay on the process that made them (an invitation needs the
// target in view, so in the same world).

import (
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
)

// SnapMember is a member in a Snapshot.
type SnapMember struct {
	CharacterID int64  `json:"c"`
	Name        string `json:"n"`
	Level       int    `json:"l"`
	Job         uint8  `json:"j"`
}

// Snapshot is a party's state as one process tells the others.
type Snapshot struct {
	ID       uint32       `json:"id"`
	LeaderID int64        `json:"leader"`
	Flags    Flags        `json:"flags"`
	Members  []SnapMember `json:"members"`
	// Gone is a dissolved party.
	Gone   bool   `json:"gone,omitempty"`
	Seq    uint64 `json:"seq"`
	Origin string `json:"origin"`
}

// clusterHook is the hub's part in several processes.
type clusterHook struct {
	origin   string
	onChange func(Snapshot)
	seq      map[uint32]snapVersion
}

type snapVersion struct {
	seq    uint64
	origin string
}

func (v snapVersion) less(o snapVersion) bool {
	if v.seq != o.seq {
		return v.seq < o.seq
	}
	return v.origin < o.origin
}

// SetCluster makes the hub tell its changes (onChange, called outside the
// hub's lock, in the order they were made) as origin, and starts its party
// ids at base (the process's own range).
func (h *Hub) SetCluster(origin string, base uint32, onChange func(Snapshot)) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.cl = &clusterHook{origin: origin, onChange: onChange, seq: map[uint32]snapVersion{}}
	if h.nextID < base {
		h.nextID = base
	}
}

// snapLocked is party id's snapshot after a local change (h.mu held); nil
// without SetCluster.
func (h *Hub) snapLocked(id uint32) *Snapshot {
	if h.cl == nil {
		return nil
	}
	v := h.cl.seq[id]
	v.seq++
	v.origin = h.cl.origin
	h.cl.seq[id] = v
	s := &Snapshot{ID: id, Seq: v.seq, Origin: v.origin}
	p, ok := h.parties[id]
	if !ok {
		s.Gone = true
		return s
	}
	s.LeaderID, s.Flags = p.LeaderID, p.Flags
	for _, m := range p.Members {
		s.Members = append(s.Members, SnapMember{CharacterID: m.CharacterID, Name: m.Name, Level: m.Level, Job: m.Job})
	}
	return s
}

func (h *Hub) notify(s *Snapshot) {
	if s == nil {
		return
	}
	h.mu.Lock()
	cl := h.cl
	h.mu.Unlock()
	if cl != nil && cl.onChange != nil {
		cl.onChange(*s)
	}
}

// Apply takes another process's snapshot, when it is newer than what the hub
// holds. sessionOf is each member's session here (a local one or a remote
// one). It reports whether the snapshot was applied.
func (h *Hub) Apply(s Snapshot, sessionOf func(characterID int64) *gateway.Session) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.cl == nil {
		return false
	}
	got := snapVersion{s.Seq, s.Origin}
	if cur, ok := h.cl.seq[s.ID]; ok && !cur.less(got) {
		return false
	}
	h.cl.seq[s.ID] = got
	if old, ok := h.parties[s.ID]; ok {
		for _, m := range old.Members {
			if h.byChar[m.CharacterID] == s.ID {
				h.forgetLocked(m)
			}
		}
	}
	if s.Gone || len(s.Members) == 0 {
		delete(h.parties, s.ID)
		delete(h.rotation, s.ID)
		h.clearListingLocked(s.LeaderID)
		return true
	}
	p := &Party{ID: s.ID, LeaderID: s.LeaderID, Flags: s.Flags}
	rot := make([]int64, 0, len(s.Members))
	for _, sm := range s.Members {
		m := Member{CharacterID: sm.CharacterID, Name: sm.Name, Level: sm.Level, Job: sm.Job}
		if sessionOf != nil {
			m.Session = sessionOf(sm.CharacterID)
		}
		// A member is in one party: another this hub still holds for it
		// (a snapshot of its leave not heard yet) lets it go.
		if other, in := h.byChar[m.CharacterID]; in && other != s.ID {
			if op := h.parties[other]; op != nil {
				if i := op.index(m.CharacterID); i >= 0 {
					op.Members = append(op.Members[:i], op.Members[i+1:]...)
				}
			}
		}
		p.Members = append(p.Members, m)
		h.byChar[m.CharacterID] = s.ID
		if m.Session != nil {
			h.bySession[m.Session.ID()] = m.CharacterID
		}
		rot = append(rot, m.CharacterID)
	}
	h.parties[s.ID] = p
	if _, ok := h.rotation[s.ID]; !ok {
		h.rotation[s.ID] = rot
	} else {
		// Keep the rotation's order for who is still in, add the new.
		keep := map[int64]bool{}
		for _, id := range rot {
			keep[id] = true
		}
		var r []int64
		seen := map[int64]bool{}
		for _, id := range h.rotation[s.ID] {
			if keep[id] {
				r = append(r, id)
				seen[id] = true
			}
		}
		for _, id := range rot {
			if !seen[id] {
				r = append(r, id)
			}
		}
		h.rotation[s.ID] = r
	}
	return true
}

// Rebind gives characterID's membership a new session (it moved process:
// its local session where it now plays, a remote one everywhere else).
func (h *Hub) Rebind(characterID int64, sess *gateway.Session) {
	h.mu.Lock()
	defer h.mu.Unlock()
	pid, in := h.byChar[characterID]
	if !in {
		return
	}
	p := h.parties[pid]
	i := p.index(characterID)
	if i < 0 {
		return
	}
	if old := p.Members[i].Session; old != nil {
		delete(h.bySession, old.ID())
	}
	p.Members[i].Session = sess
	if sess != nil {
		h.bySession[sess.ID()] = characterID
	}
}
