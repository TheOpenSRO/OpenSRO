// Package trade implements this project's own player-to-player trading
// system: a live, session-scoped request/accept/offer/confirm flow (like
// duel and party -- not persisted, a trade dissolving on server restart is
// normal). Entirely own design; no real trade-window data to RE.
package trade

import (
	"errors"
	"sync"

	"github.com/OpenSRO/srrevamp/server/internal/gateway"
)

// ErrCannotTradeSelf is returned by Hub.Request when requester and target
// are the same character.
var ErrCannotTradeSelf = errors.New("trade: cannot trade with yourself")

// ErrAlreadyTrading is returned by Hub.Request when the requester is
// already in an active trade.
var ErrAlreadyTrading = errors.New("trade: already trading")

// ErrTargetBusy is returned by Hub.Request when the target is already
// trading or already has a pending request from someone.
var ErrTargetBusy = errors.New("trade: target is busy")

// ErrNoPendingRequest is returned by Hub.Respond when the responder has no
// pending trade request to answer.
var ErrNoPendingRequest = errors.New("trade: no pending request")

// ErrNotTrading is returned when characterID isn't in an active trade.
var ErrNotTrading = errors.New("trade: not trading")

// ErrInvalidOffer is returned by Session.SetOffer for a negative gold or
// quantity value.
var ErrInvalidOffer = errors.New("trade: invalid offer")

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

// Hub tracks all pending trade requests and active trade sessions. Safe
// for concurrent use.
type Hub struct {
	mu      sync.Mutex
	pending map[int64]Member   // target character ID -> requester
	active  map[int64]*Session // character ID -> shared session (same pointer for both sides)
}

// NewHub returns an empty Hub.
func NewHub() *Hub {
	return &Hub{
		pending: make(map[int64]Member),
		active:  make(map[int64]*Session),
	}
}

// Request records that requester wants to trade with target. Returns
// ErrCannotTradeSelf, ErrAlreadyTrading, or ErrTargetBusy as appropriate.
func (h *Hub) Request(requester, target Member) error {
	h.mu.Lock()
	defer h.mu.Unlock()

	if requester.CharacterID == target.CharacterID {
		return ErrCannotTradeSelf
	}
	if _, busy := h.active[requester.CharacterID]; busy {
		return ErrAlreadyTrading
	}
	if _, busy := h.active[target.CharacterID]; busy {
		return ErrTargetBusy
	}
	if _, pending := h.pending[target.CharacterID]; pending {
		return ErrTargetBusy
	}

	h.pending[target.CharacterID] = requester
	return nil
}

// Respond answers the pending request addressed to target. If accept, a
// new Session is created for both sides. Returns the requester (for the
// caller to notify) and ErrNoPendingRequest if there was nothing pending.
func (h *Hub) Respond(target Member, accept bool) (requester Member, err error) {
	h.mu.Lock()
	defer h.mu.Unlock()

	requester, ok := h.pending[target.CharacterID]
	if !ok {
		return Member{}, ErrNoPendingRequest
	}
	delete(h.pending, target.CharacterID)

	if accept {
		sess := &Session{A: requester, B: target, OfferA: Offer{ItemSlot: -1}, OfferB: Offer{ItemSlot: -1}}
		h.active[requester.CharacterID] = sess
		h.active[target.CharacterID] = sess
	}
	return requester, nil
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
// Returns the session and whether both sides are now confirmed (the
// caller should then execute the trade and call End).
func (h *Hub) Confirm(characterID int64) (sess *Session, bothConfirmed bool, err error) {
	h.mu.Lock()
	defer h.mu.Unlock()

	sess, ok := h.active[characterID]
	if !ok {
		return nil, false, ErrNotTrading
	}
	switch characterID {
	case sess.A.CharacterID:
		sess.ConfirmedA = true
	case sess.B.CharacterID:
		sess.ConfirmedB = true
	}
	return sess, sess.ConfirmedA && sess.ConfirmedB, nil
}

// End ends characterID's active trade session (if any), removing both
// sides. Returns the session that was ended.
func (h *Hub) End(characterID int64) (sess *Session, ok bool) {
	h.mu.Lock()
	defer h.mu.Unlock()

	sess, ok = h.active[characterID]
	if !ok {
		return nil, false
	}
	delete(h.active, sess.A.CharacterID)
	delete(h.active, sess.B.CharacterID)
	return sess, true
}

// CancelPendingFor removes any pending request involving characterID.
// Mirrors duel.Hub.CancelPendingFor, including the same accepted
// simplification: if characterID was the requester, the target (who was
// never recorded with a full Member on this side of the map) isn't
// notifiable.
func (h *Hub) CancelPendingFor(characterID int64) (requester Member, notifiable bool) {
	h.mu.Lock()
	defer h.mu.Unlock()

	if requester, in := h.pending[characterID]; in {
		delete(h.pending, characterID)
		return requester, true
	}
	for targetID, requester := range h.pending {
		if requester.CharacterID == characterID {
			delete(h.pending, targetID)
			break
		}
	}
	return Member{}, false
}
