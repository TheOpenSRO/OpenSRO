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

// MaxSize caps how many characters can be in one party. **RECOVERED
// 2026-09-16**, having been own design until then.
//
// The engine enforces the cap at join time, and there are TWO of them, selected
// by a flag on the party:
//
//	5145cc  test BYTE PTR [ecx+0x10],0x1   <- bit 0 of the party's flags
//	5145d0  je   clear
//	5145d4  cmp  DWORD PTR [ecx+0x1c],0x8  <- set:   full at 8
//	5145df  cmp  DWORD PTR [ecx+0x1c],edx  <- clear: full at 4 (edx=4 at 5145af)
//
// where `+0x1c` is the member count. Which limit applied was ambiguous from the
// numbers alone; the error each branch raises settles it, because the client
// names them: bit 0 set sends `UIIT_MSG_PARTYERR_MEMBER_FULL_EXP_SHARED_PARTY`
// and clear sends `..._NONEEXP_SHARED_PARTY` (docs/protocol/error_codes.md). So
// **bit 0 of the party's +0x10 is the exp-sharing flag** -- an entry this
// project's open-items list had carried unnamed -- and an exp-sharing party
// holds 8 while a non-sharing one holds 4.
//
// srrevamp's parties share experience unconditionally: every member counts
// toward leveldata.PartyExpBonus and no flag exists to turn it off. So the
// exp-shared branch is the one that applies, and MaxSize is 8.
//
// THE PREVIOUS COMMENT WAS RIGHT TO REFUSE ITS EVIDENCE, and that is worth
// keeping. It found two loops bounded at 8 in the party module's neighbourhood
// and declined them: "they sit in CMainProcess functions that call
// CGuild__BroadcastToLocalMember, before the CParty code begins, so that 8 is
// far more likely a guild alliance's slot count (unions hold eight guilds) than
// a party's. A loop bound that lands on the expected number in the wrong module
// is a coincidence, not a citation." The number turned out to be 8 anyway. The
// refusal was still correct: the right answer reached on wrong evidence is not
// a recovery, and the citation above is from the join-time check itself.
const MaxSize = 8

// MaxSizeNotShared is the engine's OTHER cap -- the one for a party that does
// not share experience (bit 0 of its flags clear). srrevamp has no such party,
// so nothing uses this; it is recorded because the two limits are easy to
// collapse into one number and the engine keeps them apart.
const MaxSizeNotShared = 4

// MinLevelToCreate is the character level required to START a party: **5**,
// RECOVERED. Two entry points check it and both read the same way:
//
//	513fe2  mov  eax,[edx+0x124]   <- vtable slot 73 = IGObj::GetLevel
//	513fea  call eax
//	513fec  cmp  al,0x5
//	513fee  jae  ok                <- level 5 or higher may create
//	513ff0  mov  ax,0x2c0a         <- else PARTYERR_TOO_LOW_CREATOR_LEVEL
//
// and identically at 00514218 in FUN_00514170, on the branch taken when the
// character is not already in a party.
//
// JOINING HAS NO LEVEL REQUIREMENT, which is the more surprising half and is
// why both sites were read rather than one. FUN_00514170 reaches the level check
// only when its party pointer is null; with a party in hand it compares against
// that party instead and answers 0x2c1d. The client does carry a
// PARTYERR_OUT_OF_LEVEL string, but **the server never returns that code** --
// `0x2c07` appears nowhere in its .text -- so whatever enforces a level range
// between members is not here.
const MinLevelToCreate = 5

// ErrPartyFull is returned by Hub.Join when the party already has MaxSize
// members.
var ErrPartyFull = errors.New("party: party is full")

// ErrLeaderLevelTooLow is returned by Hub.Create when the would-be leader is
// below MinLevelToCreate. The engine's own refusal is
// PARTYERR_TOO_LOW_CREATOR_LEVEL.
var ErrLeaderLevelTooLow = errors.New("party: leader level too low to create a party")

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
	// Level is the character's level. Only Hub.Create reads it, to enforce
	// MinLevelToCreate; joining carries no level requirement in the engine.
	Level int
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

	if leader.Level < MinLevelToCreate {
		return nil, ErrLeaderLevelTooLow
	}

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
