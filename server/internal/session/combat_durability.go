package session

import (
	"context"
	"log/slog"
	"math/rand"
	"os"

	"github.com/OpenSRO/OpenSRO/server/internal/durability"
	"github.com/OpenSRO/OpenSRO/server/internal/equipment"
)

// durabilityAlwaysLose forces every wear roll to succeed. A QA accelerant
// (OPENSRO_DURABILITY_LOSS_ALWAYS=1), never real play: at the real 2% a hit
// a break takes hundreds of swings, too many for one render. Read once.
var durabilityAlwaysLose = os.Getenv("OPENSRO_DURABILITY_LOSS_ALWAYS") != ""

// combatRand is the wear rolls' source; a test can swap it.
type combatRand interface{ Intn(n int) int }

var wearRand combatRand = defaultCombatRand{}

type defaultCombatRand struct{}

func (defaultCombatRand) Intn(n int) int {
	if n <= 0 {
		return 0
	}
	return rand.Intn(n)
}

// rollWear is durability.RollLoss with the QA accelerant folded in.
func rollWear(rate int) bool {
	if durabilityAlwaysLose {
		return rate > 0
	}
	return durability.RollLoss(wearRand, rate)
}

// wearOneSlot takes a point off the worn item in slot, if it is tracked and
// not already broken, persisting the new value. It returns whether the item
// just broke, and logs the change so a QA server run can measure it.
func wearOneSlot(ctx context.Context, eq equipment.Store, characterID int64, slot equipment.Slot) bool {
	worn, err := eq.Get(ctx, characterID)
	if err != nil {
		return false
	}
	for _, e := range worn {
		if e.Slot != slot {
			continue
		}
		next, broke, _ := durability.Apply(e.Durability, e.Durability, -1) // max is irrelevant to a -1
		if e.Durability == durability.Untracked {
			return false
		}
		if next == e.Durability {
			return false
		}
		if err := eq.SetDurability(ctx, characterID, slot, next); err != nil {
			return false
		}
		slog.Info("durability lost", "character", characterID, "slot", int(slot), "durability", next, "broke", broke)
		return broke
	}
	return false
}

// wearWeapon rolls the attacker's weapon (slot 6) once at rate = the number
// of hits the action landed (RollDurabilityLoss kind 0).
func wearWeapon(ctx context.Context, eq equipment.Store, characterID int64, hits int) {
	if hits <= 0 {
		return
	}
	if rollWear(hits) {
		wearOneSlot(ctx, eq, characterID, equipment.SlotWeapon)
	}
}

// wearArmour rolls the defender's armour once per hit (rate 1): slots 0..7
// except the weapon, in order, the first success losing the point
// (RollDurabilityLoss kind 1).
func wearArmour(ctx context.Context, eq equipment.Store, characterID int64) {
	for _, s := range durability.ArmourSlots {
		if rollWear(1) {
			wearOneSlot(ctx, eq, characterID, equipment.Slot(s))
			return
		}
	}
}

// wearShield rolls the defender's shield (slot 7) once per blocked hit
// (RollDurabilityLoss kind 2).
func wearShield(ctx context.Context, eq equipment.Store, characterID int64) {
	if rollWear(1) {
		wearOneSlot(ctx, eq, characterID, equipment.SlotShield)
	}
}

// wornBroken reports whether the item in slot is worn and broken (durability
// 0). A broken item contributes none of its stats -- the engine drops its
// ParamKeeper entry; here the combat sums simply skip it.
func wornBroken(worn []equipment.Equipped, slot equipment.Slot) bool {
	for _, e := range worn {
		if e.Slot == slot {
			return durability.IsBroken(e.Durability)
		}
	}
	return false
}
