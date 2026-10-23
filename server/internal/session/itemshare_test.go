package session

import (
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/party"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// itemRig: a world and an Item Auto Share party of the given members, each
// at (x, 0, 0) in zone "jangan" unless moved.
func itemRig(t *testing.T, xs ...float64) (*world.Hub, *party.Hub, *party.Party, []int64) {
	t.Helper()
	hub, parties := world.NewHub(), party.NewHub()
	var ids []int64
	var members []party.Member
	for i, x := range xs {
		id := int64(500 + i)
		s := gateway.NewTestSession(uint64(88000 + i))
		hub.Enter(s, id, "m", 20, "jangan", world.Position{X: x})
		ids = append(ids, id)
		members = append(members, party.Member{Session: s, CharacterID: id, Level: 20})
	}
	p, err := parties.Form(members[0], members[1], party.FlagItemShare|party.FlagExpShare)
	if err != nil {
		t.Fatal(err)
	}
	for _, m := range members[2:] {
		if p, err = parties.Add(p.ID, m); err != nil {
			t.Fatal(err)
		}
	}
	return hub, parties, p, ids
}

func entity(t *testing.T, hub *world.Hub, id int64) world.Entity {
	t.Helper()
	e, ok := hub.EntityByCharacterID(id)
	if !ok {
		t.Fatalf("no entity %d", id)
	}
	return e
}

// Everyone in range: the rotation hands items out in turn, the picker
// included.
func TestRoundRobinInTurn(t *testing.T) {
	hub, parties, p, ids := itemRig(t, 0, 10, 20)
	picker := entity(t, hub, ids[0])
	var got []int64
	for i := 0; i < 4; i++ {
		got = append(got, roundRobinRecipient(hub, parties, p, picker))
	}
	want := []int64{ids[0], ids[1], ids[2], ids[0]}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("round robin %v, want %v", got, want)
		}
	}
}

// The fallback quirk: when no member qualifies, the last member tried keeps
// the item if he failed the alive or world test; a distance failure clears
// him and the picker gets it.
func TestRoundRobinFallback(t *testing.T) {
	// The picker is in the rotation and measured from his own position, so
	// with the pick point at the picker the loop always ends on him. The
	// fallback matters when the point is elsewhere -- a pet's pick-up is
	// measured from the pet (GObjPC::FUN_004d5510) -- so these cases move the
	// pick point 20000 away, where no member qualifies by distance.
	hub, parties, p, ids := itemRig(t, 0, 5000, 10)
	// Member 2 (last in the rotation) dead; member 1 too far; picker 0 is
	// tested from a picker standing at 20000 (his pick position).
	if !hub.SetLifeState(ids[2], world.LifeAlive, world.LifeDead, time.Now()) {
		t.Fatal("SetLifeState")
	}
	picker := entity(t, hub, ids[0])
	picker.Pos.X = 20000 // members 0 and 1 are now too far from the pick point
	if got := roundRobinRecipient(hub, parties, p, picker); got != ids[2] {
		t.Fatalf("last candidate dead: got %d, want the dead member %d (the kept pointer)", got, ids[2])
	}

	// Same, but the last member tried is too far: the picker gets it.
	hub2, parties2, p2, ids2 := itemRig(t, 0, 5000, 7000)
	picker2 := entity(t, hub2, ids2[0])
	picker2.Pos.X = 20000
	if got := roundRobinRecipient(hub2, parties2, p2, picker2); got != picker2.CharacterID {
		t.Fatalf("last candidate distant: got %d, want the picker %d", got, picker2.CharacterID)
	}

	// The last member tried is in another zone: he keeps it.
	hub3, parties3, p3, ids3 := itemRig(t, 0, 5000, 10)
	if _, _, _, ok := hub3.ChangeZone(entity(t, hub3, ids3[2]).Session, "dunhuang", world.Position{X: 10}); !ok {
		t.Fatal("ChangeZone")
	}
	picker3 := entity(t, hub3, ids3[0])
	picker3.Pos.X = 20000
	if got := roundRobinRecipient(hub3, parties3, p3, picker3); got != ids3[2] {
		t.Fatalf("last candidate in another zone: got %d, want %d", got, ids3[2])
	}
}

// The gold split: equal parts to the picker and the members within 1000,
// the remainder to the picker; fewer coins than members, the picker takes it
// all.
func TestSplitGold(t *testing.T) {
	hub, _, p, ids := itemRig(t, 0, 999, 1001)
	picker := entity(t, hub, ids[0])
	got := splitGold(hub, p, picker, 1001)
	if len(got) != 2 || got[0] != (goldShare{ids[0], 501}) || got[1] != (goldShare{ids[1], 500}) {
		t.Fatalf("split %+v, want picker 501 and the member at 999 500", got)
	}
	// A dead member still shares (being alive is not tested).
	hub.SetLifeState(ids[1], world.LifeAlive, world.LifeDead, time.Now())
	if got := splitGold(hub, p, picker, 10); len(got) != 2 || got[1].amount != 5 {
		t.Fatalf("a dead member near the pick: %+v, want a share of 5", got)
	}
	if got := splitGold(hub, p, picker, 1); len(got) != 1 || got[0] != (goldShare{ids[0], 1}) {
		t.Fatalf("one coin for two: %+v, want the picker alone", got)
	}
}

// The attack factor (FUN_0040da20): party x1.2, elite x1.5, both x1.8.
func TestMonsterAttackFactor(t *testing.T) {
	for _, c := range []struct {
		party bool
		rank  int
		min   int
	}{{false, 0, 100}, {true, 0, 120}, {false, 6, 150}, {true, 6, 180}, {true, 1, 120}} {
		f := combat.MonsterAttackFactor(c.party, c.rank)
		if got := combat.ScaleMonsterAttack(100, f); got != c.min {
			t.Errorf("party %v rank %d: 100 -> %d, want %d", c.party, c.rank, got, c.min)
		}
	}
}
