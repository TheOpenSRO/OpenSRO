// Package grounditem is the items lying on the ground: what a kill leaves
// behind and a player walks up to and picks. The real server keeps one
// CGItem object per dropped stack, in world state 2 ("on the ground"), and
// this package is that object's rules, read off SR_GameServer.exe
// (docs/protocol/ground_items.md has the citations):
//
//   - pick range: 10.0 world units, a plain 3-D Euclidean distance between
//     the picker and the item (CGObjPC vtable slot 387 -> GObjPC::CheckCanPickUp
//     0x004a9050, the limit at .rdata 0xb45b44; the pet override passes 2000);
//   - ownership: the item carries its owner's id (CGItem+0x150). 0 means
//     anyone may pick it; the owner may; a party member may when the party
//     shares items -- EXCEPT on a TypeID 3/3/9 item whose codename does not
//     begin ITEM_QNO_RM_ARCHEMY, which the engine refuses every non-owner
//     before it reaches the party test (CheckCanPickUp 0x4a930d-0x4a9350);
//     anyone else is refused with 0x1812. srrevamp does not model that
//     exclusion: PickCheck applies the party rule to every item, a known
//     divergence (docs/protocol/ground_items.md, "Picking up", step 3);
//   - the ownership window: 30 s from the drop (CGItem::Update accumulates
//     the frame time at +0x158 against .rdata 0xb45e58 = 30.0), after which the
//     owner is cleared and everyone in range is told (0x304D [u32 id]) -- but
//     only for an item whose CanTrade answers yes. The release,
//     GObjPC::FUN_004901c0, asks vtable slot 49 (CGObj::CanTrade 0x00483d50,
//     the row's flags & 1) first and does nothing on 0, so an untradeable drop
//     (a quest item) stays reserved to its owner until it decays (Item.Bound);
//   - a pick in progress marks the item busy (+0x14c) and a second picker is
//     refused with 0x1813;
//   - before any of those, an id that is no longer on the ground answers 3,
//     and an item whose row clears CanPick (flags bit 5, itemdata column 21;
//     vtable slot 53, CGObj::CanPick 0x00483e50) is refused 0x1839 to
//     everyone, its owner included (Item.noPick, Hub.SetPickLookup).
//
// How long an item lies there before it vanishes IS read now (2026-09-19,
// round 227): it is the item's own row -- `_RefObjCommon DecayTime`, itemdata
// column 13, in milliseconds (refdata.Item.DecayTimeMs has the reading). The
// engine accumulates the object's seconds from the moment it enters the world
// in life-state 2 (CGObj::EnterWorld -> SetLifeState(2, 0xff, 0)) and removes
// it once they pass that value (CGObj::Update, 0x484d10). Note the consequence
// the data forces: most drops carry 10000 (ten seconds), SHORTER than the 30 s
// ownership window, so an ordinary drop vanishes while still reserved for its
// owner -- that is the game's rule, not a bug here. FallbackLifetime below is
// used only for an item whose row has no DecayTime (an export predating the
// column), and is disclosed as this project's own value.
package grounditem

import (
	"math"
	"sync"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/inventory"
)

// PickRange is how close a player must stand to pick an item up, in world
// units. Read: .rdata 0xb45b44 = 10.0, compared against the 3-D distance in
// GObjPC::CheckCanPickUp (error 4 beyond it).
const PickRange = 10.0

// OwnershipWindow is how long a drop stays reserved for its owner (and the
// owner's item-sharing party, except on a TypeID 3/3/9 item other than
// ITEM_QNO_RM_ARCHEMY* -- see PickCheck). Read: .rdata
// 0xb45e58 = 30.0 seconds, the threshold CGItem::Update's elapsed-time field
// is held against.
const OwnershipWindow = 30 * time.Second

// FallbackLifetime is how long an item lies on the ground when its reference
// row carries no DecayTime (zero: an items export made before that column
// existed). Own design, disclosed: three minutes is long enough to walk back
// for a drop and short enough that a farmed field does not fill with junk.
// An item with a real DecayTime never uses it -- see LifetimeFor.
const FallbackLifetime = 3 * time.Minute

