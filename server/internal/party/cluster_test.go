package party

import (
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
)

// Two processes' hubs: a formation, a join and a leave on one reach the
// other as snapshots; a stale snapshot is ignored; ids come from each
// process's range; Rebind moves a member's session.
func TestPartySnapshotsAcrossHubs(t *testing.T) {
	a, b := NewHub(), NewHub()
	var toB []Snapshot
	a.SetCluster("a", 1<<24, func(s Snapshot) { toB = append(toB, s) })
	b.SetCluster("b", 2<<24, func(Snapshot) {})
	sessions := map[int64]*gateway.Session{1: gateway.NewTestSession(101), 2: gateway.NewTestSession(102), 3: gateway.NewTestSession(103)}
	sessOf := func(id int64) *gateway.Session { return sessions[id] }
	p, err := a.Form(Member{CharacterID: 1, Name: "A", Level: 30}, Member{CharacterID: 2, Name: "B", Level: 31}, FlagItemShare)
	if err != nil {
		t.Fatal(err)
	}
	if p.ID>>24 != 1 {
		t.Fatalf("party id %#x is not from a's range", p.ID)
	}
	if _, err := a.Add(p.ID, Member{CharacterID: 3, Name: "C"}); err != nil {
		t.Fatal(err)
	}
	if len(toB) != 2 || toB[1].Seq != 2 || len(toB[1].Members) != 3 {
		t.Fatalf("snapshots %+v", toB)
	}
	for _, s := range toB {
		b.Apply(s, sessOf)
	}
	got, ok := b.Get(3)
	if !ok || got.ID != p.ID || len(got.Members) != 3 || got.LeaderID != 1 || got.Flags != FlagItemShare {
		t.Fatalf("b's party %+v %v", got, ok)
	}
	if got.Members[2].Session != sessions[3] {
		t.Fatal("b's member has no session")
	}
	if b.Apply(toB[0], sessOf) {
		t.Fatal("a stale snapshot was applied")
	}
	// The leader leaves on a: b hears the new leader.
	a.Remove(1, ReasonLeave)
	b.Apply(toB[len(toB)-1], sessOf)
	got, _ = b.Get(2)
	if got.LeaderID != 2 || len(got.Members) != 2 {
		t.Fatalf("after the leave %+v", got)
	}
	if _, in := b.Get(1); in {
		t.Fatal("the leaver is still in b's party")
	}
	// A member moves to b: its session there.
	moved := gateway.NewTestSession(203)
	b.Rebind(3, moved)
	if c, ok := b.CharacterOfSession(203); !ok || c != 3 {
		t.Fatal("rebind")
	}
	got, _ = b.Get(3)
	if got.Members[1].Session != moved {
		t.Fatalf("rebound session %+v", got.Members)
	}
	// The party dissolves on a: b drops it.
	a.Remove(2, ReasonLeave)
	if !b.Apply(toB[len(toB)-1], sessOf) {
		t.Fatal("the dissolution was not applied")
	}
	if _, in := b.Get(3); in {
		t.Fatal("a dissolved party is kept")
	}
	// And b's own formation takes b's range.
	q, _ := b.Form(Member{CharacterID: 7}, Member{CharacterID: 8}, 0)
	if q.ID>>24 != 2 {
		t.Fatalf("b's id %#x", q.ID)
	}
}

// Without SetCluster nothing is told (one process, as before).
func TestPartyWithoutClusterTellsNothing(t *testing.T) {
	h := NewHub()
	p, err := h.Form(Member{CharacterID: 1}, Member{CharacterID: 2}, 0)
	if err != nil || p.ID != 1 {
		t.Fatalf("%+v %v", p, err)
	}
	if h.Apply(Snapshot{ID: 9, Members: []SnapMember{{CharacterID: 5}}, Seq: 1}, nil) {
		t.Fatal("applied without a cluster")
	}
}
