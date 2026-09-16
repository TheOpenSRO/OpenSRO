package equipment

import (
	"errors"
	"fmt"

	"github.com/OpenSRO/srrevamp/server/internal/refdata"
)

// The item requirement model, recovered from the engine's own checker.
//
// _RefObjCommon carries FOUR requirement slots: an int32 type at +0xb4 and a
// uint8 value at +0xb8, stride 8. RefObjCommon_ExtractData fills them from
// columns 32..39 in a four-iteration loop; the count of four is the engine's
// own, from the `3 < n` assert in the checker rather than from where the
// columns happen to stop.
//
// CGItemEquip::CheckEquipRequirements (server 0x004919e0), called by
// CanBeEquipedAt before any of its other tests, walks all four:
//
//	for n := 0; n < 4; n++ {
//	    id := common.ReqType[n]
//	    if id == -1 { unused++; continue }
//	    switch {
//	    case id == 1:                need |= 1; if value <= GetLevel()    { met |= 1 }
//	    case 0x201 <= id && id <= 0x206: need |= 2; if value <= Mastery() { met |= 2 }
//	    case id == 0x301:            need |= 4; if Tier() < value { return 0x18f7 }
//	    case id == 2, 3, 4, 0x10:    // accepted, no category
//	    default:                     log "This Mastery Type is not exist!"; refuse
//	    }
//	}
//	if unused == 4 { return ok }                      // no requirements at all
//	for cat := 0; cat < 3; cat++ {
//	    if need[cat] && !met[cat] { return 0x186c }   // requirement not met
//	}
//	return ok
//
// TWO THINGS ABOUT THAT SHAPE ARE EASY TO GET WRONG, and getting either
// backwards changes real answers:
//
//  1. `need` and `met` are ONE BIT PER CATEGORY, or-ed. So several slots of
//     the same type are **OR**, not AND -- satisfying any one satisfies the
//     category. The seven real rows that carry two character-level
//     requirements are all ITEM_MALL_STATS_POINT_RECALL*, e.g. (1,1) and
//     (1,40); under the engine's rule that means level >= 1, NOT level >= 40.
//     Requiring every pair would lock those items to the higher number.
//  2. Across categories it IS and -- every category that appears must be
//     satisfied.
//
// Measured over a real client's 23,327 item rows: 11,636 carry a lone
// character-level requirement, 6,504 carry none at all, 3,372 carry mastery
// requirements in the later slots, 8 carry a 0x301, and 24 carry a type 10.
// Only the first slot was read before this model existed.
const MaxRequirements = 4

// Requirement types, in the engine's own vocabulary. Values outside this set
// are what the engine's "This Mastery Type is not exist! (DEC:%d)(Hex:%x),
// Item's RefObjID(%d)" names.
const (
	// ReqTypeUnused marks a slot with no requirement. The table writes -1;
	// an export made before the later slots existed leaves 0, and both are
	// treated as unused.
	ReqTypeUnused = -1
	// ReqTypeCharacterLevel asks for the character's own level. The engine
	// compares against vtable slot 0x124 (GetLevel).
	ReqTypeCharacterLevel = 1
	// ReqTypeMasteryFirst..Last are the six mastery ids, 0x201..0x206 --
	// the table's 513..518. They are NOT "the European masteries" as an
	// earlier note here said: real Chinese rows use 513/515/518 and real
	// European ones 514/516/517/518, so the range spans both races.
	ReqTypeMasteryFirst = 0x201
	ReqTypeMasteryLast  = 0x206
	// ReqTypeTier is the engine's third category, which refuses with its own
	// code (0x18f7) rather than the shared 0x186c. The only real rows that
	// use it are ITEM_ETC_SECOND_HWAN_SCROLL_01..04, carrying values 1..4
	// beside character levels 95/100/105/110.
	ReqTypeTier = 0x301
)

// Category is which of the engine's three requirement bits a type belongs to.
// The values are the engine's own bit numbers, from the `need`/`met` masks.
type Category int

const (
	// CategoryNone is a type the equip check accepts and does nothing with:
	// 2, 3, 4 and 0x10.
	CategoryNone Category = 0
	// CategoryLevel is bit 0, the character's level.
	CategoryLevel Category = 1
	// CategoryMastery is bit 1, a mastery's level.
	CategoryMastery Category = 2
	// CategoryTier is bit 2, the ReqTypeTier category.
	CategoryTier Category = 4
	// CategoryUnknown is a type the equip check does not recognise at all --
	// where the engine logs "This Mastery Type is not exist!" and refuses.
	//
	// This is NOT only a data error. All 24 real rows carrying such a type
	// (10) are ITEM_ETC_GUILD_*_SOLDIER*_SCROLL, TypeID 3/3/12/1 -- ETC
	// items that are used, never equipped, so the equip checker never sees
	// them and the engine's assert never fires. The type means something to
	// the use path; it just is not part of THIS check's vocabulary.
	CategoryUnknown Category = -1
)

