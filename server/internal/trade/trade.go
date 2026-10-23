// Package trade implements this project's own player-to-player trading
// system: a live, session-scoped request/accept/offer/confirm flow (like
// duel and party -- not persisted, a trade dissolving on server restart is
// normal). The window and its messages are OpenSRO's own design. The rules
// for making a request follow the engine's request handler since round 500:
// RequestRange, RequestTimeout, one request per character, and no request
// to or from a busy character (docs/RE_COMPLETION.md, round 500).
package trade

import (
	"errors"
	"sync"
	"sync/atomic"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
)

// RequestRange is how close two players must stand for a trade request to be
// made or accepted, in world units, and the distance must be STRICTLY less.
// Read: .rdata 0xb460dc = float32 320.0 (bytes 00 00 a0 43).
// GObjPC_HandleTradeMsg_081 (`0x005154e0`) compares the 3-D distance between
// the two players against it at `0x51571c` (`fcomp; test ah,1`) and answers 4,
// UIIT_STT_ERR_COMMON_TOO_FAR (docs/protocol/error_codes.md), when the distance
// is not below it. CTradeMgr::EstablishTradeSession (`0x0047f970`) compares
// the same constant again at `0x47facc` when the target accepts. The distance
// is FUN_00405270, sqrt(dx*dx + dy*dy + dz*dz) through the CRT's fsqrt, with
// region offsets folded in by FUN_00430ba0 at 1920 units a region (.rdata
// 0xb45ad0), the span OpenSRO's world coordinates already use.
const RequestRange = 320.0

// RequestTimeout is how long a request waits for its target's answer before
// the engine closes it. OpenTradeSession (`0x0047f620`) creates the wait as a
// trs_wait_response of type 1 (`mov bl,0x1` at `0x47f751`, then
// GObjPC::FUN_004ea0d0). Its constructors store float32 30.0 (.rdata 0xb45b48,
// bytes 00 00 f0 41) at +0x1c (`0x46c711`, and again at `0x46c817`), and
// zero the elapsed field at +0x20 (`0x46c725`). The flag at 0xc66910 is 1 in
// the image (.data), so the constructor links every transaction into the
// timed list. CMainProcess::FUN_0046f1e0 adds GetTickCount deltas / 1000.0
// (.rdata 0xb45c68, a double) to the elapsed field. It calls OnTimeout once the
// elapsed time exceeds +0x1c. trs_wait_response::OnTimeout (`0x0046ce20`)
// takes the type-1 case (`mov ebx,0x1826` at `0x46ce37`) and closes the session
// through CTradeMgr::SendItemExchangeResult with 0x1826, UIIT_MSG_STRGERR_TIMEOUT.
// That puts both parties back to INTERACTMODE 0 and tells each of them.
const RequestTimeout = 30 * time.Second

// ErrCannotTradeSelf is returned by Hub.Request when requester and target
// are the same character.
var ErrCannotTradeSelf = errors.New("trade: cannot trade with yourself")

// ErrAlreadyTrading is returned by Hub.Request when the requester is
// already in an active trade, and by Hub.Respond when accepting would open a
// second trade for a party already in one.
var ErrAlreadyTrading = errors.New("trade: already trading")

// ErrRequestPending is returned by Hub.Request when the requester is already
// a party to a pending request, as its sender or its target. The engine holds
// each character in at most one trade session: OpenTradeSession
// (`0x0047f620`) requires INTERACTMODE 0 of both parties and sets both to 1.
// Its request handler withdraws a requester's pending session before it opens
// a new one (session.handleTradeRequest does the same), so this is defence in
// depth rather than a refusal a player sees.
var ErrRequestPending = errors.New("trade: a request is already pending")

// ErrTargetBusy is returned by Hub.Request when the target is already
// trading or is a party to a pending request, as its sender or its target
// (0x181e UIIT_MSG_STRGERR_BUSY from OpenTradeSession, `0x47f6e0`).
var ErrTargetBusy = errors.New("trade: target is busy")

// ErrNoPendingRequest is returned by Hub.Respond when the responder has no
// pending trade request to answer.
var ErrNoPendingRequest = errors.New("trade: no pending request")

// ErrNotTrading is returned when characterID isn't in an active trade.
var ErrNotTrading = errors.New("trade: not trading")

// ErrInvalidOffer is returned by Session.SetOffer for a negative gold or
// quantity value.
var ErrInvalidOffer = errors.New("trade: invalid offer")

