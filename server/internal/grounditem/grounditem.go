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
//     before it reaches the party test (CheckCanPickUp 0x4a930d-0x4a9350;
//     OwnerOnlyPick, resolved at Drop into Item.ownerOnly, round 497);
//     anyone else is refused with 0x1812;
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
//     everyone, its owner included (Item.noPick).
//
// What a drop needs from the item's reference row -- DecayTime, CanTrade,
// CanPick, the TypeID 3/3/9 exclusion -- is one DropRules value, resolved once
// per Drop through the hub's rules lookup (Hub.SetRulesLookup) BEFORE the
// hub's lock is taken, so a reference-data round trip never runs under it.
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
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
)

// PickRange is how close a player must stand to pick an item up, in world
// units. Read: .rdata 0xb45b44 = 10.0, compared against the 3-D distance in
// GObjPC::CheckCanPickUp (error 4 beyond it).
const PickRange = 10.0

// OwnershipWindow is how long a drop stays reserved for its owner (and the
// owner's item-sharing party, except on a TypeID 3/3/9 item other than
// ITEM_QNO_RM_ARCHEMY* -- see OwnerOnlyPick). Read: .rdata
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
	// ITEM_QNO_RM_ARCHEMY* -- most bound quest items (ownerOnly,
	// OwnerOnlyPick). Read: GObjPC::FUN_004901c0
	// (0x004901c0), the release CGItem::Update calls once +0x158 passes 30.0
	// (0x48fa0b), opens with `call [vtable+0xc4]` (0x4901c5) and returns
	// without clearing +0x150 when it answers 0 (0x4901d1 je). +0xc4 is slot
	// 49, and all seven vtables that carry CGItem::Update at slot 211
	// (0xae9384 .. 0xaeb824) hold CGObj::CanTrade (0x00483d50) there:
	// CGObj::IsItem (slot 18, 0x00482d80), then the ref row's flags word
	// +0x8c & 1 -- itemdata column 16 (docs/protocol/item_capability_flags.md,
	// "The bit map" and "The columns, anchored against real data"). Set at
	// Drop from the hub's rules lookup (DropRules.Bound); false when there is
	// none or the item is unknown to it.
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
	// Serial is the drop's identity (round 743, the spec's M1: "the ground
	// item gets a serial at drop time"), from the hub's serial source
	// (SetSerialSource: item_serial_seq in production). The pick-up's
	// transaction claims it in the economy ledger, so the item can be
	// granted once however many times a pick is attempted. Negative when
	// the hub has no source or it failed: a number unique within this
	// process, which the pick-up's key pairs with the process's boot id
	// (session.pickupLedgerKey).
	Serial int64
	busy   bool
	// noPick is an item whose reference row answers CanPick = 0 (itemdata
	// column 21, flags bit 5): CheckCanPickUp refuses it 0x1839 to everyone,
	// owner included. Set at Drop from the hub's rules lookup.
	noPick bool
	// Expendable is DropRules.Expendable, set at Drop (round 712).
	Expendable bool
	// ownerOnly is a TypeID 3/3/9 item not named ITEM_QNO_RM_ARCHEMY*
	// (OwnerOnlyPick): while it is owned, CheckCanPickUp refuses every
	// non-owner 0x1812 before the party test, so the party allowance never
	// applies to it. Set at Drop from the hub's rules lookup.
	ownerOnly bool
}

// OwnerOnly reports the item's OwnerOnlyPick answer: the party allowance and
// the party's item round robin never apply to it (round 712: FUN_00525dc0
// keeps a TypeID 3/3/9 item that is not ITEM_QNO_RM_ARCHEMY* for the picker).
func (it Item) OwnerOnly() bool { return it.ownerOnly }

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
	// rules answers what a drop of an item needs from its reference row; nil
	// means no reference data was given, and every drop gets the zero
	// DropRules (FallbackLifetime, released, pickable, shared).
	rules func(itemID int64) DropRules
	// serial numbers each drop (Item.Serial); nil leaves it zero.
	serial func() int64
}

// localSerials numbers drops without a serial source, across every Hub of
// the process (Item.Serial, negated).
var localSerials atomic.Int64

// SetSerialSource gives each later drop a serial from next, called once per
// drop before the hub's lock is taken (it may reach the database). A zero
// answer leaves the drop without one.
func (h *Hub) SetSerialSource(next func() int64) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.serial = next
}

func NewHub() *Hub {
	return &Hub{items: make(map[int64]*Item), now: time.Now}
}

