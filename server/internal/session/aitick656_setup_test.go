package session

import (
	"testing"

	"github.com/OpenSRO/OpenSRO/server/internal/combat"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// benchSetup656 installs what cmd/server runs since round 656 for
// BenchmarkMonsterAITick: the area-of-interest runtime (its reconcile runs
// once before each tick, as its own ticker would at the same period) and the
// sleep (-monster-sleep, on by default).
func benchSetup656(b *testing.B, a *monsterAI, hub *world.Hub, monsters *combat.Hub) func() {
	v := newMonsterAOI(hub, monsters, nil)
	monsterAOIRuntime.Store(v)
	b.Cleanup(func() { monsterAOIRuntime.Store(nil) })
	a.sleep = true
	return v.reconcile
}
