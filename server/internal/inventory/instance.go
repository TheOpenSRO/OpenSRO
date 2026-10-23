package inventory

import (
	"context"
	"math/rand"

	"github.com/TheOpenSRO/OpenSRO/server/internal/durability"
)

// globalRand draws from math/rand's goroutine-safe top-level source; stores
// use it unless a test hands them a deterministic one.
type globalRand struct{}

func (globalRand) Intn(n int) int { return rand.Intn(n) }

// FreshInstance rolls what a newly created item of itemID carries: the
// game's variance roll and a durability equal to its max (durability.md,
// "Creating an item"). Without a lookup, or for an item the lookup says has
// no durability, the instance is Untracked.
func FreshInstance(ctx context.Context, lookup DurabilityLookup, rng durability.Rand, itemID int64) (Instance, error) {
	if lookup == nil {
		return Instance{Durability: durability.Untracked}, nil
	}
	durMin, durMax, ok, err := lookup.DurabilityRange(ctx, itemID)
	if err != nil {
		return Instance{}, err
	}
	if !ok || !durability.Tracked(durMin, durMax) {
		return Instance{Durability: durability.Untracked}, nil
	}
	if rng == nil {
		rng = globalRand{}
	}
	v := durability.RollVariance(rng)
	return Instance{Variance: v, Durability: durability.MaxDurability(durMin, durMax, v)}, nil
}

// initLegacy gives an Untracked slot from before durability existed a real
// instance on first read, so nothing already in a player's bag reads as
// broken. Returns true when it changed the slot (the caller persists it).
func initLegacy(ctx context.Context, lookup DurabilityLookup, rng durability.Rand, sl *Slot) (bool, error) {
	if sl.Durability != durability.Untracked || lookup == nil {
		return false, nil
	}
	inst, err := FreshInstance(ctx, lookup, rng, sl.ItemID)
	if err != nil {
		return false, err
	}
	if inst.Durability == durability.Untracked {
		return false, nil
	}
	sl.Variance, sl.Durability = inst.Variance, inst.Durability
	return true, nil
}
