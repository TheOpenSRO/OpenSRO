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
//     shares items; anyone else is refused with 0x1812;
//   - the ownership window: 30 s from the drop (CGItem::Update accumulates
//     the frame time at +0x158 against .rdata 0xb45e58 = 30.0), after which the
//     owner is cleared and everyone in range is told (0x304D [u32 id]);
//   - a pick in progress marks the item busy (+0x14c) and a second picker is
//     refused with 0x1813.
//
// What is NOT read: how long an unclaimed item lies there before it vanishes.
// Lifetime below is this project's own value, said so, and easy to replace.
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
// owner's item-sharing party). Read: .rdata 0xb45e58 = 30.0 seconds, the
// threshold CGItem::Update's elapsed-time field is held against.
const OwnershipWindow = 30 * time.Second

// Lifetime is how long an item lies on the ground before it vanishes. NOT
// read from the binary -- CGItem::DoJob is a stub and the sweep that deletes
// stale items was not located -- so this is own design, disclosed. Three
// minutes is long enough to walk back for a drop and short enough that a
// farmed field does not fill with junk.
const Lifetime = 3 * time.Minute

// GoldItemID is the reference item a pile of dropped gold is: ITEM_ETC_GOLD_03,
// itemdata id 3, which FUN_009348f0 spawns with an amount rolled from the
// level gold table (docs/RE_COMPLETION.md, "Gold -- data real, linkage
// inferred"). Picking it up adds gold, not an item.
const GoldItemID int64 = 3

// The refusal codes the real client shows, from GObjPC::CheckCanPickUp.
const (
	ErrTooFar     = 4      // the 10-unit range
	ErrNotOwner   = 0x1812 // someone else's drop, inside the window
	ErrBusy       = 0x1813 // another pick is in progress
	ErrCannotPick = 0x1839 // CanPick said no (not a pickable object)
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
	OwnerID   int64
	DroppedAt time.Time
	// Instance is the stack's own variance and durability when it already
	// had one (an item a player dropped, a stack picked back up); nil for a
	// stack fresh off the loot table, which the bag rolls on pick-up exactly
	// as it would any new item.
	Instance *inventory.Instance
	busy     bool
}

// OwnerAt returns who owns the item at t: its owner inside the window, 0
// after it -- the same answer the real item gives once CGItem::Update has
// cleared +0x150.
func (it Item) OwnerAt(t time.Time) int64 {
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
}

func NewHub() *Hub {
	return &Hub{items: make(map[int64]*Item), now: time.Now}
}

// Drop puts a stack on the ground at (x, y, z) in zone, owned by ownerID.
func (h *Hub) Drop(zone string, itemID int64, quantity int32, gold bool, x, y, z float32, ownerID int64) Item {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.nextID++
	it := &Item{ID: h.nextID, Zone: zone, ItemID: itemID, Quantity: quantity, Gold: gold,
		X: x, Y: y, Z: z, OwnerID: ownerID, DroppedAt: h.now()}
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
// hands: range, ownership (with the party rule the caller supplies) and the
// busy flag. On success the item is marked busy for this picker until
// Remove or Release is called; a 0 result code means the pick may proceed.
func (h *Hub) PickCheck(id int64, pickerID int64, px, py, pz float32, sameParty func(a, b int64) bool) (Item, int) {
	h.mu.Lock()
	defer h.mu.Unlock()
	it, ok := h.items[id]
	if !ok {
		return Item{}, ErrCannotPick
	}
	if it.busy {
		return *it, ErrBusy
	}
	dx, dy, dz := float64(it.X-px), float64(it.Y-py), float64(it.Z-pz)
	if math.Sqrt(dx*dx+dy*dy+dz*dz) > PickRange {
		return *it, ErrTooFar
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
// item is returned once.
func (h *Hub) ReleaseOwnerships() []Item {
	h.mu.Lock()
	defer h.mu.Unlock()
	now := h.now()
	var out []Item
	for _, it := range h.items {
		if it.OwnerID != 0 && !now.Before(it.DroppedAt.Add(OwnershipWindow)) {
			it.OwnerID = 0
			out = append(out, *it)
		}
	}
	sortByID(out)
	return out
}

// Expire removes every item older than Lifetime and returns them.
func (h *Hub) Expire() []Item {
	h.mu.Lock()
	defer h.mu.Unlock()
	now := h.now()
	var out []Item
	for id, it := range h.items {
		if !now.Before(it.DroppedAt.Add(Lifetime)) {
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
