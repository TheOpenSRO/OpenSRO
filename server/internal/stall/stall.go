// Package stall holds the players' stalls (round 839, lane S: retail's
// CFleaMarket, docs/protocol/stall.md). A stall is live state only, as in the
// original: it is pooled in memory, its items stay in the owner's bag until
// one sells, and a server restart closes every stall. The rules -- who may
// open, list, enter and buy, and what each refusal answers -- are
// session/stall.go's; this package keeps the stalls, their members and their
// locking, and the sale record (store.go).
//
// READ, SR_GameServer.exe (s: addresses): the stall object S is pooled and a
// manager at [0xd6a954] maps the owner's uid to it (mgr+0x5c). S+8 the owner
// uid, S+0x10 the name, S+0x2c the welcome message, S+0x48 the open flag (0
// modify, the initial state, s:0x471b70; 1 open), S+0x49 the type-4 value
// (0..2), S+0x50 + i*0x20 ten slots (u64 item DBID, u8 bag slot -- 0xff
// empty --, u16 quantity, u64 price, the item, a u32 the client sends), and
// S+0x194 the participant vector, the owner first (s:0x471e57). A
// character's pc+0x1cc4 points at the stall it is in; chardata+6
// (INTERACTMODE) is 4 for the owner and 2 for a visitor (FUN_00515e90).
package stall

import (
	"errors"
	"sync"
	"sync/atomic"

	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
)

// The stall's sizes, READ.
const (
	// MaxSlots is the ten slots at S+0x50 (type 2's `slot >= 10`, s:0x473121).
	MaxSlots = 10
	// MaxParticipants is CheckHasRoom's bound (s:0x4734e0, 0x3c18 at 8):
	// the owner and seven visitors.
	MaxParticipants = 8
	// MaxPrice is 0x2_540BE3FF, the price bound of types 1 and 2
	// (s:0x472f90, 0x4719c0): 9,999,999,999. A price of 0 is accepted.
	MaxPrice int64 = 9_999_999_999
	// MaxText is the name's and the welcome message's bound in bytes
	// (s:0x471da3, 0x4733fd): 64.
	MaxText = 64
)

// The interaction modes a stall gives (chardata+6, FUN_00515e90).
const (
	ModeNone    byte = 0
	ModeVisitor byte = 2
	ModeOwner   byte = 4
)

// Listing is one slot: the owner's bag slot (a bag index, the +13 removed),
// what was there when it was listed -- the sale checks it again --, the
// price, and the u32 the client sends with type 2 (READ: the server keeps it
// and refuses 0, 0x3c3c; INFERRED the ware network's TidGroupID).
type Listing struct {
	Used     bool
	BagSlot  int
	ItemID   int64
	Quantity int
	Inst     inventory.Instance
	Price    int64
	Group    uint32
	// Seq (round 840, OURS) is the listing's number, from the hub's counter
	// (Hub.NextSeq) when it was listed: the stall network shows the newest
	// listing first and echoes it as the record's u64 (stall_network.md).
	Seq uint64
}

// Member is one participant.
type Member struct {
	CharacterID int64
	Session     *gateway.Session
	Name        string
}

// Stall is one open stall. Its fields are read and written under the hub's
// lock only (Hub.Do).
type Stall struct {
	Owner   Member
	Name    string
	Welcome string
	// Open is S+0x48: buying needs it; listing, removing, pricing and the
	// rename need it clear.
	Open bool
	// Value4 is S+0x49, type 4's byte (0..2; its meaning is OPEN).
	Value4   byte
	Slots    [MaxSlots]Listing
	Visitors []Member
	// Selling is S+0x1a4 == 5: a sale between its checks and its end.
	Selling bool
	// Decoration is the booth the stall was announced with (0x30B8's u32).
	Decoration int
	// Network (round 840) is CIFStall +0x864's server side: the stall is
	// registered on the stall network (0x70BA type 5 {1, net 1} in a town).
	// Its listings are searchable while Open (docs/protocol/stall_network.md).
	Network bool
}

// Members is the participant vector: the owner, then the visitors in the
// order they came.
func (s *Stall) Members() []Member {
	out := make([]Member, 0, 1+len(s.Visitors))
	out = append(out, s.Owner)
	return append(out, s.Visitors...)
}

// HasVisitor reports whether characterID is one of the visitors.
func (s *Stall) HasVisitor(characterID int64) bool {
	for _, v := range s.Visitors {
		if v.CharacterID == characterID {
			return true
		}
	}
	return false
}

// ListedBagSlot reports whether bag slot is already in a slot (0x3c13).
func (s *Stall) ListedBagSlot(slot int) bool {
	for _, l := range s.Slots {
		if l.Used && l.BagSlot == slot {
			return true
		}
	}
	return false
}

// FirstFree is the first empty slot, or -1 (type 2's fallback, 0x3c30).
func (s *Stall) FirstFree() int {
	for i, l := range s.Slots {
		if !l.Used {
			return i
		}
	}
	return -1
}

// Copy is a snapshot of s, safe to read without the lock.
func (s *Stall) Copy() Stall {
	c := *s
	c.Visitors = append([]Member(nil), s.Visitors...)
	return c
}

