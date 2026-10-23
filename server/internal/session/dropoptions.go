package session

// Round 770: a monster's equipment drop gets its blue options the way
// SR_GameServer.exe's _AddMagicOptions (0x7276a0) gives them
// (magicopt.RollDrop; docs/protocol/magic_options.md, "Drops"). The server
// rolls them when it creates the dropped item; OpenSRO creates a fresh
// drop's instance when it is picked up (the ground item carries none), so the
// roll is made there, once per item, before the pick-up's transaction (OURS:
// the moment; the rule is the server's). Only a monster's drop reaches this:
// a shop, a quest or a GM's /give creates its item through the bag, which
// rolls the white stats alone, as CGObjPC::AddItem_EXT (0x4ee370) does.
//
// Not built: the drop's plus (FUN_00724400, _RefDropOptLvlSel, a server-only
// table, with a per-ItemClass cap whose source was not read), and the special
// drop tables' path (FUN_00725720).

import (
	"context"
	"sync"

	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/magicopt"
)

var dropOptions struct {
	sync.RWMutex
	items  ItemLookup
	assign *magicopt.AssignTable
}

// SetDropOptions installs what a drop's options are rolled from: the item
// table and the assign table (cmd/server's -magic-option-assign-csv; the
// magic option table is SetMagicOptions'). Either nil: drops get none.
func SetDropOptions(items ItemLookup, assign *magicopt.AssignTable) {
	dropOptions.Lock()
	dropOptions.items, dropOptions.assign = items, assign
	dropOptions.Unlock()
}

// dropRand is the roll's rand(); a test replaces it.
var dropRand magicopt.Rand = defaultCombatRand{}

// freshDropInstance is a fresh equipment drop's instance: the white stats
// and durability any new item gets (inventory.FreshInstance), and the blue
// options magicopt.RollDrop gives it. ok false for anything else, which the
// bag rolls as before.
func freshDropInstance(ctx context.Context, itemID int64) (inventory.Instance, bool) {
	dropOptions.RLock()
	items, assign := dropOptions.items, dropOptions.assign
	dropOptions.RUnlock()
	table := magicOptions.Load()
	if items == nil || assign == nil || table == nil {
		return inventory.Instance{}, false
	}
	it, err := items.GetItem(ctx, itemID)
	if err != nil || it == nil || !isEquipment(it) {
		return inventory.Instance{}, false
	}
	lookup, _ := items.(inventory.DurabilityLookup)
	inst, err := inventory.FreshInstance(ctx, lookup, nil, itemID)
	if err != nil {
		return inventory.Instance{}, false
	}
	for _, o := range magicopt.RollDrop(table, assign, magicopt.DropItem{
		Equip: true, Rarity: it.Rarity, Race: it.Country, TypeID3: it.TypeID3, TypeID4: it.TypeID4,
		Code: it.CodeName, MaxOptions: it.MaxMagicOptions,
	}, dropRand) {
		inst.MagParams = append(inst.MagParams, inventory.MagParam(o.ID, o.Value))
	}
	return inst, true
}