var (
	// ErrRequirementNotMet means a requirement category the item asks for is
	// not satisfied. Engine: 0x186c.
	ErrRequirementNotMet = errors.New("equipment: item requirement not met")
	// ErrTierTooLow is the ReqTypeTier refusal, which the engine gives its
	// own code rather than folding into ErrRequirementNotMet.
	// Engine: 0x18f7.
	ErrTierTooLow = errors.New("equipment: job tier too low")
)

// Requirement is one of an item's four requirement slots.
type Requirement struct {
	Type  int
	Value int
}

// CategoryOf reports which category a requirement type belongs to, mirroring
// the engine's branch order exactly.
func CategoryOf(reqType int) Category {
	switch {
	case reqType == ReqTypeCharacterLevel:
		return CategoryLevel
	case reqType >= ReqTypeMasteryFirst && reqType <= ReqTypeMasteryLast:
		return CategoryMastery
	case reqType == ReqTypeTier:
		return CategoryTier
	case reqType == 2, reqType == 3, reqType == 4, reqType == 0x10:
		return CategoryNone
	default:
		return CategoryUnknown
	}
}

// RequirementsOf returns an item's used requirement slots, in table order.
// A slot holding -1 (the table's own "unused") or 0 (an export made before
// the later slots were carried) is left out.
func RequirementsOf(it *refdata.Item) []Requirement {
	if it == nil {
		return nil
	}
	all := [MaxRequirements]Requirement{
		{it.ReqLevelType1, it.ReqLevel1},
		{it.ReqLevelType2, it.ReqLevel2},
		{it.ReqLevelType3, it.ReqLevel3},
		{it.ReqLevelType4, it.ReqLevel4},
	}
	used := make([]Requirement, 0, MaxRequirements)
	for _, r := range all {
		if r.Type == ReqTypeUnused || r.Type == 0 {
			continue
		}
		used = append(used, r)
	}
	return used
}

// CheckRequirements applies the engine's rule to an item's requirement slots.
//
// masteryLevel and tier are how the caller supplies the two values srrevamp
// does not track yet. **A nil lookup means that category is not enforced**,
// which is deliberate: refusing every mastery-gated item because nothing
// records a mastery level would be a worse answer than the engine's, not a
// closer one. When mastery tracking lands, pass a real lookup and the rule
// already here starts enforcing it.
func CheckRequirements(reqs []Requirement, level int, masteryLevel func(masteryID int) (int, bool), tier func() (int, bool)) error {
	var need, met Category
	for _, r := range reqs {
		switch CategoryOf(r.Type) {
		case CategoryLevel:
			need |= CategoryLevel
			if r.Value <= level {
				met |= CategoryLevel
			}
		case CategoryMastery:
			if masteryLevel == nil {
				continue
			}
			need |= CategoryMastery
			if have, ok := masteryLevel(r.Type); ok && r.Value <= have {
				met |= CategoryMastery
			}
		case CategoryTier:
			if tier == nil {
				continue
			}
			// The engine refuses here and then, with its own code, rather
			// than deferring to the shared one at the end.
			have, ok := tier()
			if !ok || have < r.Value {
				return fmt.Errorf("%w: needs tier %d", ErrTierTooLow, r.Value)
			}
			need |= CategoryTier
			met |= CategoryTier
		case CategoryNone, CategoryUnknown:
			// Accepted without effect. See CategoryUnknown: the real rows
			// that reach it are never equipped in the first place.
		}
	}
	// Every category that appears must be satisfied; within a category the
	// slots are or-ed, which the single bit above already does.
	if unmet := need &^ met; unmet != 0 {
		if unmet&CategoryLevel != 0 {
			return fmt.Errorf("%w: needs level %d, character is %d", ErrLevelTooLow, requiredLevel(reqs), level)
		}
		return fmt.Errorf("%w: unsatisfied category %d", ErrRequirementNotMet, unmet)
	}
	return nil
}

// requiredLevel is the lowest character level that would satisfy the level
// category -- the smallest value across its slots, because the slots are
// or-ed. Used only to word the refusal.
func requiredLevel(reqs []Requirement) int {
	lowest := 0
	for _, r := range reqs {
		if CategoryOf(r.Type) != CategoryLevel {
			continue
		}
		if lowest == 0 || r.Value < lowest {
			lowest = r.Value
		}
	}
	return lowest
}
