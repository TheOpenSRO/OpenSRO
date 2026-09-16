package equipment

import "github.com/OpenSRO/srrevamp/server/internal/refdata"

// Item sets: which pieces belong together, and when a character is wearing a
// whole one.
//
// THE MECHANISM IS RECOVERED; THE BONUS IS NOT. srrevamp can say that a
// character has completed a set and which slots it covers, because the client
// computes exactly that and this mirrors it. It grants nothing, because the set
// table's twelve trailing columns -- where the reward lives -- are not decoded.
// See refdata.Item.SetID.
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
