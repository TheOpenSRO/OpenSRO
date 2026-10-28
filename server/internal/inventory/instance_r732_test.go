package inventory

import (
	"bytes"
	"context"
	"reflect"
	"testing"
)

// Round 732: the plus, the blue options and the advanced elixir are an
// item's own data, stored with it and carried wherever it moves.

func TestMagParamPacking(t *testing.T) {
	p := MagParam(16, 100)
	if p != 0x00000064_00000010 || MagParamOption(p) != 16 || MagParamValue(p) != 100 {
		t.Fatalf("MagParam(16, 100) = %#x", p)
	}
	params := []uint64{MagParam(1, 7), MagParam(0xffff, 0xffffffff)}
	enc := EncodeMagParams(params)
	want := []byte{1, 0, 0, 0, 7, 0, 0, 0, 0xff, 0xff, 0, 0, 0xff, 0xff, 0xff, 0xff}
	if !bytes.Equal(enc, want) {
		t.Fatalf("EncodeMagParams % x, want % x", enc, want)
	}
	if got := DecodeMagParams(append(enc, 1, 2, 3)); !reflect.DeepEqual(got, params) {
		t.Fatalf("DecodeMagParams drops a partial tail: %#x", got)
	}
	if DecodeMagParams(nil) != nil {
		t.Error("no bytes, no options")
	}
	many := make([]uint64, 15)
	for i := range many {
		many[i] = MagParam(uint16(i+1), 1)
	}
	if got := DecodeMagParams(EncodeMagParams(many)); len(got) != MaxMagParams {
		t.Errorf("decoded %d options, want the cap %d", len(got), MaxMagParams)
	}
}

func r732Instance() Instance {
	return Instance{Variance: 0x0123456789abcdef, Durability: 41, OptLevel: 5,
		MagParams: []uint64{MagParam(1, 7), MagParam(16, 100)}, AdvElixir: 2,
		Model: 62515} // round 838: a model switcher's choice travels too
}

// Round 838: MutateItem turns a slot's item into another in place -- the
// slot, the serial and the given instance -- and refuses a slot that holds
// something else or nothing.
func testMutateItem(t *testing.T, s Store) {
	t.Helper()
	ctx := context.Background()
	m, ok := s.(Mutator)
	if !ok {
		t.Fatal("the store is not a Mutator")
	}
	if err := s.AddItem(ctx, 1, 100, 1); err != nil {
		t.Fatal(err)
	}
	inst := r732Instance()
	if err := m.MutateItem(ctx, 1, 0, 101, 102, inst); err != ErrItemChanged {
		t.Errorf("the wrong item: %v, want ErrItemChanged", err)
	}
	if err := m.MutateItem(ctx, 1, 4, 100, 102, inst); err != ErrSlotEmpty {
		t.Errorf("an empty slot: %v, want ErrSlotEmpty", err)
	}
	if err := m.MutateItem(ctx, 1, 0, 100, 102, inst); err != nil {
		t.Fatalf("MutateItem: %v", err)
	}
	slots, err := s.List(ctx, 1)
	if err != nil || len(slots) != 1 || slots[0].Index != 0 || slots[0].ItemID != 102 || slots[0].Quantity != 1 ||
		!slots[0].Instance().Equal(inst) {
		t.Fatalf("after: %+v %v", slots, err)
	}
}

func TestMutateItemMem(t *testing.T) {
	testMutateItem(t, NewMemStore(stubMaxStacks{100: 1, 102: 1}))
}

func TestMutateItemSQL(t *testing.T) {
	testMutateItem(t, openTestSQLStore(t, stubMaxStacks{100: 1, 102: 1}))
}