// ErrExecuting is returned by SetOffer while the trade is being executed:
// both sides confirmed, and the offers are what is being moved.
var ErrExecuting = errors.New("trade: the trade is being executed")

// Member identifies one side of a request or trade.
type Member struct {
	Session     *gateway.Session
	CharacterID int64
	Name        string
}

// Offer is what one side has put on the table. ItemSlot is -1 if no item
// is being offered (gold-only, or nothing yet).
type Offer struct {
	Gold     int64
	ItemSlot int
	Quantity int
}

// Session is one active trade between two characters.
type Session struct {
	A, B                   Member
	OfferA, OfferB         Offer
	ConfirmedA, ConfirmedB bool
	// ID numbers the trade within this process, across every Hub (round 743): with
	// txn.BootID it is the trade's key in the economy ledger, so one trade
	// can be applied once.
	ID uint64
	// executing is the latch (round 743): set by the Confirm that completes
	// both confirmations, once. While it is set no Confirm answers
	// both-confirmed again, no offer changes, and End leaves the trade to
	// Finish.
	executing bool
}

// Other returns the counterparty to characterID in this session, and their
// offer (what THEY are offering, i.e. what characterID would receive).
func (s *Session) Other(characterID int64) (Member, Offer, bool) {
	switch characterID {
	case s.A.CharacterID:
		return s.B, s.OfferB, true
	case s.B.CharacterID:
		return s.A, s.OfferA, true
	default:
		return Member{}, Offer{}, false
	}
}

// PendingRequest is one request waiting for its target's answer.
type PendingRequest struct {
	Requester Member
	TargetID  int64
	// ID numbers the request the way CTradeMgr numbers its sessions:
	// OpenTradeSession (`0x0047f620`) increments the manager's counter at +4
	// and skips 0. The engine's timeout closes a session by that number, so
	// a timeout left over from a closed session finds nothing
	// (SendItemExchangeResult answers 0x181b and notifies nobody). Hub.Expire
	// matches on it for the same reason.
	ID uint64
}

// Hub tracks all pending trade requests and active trade sessions. Safe
// for concurrent use.
type Hub struct {
	mu      sync.Mutex
	pending map[int64]PendingRequest // target character ID -> request
	active  map[int64]*Session       // character ID -> shared session (same pointer for both sides)
	lastID  uint64                   // the last PendingRequest.ID handed out
}

// tradeIDs numbers trades across every Hub of the process, so no two trades
// of one run share a ledger key (Session.ID).
var tradeIDs atomic.Uint64

// NewHub returns an empty Hub.
func NewHub() *Hub {
	return &Hub{
		pending: make(map[int64]PendingRequest),
		active:  make(map[int64]*Session),
	}
}

// Request records that requester wants to trade with target and returns the
// request's ID, which Expire needs. Returns ErrCannotTradeSelf,
// ErrAlreadyTrading, ErrRequestPending or ErrTargetBusy as appropriate.
//
// Both parties must be free, as GObjPC::FUN_004ea050's INTERACTMODE-0 test
// requires. The request handler runs it on the requester and
// OpenTradeSession (`0x0047f620`) runs it on the target. A pending request
// counts on either side, because OpenTradeSession writes 1 to both parties.
func (h *Hub) Request(requester, target Member) (uint64, error) {
	h.mu.Lock()
	defer h.mu.Unlock()

	if requester.CharacterID == target.CharacterID {
		return 0, ErrCannotTradeSelf
	}
	if _, busy := h.active[requester.CharacterID]; busy {
		return 0, ErrAlreadyTrading
	}
	if _, pending := h.pendingOfLocked(requester.CharacterID); pending {
		return 0, ErrRequestPending
	}
	if _, busy := h.active[target.CharacterID]; busy {
		return 0, ErrTargetBusy
	}
	if _, pending := h.pendingOfLocked(target.CharacterID); pending {
		return 0, ErrTargetBusy
	}

	h.lastID++
	if h.lastID == 0 {
		h.lastID = 1
	}
	h.pending[target.CharacterID] = PendingRequest{Requester: requester, TargetID: target.CharacterID, ID: h.lastID}
	return h.lastID, nil
}

