package main

import (
	"io"
	"log/slog"
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/combat"
)

// Round 656: one scheduler keeps every placement alive, with the one loop's
// timing unchanged -- a death is noticed at a check, and the first check at
// least respawnDelay after that spawns the placement again, in the same
// place, with a new id. The other placements are left alone.
func TestRespawnSchedulerKeepsEveryPlacement(t *testing.T) {
	monsters := combat.NewHub()
	var reported []int64
	s := newRespawnScheduler(monsters, slog.New(slog.NewTextHandler(io.Discard, nil)), func(id int64) { reported = append(reported, id) })
	const n = 300
	for i := 0; i < n; i++ {
		spec := monsterSpecs[i%len(monsterSpecs)]
		spec.X, spec.Z = float64(i)*10, 0
		s.add(spec)
	}
	for _, p := range s.places {
		s.spawn(p, false)
	}
	if monsters.Count() != n || len(reported) != n {
		t.Fatalf("first fill: %d alive, %d reported, want %d", monsters.Count(), len(reported), n)
	}
	victim := s.places[17]
	first := victim.currentID
	m, _ := monsters.Get(first)
	monsters.ApplyDamage(first, m.HP)

	t0 := time.Date(2026, 9, 30, 12, 0, 0, 0, time.UTC)
	s.check(t0) // notices the death
	s.check(t0.Add(respawnDelay - time.Second))
	if monsters.Count() != n-1 {
		t.Fatalf("respawned before respawnDelay: %d alive", monsters.Count())
	}
	s.check(t0.Add(respawnDelay))
	if monsters.Count() != n || victim.currentID == first {
		t.Fatalf("after respawnDelay: %d alive, id %d (was %d)", monsters.Count(), victim.currentID, first)
	}
	again, _ := monsters.Get(victim.currentID)
	if again.X != 170 || again.Name != m.Name {
		t.Fatalf("respawned %+v, want a %s back at x 170", again, m.Name)
	}
	if len(reported) != n+1 || reported[n] != victim.currentID {
		t.Fatalf("the respawn was not reported: %d reports", len(reported))
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
