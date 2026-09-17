package cos

import (
	"strings"
	"testing"
)

func TestMinOwnerLevelMatchesParty(t *testing.T) {
	if MinOwnerLevel != 5 {
		t.Errorf("MinOwnerLevel is %d, want 5", MinOwnerLevel)
	}
}

// 1 to 12, and the minimum is what differs from a guild name's 2.
func TestValidName(t *testing.T) {
	for n := MinNameLength; n <= MaxNameLength; n++ {
		if !ValidName(strings.Repeat("a", n)) {
			t.Errorf("a %d-character name was rejected", n)
		}
	}
	for _, n := range []int{0, 13, 14, 32} {
		if ValidName(strings.Repeat("a", n)) {
			t.Errorf("a %d-character name was accepted", n)
		}
	}
	// A one-character pet name is legal; a one-character guild name is not.
	// Writing that down stops the two rules being collapsed into one helper.
	if !ValidName("a") {
		t.Error("a one-character pet name should be legal")
	}
}

func TestCheckSummon(t *testing.T) {
	for _, c := range []struct {
		name string
		in   SummonRequest
		want int
	}{
		{
			"an adequate owner",
			SummonRequest{OwnerLevel: 20, ItemRequiredLevel: 10, HasOwner: true},
			0,
		},
		{
			"below the floor",
			SummonRequest{OwnerLevel: 4, ItemRequiredLevel: 1, HasOwner: true},
			ErrHigherLevelRequired,
		},
		{
			"at the floor exactly",
			SummonRequest{OwnerLevel: 5, ItemRequiredLevel: 1, HasOwner: true},
			0,
		},
		{
			"below the item's own requirement",
			SummonRequest{OwnerLevel: 20, ItemRequiredLevel: 40, HasOwner: true},
			ErrHigherLevelRequired,
		},
		{
			"at the item's requirement exactly",
			SummonRequest{OwnerLevel: 40, ItemRequiredLevel: 40, HasOwner: true},
			0,
		},
		{
			// The floor sits behind a `has owner` guard; without one only the
			// item's own requirement applies.
			"no owner skips the floor",
			SummonRequest{OwnerLevel: 2, ItemRequiredLevel: 1, HasOwner: false},
			0,
		},
		{
			"same type already out",
			SummonRequest{OwnerLevel: 20, ItemRequiredLevel: 1, HasOwner: true, SameTypeAlreadyOut: true},
			ErrDuplicatePetType,
		},
		{
			// The level tests run first, so a request failing both is told
			// about the level.
			"level beats duplicate",
			SummonRequest{OwnerLevel: 1, ItemRequiredLevel: 1, HasOwner: true, SameTypeAlreadyOut: true},
			ErrHigherLevelRequired,
		},
	} {
		if got := CheckSummon(c.in); got != c.want {
			t.Errorf("%s: got %#x, want %#x", c.name, got, c.want)
		}
	}
}

func TestRefusalCodesAreDistinct(t *testing.T) {
	seen := map[int]bool{}
	for _, c := range []int{
		ErrCannotActivateCart, ErrMultipleCOS, ErrHigherLevelRequired,
		ErrDuplicatePetType, ErrPetTooHighLevel,
	} {
		if seen[c] {
			t.Errorf("code %#x listed twice", c)
		}
		seen[c] = true
	}
	if len(seen) != 5 {
		t.Errorf("%d distinct codes, want 5", len(seen))
	}
}

func TestTheClassAndProcSurface(t *testing.T) {
	if len(Classes) != 6 {
		t.Errorf("%d COS classes, want 6", len(Classes))
	}
	for name, vt := range Classes {
		if !strings.HasPrefix(name, "CGObjCOS") {
			t.Errorf("%s is in Classes but is not a CGObjCOS class", name)
		}
		if vt < 0x00a00000 || vt > 0x00c00000 {
			t.Errorf("%s vtable %#x is outside .rdata", name, vt)
		}
	}
	if len(Procs) != 4 {
		t.Errorf("%d procedures, want 4", len(Procs))
	}
}

// The offset is recorded rather than a value, because the requirement is
// per-item data. A constant appearing here later would be a mistake.
func TestPetRequiredLevelIsAnOffsetNotAValue(t *testing.T) {
	if PetRequiredLevelOffset != 0x198 {
		t.Errorf("PetRequiredLevelOffset is %#x, want 0x198", PetRequiredLevelOffset)
	}
}
