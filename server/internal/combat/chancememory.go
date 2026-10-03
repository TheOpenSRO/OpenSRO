package combat

import (
	"math/rand"
	"sync"
)

// The engine's chance rolls are NOT memoryless. FUN_00599cc0 -- reached from
// Combat_ResolveDamage through GObjPC::FUN_005a1a20 -- keeps a per-actor
// accumulator and rolls against THAT rather than against the raw chance:
//
//	if (chance == 0)   return false;      // no roll taken, no accumulator touched
//	if (chance >= 100) return true;       // likewise
//	roll = rand() % 101;
//	entry = find(container, key);
//	if (entry) {
//	    if (entry.acc < roll) { entry.acc += chance;        return false; }
//	                            entry.acc += chance - 100;  return true;
//	}
//	// first roll for this key
//	if (chance < roll) { insert(key, chance*2);       return false; }
//	                     insert(key, chance*2 - 100); return true;
//
// The two seeds look like special cases and are not: `chance*2` and
// `chance*2 - 100` are exactly what the update rule produces from a starting
// value of `chance`. So the whole function is one rule --
//
//	succeed when acc >= rand()%101, where acc starts at chance
//	then acc += chance        on failure
//	     acc += chance - 100  on success
//
// -- which is bad-luck protection: every failure raises the effective chance by
// the base chance, and every success spends 100 of it. A long dry streak becomes
// progressively more likely to break, and the long-run rate is unchanged.
//
// SCOPING, and the part that is grounded versus the part that is not. The
// accumulator lives in a map keyed by `(objectId & 0xFFFFFF) | tag<<24`, built
// at the call site as `and ecx,0xffffff` then `or ecx,<tag>000000`. Seven
// distinct tags appear in the binary, six of them ASCII: 'B', 'C', 'D', 'E',
// 'H', 'M'. So the engine keeps SEPARATE accumulators per actor AND per kind of
// roll -- that separation is what is recovered, and this file reproduces it.
//
// Only one tag has a use-site behind it: the call inside Combat_ResolveDamage
// that passes 0x43 ('C'). The letters for the other kinds are NOT identified, so
// the constants below are named for what they gate in OpenSRO rather than for
// a letter this project cannot pin. ChanceCritical carries its citation;
// ChanceBlock is a separate accumulator because the engine separates kinds, not
// because 'B' was proven to mean block.

// ChanceKind identifies which accumulator a roll uses. Rolls of different kinds
// never share a streak.
type ChanceKind uint8

const (
	// ChanceCritical is the critical-hit accumulator. The engine's tag for it
	// is 0x43 ('C'), read off the call site inside Combat_ResolveDamage.
	ChanceCritical ChanceKind = iota + 1

	// ChanceBlock is the blocking accumulator. Separate from ChanceCritical
	// because the engine keys accumulators per kind; which of its six ASCII
	// tags denotes blocking is not recovered.
	ChanceBlock
)

// ChanceStatus is the accumulator of one abnormal state, by its kind (1..25,
// statuseffect.State.Kind). Combat_ApplyStatusEffects (0x590680) rolls every
// state through the same dice as a critical -- GObjPC::RollChance 0x5a1a20 ->
// FUN_00599cc0 -- keyed `kind << 24` in the TARGET's map (`mov ecx,
// 0xN000000; lea edx,[esi+0xa30]` before each call), so each state keeps its
// own streak on each target. READ (round 659).
func ChanceStatus(kind int) ChanceKind { return ChanceKind(0x40 + kind&0x3f) }

type chanceKey struct {
	actor int64
	kind  ChanceKind
}

// ChanceTracker holds the engine's per-actor, per-kind chance accumulators.
// The zero value is not usable; call NewChanceTracker. Safe for concurrent use.
type ChanceTracker struct {
	mu  sync.Mutex
	acc map[chanceKey]int
}

// NewChanceTracker returns an empty tracker.
func NewChanceTracker() *ChanceTracker {
	return &ChanceTracker{acc: make(map[chanceKey]int)}
}

// Forget drops every accumulator belonging to an actor. Call it when the actor
// stops existing -- a monster despawning, a character disconnecting -- so a
// recycled id cannot inherit a stranger's streak.
func (t *ChanceTracker) Forget(actorID int64) {
	if t == nil {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	for k := range t.acc {
		if k.actor == actorID {
			delete(t.acc, k)
		}
	}
}

// Accumulated reports an actor's current accumulator for a kind, and whether it
// has rolled at all. Exposed for tests and diagnostics, not for gameplay.
func (t *ChanceTracker) Accumulated(actorID int64, kind ChanceKind) (int, bool) {
	if t == nil {
		return 0, false
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	v, ok := t.acc[chanceKey{actor: actorID, kind: kind}]
	return v, ok
}

// RollChanceTracked is RollChance with the engine's bad-luck protection.
//
// A nil tracker falls back to RollChance exactly, so every existing caller and
// test keeps its memoryless behaviour. The trivial outcomes -- a chance of zero
// or of 100 and above -- take no roll and touch no accumulator, matching the
// engine, which returns before it ever looks the actor up.
//
// A nil r takes the maximum outcome, the same convention RollChance, RollDamage
// and RollGold already use in this package.
func RollChanceTracked(chance int, r *rand.Rand, t *ChanceTracker, actorID int64, kind ChanceKind) bool {
	if t == nil {
		return RollChance(chance, r)
	}
	if chance <= 0 {
		return false
	}
	if chance >= 100 || r == nil {
		return true
	}

	t.mu.Lock()
	defer t.mu.Unlock()

	key := chanceKey{actor: actorID, kind: kind}
	acc, seen := t.acc[key]
	if !seen {
		// The engine's first roll compares the raw chance; the seeds it
		// then stores are this same rule applied once.
		acc = chance
	}

	success := acc >= r.Intn(ChanceRollSides)
	acc += chance
	if success {
		acc -= 100
	}
	t.acc[key] = acc
	return success
}

// ChanceMemory binds a tracker to the two actors in one blow. A nil pointer, or
// a nil Tracker inside it, means memoryless rolls.
//
// The block roll belongs to the DEFENDER and the critical roll to the ATTACKER,
// which is why both ids are carried: a player's critical streak and the
// monster's blocking streak are separate accumulators on separate actors.
type ChanceMemory struct {
	Tracker    *ChanceTracker
	AttackerID int64
	DefenderID int64
}

func (m *ChanceMemory) attacker() int64 {
	if m == nil {
		return 0
	}
	return m.AttackerID
}

func (m *ChanceMemory) defender() int64 {
	if m == nil {
		return 0
	}
	return m.DefenderID
}

// roll takes one chance roll, through the accumulator when there is one.
func (m *ChanceMemory) roll(chance int, r *rand.Rand, actorID int64, kind ChanceKind) bool {
	if m == nil || m.Tracker == nil {
		return RollChance(chance, r)
	}
	return RollChanceTracked(chance, r, m.Tracker, actorID, kind)
}