// Respond answers the pending request addressed to target. If accept, a
// new Session is created for both sides. Returns the requester (for the
// caller to notify) and ErrNoPendingRequest if there was nothing pending.
//
// An accept that would put either party in a second trade is refused with
// ErrAlreadyTrading, and the request is dropped. Before round 500 it
// overwrote the requester's open session, leaving the old partner holding a
// session nobody else shared. The engine cannot reach that state:
// EstablishTradeSession (`0x0047f970`) requires both parties at INTERACTMODE 1.
// Request already refuses a busy party, so this check is defence in depth.
func (h *Hub) Respond(target Member, accept bool) (requester Member, err error) {
	h.mu.Lock()
	defer h.mu.Unlock()

	p, ok := h.pending[target.CharacterID]
	if !ok {
		return Member{}, ErrNoPendingRequest
	}
	delete(h.pending, target.CharacterID)
	requester = p.Requester

	if accept {
		if _, busy := h.active[requester.CharacterID]; busy {
			return Member{}, ErrAlreadyTrading
		}
		if _, busy := h.active[target.CharacterID]; busy {
			return Member{}, ErrAlreadyTrading
		}
		sess := &Session{A: requester, B: target, OfferA: Offer{ItemSlot: -1}, OfferB: Offer{ItemSlot: -1}, ID: tradeIDs.Add(1)}
		h.active[requester.CharacterID] = sess
		h.active[target.CharacterID] = sess
	}
	return requester, nil
}

// PendingOf returns the pending request characterID is a party to, as its
// requester or its target. Request keeps each character in at most one.
func (h *Hub) PendingOf(characterID int64) (PendingRequest, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.pendingOfLocked(characterID)
}

// pendingOfLocked is PendingOf for a caller that holds h.mu.
func (h *Hub) pendingOfLocked(characterID int64) (PendingRequest, bool) {
	if p, ok := h.pending[characterID]; ok {
		return p, true
	}
	for _, p := range h.pending {
		if p.Requester.CharacterID == characterID {
			return p, true
		}
	}
	return PendingRequest{}, false
}

// Expire removes the request addressed to targetID if it is still the
// request numbered id, and returns its requester so the caller can tell both
// parties. It is the engine's timeout (see RequestTimeout). A request that was
// answered, withdrawn or replaced in the meantime is left alone.
func (h *Hub) Expire(targetID int64, id uint64) (requester Member, ok bool) {
	h.mu.Lock()
	defer h.mu.Unlock()

	p, in := h.pending[targetID]
	if !in || p.ID != id {
		return Member{}, false
	}
	delete(h.pending, targetID)
	return p.Requester, true
}

// SessionOf returns characterID's active trade session, if any.
func (h *Hub) SessionOf(characterID int64) (*Session, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()

	s, ok := h.active[characterID]
	return s, ok
}

// SetOffer replaces characterID's offer in their active session and clears
// both sides' confirmation (changing an offer after confirming voids the
// confirmation -- a deliberate anti-bait-and-switch rule). Returns the
// updated session.
func (h *Hub) SetOffer(characterID int64, offer Offer) (*Session, error) {
	if offer.Gold < 0 || offer.Quantity < 0 {
		return nil, ErrInvalidOffer
	}

	h.mu.Lock()
	defer h.mu.Unlock()

	sess, ok := h.active[characterID]
	if !ok {
		return nil, ErrNotTrading
	}
	if sess.executing {
		return nil, ErrExecuting
	}
	switch characterID {
	case sess.A.CharacterID:
		sess.OfferA = offer
	case sess.B.CharacterID:
		sess.OfferB = offer
	}
	sess.ConfirmedA = false
	sess.ConfirmedB = false
	return sess, nil
}

// Confirm marks characterID's side of their active session as confirmed.
// bothConfirmed is true for exactly ONE call per trade: the one that
// completes both confirmations, which latches the trade as executing and
// returns a copy of it, the offers as they will be moved. The caller then
// executes the trade and calls Finish.
//
// Round 743: there was no latch, so a confirm resent by the side that had
// already confirmed, arriving while the other side's handler executed the
// trade, answered both-confirmed again and the trade ran twice
// (session.TestTradeResentConfirmDuplicatesItem). A confirm while the trade
// executes now answers false, and changes nothing.
func (h *Hub) Confirm(characterID int64) (sess *Session, bothConfirmed bool, err error) {
	h.mu.Lock()
	defer h.mu.Unlock()

	live, ok := h.active[characterID]
	if !ok {
		return nil, false, ErrNotTrading
	}
	if live.executing {
		cp := *live
		return &cp, false, nil
	}
	switch characterID {
	case live.A.CharacterID:
		live.ConfirmedA = true
	case live.B.CharacterID:
		live.ConfirmedB = true
	}
	cp := *live
	if !(live.ConfirmedA && live.ConfirmedB) {
		return &cp, false, nil
	}
	live.executing = true
	cp.executing = true
	return &cp, true, nil
}

