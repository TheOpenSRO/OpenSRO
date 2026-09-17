package timedjob

import (
	"strings"
	"testing"
)

// The argument count in each call literal must match the getter run that fills
// it. That correspondence is the whole evidence for the field mapping.
func TestFieldCountsMatchTheProcArities(t *testing.T) {
	if Procs["_ADDTIMEDJOB"] != FieldCount {
		t.Errorf("_ADDTIMEDJOB takes %d arguments but FieldCount is %d",
			Procs["_ADDTIMEDJOB"], FieldCount)
	}
	if Procs["_ADDTIMEDJOBFORPET"] != PetFieldCount {
		t.Errorf("_ADDTIMEDJOBFORPET takes %d arguments but PetFieldCount is %d",
			Procs["_ADDTIMEDJOBFORPET"], PetFieldCount)
	}
	// The pet record is the character record minus its first field.
	if PetFieldCount != FieldCount-1 {
		t.Errorf("pet fields %d, character fields %d", PetFieldCount, FieldCount)
	}
	if PetFirstGetterSlot != FirstGetterSlot+1 {
		t.Errorf("pet getters start at slot %d, character at %d -- the pet run "+
			"should start one later", PetFirstGetterSlot, FirstGetterSlot)
	}
}

// Slots 25..38 for the character, and the wide field lands on slot 37.
func TestGetterSlotMapping(t *testing.T) {
	if s, ok := GetterSlotFor(1); !ok || s != 25 {
		t.Errorf("field 1 -> slot %d (ok=%v), want 25", s, ok)
	}
	if s, ok := GetterSlotFor(FieldCount); !ok || s != 38 {
		t.Errorf("field %d -> slot %d (ok=%v), want 38", FieldCount, s, ok)
	}
	if s, ok := GetterSlotFor(WideFieldIndex); !ok || s != 37 {
		t.Errorf("the %%I64d field -> slot %d (ok=%v), want 37 -- the one wide "+
			"getter must land on the one wide column", s, ok)
	}
	for _, f := range []int{0, -1, FieldCount + 1, 99} {
		if _, ok := GetterSlotFor(f); ok {
			t.Errorf("field %d should not exist", f)
		}
	}
}

func TestKinds(t *testing.T) {
	if len(Kinds) != 12 {
		t.Errorf("%d job kinds listed, want the 12 CTJ_* classes", len(Kinds))
	}
	seen := map[string]bool{}
	for _, k := range Kinds {
		if !strings.HasPrefix(k.Name, "CTJ_") {
			t.Errorf("%s is not a CTJ_ class", k.Name)
		}
		if seen[k.Name] {
			t.Errorf("%s listed twice", k.Name)
		}
		seen[k.Name] = true
		if k.Slots < SlotCount {
			t.Errorf("%s has %d slots, fewer than the base's %d", k.Name, k.Slots, SlotCount)
		}
		if k.VTable < 0x00b00000 || k.VTable > 0x00b10000 {
			t.Errorf("%s vtable %#x is outside the range the family occupies", k.Name, k.VTable)
		}
	}
}

func TestInterfaceSlotsAreDistinct(t *testing.T) {
	slots := map[int]string{
		SlotDestructor: "Destructor", SlotCreate: "Create", SlotPersist: "Persist",
		SlotPureA: "PureA", SlotPureB: "PureB", SlotPureC: "PureC",
	}
	if len(slots) != 6 {
		t.Errorf("%d distinct slots, want 6 -- two constants collided", len(slots))
	}
	for i, name := range slots {
		if i < 0 || i >= SlotCount {
			t.Errorf("slot %s is %d, outside the base's %d", name, i, SlotCount)
		}
	}
}

func TestPersistenceSurface(t *testing.T) {
	if len(Tables) != 2 || len(Procs) != 2 || len(Managers) != 3 || len(CommonData) != 3 {
		t.Error("the surface counts changed")
	}
}
