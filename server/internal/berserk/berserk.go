// Package berserk implements the Silkroad berserk gauge: fighting fills a
// five-orb gauge, and when it is full the player can go berserk for a burst of
// extra damage before it empties. The mechanic is the real one; the numbers
// (how fast it fills, how long it lasts, how much it hits for) are this
// project's own disclosed design -- they are server-side balance values that
// were never recovered.
package berserk

import (
	"sync"
	"time"
)

const (
	// Max is a full gauge; Orbs is how many pips the client shows, so each orb
	// is Max/Orbs of gauge.
	Max  = 100
	Orbs = 5

	// FillPerHit is the gauge gained from one of the player's attacks (own
	// design): ~13 hits to fill from empty.
	FillPerHit = 8

	// Duration is how long a berserk lasts, and DamageBonusPct the extra
	// damage while it is active (own design).
	Duration       = 20 * time.Second
	DamageBonusPct = 50
)

// Tracker holds each character's transient berserk state. Not persisted --
// berserk is in-the-moment combat state, cleared on disconnect like a duel.
type Tracker struct {
	mu          sync.Mutex
	gauge       map[int64]int
	activeUntil map[int64]time.Time
}

func NewTracker() *Tracker {
	return &Tracker{gauge: map[int64]int{}, activeUntil: map[int64]time.Time{}}
}

// Fill adds one attack's worth of gauge (capped at Max) and returns the new
// gauge value.
func (t *Tracker) Fill(characterID int64) int {
	t.mu.Lock()
	defer t.mu.Unlock()
	g := t.gauge[characterID] + FillPerHit
	if g > Max {
		g = Max
	}
	t.gauge[characterID] = g
	return g
}

// Gauge returns the current gauge (0..Max).
func (t *Tracker) Gauge(characterID int64) int {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.gauge[characterID]
}

// Activate goes berserk if the gauge is full, emptying it and returning true.
// A gauge that is not full is left untouched and false is returned.
func (t *Tracker) Activate(characterID int64) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.gauge[characterID] < Max {
		return false
	}
	t.gauge[characterID] = 0
	t.activeUntil[characterID] = time.Now().Add(Duration)
	return true
}

// Active reports whether the character is currently berserk.
func (t *Tracker) Active(characterID int64) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	return time.Now().Before(t.activeUntil[characterID])
}

// Boost applies the berserk damage bonus to a base amount when active, else
// returns it unchanged.
func (t *Tracker) Boost(characterID int64, damage int) int {
	if !t.Active(characterID) {
		return damage
	}
	return damage + damage*DamageBonusPct/100
}

// Clear drops a character's state (on disconnect).
func (t *Tracker) Clear(characterID int64) {
	t.mu.Lock()
	defer t.mu.Unlock()
	delete(t.gauge, characterID)
	delete(t.activeUntil, characterID)
}