// End ends characterID's active trade session (if any), removing both
// sides. Returns the session that was ended. A trade being executed is not
// ended (ok false): its executor ends it with Finish once the outcome is
// known, so a cancel or a disconnect mid-execution cannot tell the partner
// "cancelled" about a trade that completes.
func (h *Hub) End(characterID int64) (sess *Session, ok bool) {
	h.mu.Lock()
	defer h.mu.Unlock()

	sess, ok = h.active[characterID]
	if !ok || sess.executing {
		return nil, false
	}
	delete(h.active, sess.A.CharacterID)
	delete(h.active, sess.B.CharacterID)
	return sess, true
}

// Finish ends the trade characterID's Confirm latched as executing, whatever
// its outcome. Only the executor calls it.
func (h *Hub) Finish(characterID int64) {
	h.mu.Lock()
	defer h.mu.Unlock()

	sess, ok := h.active[characterID]
	if !ok {
		return
	}
	delete(h.active, sess.A.CharacterID)
	delete(h.active, sess.B.CharacterID)
}

// CancelPendingFor removes every pending request involving characterID: the
// one addressed to them, and EVERY one they sent. If characterID was a
// requester, the targets are not notifiable, because the map records only
// their character IDs and not a full Member. requester and notifiable describe
// the request addressed to characterID, if there was one.
//
// It started as a copy of duel.Hub.CancelPendingFor and no longer matches it.
// The duel version still returns early when characterID is a target, and
// still has a `break` in its challenger scan. Until round 499 this one did too,
// so it stopped at the first request it found. A character who had asked two
// people left one request behind, and (now that a pending request makes both
// parties Busy) left that target unable to use an NPC service. Since round 500
// Request lets a character hold only one request, so the loop finds at most
// one. It still scans them all.
func (h *Hub) CancelPendingFor(characterID int64) (requester Member, notifiable bool) {
	h.mu.Lock()
	defer h.mu.Unlock()

	if p, in := h.pending[characterID]; in {
		delete(h.pending, characterID)
		requester, notifiable = p.Requester, true
	}
	for targetID, p := range h.pending {
		if p.Requester.CharacterID == characterID {
			delete(h.pending, targetID)
		}
	}
	return requester, notifiable
}

// WithdrawRequest removes every pending request requesterID sent and returns
// the targets' character IDs (in no particular order), so the caller can tell
// each of them the request is gone. A request addressed TO requesterID is
// left alone: that one is answered with Respond.
func (h *Hub) WithdrawRequest(requesterID int64) []int64 {
	h.mu.Lock()
	defer h.mu.Unlock()

	var targets []int64
	for targetID, p := range h.pending {
		if p.Requester.CharacterID == requesterID {
			delete(h.pending, targetID)
			targets = append(targets, targetID)
		}
	}
	return targets
}

// Busy reports whether characterID is held by a trade in ANY phase: an open
// session, a pending request addressed to them, or a pending request they
// sent. It is the engine's INTERACTMODE (chardata+6, docs/protocol/
// character_state.md) at 1 or 2: CTradeMgr::OpenTradeSession (`0x0047f620`),
// called only from the trade-request handler GObjPC_HandleTradeMsg_081
// (`0x005154e0`), writes 1 to BOTH parties when the request is made, and
// CTradeMgr::EstablishTradeSession (`0x0047f970`, from
// trs_wait_response::vslot_002 `0x0046cb30`) moves both to 2 on acceptance.
// So a request already holds its target, not only its sender.
//
// Safe on a nil Hub (nothing is busy), so a handler built without trading
// needs no special case.
func (h *Hub) Busy(characterID int64) bool {
	if h == nil {
		return false
	}
	h.mu.Lock()
	defer h.mu.Unlock()

	if _, ok := h.active[characterID]; ok {
		return true
	}
	_, pending := h.pendingOfLocked(characterID)
	return pending
}

// Established reports whether characterID is in an accepted trade -- the
// engine's INTERACTMODE 2, which CTradeMgr::EstablishTradeSession
// (`0x0047f970`) writes when the target accepts and which
// CGObjPC::AttachEquipItem / DetachEquipItem refuse (see
// session.tradeEquipLockedReason). A pending request is Busy but not
// Established. Safe on a nil Hub.
func (h *Hub) Established(characterID int64) bool {
	if h == nil {
		return false
	}
	h.mu.Lock()
	defer h.mu.Unlock()

	_, ok := h.active[characterID]
	return ok
}