// LifetimeFor turns an item's DecayTime (milliseconds, itemdata column 13)
// into the time it lies on the ground: the row's value when it has one, the
// disclosed fallback when it does not.
func LifetimeFor(decayTimeMs int) time.Duration {
	if decayTimeMs <= 0 {
		return FallbackLifetime
	}
	return time.Duration(decayTimeMs) * time.Millisecond
}

// GoldItemID is the reference item a pile of dropped gold is: ITEM_ETC_GOLD_03,
// itemdata id 3, which FUN_009348f0 spawns with an amount rolled from the
// level gold table (docs/RE_COMPLETION.md, "Gold -- data real, linkage
// inferred"). Picking it up adds gold, not an item.
const GoldItemID int64 = 3

// The refusal codes the real client shows, from GObjPC::CheckCanPickUp
// (0x004a9050).
const (
	// ErrNotThere: no such object, or not an item. The function opens with
	// `*param_2 = 3`, and returns false with it still 3 when the id resolves
	// to nothing (FUN_00485d90) or IGObj::IsItem (slot 18) says no -- a drop
	// that has already been picked up or has decayed. The same 3 is written
	// later for a life state other than 2 and for an owner of -1.
	ErrNotThere   = 3
	ErrTooFar     = 4      // the 10-unit range
	ErrNotOwner   = 0x1812 // someone else's drop, inside the window
	ErrBusy       = 0x1813 // another pick is in progress
	ErrCannotPick = 0x1839 // CanPick answered 0 (UIIT_MSG_STRGERR_CANNOT_BE_PICKED)
)

// Item is one stack lying on the ground.
type Item struct {
	ID       int64
	Zone     string
	ItemID   int64 // reference item id; GoldItemID for gold
	Quantity int32 // stack size, or the gold amount
	Gold     bool  // picks up as gold rather than as a bag item
	X, Y, Z  float32
	// OwnerID is the character the drop belongs to for OwnershipWindow after
	// DroppedAt; 0 once released (or if it never had one).
	OwnerID int64
	// Bound is an item whose reference row says it cannot be traded: its
	// owner is never released, so it stays reserved to its owner until it
	// decays. Who besides the owner may pick it is CheckCanPickUp's party
	// rule, which the engine skips for a TypeID 3/3/9 item not named
	// ITEM_QNO_RM_ARCHEMY* -- most bound quest items -- and srrevamp does not
	// (PickCheck). Read: GObjPC::FUN_004901c0
	// (0x004901c0), the release CGItem::Update calls once +0x158 passes 30.0
	// (0x48fa0b), opens with `call [vtable+0xc4]` (0x4901c5) and returns
	// without clearing +0x150 when it answers 0 (0x4901d1 je). +0xc4 is slot
	// 49, and all seven vtables that carry CGItem::Update at slot 211
	// (0xae9384 .. 0xaeb824) hold CGObj::CanTrade (0x00483d50) there:
	// CGObj::IsItem (slot 18, 0x00482d80), then the ref row's flags word
	// +0x8c & 1 -- itemdata column 16 (docs/protocol/item_capability_flags.md,
	// "The bit map" and "The columns, anchored against real data"). Set at
	// Drop from the hub's trade lookup; false when there is none or the item
	// is unknown to it.
	Bound     bool
	DroppedAt time.Time
	// ExpiresAt is when the world removes the stack: DroppedAt plus the
	// item's own DecayTime (LifetimeFor), fixed when it is dropped.
	ExpiresAt time.Time
	// Instance is the stack's own variance and durability when it already
	// had one (an item a player dropped, a stack picked back up); nil for a
	// stack fresh off the loot table, which the bag rolls on pick-up exactly
	// as it would any new item.
	Instance *inventory.Instance
	busy     bool
	// noPick is an item whose reference row answers CanPick = 0 (itemdata
	// column 21, flags bit 5): CheckCanPickUp refuses it 0x1839 to everyone,
	// owner included. Set at Drop from the hub's pick lookup.
	noPick bool
}

// OwnerAt returns who owns the item at t: its owner inside the window, 0
// after it -- the same answer the real item gives once CGItem::Update has
// cleared +0x150. A Bound item keeps its owner past the window, because
// FUN_004901c0 never clears it.
func (it Item) OwnerAt(t time.Time) int64 {
	if it.Bound {
		return it.OwnerID
	}
	if it.OwnerID == 0 || !t.Before(it.DroppedAt.Add(OwnershipWindow)) {
		return 0
	}
	return it.OwnerID
}

