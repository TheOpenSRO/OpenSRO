package main

import (
	"io"
	"log/slog"
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/combat"
)

// Round 656: one scheduler keeps every placement alive -- since round 660
// each placement a stand-in nest (internal/nest): the first pass hatches every
// one, a death out of the full nest arms its timer at the pass that drains
// it, and the first pass respawnDelay after that hatches it again, in the
// same place, with a new id. The other placements are left alone.
func TestRespawnSchedulerKeepsEveryPlacement(t *testing.T) {
	monsters := combat.NewHub()
	var reported []int64
	s := newRespawnScheduler(monsters, slog.New(slog.NewTextHandler(io.Discard, nil)), func(id int64) { reported = append(reported, id) })
	s.quiet = true
	const n = 300
	for i := 0; i < n; i++ {
		spec := monsterSpecs[i%len(monsterSpecs)]
		spec.X, spec.Z = float64(i)*10, 0
		s.add(spec)
	}
	t0 := time.Date(2026, 9, 30, 12, 0, 0, 0, time.UTC)
	s.check(t0)
	if monsters.Count() != n || len(reported) != n {
		t.Fatalf("first fill: %d alive, %d reported, want %d", monsters.Count(), len(reported), n)
	}
	first := reported[17]
	m, _ := monsters.Get(first)
	monsters.ApplyDamage(first, m.HP)

	t1 := t0.Add(time.Second)
	s.check(t1) // drains the death: the full nest's timer starts here
	s.check(t1.Add(respawnDelay - time.Millisecond))
	if monsters.Count() != n-1 {
		t.Fatalf("respawned before respawnDelay: %d alive", monsters.Count())
	}
	s.check(t1.Add(respawnDelay))
	if monsters.Count() != n || len(reported) != n+1 || reported[n] == first {
		t.Fatalf("after respawnDelay: %d alive, %d reported", monsters.Count(), len(reported))
	}
	again, _ := monsters.Get(reported[n])
	if again.X != 170 || again.Name != m.Name || again.HomeX != 170 {
		t.Fatalf("respawned %+v, want a %s back at x 170", again, m.Name)
	}
}

// The QA spread is deterministic, sized as asked, and inside the square of
// regions it names around Jangan.
func TestQASpreadInstances(t *testing.T) {
	a := qaSpreadInstances(500, 3, monsterSpecs)
	b := qaSpreadInstances(500, 3, monsterSpecs)
	if len(a) != 500 {
		t.Fatalf("%d instances, want 500", len(a))
	}
	lim := 3.5 * 1920
	for i := range a {
		if a[i].X != b[i].X || a[i].Z != b[i].Z || a[i].Name != b[i].Name {
			t.Fatal("two spreads differ")
		}
		if a[i].X < -lim || a[i].X >= lim || a[i].Z < -lim || a[i].Z >= lim {
			t.Fatalf("instance %d at %.0f,%.0f is outside 3 regions of Jangan", i, a[i].X, a[i].Z)
		}
		if a[i].Spawns != nil {
			t.Fatal("a spread instance carries npcpos rows")
		}
	}
	if qaSpreadInstances(0, 3, monsterSpecs) != nil {
		t.Fatal("0 asks for none")
	}
}
