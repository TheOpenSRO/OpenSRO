package session

import "github.com/TheOpenSRO/OpenSRO/server/internal/combat"

// spawnWithTactics660 spawns sp at (x, z) running a tactics row with the given
// sight, aggression type, give-up distance and roam radius (round 660). The
// round's negative runs nest660_test.go against the base revision with a stub
// of this file that spawns the monster plainly, ignoring the row -- the base
// has no per-monster tactics -- so its stand-ins decide (docs/WORLD_ISSUES.md,
// round 660).
func spawnWithTactics660(monsters *combat.Hub, sp combat.Species, x, z float64, sight int, aggressType uint8, giveUp int, roam float64) combat.Monster {
	m := monsters.SpawnHatched("jangan", sp, x, 0, z, 1000, 0, 15, 0, combat.Hatch{HomeX: x, HomeZ: z,
		Tactics: &combat.Tactics{ID: 1, SightRange: sight, AggressType: aggressType, TraceBoundary: 1, TraceData: giveUp, RoamRadius: roam}})
	return *m
}
