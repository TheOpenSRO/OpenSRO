package session

// Round 877: a worn item counts only when its level and mastery requirements
// were met when it was last published, as the original's.
//
// READ in SR_GameServer.exe:
//
//   - GObjPC::PublishEquipItemParams (s:0x4e3760) adds a worn item's params
//     (its defences, parry, attack, absorption, its blues and its plus) only
//     when CGItemEquip::CheckEquipRequirements (s:0x4919e0) passes: the
//     character's level against a type-1 requirement, a mastery's level
//     (Mastery_GetLevel with the requirement's own type as the mastery id,
//     s:0x491b25..0x491b40) against a type 513..518 one, any one of each kind.
//   - It runs at a login (CGObjPC::Create s:0x4e0dc0 ->
//     CGStorage::RefreshEquipParamEntryForPC(0)), on every level change, up or
//     down (GObjPC_SetLevel s:0x4e4d90 -> RefreshEquipParamEntryForPC(1) at
//     s:0x4e5207 / 0x4e5214: every worn item's entry removed and published
//     again through the test), and for the one item an equip attaches (after
//     CanBeEquipedAt passed the same test) or a durability change re-adds
//     (CGObjPC::ChangeItemDurability s:0x4e7100).
//   - Mastery_LevelUp (s:0x59c4e0) publishes nothing again: it recomputes the
//     level ratios (FUN_004e30d0) and tells the client.
//   - A worn item that fails the test STAYS WORN: CheckEquipsetIntegrity
//     (s:0x4bb020) gives up on a login only for CanBeEquipedAt's 0x180e (the
//     wrong slot), not for 0x186c.
//
// MEASURED (a European at level 110, Warrior 110, Str/Int 129, the Seal of
// Nova robe's chest piece, ITEM_EU_M_CLOTHES_11_BA_A, which asks for Wizard,
// Warlock, Bard or Cleric 101): naked the character window reads phy def 24,
// mag def 39, parry 120; the robe put on at Cleric 101 reads 286 / 561 / 141;
// the same robe worn at a login with Cleric 100 reads 24 / 39 / 120 (worn,
// drawn, counting nothing); Cleric raised to 101 in the skill window with the
// robe on still reads 24 / 39 / 120; the robe taken off and put on again reads
// 286 / 561 / 141. So the snapshot below is the original's, not a cache
// artefact.
//
// OpenSRO keeps that snapshot per character: the worn slots whose item
// failed the test when it was last published ("held"). It is computed at a
// world entry (gearAtEntry) and on a level change (the character store's
// level hook), a successful equip clears its slot (it passed the test), an
// unequip clears its slot, and a mastery raise leaves it alone. A slot whose
// item is not the one held (an item put there by a path with no hook) counts,
// as an attached item does. Every stat sum reads the worn items through
// countedWorn.

import (
	"context"
	"sync"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/skill"
)

// gearEntry is one character's snapshot: the level it was taken at, the
// character's Country (whose masteries it holds), and the held slots with
// the ref id of the item held there.
type gearEntry struct {
	level   int
	country int
	held    map[equipment.Slot]int64
}

// gearSources is what a snapshot is taken from (SetGearRequirementSource).
type gearSources struct {
	chars  character.Store
	eq     equipment.Store
	skills skill.Store
	items  ItemLookup
}

var gearGate = struct {
	sync.Mutex
	src     *gearSources
	entries map[int64]*gearEntry
}{entries: map[int64]*gearEntry{}}

// SetGearRequirementSource makes the worn items' requirements count (round
// 877): every stat sum leaves out a worn item whose level or mastery
// requirement failed when it was last published. Any nil store: every worn
// item counts, as before.
func SetGearRequirementSource(chars character.Store, eq equipment.Store, skills skill.Store, items ItemLookup) {
	gearGate.Lock()
	if chars == nil || eq == nil || skills == nil || items == nil {
		gearGate.src = nil
	} else {
		gearGate.src = &gearSources{chars: chars, eq: eq, skills: skills, items: items}
	}
	gearGate.entries = map[int64]*gearEntry{}
	gearGate.Unlock()
	if chars == nil || eq == nil || skills == nil || items == nil {
		character.SetLevelHook(nil)
		return
	}
	character.SetLevelHook(gearOnLevel)
}

// masteryLookup is Mastery_GetLevel over levels: a mastery the character's
// Country does not hold reads 0, as one absent from the engine's held map.
func masteryLookup(country int, levels map[int64]int) func(int) (int, bool) {
	return func(id int) (int, bool) {
		if !skill.HoldsMastery(country, int64(id)) {
			return 0, true
		}
		return levels[int64(id)], true
	}
}

