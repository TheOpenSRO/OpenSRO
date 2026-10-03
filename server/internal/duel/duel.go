// Package duel implements this project's own 1v1 PvP system: a live,
// session-scoped challenge/accept/fight flow (like party and combat, not
// persisted -- a duel dissolving on server restart is normal, not a bug).
// Entirely own design; no real duel/PvP data to RE.
//
// TESTED 2026-09-16, not merely asserted -- two claims of this shape elsewhere
// in the tree turned out to be wrong. The server's error vocabulary contains no
// duel family: the only PvP codes are two spellings of
// UIIT_MGS_ERR_FRPVP_DURING_CHANGE, about switching free-PvP mode, and there is
// no challenge/accept/refuse family at all. See docs/protocol/absence_audit.md
// for the method and its limits.
package duel

import (
	"errors"
	"sync"

	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
)

// ErrCannotChallengeSelf is returned by Hub.Challenge when challenger and
// target are the same character.
var ErrCannotChallengeSelf = errors.New("duel: cannot challenge yourself")

// ErrAlreadyDueling is returned by Hub.Challenge when the challenger is
// already in an active duel.
var ErrAlreadyDueling = errors.New("duel: already in a duel")

// ErrTargetBusy is returned by Hub.Challenge when the target is already in
// an active duel or already has a pending challenge from someone.
var ErrTargetBusy = errors.New("duel: target is busy")

// ErrNoPendingChallenge is returned by Hub.Respond when the responder has
// no pending challenge to answer.
var ErrNoPendingChallenge = errors.New("duel: no pending challenge")

// ErrNotDueling is returned by Hub.OpponentOf/End when the character isn't
// in an active duel.
var ErrNotDueling = errors.New("duel: not in a duel")

// Member identifies one side of a challenge or duel.
type Member struct {
	Session     *gateway.Session
	CharacterID int64
	Name        string
}

// Hub tracks all pending challenges and active duels. Safe for concurrent
// use.
type Hub struct {
	mu      sync.Mutex
	pending map[int64]Member // target character ID -> challenger
	active  map[int64]Member // character ID -> opponent (stored both directions)
}

// NewHub returns an empty Hub.
func NewHub() *Hub {
	return &Hub{
		pending: make(map[int64]Member),
		active:  make(map[int64]Member),
	}
}

// Challenge records that challenger wants to duel target. Returns
// ErrCannotChallengeSelf, ErrAlreadyDueling (challenger's side), or
// ErrTargetBusy (target already dueling or already has a pending
// challenge) as appropriate.
func (h *Hub) Challenge(challenger, target Member) error {
	h.mu.Lock()
	defer h.mu.Unlock()

	if challenger.CharacterID == target.CharacterID {
		return ErrCannotChallengeSelf
	}
	if _, busy := h.active[challenger.CharacterID]; busy {
		return ErrAlreadyDueling
	}
	if _, busy := h.active[target.CharacterID]; busy {
		return ErrTargetBusy
	}
	if _, pending := h.pending[target.CharacterID]; pending {
		return ErrTargetBusy
	}

	h.pending[target.CharacterID] = challenger
	return nil
}

// Respond answers the pending challenge addressed to target. If accept,
// both sides are marked as actively dueling. Returns the challenger (for
// the caller to notify) and ErrNoPendingChallenge if there was nothing to
// respond to.
func (h *Hub) Respond(target Member, accept bool) (challenger Member, err error) {
	h.mu.Lock()
	defer h.mu.Unlock()

	challenger, ok := h.pending[target.CharacterID]
	if !ok {
		return Member{}, ErrNoPendingChallenge
	}
	delete(h.pending, target.CharacterID)

	if accept {
		h.active[challenger.CharacterID] = target
		h.active[target.CharacterID] = challenger
	}
	return challenger, nil
}

// OpponentOf returns the character characterID is currently dueling, if
// any.
func (h *Hub) OpponentOf(characterID int64) (Member, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()

	m, ok := h.active[characterID]
	return m, ok
}

// End ends characterID's active duel (if any), removing both sides.
// Returns the opponent that was ended (for the caller to notify) and
// ok=false if characterID wasn't dueling.
func (h *Hub) End(characterID int64) (opponent Member, ok bool) {
	h.mu.Lock()
	defer h.mu.Unlock()

	opponent, ok = h.active[characterID]
	if !ok {
		return Member{}, false
	}
	delete(h.active, characterID)
	delete(h.active, opponent.CharacterID)
	return opponent, true
}

// CancelPendingFor removes any pending challenge involving characterID,
// whether they were the challenger or the target. Used for disconnect
// cleanup so a departed player doesn't leave a stale, unanswerable
// challenge behind.
//
// If characterID was the target of a pending challenge, the challenger is
// returned (with a full Member -- Session included) so the caller can
// notify them their challenge was voided. If characterID was the
// challenger, there's nothing to return: the target's Member (including
// their Session) was never recorded on this side of the map, only their
// character ID as the map key, so there's no one to notify -- an accepted
// simplification, not an oversight; the target simply never gets a
// response, same as if the challenger had just gone quiet.
func (h *Hub) CancelPendingFor(characterID int64) (challenger Member, notifiable bool) {
	h.mu.Lock()
	defer h.mu.Unlock()

	if challenger, in := h.pending[characterID]; in {
		delete(h.pending, characterID)
		return challenger, true
	}
	for targetID, challenger := range h.pending {
		if challenger.CharacterID == characterID {
			delete(h.pending, targetID)
			break
		}
	}
	return Member{}, false
}