// The instance survives SetInstance, a move, a swap and a stack split, in
// both stores.
func testInstanceTravels(t *testing.T, s Store) {
	t.Helper()
	ctx := context.Background()
	if err := s.AddItem(ctx, 1, 100, 1); err != nil {
		t.Fatal(err)
	}
	if err := s.AddItem(ctx, 1, 101, 1); err != nil {
		t.Fatal(err)
	}
	inst := r732Instance()
	if err := s.SetInstance(ctx, 1, 0, inst); err != nil {
		t.Fatalf("SetInstance: %v", err)
	}
	if err := s.SetInstance(ctx, 1, 9, inst); err != ErrSlotEmpty {
		t.Errorf("SetInstance on an empty slot = %v, want ErrSlotEmpty", err)
	}
	at := func(slot int) Instance {
		t.Helper()
		slots, err := s.List(ctx, 1)
		if err != nil {
			t.Fatal(err)
		}
		for _, sl := range slots {
			if sl.Index == slot {
				return sl.Instance()
			}
		}
		t.Fatalf("slot %d empty", slot)
		return Instance{}
	}
	if got := at(0); !got.Equal(inst) {
		t.Fatalf("after SetInstance: %+v, want %+v", got, inst)
	}
	if err := s.MoveItem(ctx, 1, 0, 5); err != nil {
		t.Fatal(err)
	}
	if got := at(5); !got.Equal(inst) {
		t.Fatalf("after a move: %+v", got)
	}
	if err := s.MoveItem(ctx, 1, 5, 1); err != nil { // a swap with item 101
		t.Fatal(err)
	}
	if got := at(1); !got.Equal(inst) {
		t.Fatalf("after a swap: %+v", got)
	}
	if got := at(5); got.OptLevel != 0 || len(got.MagParams) != 0 {
		t.Fatalf("the swapped-out item took the instance: %+v", got)
	}
	if err := s.AddItemInstance(ctx, 2, 100, 1, inst); err != nil {
		t.Fatal(err)
	}
	other, _ := s.List(ctx, 2)
	if len(other) != 1 || !other[0].Instance().Equal(inst) {
		t.Fatalf("AddItemInstance: %+v", other)
	}
}

func TestInstanceTravelsMem(t *testing.T) {
	testInstanceTravels(t, NewMemStore(stubMaxStacks{100: 1, 101: 1}))
}

func TestInstanceTravelsSQL(t *testing.T) {
	testInstanceTravels(t, openTestSQLStore(t, stubMaxStacks{100: 1, 101: 1}))
}

// The migration on a table from before round 732: the columns are added on
// open, and every existing row reads +0 with no options -- what production
// data gets.
func TestR732MigrationDefaultsExistingRows(t *testing.T) {
	s := openTestSQLStore(t, stubMaxStacks{100: 1})
	ctx := context.Background()
	if _, err := s.db.Exec(`ALTER TABLE inventory_slots DROP COLUMN opt_level, DROP COLUMN mag_params, DROP COLUMN adv_elixir`); err != nil {
		t.Fatal(err)
	}
	if _, err := s.db.Exec(`INSERT INTO inventory_slots (character_id, slot, item_id, quantity, variance, durability) VALUES (7, 3, 100, 1, 99, 30)`); err != nil {
		t.Fatal(err)
	}
	s2, err := OpenSQLStore(testDSN(), stubMaxStacks{100: 1})
	if err != nil {
		t.Fatalf("reopening runs the migration: %v", err)
	}
	defer s2.Close()
	slots, err := s2.List(ctx, 7)
	if err != nil {
		t.Fatal(err)
	}
	if len(slots) != 1 {
		t.Fatalf("slots %+v", slots)
	}
	got := slots[0].Instance()
	if !got.Equal(Instance{Variance: 99, Durability: 30}) {
		t.Fatalf("a pre-732 row reads %+v, want variance 99, durability 30, +0, no options", got)
	}
	// Opening again is a no-op (ADD COLUMN IF NOT EXISTS).
	s3, err := OpenSQLStore(testDSN(), stubMaxStacks{100: 1})
	if err != nil {
		t.Fatal(err)
	}
	s3.Close()
}
