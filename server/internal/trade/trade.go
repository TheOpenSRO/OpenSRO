// Package trade holds the player exchange's sessions (round 834: retail's
// CTradeMgr, docs/protocol/exchange.md §2). A session is live state only: a
// trade dissolving on a server restart is normal, as in the original. The
// rules -- who may ask, what may be offered, when it closes -- are
// session/exchange.go's; this package keeps the sessions and their locking.
//
// READ, SR_GameServer.exe: CTradeMgr (DAT_00d6a95c) keeps the sessions in a
// map keyed by a counter that skips 0 (s:0x47f6f0); pc+0x1cc0 holds a
// character's session id. A session's state is 1 opened (the request
// pending), 2 established, 3 both confirmed, 5 waiting on the database, 6
// done; each participant has its own state, 2 offering, 3 confirmed, 4
// approved, its offered gold and its bay of up to 12 items.
package trade

import (
	"errors"
	"sync"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
)

// RequestRange is how close two players must stand for a request to be made
// or accepted, in world units, strictly less. Read: .rdata 0xb460dc =
// float32 320.0; GObjPC_HandleTradeMsg_081 (0x5154e0) compares the 3-D
// distance at 0x51571c and answers 4, and CTradeMgr::EstablishTradeSession
// (0x47f970) compares it again at 0x47facc when the target accepts.
const RequestRange = 320.0

// RequestTimeout is how long a request waits for its answer: float32 30.0
// (.rdata 0xb45b48) at the trs_wait_response's +0x1c (0x46c711, 0x46c817);
// trs_wait_response::OnTimeout (0x46ce20) type 1 closes the session with
// 0x1826 UIIT_MSG_STRGERR_TIMEOUT.
const RequestTimeout = 30 * time.Second

// MaxBay is the most items one side offers (0x1821 TRADE_BAY_FULL past it,
// TradeMgr::OfferItemToPartner s:0x480a20).
const MaxBay = 12

// MaxGold is the largest offer (0x3b9aca00, s:0x480f30).
const MaxGold int64 = 1_000_000_000

// Session states (READ, the session's +4).
const (
	StateOpened      = 1
	StateEstablished = 2
	StateConfirmed   = 3
	StateDealing     = 5
)

// Participant states (READ, p+0x24).
const (
	PartOffering  = 2
	PartConfirmed = 3
	PartApproved  = 4
)

// Item is one bay entry: the bag slot it was offered from (a bag index, the
// +13 removed) and what was there, which the exchange checks again before it
// moves anything (trade_p2p__VerifyLoadedItemValidity, 0x1841). The whole
// stack goes: the move carries no count (READ c:0x7923a0 case 4).
type Item struct {
	Slot     int
	ItemID   int64
	Quantity int
	Inst     inventory.Instance
}

// Party is one side of a session.
type Party struct {
	Session     *gateway.Session
	CharacterID int64
	Name        string
	State       int
	Gold        int64
	Bay         []Item
}

// HasSlot reports whether the bay already holds the item from this bag slot
// (the DBID test, 0x182d).
func (p *Party) HasSlot(slot int) bool {
	for _, it := range p.Bay {
		if it.Slot == slot {
			return true
		}
	}
	return false
}

// Session is one exchange. P[0] is the requester, P[1] the target (the
// session's +8 and +0x48).
type Session struct {
	ID    uint32
	State int
	P     [2]*Party
	timer *time.Timer
}

// Index is the participant number of characterID, or -1.
func (s *Session) Index(characterID int64) int {
	for i, p := range s.P {
		if p != nil && p.CharacterID == characterID {
			return i
		}
	}
	return -1
}

// ErrBusy is returned by Hub.Open when either player is already in a
// session.
var ErrBusy = errors.New("trade: busy")

// Hub keeps every session. A nil *Hub holds none (the read methods answer
// false, as handlers built without one expect). Its methods are safe for
// concurrent use; a
// session's fields are read and written only inside Do or Open's callers'
// own critical sections (Do), never outside.
type Hub struct {
	// Timeout is a request's wait, RequestTimeout unless a test shortens it.
	Timeout time.Duration

	mu     sync.Mutex
	next   uint32
	byID   map[uint32]*Session
	byChar map[int64]*Session
}

// NewHub returns an empty Hub.
func NewHub() *Hub {
	return &Hub{Timeout: RequestTimeout, byID: map[uint32]*Session{}, byChar: map[int64]*Session{}}
}

// Open makes a session in state 1 for requester and target, or ErrBusy when
// either is in one already (CTradeMgr::OpenTradeSession s:0x47f620 sets both
// INTERACTMODEs to 1). onTimeout runs once after Timeout unless the
// session is gone or established by then.
func (h *Hub) Open(requester, target Party, onTimeout func(id uint32)) (uint32, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.byChar[requester.CharacterID] != nil || h.byChar[target.CharacterID] != nil {
		return 0, ErrBusy
	}
	h.next++
	if h.next == 0 {
		h.next = 1
	}
	s := &Session{ID: h.next, State: StateOpened}
	a, b := requester, target
	s.P = [2]*Party{&a, &b}
	h.byID[s.ID] = s
	h.byChar[a.CharacterID] = s
	h.byChar[b.CharacterID] = s
	id := s.ID
	if onTimeout != nil {
		s.timer = time.AfterFunc(h.Timeout, func() {
			h.mu.Lock()
			live := h.byID[id] == s && s.State == StateOpened
			h.mu.Unlock()
			if live {
				onTimeout(id)
			}
		})
	}
	return id, nil
}

// Do runs f on characterID's session under the hub's lock, with the
// character's participant number; false when the character is in none.
func (h *Hub) Do(characterID int64, f func(s *Session, me int)) bool {
	if h == nil {
		return false
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	s := h.byChar[characterID]
	if s == nil {
		return false
	}
	f(s, s.Index(characterID))
	return true
}

// DoID is Do by session id.
func (h *Hub) DoID(id uint32, f func(s *Session)) bool {
	if h == nil {
		return false
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	s := h.byID[id]
	if s == nil {
		return false
	}
	f(s)
	return true
}

// Close removes session id and returns a copy of its parties as they were;
// false when it is already gone (a session closes once).
func (h *Hub) Close(id uint32) ([2]Party, bool) {
	if h == nil {
		return [2]Party{}, false
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	s := h.byID[id]
	if s == nil {
		return [2]Party{}, false
	}
	if s.timer != nil {
		s.timer.Stop()
	}
	delete(h.byID, id)
	var out [2]Party
	for i, p := range s.P {
		if h.byChar[p.CharacterID] == s {
			delete(h.byChar, p.CharacterID)
		}
		out[i] = *p
	}
	return out, true
}

// SessionOf is characterID's session id, or 0.
func (h *Hub) SessionOf(characterID int64) uint32 {
	if h == nil {
		return 0
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	if s := h.byChar[characterID]; s != nil {
		return s.ID
	}
	return 0
}

// Busy reports whether characterID is in a session of any state: INTERACTMODE
// 1 or 2, which NPC services and new requests refuse (session/tradebusy.go).
func (h *Hub) Busy(characterID int64) bool {
	if h == nil {
		return false
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.byChar[characterID] != nil
}

// Established reports whether characterID's session is past the request
// (INTERACTMODE 2): the equip lock and the item operations' guard.
func (h *Hub) Established(characterID int64) bool {
	if h == nil {
		return false
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	s := h.byChar[characterID]
	return s != nil && s.State >= StateEstablished
}
