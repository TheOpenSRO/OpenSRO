package session

// Knockdown and knockback (round 785): Combat_ResolveDamage's 'ko' and 'kb'
// (0x58fef0..0x590350, READ; docs/protocol/skill_attack.md). A knocked
// monster is moved, then held -- it neither moves nor strikes -- for the
// state's time (motion state 8 KNOCKDOWN, 16 SKILL_KNOCKBACK; INFERRED that
// the held monster cannot act, the engine's motion state gates its AI).

import (
	"math"
	"sync"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// The knock constants (READ).
const (
	knockdownPush      = 20.0                    // double 0xb45ac8
	knockdownChanceCap = 75.0                    // float 0xb45de0
	knockdownSlack     = 500 * time.Millisecond  // + 0.5 s (0xb45c50)
	knockbackHold      = 2000 * time.Millisecond // float 0xb46010
	defaultKORecover   = 3000                    // RefObjChar's loader default (0x6a58f0)
	// defaultKnockdown is the flags a monster without the round-785 column
	// takes: 3, both allowed -- the value on 6,112 of the 6,850 retail
	// monster rows (MEASURED, OURS fallback).
	defaultKnockdown = 3
)

// The chance-memory kinds for the two rolls (tags 0x44 and 0x45 in the
// engine; offset by 0x80 here so no status kind shares them).
const (
	chanceKnockdown = combat.ChanceKind(0xC4)
	chanceKnockback = combat.ChanceKind(0xC5)
)

type knockState struct {
	until time.Time
	down  bool // motion state 8 (knocked down), else 16 (knocked back)
}

var knocks = struct {
	sync.Mutex
	m map[int64]knockState
}{m: map[int64]knockState{}}

// knockOf is monster id's knock, if one is running at now.
func knockOf(id int64, now time.Time) (knockState, bool) {
	knocks.Lock()
	defer knocks.Unlock()
	k, ok := knocks.m[id]
	if !ok {
		return knockState{}, false
	}
	if !now.Before(k.until) {
		delete(knocks.m, id)
		return knockState{}, false
	}
	return k, true
}

// knockedDown reports motion state 8 ('da' reads it, READ 0x58f81a).
func knockedDown(id int64, now time.Time) bool {
	k, ok := knockOf(id, now)
	return ok && k.down
}

func setKnock(id int64, k knockState) {
	knocks.Lock()
	knocks.m[id] = k
	knocks.Unlock()
}

func forgetKnock(id int64) {
	knocks.Lock()
	delete(knocks.m, id)
	knocks.Unlock()
}

// knockFlags is a monster's Knockdown byte and KO_RecoverTime, with the
// fallback for data without them.
func knockFlags(m combat.Monster) (flags, recoverMs int) {
	if !m.HasKnockdown {
		return defaultKnockdown, defaultKORecover
	}
	r := m.KORecoverMs
	if m.Knockdown != 0 && r == 0 {
		r = defaultKORecover
	}
	return m.Knockdown, r
}

// knockdownChance is FUN_0040fcb0 (READ): min(75, max(0, round(ko[1] x
// 2 ko[0] / (targetLevel + ko[0])))).
func knockdownChance(ko0, ko1, targetLevel int) int {
	if targetLevel+ko0 <= 0 {
		return 0
	}
	c := math.Round(float64(ko1) * 2 * float64(ko0) / float64(targetLevel+ko0))
	return int(math.Max(0, math.Min(knockdownChanceCap, c)))
}

// knockDestination is the target's new position: dist units along the
// horizontal line from the attacker through the target (y zeroed before the
// normalisation, READ; "away from the attacker" INFERRED).
func knockDestination(attacker world.Position, m combat.Monster, dist float64) world.Position {
	dx, dz := m.X-attacker.X, m.Z-attacker.Z
	l := math.Hypot(dx, dz)
	if l == 0 {
		return world.Position{X: m.X, Y: m.Y, Z: m.Z}
	}
	return world.Position{X: m.X + dx/l*dist, Y: m.Y, Z: m.Z + dz/l*dist}
}

func rollKnock(chance int, casterID int64, kind combat.ChanceKind) bool {
	damageRollMu.Lock()
	defer damageRollMu.Unlock()
	return combat.RollChanceTracked(chance, damageRollNG, chanceMemory, casterID, kind)
}
