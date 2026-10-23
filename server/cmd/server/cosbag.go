package main

import (
	"context"

	"github.com/TheOpenSRO/OpenSRO/server/internal/cos"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
)

// cosBagCapacity is a COS bag's size: its record's (round 795; 28 for an
// ability pet, cos.AbilityPetSlots).
func cosBagCapacity(store cos.Store) inventory.CapacityFunc {
	return func(ctx context.Context, id int64) int {
		if store == nil {
			return 0
		}
		rec, err := store.Get(ctx, id)
		if err != nil {
			return 0
		}
		return rec.InvSize
	}
}