// The hub's refusals.
var (
	ErrHasStall = errors.New("stall: the owner already has a stall")
	ErrNoStall  = errors.New("stall: no such stall")
	ErrFull     = errors.New("stall: the stall is full")
	ErrInside   = errors.New("stall: already inside")
)

// Hub keeps every open stall.
type Hub struct {
	mu      sync.Mutex
	byOwner map[int64]*Stall
	// in is each visitor's stall owner.
	in map[int64]int64
	// seq numbers the listings (Listing.Seq).
	seq atomic.Uint64
}

// NewHub returns an empty hub.
func NewHub() *Hub {
	return &Hub{byOwner: map[int64]*Stall{}, in: map[int64]int64{}}
}

// Open is FUN_00474210: a new stall for owner, in the modify state, with the
// owner as participant 0. ErrHasStall when the owner has one (0x3c14).
func (h *Hub) Open(owner Member, name string, decoration int) (Stall, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if _, ok := h.byOwner[owner.CharacterID]; ok {
		return Stall{}, ErrHasStall
	}
	s := &Stall{Owner: owner, Name: name, Decoration: decoration}
	h.byOwner[owner.CharacterID] = s
	return s.Copy(), nil
}

// Mode is characterID's INTERACTMODE as the stalls set it: 4 an owner, 2 a
// visitor, 0 neither.
func (h *Hub) Mode(characterID int64) byte {
	if h == nil {
		return ModeNone
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	if _, ok := h.byOwner[characterID]; ok {
		return ModeOwner
	}
	if _, ok := h.in[characterID]; ok {
		return ModeVisitor
	}
	return ModeNone
}

// StallOf is the owner of the stall characterID is in (its own as owner), or
// 0 (pc+0x1cc4).
func (h *Hub) StallOf(characterID int64) int64 {
	if h == nil {
		return 0
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	if _, ok := h.byOwner[characterID]; ok {
		return characterID
	}
	return h.in[characterID]
}

// Do runs f on owner's stall under the lock; false when there is none.
func (h *Hub) Do(owner int64, f func(s *Stall)) bool {
	if h == nil {
		return false
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	s, ok := h.byOwner[owner]
	if !ok {
		return false
	}
	f(s)
	return true
}

// Get is a snapshot of owner's stall.
func (h *Hub) Get(owner int64) (Stall, bool) {
	var out Stall
	ok := h.Do(owner, func(s *Stall) { out = s.Copy() })
	return out, ok
}

// Join is FUN_004725d0 after CheckHasRoom: v becomes a visitor of owner's
// stall. It answers the members before v came (each is told 0x30B7 kind 2)
// and the stall as v finds it. ErrFull past MaxParticipants (0x3c18), and
// ErrInside when v is already in a stall (0x3c19).
func (h *Hub) Join(owner int64, v Member) ([]Member, Stall, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	s, ok := h.byOwner[owner]
	if !ok {
		return nil, Stall{}, ErrNoStall
	}
	if _, in := h.in[v.CharacterID]; in || v.CharacterID == owner {
		return nil, Stall{}, ErrInside
	}
	if 1+len(s.Visitors) >= MaxParticipants {
		return nil, Stall{}, ErrFull
	}
	before := s.Members()
	s.Visitors = append(s.Visitors, v)
	h.in[v.CharacterID] = owner
	return before, s.Copy(), nil
}

// Leave is FUN_00472490: visitor out of the stall it is in. It answers the
// stall's owner and the members left (each is told 0x30B7 kind 1).
func (h *Hub) Leave(visitor int64) (int64, []Member, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	owner, ok := h.in[visitor]
	if !ok {
		return 0, nil, false
	}
	delete(h.in, visitor)
	s := h.byOwner[owner]
	if s == nil {
		return owner, nil, true
	}
	for i, m := range s.Visitors {
		if m.CharacterID == visitor {
			s.Visitors = append(s.Visitors[:i], s.Visitors[i+1:]...)
			break
		}
	}
	return owner, s.Members(), true
}

// Close is FUN_00472cf0's bookkeeping: the stall gone and every participant
// out of it. It answers the stall as it was.
func (h *Hub) Close(owner int64) (Stall, bool) {
	if h == nil {
		return Stall{}, false
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	s, ok := h.byOwner[owner]
	if !ok {
		return Stall{}, false
	}
	delete(h.byOwner, owner)
	for _, v := range s.Visitors {
		delete(h.in, v.CharacterID)
	}
	return s.Copy(), true
}

// NextSeq is the next listing number (Listing.Seq); it never repeats while
// the hub lives. Safe under or outside the lock.
func (h *Hub) NextSeq() uint64 { return h.seq.Add(1) }

// Network is a snapshot of every stall the stall network searches: open and
// registered (round 840).
func (h *Hub) Network() []Stall {
	if h == nil {
		return nil
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	var out []Stall
	for _, s := range h.byOwner {
		if s.Open && s.Network {
			out = append(out, s.Copy())
		}
	}
	return out
}

// All is a snapshot of every open stall (the spawn record and the tests).
func (h *Hub) All() []Stall {
	h.mu.Lock()
	defer h.mu.Unlock()
	out := make([]Stall, 0, len(h.byOwner))
	for _, s := range h.byOwner {
		out = append(out, s.Copy())
	}
	return out
}
