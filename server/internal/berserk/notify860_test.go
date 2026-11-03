package berserk

import "testing"

// Round 860: every change of the count is announced once, with the kill's
// victim as the source of a gain and 0 for the rest (GObjPC::AddHwanCount
// s:0x4e4d00 -> 0x304E kind 4, READ); a change of nothing announces nothing.
func TestCountChangesAreAnnounced(t *testing.T) {
	tr := NewTracker()
	type note struct {
		id     int64
		count  int
		source uint32
	}
	var got []note
	tr.SetNotify(func(id int64, count int, source uint32) { got = append(got, note{id, count, source}) })

	// A unique always gives all five (GainChance): one note, the victim named.
	if n := tr.EarnOnKill(7, Kill{KillerLevel: 10, VictimLevel: 10, VictimIsMonster: true, VictimRarity: 3, Source: 0x1234}); n != Orbs {
		t.Fatalf("a unique gave %d orbs", n)
	}
	if len(got) != 1 || got[0] != (note{7, Orbs, 0x1234}) {
		t.Fatalf("after the kill: %+v", got)
	}
	// Full: another unique adds nothing and says nothing.
	tr.EarnOnKill(7, Kill{VictimIsMonster: true, VictimRarity: 3, Source: 0x99})
	if len(got) != 1 {
		t.Fatalf("a gain of nothing was announced: %+v", got)
	}
	// The activation spends all five: {0, 0}.
	if !tr.Activate(7) {
		t.Fatal("five orbs did not activate")
	}
	if len(got) != 2 || got[1] != (note{7, 0, 0}) {
		t.Fatalf("after the activation: %+v", got)
	}
	// A potion while berserk adds nothing; the GM set does, with source 0.
	tr.Add(7, PotionCharges)
	if len(got) != 2 {
		t.Fatalf("a refused potion was announced: %+v", got)
	}
	tr.SetCharges(7, 3)
	if len(got) != 3 || got[2] != (note{7, 3, 0}) {
		t.Fatalf("after the set: %+v", got)
	}
}