// DropRules is everything Drop needs to know about an item from its
// reference row, answered by ONE lookup per drop. The zero value is what an
// item the reference data does not know gets -- and what every drop gets
// without a lookup -- so that no drop is locked, refused or held back on
// data the deployment does not have:
//   - DecayTimeMs 0: FallbackLifetime (LifetimeFor);
//   - Bound false: released to everyone after OwnershipWindow;
//   - NoPick false: pickable;
//   - OwnerOnly false: the party allowance applies.
type DropRules struct {
	// DecayTimeMs is the row's DecayTime, itemdata column 13, in ms.
	DecayTimeMs int
	// Bound is CanTrade (itemdata column 16) answering 0: GObjPC::FUN_004901c0
	// never releases the owner (Item.Bound).
	Bound bool
	// NoPick is CanPick (itemdata column 21) answering 0: CheckCanPickUp
	// refuses 0x1839 to everyone (Item.noPick).
	NoPick bool
	// OwnerOnly is OwnerOnlyPick's answer for the row: no party allowance
	// while the item is owned (Item.ownerOnly).
	OwnerOnly bool
	// Expendable is TypeID1 3 and TypeID2 3 (an "ETC" item: potions, scrolls,
	// stones), the class the party's item notice 0x3068 sends a u16 count
	// for (READ, GS 0x42fe80 at 0x5bdd28; client c:0x873ac9..0x873aed).
	// Round 712, party lane S2.
	Expendable bool
}

// SetRulesLookup gives the hub the reference data a drop needs (DropRules).
// Drop calls it once per drop, before it takes the hub's lock -- in
// production it is a reference-data query (cmd/server's groundDropRules, one
// refdata GetItem), and running it under the lock would stall every pick,
// sweep and zone listing behind it. Without a lookup every drop gets the zero
// DropRules.
func (h *Hub) SetRulesLookup(rules func(itemID int64) DropRules) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.rules = rules
}

// ownerOnlyExemptName is the codename CheckCanPickUp exempts from the
// TypeID 3/3/9 exclusion: the .rdata string at 0xaebf58, "ITEM_QNO_RM_ARCHEMY",
// 19 characters, compared by `CompareStringA(0x400, 0, codename, 0x13,
// "ITEM_QNO_RM_ARCHEMY", 0x13)` at 0x4a9342 -- the codename's first 0x13
// characters against all of it, so a prefix test. dwCmpFlags is 0: no
// NORM_IGNORECASE, so the comparison is case-sensitive. That is not unusual
// in this binary (recounted in round 501): srv.asm has 157 DIRECT
// `call DWORD PTR ds:0xad90b8`, of which 113 push 0x10001
// (NORM_IGNORECASE|NORM_IGNOREKANATYPE), 38 including this one push 0, 5 push
// ebx and 1 pushes a caller's argument ([ebp+0xc], 0x9f4fbf). Each of the five
// ebx sites follows an `xor ebx,ebx` in its function with no other write to
// ebx on the straight line read (0x435724, 0x4d553e, 0x51cfa9, 0x525f06,
// 0x6add09), so by that linear read they pass 0 too. A further 34 sites load
// the import into a register first (14 ebp, 8 ebx, 7 edi, 5 esi) and call
// through it; their flags were not counted.
const ownerOnlyExemptName = "ITEM_QNO_RM_ARCHEMY"

// OwnerOnlyPick reports whether an owned drop of this item may be picked by
// its owner alone: GObjPC::CheckCanPickUp (0x004a9050) sends every non-owner
// through 0x4a930d, where the item's TID (CGObj::GetTID 0x00485c90, the ref
// row's +0x80 word) goes to FUN_0042fdc0 (0x4a931b). That answers 1 only for
// TID bit 1 clear, `& 0x1c == 0xc`, `& 0x60 == 0x60` and `& 0x780 == 0x480`
// -- TypeID1 3, TypeID2 3, TypeID3 9 in docs/protocol/damage_pipeline.md's
// "The TID layout" -- and for such an item the codename (vtable +0xe8,
// CGObj::GetCodeName) is compared with ownerOnlyExemptName; anything but
// CSTR_EQUAL stores 0x1812 (0x4a934d) and the party test at 0x4a9360 is never
// reached. So a party member is refused every 3/3/9 item but
// ITEM_QNO_RM_ARCHEMY*. (docs/protocol/ground_items.md, "Picking up", step 3.)
// The rule keys on the TypeIDs, not on the ITEM_QNO_ prefix. Over the combined
// itemdata with its ten glued lines split (round 495; recounted in round 501)
// there are 690 distinct 3/3/9 ids: 549 ITEM_QNO_ and 141 others -- 113
// ITEM_ETC_ event items (102 of them ITEM_ETC_E..., 11 Halloween, Japan and
// Taiwan event items), 17 ITEM_QCX_, 10 ITEM_QSP_ and 1 ITEM_EVENT_. Who it
// affects: the 682 not named ITEM_QNO_RM_ARCHEMY*. 594 of them are bound
// (CanTrade 0: 540 ITEM_QNO_, the rest QCX/QSP/ETC/EVENT) and so owner-only
// for their whole DecayTime; the other 88 are tradeable (86 ITEM_ETC_E...
// event items such as ITEM_ETC_E100401_GOLDEN_B, ITEM_QNO_RM_MEETROC_6_01 and
// ITEM_ETC_JAPAN_EVENT_GIFTBOX) and owner-only for their 30 s window.
//
// TID bit 1 is itemdata column 8, which is 0 on every item row of the
// combined itemdata (21,562 rows once the glued lines are split), so it is
// not carried and not tested here.
//
// strings.HasPrefix compares bytes; the engine's compare is linguistic
// (LOCALE_USER_DEFAULT 0x400, flags 0), which can pass over characters that
// carry no sort weight (NUL or the soft hyphen 0xAD, for example). The two can
// only differ on characters outside A-Z, 0-9 and '_', and all 914 3/3/9 rows
// of the combined itemdata have codenames made of those alone, so they agree
// on every retail codename.
//
// An empty codename answers false. That is OpenSRO's own rule, not the
// engine's (whose items always have one): an export older than the CodeName
// column cannot tell the ITEM_QNO_RM_ARCHEMY items from the rest, and such a
// deployment keeps the party allowance for every item, as it had before
// round 497, rather than refuse the eight exempt items to a party.
func OwnerOnlyPick(typeID1, typeID2, typeID3 int, codeName string) bool {
	if typeID1 != 3 || typeID2 != 3 || typeID3 != 9 || codeName == "" {
		return false
	}
	return !strings.HasPrefix(codeName, ownerOnlyExemptName)
}

