// Package party implements this project's own grouping system: a small
// live-session concept (like world.Hub and combat.Hub, not persisted --
// parties dissolving on server restart is normal, not a bug) letting
// players band together. Entirely own design.
package party

import (
	"errors"
	"sync"
	"sync/atomic"

	"github.com/OpenSRO/srrevamp/server/internal/gateway"
)

// MaxSize caps how many characters can be in one party. Own design choice.
const MaxSize = 5

// ErrPartyFull is returned by Hub.Join when the party already has MaxSize
// members.
var ErrPartyFull = errors.New("party: party is full")

// ErrPartyNotFound is returned by Hub.Join when partyID doesn't exist.
var ErrPartyNotFound = errors.New("party: no such party")

// ErrAlreadyInParty is returned by Hub.Join/Create when the character is
// already in a party (leave it first).
var ErrAlreadyInParty = errors.New("party: already in a party")

// ErrNotInParty is returned by Hub.Leave when the character isn't in any
// party.
var ErrNotInParty = errors.New("party: not in a party")

// Member is one party member.
type Member struct {
	Session     *gateway.Session
	CharacterID int64
	Name        string
}

// Party is a group of characters, one of whom is the leader.
type Party struct {
	ID       int64
	LeaderID int64
	Members  []Member
}

// Hub tracks all live parties. Safe for concurrent use.
type Hub struct {
	mu            sync.Mutex
	parties       map[int64]*Party
	characterToID map[int64]int64  // character ID -> party ID
	sessionToChar map[uint64]int64 // session ID -> character ID, for disconnect cleanup
	nextID        atomic.Int64
}

// NewHub returns an empty Hub.
func NewHub() *Hub {
	return &Hub{
		parties:       make(map[int64]*Party),
		characterToID: make(map[int64]int64),
		sessionToChar: make(map[uint64]int64),
	}
}

// Create starts a new party with leader as its sole member and leader.
// Returns ErrAlreadyInParty if leader's character is already in a party.
func (h *Hub) Create(leader Member) (*Party, error) {
	h.mu.Lock()
	defer h.mu.Unlock()

	if _, in := h.characterToID[leader.CharacterID]; in {
		return nil, ErrAlreadyInParty
	}

	id := h.nextID.Add(1)
	p := &Party{ID: id, LeaderID: leader.CharacterID, Members: []Member{leader}}
	h.parties[id] = p
	h.characterToID[leader.CharacterID] = id
	h.sessionToChar[leader.Session.ID()] = leader.CharacterID
	return p.clone(), nil
}

// Join adds member to partyID. Returns ErrPartyNotFound, ErrPartyFull, or
// ErrAlreadyInParty as appropriate. On success, returns the full party
// roster (including the new member) for the caller to notify everyone.
func (h *Hub) Join(partyID int64, member Member) (*Party, error) {
	h.mu.Lock()
	defer h.mu.Unlock()

	if _, in := h.characterToID[member.CharacterID]; in {
		return nil, ErrAlreadyInParty
	}
	p, ok := h.parties[partyID]
	if !ok {
		return nil, ErrPartyNotFound
	}
	if len(p.Members) >= MaxSize {
		return nil, ErrPartyFull
	}

	p.Members = append(p.Members, member)
	h.characterToID[member.CharacterID] = partyID
	h.sessionToChar[member.Session.ID()] = member.CharacterID
	return p.clone(), nil
}

// Leave removes characterID from its party. If they were the leader,
// leadership passes to the next-longest-standing member. If they were the
// last member, the party is disbanded. Returns the party as it looks after
// leaving (nil if disbanded), and the party ID left (for notification even
// if disbanded).
func (h *Hub) Leave(characterID int64) (partyID int64, remaining *Party, err error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.leaveLocked(characterID)
}

// LeaveBySession is Leave, but looks up the character by session ID --
// for disconnect cleanup, where the caller only has the gateway.Session,
// not which character it was playing. Returns ok=false if this session
// wasn't in any party (nothing to clean up).
func (h *Hub) LeaveBySession(sessionID uint64) (characterID, partyID int64, remaining *Party, ok bool, err error) {
	h.mu.Lock()
	defer h.mu.Unlock()

	cid, in := h.sessionToChar[sessionID]
	if !in {
		return 0, 0, nil, false, nil
	}
	pid, remaining, err := h.leaveLocked(cid)
	return cid, pid, remaining, true, err
}

// leaveLocked is Leave's implementation. Caller must hold h.mu.
func (h *Hub) leaveLocked(characterID int64) (partyID int64, remaining *Party, err error) {
	pid, in := h.characterToID[characterID]
	if !in {
		return 0, nil, ErrNotInParty
	}
	p := h.parties[pid]

	idx := -1
	for i, m := range p.Members {
		if m.CharacterID == characterID {
			idx = i
			break
		}
	}
	if idx == -1 {
		// Shouldn't happen given characterToID is kept in sync, but don't
		// panic on an index that isn't there.
		delete(h.characterToID, characterID)
		return pid, nil, nil
	}
	delete(h.sessionToChar, p.Members[idx].Session.ID())
	p.Members = append(p.Members[:idx], p.Members[idx+1:]...)
	delete(h.characterToID, characterID)

	if len(p.Members) == 0 {
		delete(h.parties, pid)
		return pid, nil, nil
	}
	if p.LeaderID == characterID {
		p.LeaderID = p.Members[0].CharacterID
	}
	return pid, p.clone(), nil
}

// Get returns the party characterID currently belongs to, if any.
func (h *Hub) Get(characterID int64) (*Party, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()

	pid, in := h.characterToID[characterID]
	if !in {
		return nil, false
	}
	return h.parties[pid].clone(), true
}

func (p *Party) clone() *Party {
	cp := *p
	cp.Members = append([]Member(nil), p.Members...)
	return &cp
}