// Hub holds every item on the ground across zones.
type Hub struct {
	mu     sync.Mutex
	nextID int64
	items  map[int64]*Item
	// now is swappable for tests.
	now func() time.Time
	// decayTimeMs answers an item's DecayTime in ms (0 = unknown); nil means
	// no reference data was given and every drop gets FallbackLifetime.
	decayTimeMs func(itemID int64) int
	// canTrade answers an item's CanTrade flag, known=false when the item is
	// not in the reference data; nil means none was given and no drop is
	// Bound.
	canTrade func(itemID int64) (canTrade, known bool)
	// canPick answers an item's CanPick flag; nil means none was given and
	// every drop is pickable.
	canPick func(itemID int64) bool
}

func NewHub() *Hub {
	return &Hub{items: make(map[int64]*Item), now: time.Now}
}

// SetDecayLookup gives the hub the reference data that says how long each
// item lies on the ground. Without one every drop gets FallbackLifetime.
func (h *Hub) SetDecayLookup(decayTimeMs func(itemID int64) int) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.decayTimeMs = decayTimeMs
}

// SetTradeLookup gives the hub the reference data that says whether each
// item can be traded. A drop whose row answers no is Bound: its owner is
// never released. Without a lookup, or for an item the lookup does not know,
// every drop is released after OwnershipWindow, so a deployment with no
// reference data does not lock its drops.
func (h *Hub) SetTradeLookup(canTrade func(itemID int64) (canTrade, known bool)) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.canTrade = canTrade
}

// SetPickLookup gives the hub the reference data that says whether each item
// can be picked up at all (refdata.Item.CanPick, itemdata column 21). A drop
// whose row answers no is refused ErrCannotPick by PickCheck. Without a
// lookup every drop is pickable. The answer is taken once, at Drop, so no
// lookup runs under the hub's lock at pick time.
func (h *Hub) SetPickLookup(canPick func(itemID int64) bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.canPick = canPick
}

// Drop puts a stack on the ground at (x, y, z) in zone, owned by ownerID. It
// lies there for its own DecayTime (LifetimeFor) from this moment, is Bound
// when the trade lookup knows it and says it cannot be traded, and cannot be
// picked when the pick lookup says so.
func (h *Hub) Drop(zone string, itemID int64, quantity int32, gold bool, x, y, z float32, ownerID int64) Item {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.nextID++
	now := h.now()
	decay := 0
	if h.decayTimeMs != nil {
		decay = h.decayTimeMs(itemID)
	}
	bound := false
	if h.canTrade != nil {
		ct, known := h.canTrade(itemID)
		bound = known && !ct
	}
	noPick := h.canPick != nil && !h.canPick(itemID)
	it := &Item{ID: h.nextID, Zone: zone, ItemID: itemID, Quantity: quantity, Gold: gold,
		X: x, Y: y, Z: z, OwnerID: ownerID, Bound: bound, DroppedAt: now, ExpiresAt: now.Add(LifetimeFor(decay)),
		noPick: noPick}
	h.items[it.ID] = it
	return *it
}

// Get returns a copy of the item, if it is still on the ground.
func (h *Hub) Get(id int64) (Item, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	it, ok := h.items[id]
	if !ok {
		return Item{}, false
	}
	return *it, true
}

// InZone lists what lies in a zone, oldest first.
func (h *Hub) InZone(zone string) []Item {
	h.mu.Lock()
	defer h.mu.Unlock()
	var out []Item
	for _, it := range h.items {
		if it.Zone == zone {
			out = append(out, *it)
		}
	}
	sortByID(out)
	return out
}