// gearSnapshot takes a character's snapshot at level: every worn item
// tested as PublishEquipItemParams tests it. ok false when the stores could
// not be read (nothing is cached then, and every item counts).
func gearSnapshot(ctx context.Context, src *gearSources, characterID int64, level, country int) (*gearEntry, bool) {
	worn, err := src.eq.Get(ctx, characterID)
	if err != nil {
		return nil, false
	}
	levels, err := src.skills.MasteryLevels(ctx, characterID)
	if err != nil {
		return nil, false
	}
	look := masteryLookup(country, levels)
	e := &gearEntry{level: level, country: country, held: map[equipment.Slot]int64{}}
	for _, w := range worn {
		it, err := src.items.GetItem(ctx, w.ItemID)
		if err != nil || it == nil {
			continue // an item nobody has data for counts as it always has
		}
		if !equipment.Qualifies(it, level, look) {
			e.held[w.Slot] = w.ItemID
		}
	}
	return e, true
}

// gearEntryOf is the character's snapshot, taken now (as at a login) when
// there is none. nil when there is no source or it could not be read.
func gearEntryOf(ctx context.Context, characterID int64) *gearEntry {
	gearGate.Lock()
	src, e := gearGate.src, gearGate.entries[characterID]
	gearGate.Unlock()
	if src == nil || characterID == 0 {
		return nil
	}
	if e != nil {
		return e
	}
	c, err := src.chars.GetByID(ctx, characterID)
	if err != nil || c == nil {
		return nil
	}
	e, ok := gearSnapshot(ctx, src, characterID, c.Level, characterCountry(c))
	if !ok {
		return nil
	}
	gearGate.Lock()
	if gearGate.src == src {
		if cur := gearGate.entries[characterID]; cur != nil {
			e = cur // a hook got there first
		} else {
			gearGate.entries[characterID] = e
		}
	}
	gearGate.Unlock()
	return e
}

// gearRefresh takes a character's snapshot again at level (a login, a level
// change) and forgets its cached bonus when what counts changed.
func gearRefresh(ctx context.Context, characterID int64, level, country int) {
	gearGate.Lock()
	src := gearGate.src
	gearGate.Unlock()
	if src == nil || characterID == 0 {
		return
	}
	e, ok := gearSnapshot(ctx, src, characterID, level, country)
	gearGate.Lock()
	if gearGate.src == src {
		if ok {
			gearGate.entries[characterID] = e
		} else {
			delete(gearGate.entries, characterID)
		}
	}
	gearGate.Unlock()
	character.InvalidateBonus(characterID)
}

// gearAtEntry is CGObjPC::Create's RefreshEquipParamEntryForPC: the worn
// items tested at a world entry. A character whose blues stop counting has
// its HP lowered to the new max (clampHP; INFERRED, as on a swap).
func gearAtEntry(ctx context.Context, chars character.Store, owned *character.Character) {
	if owned == nil {
		return
	}
	gearRefresh(ctx, owned.ID, owned.Level, characterCountry(owned))
	clampHP(ctx, chars, owned.ID)
}

// gearOnLevel is GObjPC_SetLevel's RefreshEquipParamEntryForPC(1), run by
// the character stores whenever a level is written: a changed level tests
// every worn item again. A character with no snapshot yet takes one on its
// next read, at the level then stored.
func gearOnLevel(characterID int64, level int) {
	gearGate.Lock()
	e := gearGate.entries[characterID]
	gearGate.Unlock()
	if e == nil || e.level == level {
		return
	}
	gearRefresh(context.Background(), characterID, level, e.country)
}

// gearSlotChanged clears a slot's hold: an equip attached an item that passed
// CanBeEquipedAt, or an unequip took it off.
func gearSlotChanged(characterID int64, slot equipment.Slot) {
	gearGate.Lock()
	if e := gearGate.entries[characterID]; e != nil {
		delete(e.held, slot)
	}
	gearGate.Unlock()
}

// gearCounted is worn without the items held by the snapshot.
func gearCounted(ctx context.Context, characterID int64, worn []equipment.Equipped) []equipment.Equipped {
	e := gearEntryOf(ctx, characterID)
	if e == nil {
		return worn
	}
	gearGate.Lock()
	defer gearGate.Unlock()
	if len(e.held) == 0 {
		return worn
	}
	out := make([]equipment.Equipped, 0, len(worn))
	for _, w := range worn {
		if id, held := e.held[w.Slot]; held && id == w.ItemID {
			continue
		}
		out = append(out, w)
	}
	return out
}

// countedWorn is eq.Get for a stat sum: the worn items whose params count.
func countedWorn(ctx context.Context, eq equipment.Store, characterID int64) ([]equipment.Equipped, error) {
	worn, err := eq.Get(ctx, characterID)
	if err != nil {
		return nil, err
	}
	return gearCounted(ctx, characterID, worn), nil
}

// gearMastery is the equip refusal's mastery lookup for c (nil when the
// masteries cannot be read: the requirement is then not enforced, as before
// round 877).
func gearMastery(ctx context.Context, skills skill.Store, c *character.Character) func(int) (int, bool) {
	if skills == nil || c == nil {
		return nil
	}
	levels, err := skills.MasteryLevels(ctx, c.ID)
	if err != nil {
		return nil
	}
	return masteryLookup(characterCountry(c), levels)
}

// gearSkills is the skill store the snapshot reads, for the equip refusal.
func gearSkills() skill.Store {
	gearGate.Lock()
	defer gearGate.Unlock()
	if gearGate.src == nil {
		return nil
	}
	return gearGate.src.skills
}