// Drop puts a stack on the ground at (x, y, z) in zone, owned by ownerID. It
// lies there for its own DecayTime (LifetimeFor) from this moment, and is
// Bound, unpickable or owner-only as its DropRules say. The rules are looked
// up once, before the hub's lock is taken (SetRulesLookup).
func (h *Hub) Drop(zone string, itemID int64, quantity int32, gold bool, x, y, z float32, ownerID int64) Item {
	h.mu.Lock()
	lookup, nextSerial := h.rules, h.serial
	h.mu.Unlock()
	var r DropRules
	if lookup != nil {
		r = lookup(itemID)
	}
	var serial int64
	if nextSerial != nil {
		serial = nextSerial()
	}
	if serial == 0 {
		serial = -localSerials.Add(1)
	}

	h.mu.Lock()
	defer h.mu.Unlock()
	h.nextID++
	now := h.now()
	it := &Item{ID: h.nextID, Zone: zone, ItemID: itemID, Quantity: quantity, Gold: gold,
		X: x, Y: y, Z: z, OwnerID: ownerID, Bound: r.Bound, DroppedAt: now, ExpiresAt: now.Add(LifetimeFor(r.DecayTimeMs)),
		noPick: r.NoPick, ownerOnly: r.OwnerOnly, Expendable: r.Expendable, Serial: serial}
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
// party rule the caller supplies (ErrNotOwner). An owner-only item
// (OwnerOnlyPick: TypeID 3/3/9 but not ITEM_QNO_RM_ARCHEMY*) is refused to
// every non-owner before the party rule is asked, as CheckCanPickUp stores
// 0x1812 at 0x4a934d before its party test at 0x4a9360. Like the party rule,
// this applies only while the item is owned: the engine's owner test
// (0x4a93c8 `test esi,esi; je 0x4a93a9`) lets anyone pick an item whose
// +0x150 is 0 before the exclusion is reached. On success the item is
// marked busy for this picker until Remove or Release is called; a 0 result
// code means the pick may proceed.
//
// Two engine tests in that sequence have nothing to act on here. Between
// CanPick and the range, an item whose slot 46 (IGObj::IsQuest_n_EventItem)
// answers yes has the picker's quest state asked, refusing 0x1874
// UIIT_MSG_STRGERR_CANNOT_BE_PICKED_AT_QUEST_ACHIEVE_CONDITION; OpenSRO
// has no quest-achieve condition to ask. Between the range and the busy
// flag, a life state other than 2 answers 3; every item in the hub is on the
// ground, which this project INFERS is life state 2 -- slot 62 in the item
// vtables is CGObj::GetLifeState (0x485ee0), a raw byte read, and nothing
// read so far ties a ground item to state 2 (round 495).
//
// One of the engine's ownership outcomes is not modelled, a known divergence
// (docs/protocol/ground_items.md, "Picking up", step 3): the absent owner.
// When the owner id resolves to no object (FUN_00485dc0 == 0, 0x4a93d1 /
// 0x4a92ec) the engine writes result 1 and returns false; here the
// owner-only test and the party rule decide, and the party rule asks party
// membership, not whether the owner is in the world.
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
		// The TypeID 3/3/9 exclusion first (0x4a930d-0x4a9350), then the party
		// test (0x4a9360); both refuse with 0x1812.
		if it.ownerOnly || sameParty == nil || !sameParty(owner, pickerID) {
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