// PickCheck is everything CheckCanPickUp decides before an item changes
// hands, in the engine's order (GObjPC::CheckCanPickUp, 0x004a9050): the
// item must still be there (ErrNotThere, 3), its CanPick must answer yes
// (ErrCannotPick, 0x1839, vtable slot 53), it must be in range (ErrTooFar,
// 4), not already being picked (ErrBusy, 0x1813, the +0x14c test the engine
// makes after the range), and the picker must own it or be let in by the
// party rule the caller supplies (ErrNotOwner). On success the item is
// marked busy for this picker until Remove or Release is called; a 0 result
// code means the pick may proceed.
//
// Two engine tests in that sequence have nothing to act on here. Between
// CanPick and the range, an item whose slot 46 (IGObj::IsQuest_n_EventItem)
// answers yes has the picker's quest state asked, refusing 0x1874
// UIIT_MSG_STRGERR_CANNOT_BE_PICKED_AT_QUEST_ACHIEVE_CONDITION; srrevamp
// has no quest-achieve condition to ask. Between the range and the busy
// flag, a life state other than 2 answers 3; every item in the hub is on the
// ground, which this project INFERS is life state 2 -- slot 62 in the item
// vtables is CGObj::GetLifeState (0x485ee0), a raw byte read, and nothing
// read so far ties a ground item to state 2 (round 495).
//
// Two of the engine's ownership outcomes are not modelled, both known
// divergences (docs/protocol/ground_items.md, "Picking up", step 3):
//   - the party exclusion. For an item whose TID answers FUN_0042fdc0
//     (TypeID 3/3/9) the engine compares the codename's first 0x13 chars
//     with "ITEM_QNO_RM_ARCHEMY" (.rdata 0xaebf58, CompareStringA at
//     0x4a9342) and, unless they match, refuses every non-owner 0x1812
//     (0x4a934d) before the party test at 0x4a9360. The hub knows neither
//     the TID nor the codename, so sameParty is asked for every item: a
//     sharing party member may pick an owned 3/3/9 item here that the
//     engine would refuse them.
//   - the absent owner. When the owner id resolves to no object
//     (FUN_00485dc0 == 0, 0x4a93d1 / 0x4a92ec) the engine writes result 1
//     and returns false; here the party rule alone decides, and it asks
//     party membership, not whether the owner is in the world.
func (h *Hub) PickCheck(id int64, pickerID int64, px, py, pz float32, sameParty func(a, b int64) bool) (Item, int) {
	h.mu.Lock()
	defer h.mu.Unlock()
	it, ok := h.items[id]
	if !ok {
		return Item{}, ErrNotThere
	}
	if it.noPick {
		return *it, ErrCannotPick
	}
	dx, dy, dz := float64(it.X-px), float64(it.Y-py), float64(it.Z-pz)
	if math.Sqrt(dx*dx+dy*dy+dz*dz) > PickRange {
		return *it, ErrTooFar
	}
	if it.busy {
		return *it, ErrBusy
	}
	if owner := it.OwnerAt(h.now()); owner != 0 && owner != pickerID {
		if sameParty == nil || !sameParty(owner, pickerID) {
			return *it, ErrNotOwner
		}
	}
	it.busy = true
	return *it, 0
}

// Release clears the busy mark a failed pick left behind.
func (h *Hub) Release(id int64) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if it, ok := h.items[id]; ok {
		it.busy = false
	}
}

// Remove takes the item off the ground (picked up, or expired).
func (h *Hub) Remove(id int64) (Item, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	it, ok := h.items[id]
	if !ok {
		return Item{}, false
	}
	delete(h.items, id)
	return *it, true
}

// ReleaseOwnerships clears the owner of every item whose window has passed
// and returns them, so the caller can tell the zone (the real 0x304D). Each
// item is returned once. A Bound item is skipped: FUN_004901c0 neither
// clears its owner nor sends 0x304D.
func (h *Hub) ReleaseOwnerships() []Item {
	h.mu.Lock()
	defer h.mu.Unlock()
	now := h.now()
	var out []Item
	for _, it := range h.items {
		if it.Bound {
			continue
		}
		if it.OwnerID != 0 && !now.Before(it.DroppedAt.Add(OwnershipWindow)) {
			it.OwnerID = 0
			out = append(out, *it)
		}
	}
	sortByID(out)
	return out
}

// Expire removes every item whose own DecayTime has passed and returns them.
func (h *Hub) Expire() []Item {
	h.mu.Lock()
	defer h.mu.Unlock()
	now := h.now()
	var out []Item
	for id, it := range h.items {
		if !now.Before(it.ExpiresAt) {
			out = append(out, *it)
			delete(h.items, id)
		}
	}
	sortByID(out)
	return out
}

func sortByID(items []Item) {
	for i := 1; i < len(items); i++ {
		for j := i; j > 0 && items[j-1].ID > items[j].ID; j-- {
			items[j-1], items[j] = items[j], items[j-1]
		}
	}
}
