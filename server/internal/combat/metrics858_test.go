package combat

import (
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/metrics"
)

// Round 858: a spawn, a blow, a kill and a removal move the monster families.
func TestRound858MonsterMetrics(t *testing.T) {
	spawned0, killed0 := metrics.Value("monsters_spawned_total"), metrics.Value("monsters_killed_total")
	removed0 := metrics.Value("monsters_removed_total")
	dmg0 := metrics.Value("combat_damage_total", "target", "monster", "source", "attack")
	h := NewHub()
	a := h.Spawn("jangan", "Mangyang", 0, 0, 0, 100, 0, 1, 0)
	b := h.Spawn("jangan", "Mangyang", 5, 0, 5, 100, 0, 1, 0)
	if _, died, _, _ := h.ApplyDamageFrom(a.ID, 7, 40); died {
		t.Fatal("died at 60 HP")
	}
	if _, died, _, _ := h.ApplyDamageFrom(a.ID, 7, 60); !died {
		t.Fatal("did not die at 0 HP")
	}
	h.Remove(b.ID)
	for _, c := range []struct {
		name      string
		got, want float64
	}{
		{"spawned", metrics.Value("monsters_spawned_total") - spawned0, 2},
		{"killed", metrics.Value("monsters_killed_total") - killed0, 1},
		{"removed", metrics.Value("monsters_removed_total") - removed0, 1},
		{"damage", metrics.Value("combat_damage_total", "target", "monster", "source", "attack") - dmg0, 100},
	} {
		if c.got != c.want {
			t.Errorf("%s moved by %v, want %v", c.name, c.got, c.want)
		}
	}
}
