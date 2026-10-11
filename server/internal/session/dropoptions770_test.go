package session

import (
	"context"
	"strings"
	"testing"

	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
	"github.com/OpenSRO/OpenSRO/server/internal/magicopt"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
)

// Round 770: a fresh equipment drop picked up carries its white stats,
// durability and the blue options magicopt.RollDrop gives it; a stackable
// drop is left to the bag.
func TestFreshDropInstanceRollsOptions(t *testing.T) {
	ctx := context.Background()
	tbl, err := magicopt.LoadCSV(strings.NewReader("11,MATTR_STR,1,1,7566450,65538,196608,0,0,weapon,+\n"))
	if err != nil {
		t.Fatal(err)
	}
	assign, err := magicopt.LoadAssignCSV(strings.NewReader("0,6,2,MATTR_STR\n"))
	if err != nil {
		t.Fatal(err)
	}
	items := refdata.NewMemStore()
	if err := items.ImportItems(ctx, []refdata.Item{
		{ID: 1, MaxStack: 1, TypeID1: 3, TypeID2: 1, TypeID3: 6, TypeID4: 2, Rarity: 2, MaxMagicOptions: 9,
			DurabilityMin: 20, DurabilityMax: 30},
		{ID: 2, MaxStack: 50, TypeID1: 3, TypeID2: 3, TypeID3: 1, TypeID4: 1},
	}); err != nil {
		t.Fatal(err)
	}
	SetMagicOptions(tbl)
	SetDropOptions(items, assign)
	saved := dropRand
	t.Cleanup(func() { SetMagicOptions(nil); SetDropOptions(nil, nil); dropRand = saved })
	// A Seal sword: no chance roll; count 1; STR; the level roll; value 2.
	dropRand = &alcScript{vals: []int{0, 0, 0, 0, 0, 0, 0, 1}}
	inst, ok := freshDropInstance(ctx, 1)
	if !ok || len(inst.MagParams) != 1 || inventory.MagParamOption(inst.MagParams[0]) != 11 ||
		inventory.MagParamValue(inst.MagParams[0]) != 2 || inst.Durability <= 0 {
		t.Fatalf("ok %v instance %+v, want STR 2 with a rolled durability", ok, inst)
	}
	if _, ok := freshDropInstance(ctx, 2); ok {
		t.Fatal("a potion drop must be left to the bag")
	}
}
