package equipment

import (
	"errors"
	"testing"

	"github.com/OpenSRO/srrevamp/server/internal/refdata"
)

func TestCategoryOfMirrorsEngineVocabulary(t *testing.T) {
	cases := []struct {
		reqType int
		want    Category
		why     string
	}{
		{1, CategoryLevel, "the character's own level"},
		{0x201, CategoryMastery, "513, first mastery"},
		{0x206, CategoryMastery, "518, last mastery"},
		{0x203, CategoryMastery, "515, a mastery real Chinese rows use"},
		{0x301, CategoryTier, "769, the SECOND_HWAN scrolls' type"},
		{2, CategoryNone, "accepted, no effect"},
		{3, CategoryNone, "accepted, no effect"},
		{4, CategoryNone, "accepted, no effect"},
		{0x10, CategoryNone, "accepted, no effect"},
		{10, CategoryUnknown, "the guild soldier scrolls' type"},
		{0x207, CategoryUnknown, "one past the last mastery"},
		{0x200, CategoryUnknown, "one before the first mastery"},
		{5, CategoryUnknown, "one past the accepted 2..4 run"},
	}
	for _, c := range cases {
		if got := CategoryOf(c.reqType); got != c.want {
			t.Errorf("CategoryOf(%d) = %d, want %d (%s)", c.reqType, got, c.want, c.why)
		}
	}
}

// Several slots of the SAME type are or-ed, because the engine keeps one bit
// per category. The seven real rows that carry two character-level
// requirements are the ITEM_MALL_STATS_POINT_RECALL* family; this is
// ...RECALL itself, (1,1) and (1,40). Requiring both would lock a level-1
// item to level 40.
func TestSameCategorySlotsAreOredNotAnded(t *testing.T) {
	it := &refdata.Item{
		ID:            1,
		ReqLevelType1: ReqTypeCharacterLevel, ReqLevel1: 1,
		ReqLevelType2: ReqTypeCharacterLevel, ReqLevel2: 40,
	}
	reqs := RequirementsOf(it)
	if len(reqs) != 2 {
		t.Fatalf("RequirementsOf gave %d slots, want 2", len(reqs))
	}
	if err := CheckRequirements(reqs, 1, nil, nil); err != nil {
		t.Errorf("level 1 against (1,1)+(1,40): %v, want satisfied -- the slots are or-ed", err)
	}
	// And a level below every slot still fails.
	if err := CheckRequirements(reqs, 0, nil, nil); !errors.Is(err, ErrLevelTooLow) {
		t.Errorf("level 0 against (1,1)+(1,40) = %v, want ErrLevelTooLow", err)
	}
}

// Across categories it is and: a needed category that is not met refuses.
func TestDifferentCategoriesAreAnded(t *testing.T) {
	it := &refdata.Item{
		ID:            2,
		ReqLevelType1: ReqTypeCharacterLevel, ReqLevel1: 20,
		ReqLevelType2: 0x203, ReqLevel2: 10,
	}
	reqs := RequirementsOf(it)
	mastery := func(int) (int, bool) { return 4, true }

	// Level met, mastery not -- refuse.
	if err := CheckRequirements(reqs, 30, mastery, nil); !errors.Is(err, ErrRequirementNotMet) {
		t.Errorf("mastery 4 against a needed 10 = %v, want ErrRequirementNotMet", err)
	}
	// Both met -- allow.
	if err := CheckRequirements(reqs, 30, func(int) (int, bool) { return 10, true }, nil); err != nil {
		t.Errorf("both categories met: %v, want satisfied", err)
	}
	// Level not met -- refuse on the level, which has its own error.
	if err := CheckRequirements(reqs, 19, func(int) (int, bool) { return 10, true }, nil); !errors.Is(err, ErrLevelTooLow) {
		t.Errorf("level 19 against a needed 20 = %v, want ErrLevelTooLow", err)
	}
}

// A nil lookup means the category is carried but not enforced. This is the
// state srrevamp is actually in, and it must not refuse mastery-gated items.
func TestUnenforcedCategoriesDoNotRefuse(t *testing.T) {
	// ITEM_CH_... shaped: pair 0 a mastery, nothing else. 1,776 real rows.
	it := &refdata.Item{ID: 3, ReqLevelType1: 0x201, ReqLevel1: 60}
	if err := CheckRequirements(RequirementsOf(it), 1, nil, nil); err != nil {
		t.Errorf("mastery requirement with no mastery tracking: %v, want allowed", err)
	}
	// The SECOND_HWAN shape: a level AND a tier.
	hwan := &refdata.Item{
		ID:            4,
		ReqLevelType1: ReqTypeCharacterLevel, ReqLevel1: 95,
		ReqLevelType2: ReqTypeTier, ReqLevel2: 1,
	}
	if err := CheckRequirements(RequirementsOf(hwan), 95, nil, nil); err != nil {
		t.Errorf("tier requirement with no tier tracking: %v, want allowed", err)
	}
	// With a tier lookup it refuses with its own error, not the shared one.
	low := func() (int, bool) { return 0, true }
	if err := CheckRequirements(RequirementsOf(hwan), 95, nil, low); !errors.Is(err, ErrTierTooLow) {
		t.Errorf("tier 0 against a needed 1 = %v, want ErrTierTooLow", err)
	}
}

// An unused slot is -1 in the table and 0 in an export made before the later
// slots were carried; both must drop out, and an item with no requirement at
// all must be allowed at any level.
func TestUnusedSlotsAreSkipped(t *testing.T) {
	it := &refdata.Item{
		ID:            5,
		ReqLevelType1: ReqTypeUnused, ReqLevel1: 0,
		ReqLevelType2: 0, ReqLevel2: 0,
		ReqLevelType3: ReqTypeUnused, ReqLevel3: 0,
		ReqLevelType4: 0, ReqLevel4: 0,
	}
	if reqs := RequirementsOf(it); len(reqs) != 0 {
		t.Fatalf("RequirementsOf gave %d slots, want 0: %v", len(reqs), reqs)
	}
	if err := CheckRequirements(RequirementsOf(it), 1, nil, nil); err != nil {
		t.Errorf("item with no requirements: %v, want allowed", err)
	}
	if RequirementsOf(nil) != nil {
		t.Error("RequirementsOf(nil) should be nil")
	}
}

// The guild soldier scrolls carry a type the equip check has no branch for.
// The engine logs and refuses, but those rows are ETC items that are never
// equipped -- so the category must not make srrevamp refuse anything real.
func TestUnknownTypeDoesNotRefuse(t *testing.T) {
	it := &refdata.Item{ID: 6, ReqLevelType1: 10, ReqLevel1: 3}
	if err := CheckRequirements(RequirementsOf(it), 1, nil, nil); err != nil {
		t.Errorf("unknown requirement type: %v, want allowed", err)
	}
}
