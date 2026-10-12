package session

// The Test Items NPC's equipment comes perfect (round 786, OURS: the user's
// request, "all +12 full blue at 100% stats"): every piece it gives away is
// +12, every white-stat variance group at its top (31 of 31, the 100% the
// item tooltip shows), and "full blue" -- every standard blue option the
// item kind can carry, at the item's degree and its highest value
// (magicopt.FullBlue). Its durability is the max those make. Bought from any
// other NPC the same item is an ordinary one.

import (
	"context"

	"github.com/OpenSRO/OpenSRO/server/internal/alchemy"
	"github.com/OpenSRO/OpenSRO/server/internal/durability"
	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
	"github.com/OpenSRO/OpenSRO/server/internal/magicopt"
)

// TestShopPlus is the plus the Test Items NPC's equipment carries.
const TestShopPlus = 12

// fullVariance is every variance group at its top (durability.GroupMax).
var fullVariance = func() uint64 {
	var v uint64
	for k := 0; k < durability.Groups; k++ {
		v |= uint64(durability.GroupMax) << (5 * uint(k))
	}
	return v
}()

// testShopInstance is the Test Items NPC's instance of itemID; ok false for
// an item that is not equipment, or with no item table, which the bag rolls
// as any buy.
func testShopInstance(ctx context.Context, itemID int64) (inventory.Instance, bool) {
	dropOptions.RLock()
	items, assign := dropOptions.items, dropOptions.assign
	dropOptions.RUnlock()
	if items == nil {
		return inventory.Instance{}, false
	}
	it, err := items.GetItem(ctx, itemID)
	if err != nil || it == nil || !isEquipment(it) {
		return inventory.Instance{}, false
	}
	inst := inventory.Instance{Variance: fullVariance, OptLevel: TestShopPlus, Durability: durability.Untracked}
	table := magicOptions.Load()
	var opts []alchemy.Option
	for _, o := range magicopt.FullBlue(table, assign, magicopt.DropItem{
		Equip: true, Rarity: it.Rarity, Race: it.Country, TypeID3: it.TypeID3, TypeID4: it.TypeID4,
		Code: it.CodeName, MaxOptions: it.MaxMagicOptions,
	}, (it.ItemClass-1)/3+1) {
		inst.MagParams = append(inst.MagParams, inventory.MagParam(o.ID, o.Value))
		if r := table.ByID(o.ID); r != nil {
			opts = append(opts, alchemy.Option{ID: o.ID, Tag: r.Tag, Value: o.Value})
		}
	}
	if lookup, ok := items.(inventory.DurabilityLookup); ok {
		lo, hi, tracked, err := lookup.DurabilityRange(ctx, itemID)
		if err == nil && tracked && durability.Tracked(lo, hi) {
			inst.Durability = alchemy.MaxDurability(durability.MaxDurability(lo, hi, fullVariance), opts, table)
		}
	}
	return inst, true
}
