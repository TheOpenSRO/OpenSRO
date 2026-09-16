package equipment

import "github.com/OpenSRO/srrevamp/server/internal/refdata"

// Item sets: which pieces belong together, and when a character is wearing a
// whole one.
//
// THE MECHANISM IS RECOVERED, AND SO IS THE TIER TABLE (2026-09-16, one tick
// after this file said it was not). The previous note here read "the set
// table's twelve trailing columns -- where the reward lives -- are not
// decoded", which was true when written and is not now. The last ten of those
// columns are indexed by piece count: column at position N holds the
// `MagicOptGroupID` granted for wearing exactly N pieces, for N in 2..11.
//
// What settled it was a falsifiable prediction rather than a pattern. The
// group table names its own tiers -- group 2 is `MAGIC_11_SET_A_DEFENSE_2`,
// group 3 `..._DEFENSE_4`, group 4 `..._DEFENSE_6` -- and those three sit at
// positions 2, 4 and 6. If position means piece count, then an ACCESSORY set,
// having only three slots, can never reach six pieces and must leave position
// 6 empty. It does: `ITEM_11_SET_A_ACCESSORY` carries `_ACCESSORY_2` at 2 and
// `_ACCESSORY_4` at 4, and nothing at 6.
//
// Positions 0 and 1 are NOT tiers and are still unknown. Position 1 looks like
// one -- its values are legal group ids -- but they misbehave: the armour sets
// hold 21 there, which is `SOCKET_STONE_CRITICAL_E`, and SET_B's accessory row
// holds 5, which is SET_A's accessory group. A value being a legal id is not
// evidence that it is one.
//
// srrevamp still grants nothing: it has no magic-option system to grant into,
// and `refmagicoptgroup.txt` is not loaded. What it has is the rule, tested.
// See refdata.Item.SetID and BonusTier.
//
// The client keeps, per character, a map from set id to a two-word record:
//
//	FUN_00a5ff00(slot, item)   bit = 1 << slot
//	                           if ((bit & mask) == 0) { count++; mask |= bit; }
//	FUN_00a5ffd0(slot, item)   if ((bit & mask) != 0) { count--; mask &= ~bit; }
//	                           if (mask == 0) erase the entry
//	FUN_00a60220(item)         return count == popcount(setdef + 0xa4)
//
// (`0x00a5ff00`, `0x00a5ffd0`, `0x00a60220`; the removal path `0x00a60160`
// derives its slot from GlobalDataManager::FUN_009db5e0, the visual-slot
// resolver, which is what proves the bits are SLOT numbers.) The set
// definition carries a slot mask and FUN_009733c0 (`0x009733c0`) is an
// unrolled popcount of it, so **a set is complete when a character wears one
// piece in each of its slots** -- a count of distinct slots, not of items.
// When the count matches, the appearance installer sets a byte at
// character+0x1a0.
//
// That the bits are distinct slots rather than items matters, and the data
// says why: of the 42 sets a real itemdata references, 30 list more than one
// item for some slot (gender and rarity variants). Counting items would never
// complete those. Counting slots does, which is also what the client's
// `(bit & mask) == 0` guard is for.
//
// Measured over a real client's tables, the 42 sets have these shapes:
//
//	36 sets  slots {0,1,2,3,4,5}   the six armour pieces
//	 2 sets  slots {9,10,11}       the three accessories
//	 2 sets  slots {6}             a weapon alone
//	 2 sets  slots {7}             a shield alone
//
// Every piece of every set resolves through SlotFor, with none left over.

// MinSetPiecesForBonus is the fewest pieces that grant anything. The engine
// computes the tier key from the worn count with
//
//	CSetMagicOptionOP::FUN_0066c3d0(count):
//	    if (count < 2) return 0;
//	    return 1 << (count - 2);
//
// (`0x0066c3d0`) -- so one piece is worth nothing, and the tiers start at two.
const MinSetPiecesForBonus = 2

// SetProgress is how far one character is through one item set.
type SetProgress struct {
	SetID int
	// Slots is the set of slots the character has a piece of this set in.
	// It is a set, not a count of items: two items of the same set in one
	// slot is impossible, and two listed for one slot is common.
	Slots map[Slot]bool
}

// Count is how many of the set's slots are filled.
func (p SetProgress) Count() int { return len(p.Slots) }

// Complete reports whether the character is wearing a whole set, given how
// many slots the set has. The caller supplies that: it is popcount of the set
// definition's own slot mask, which lives in the `_RefSetItemGroup` table this
// project does not parse. Reports false for a non-positive size rather than
// calling an empty set complete.
func (p SetProgress) Complete(setSlots int) bool {
	return setSlots > 0 && p.Count() == setSlots
}

// SetsWorn groups what a character has equipped by item set, skipping items
// that belong to no set and items with no reference row.
//
// `worn` maps each occupied slot to that slot's item. The slot in the map is
// used rather than SlotFor's answer, so a ring in either of its two slots
// counts once for the slot it is actually in.
func SetsWorn(worn map[Slot]*refdata.Item) map[int]SetProgress {
	out := map[int]SetProgress{}
	for slot, it := range worn {
		if it == nil || it.SetID == 0 {
			continue
		}
		p, ok := out[it.SetID]
		if !ok {
			p = SetProgress{SetID: it.SetID, Slots: map[Slot]bool{}}
		}
		p.Slots[slot] = true
		out[it.SetID] = p
	}
	return out
}

// BonusTier reports which of a set's bonus tiers a character has earned:
// the MagicOptGroupID to apply, or false for none.
//
// `tiers` maps a piece count to the group granted for wearing exactly that
// many pieces -- which is what the last ten of `_RefSetItemGroup`'s twelve
// trailing columns hold, one per count. The caller supplies it because this
// project does not load that table.
//
// THE RULE IS "HIGHEST TIER NOT EXCEEDING WHAT YOU WEAR", not an exact match.
// CSetMagicOptionOP::FUN_006a7320 (`0x006a7320`) takes the bit above and walks
// the set's own tier map, shifting the bit right and retrying until something
// matches or it reaches zero:
//
//	while (bit != 0) { if (found(bit)) return group; bit >>= 1; }
//	return 0;
//
// Each shift is one fewer piece, so five pieces of a six-slot set earn the
// four-piece bonus.
func (p SetProgress) BonusTier(tiers map[int]int) (int, bool) {
	best, group := 0, 0
	for n := p.Count(); n >= MinSetPiecesForBonus; n-- {
		if g, ok := tiers[n]; ok && g != 0 {
			best, group = n, g
			break
		}
	}
	if best == 0 {
		return 0, false
	}
	return group, true
}
