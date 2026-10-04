// Package party holds the live parties: who is in which, its flags, its
// leader, the pending invitations and the rules that decide them. Not
// persisted -- retail's parties live in the ShardManager's memory too, and a
// restart ends them.
//
// Round 710 rebuilt it on the original's rules (docs/protocol/party_protocol.md
// and party_rules.md, round 709). Where retail splits the work between the
// GameServer (invite checks, the member records) and the ShardManager (the
// party list, formation, join, removal, succession), OpenSRO has one process
// and does both here; the session layer (internal/session/party.go) owns the
// wire.
//
// # The Hub API (for S2 sharing and S3 party matching)
//
// Read side, safe from any goroutine:
//   - Get(characterID) (*Party, bool): a copy of the character's party.
//   - PartyByID(id) (*Party, bool): a copy of a party by its id.
//   - State(characterID) byte: the character's chardata+7 byte (StateFree ..
//     StateListed), derived from membership, invitations and listings.
//   - Listing(characterID) (entry uint32, flags Flags, ok bool): the party-match
//     entry a character holds (S3 sets it).
//
// Write side:
//   - Form(inviter, invitee, flags): a new two-member party (an accepted
//     0x7060 invitation; a party-match accept with no party yet).
//   - Add(partyID, m): a member joins (an accepted 0x7062; a party-match
//     accept into an existing party).
//   - Remove(characterID, reason): leave (2), kick (4), logout (1); dissolves a
//     two-member party, passes leadership to the longest-standing member.
//   - Invite / TakeInvite: the pending invitations and their 30 s timeout.
//   - SetListing / ClearListing: S3's party-match entries, which the invite
//     ladder and the formation refusal 0x2c20 read.
//
// Every write returns copies; callers never see the hub's own slices.
package party

import (
	"errors"
	"sort"
	"sync"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
)

// Flags is the party-type byte, chosen at formation and never changed
// (party+0x10 in the GameServer, party+0x08 in the ShardManager; READ, the
// round-709 specs: no message writes it after formation, in any of the three
// binaries).
type Flags uint8

const (
	// FlagExpShare is "Exp Auto Share". Set: cap 8; clear ("Exp
	// Free-For-All"): cap 4 (READ: GS CParty::CheckCanJoin 0x514560, SM
	// 0x44de70, client 0x987050).
	FlagExpShare Flags = 0x01
	// FlagItemShare is "Item Auto Share" (READ, GObjPC::CheckCanPickUp's
	// party test, the 0x3068 notice 0x5bdc80).
	FlagItemShare Flags = 0x02
	// FlagAnyoneInvite is "Can invite without master status": any member,
	// not only the leader, may invite (READ, CParty::CheckCanJoin's OR with
	// the leader test, round 357).
	FlagAnyoneInvite Flags = 0x04
)

// ExpShare, ItemShare and AnyoneInvite test the three bits.
func (f Flags) ExpShare() bool     { return f&FlagExpShare != 0 }
func (f Flags) ItemShare() bool    { return f&FlagItemShare != 0 }
func (f Flags) AnyoneInvite() bool { return f&FlagAnyoneInvite != 0 }

// Cap is the member cap the flags select: 8 when EXP is shared, 4 when it is
// not, whatever bit 1 says (READ, three binaries agree; party_rules.md).
func (f Flags) Cap() int {
	if f.ExpShare() {
		return MaxSize
	}
	return MaxSizeNotShared
}

// FullCode is the refusal for a full party of these flags: 0x2c13
// UIIT_MSG_PARTYERR_MEMBER_FULL_EXP_SHARED_PARTY when EXP is shared, 0x2c14
// ..._NONEEXP_SHARED_PARTY when not (READ, CheckCanJoin 0x514560; SM
// 0x44f130).
func (f Flags) FullCode() uint16 {
	if f.ExpShare() {
		return CodeFullExpShared
	}
	return CodeFullNotShared
}

// MaxSize is the cap of an exp-sharing party (READ, `cmp [party+0x1c],8` at
// GS 0x5145d4 when bit 0 is set).
const MaxSize = 8

// MaxSizeNotShared is the cap of a party that does not share EXP (READ, the
// same check's other branch, `edx = 4` at GS 0x5145af).
const MaxSizeNotShared = 4

// MinCreatorLevel is 5: a character below level 5 cannot form a party (READ,
// GS CParty::CheckCanCreate 0x513f90, `cmp al,5; jae` at 0x513fec, and the
// party-match path 0x514170; refusal 0x2c0a
// UIIT_MSG_PARTYERR_TOO_LOW_CREATOR_LEVEL). Joining has no level rule.
const MinCreatorLevel = 5

// CanCreate reports whether a character of this level may form a party.
func CanCreate(level int) bool { return level >= MinCreatorLevel }

// InviteTimeout is how long an invitation waits for its answer: 30 s, the
// float at GS 0xb45b48 stored at trs_wait_response+0x1c (0x46c817) and ticked
// in seconds by CMainProcess::FUN_0046f1e0 (READ, party_rules.md). On expiry
// both sides get 0x2c10.
const InviteTimeout = 30 * time.Second

// The job state, GetJobState (vtable slot 71, chardata+0xf). READ in all three
// binaries (party_protocol.md "Job rules"): 1..4 with 4 = not in job mode;
// 0 is not a valid value (GS Party_UserMatches 0x5bf240 asserts on it).
const (
	JobTrader uint8 = 1
	JobThief  uint8 = 2
	JobHunter uint8 = 3
	JobNone   uint8 = 4
)

// JobsMatch is the person-to-person job rule (READ, SM 0x44ed20 and its GS
// twin 0x5bc1c0): trader and hunter go together, a thief only with a thief, no
// job only with no job. Anything else -- 0 included -- matches nobody.
func JobsMatch(a, b uint8) bool {
	switch a {
	case JobTrader, JobHunter:
		return b == JobTrader || b == JobHunter
	case JobThief:
		return b == JobThief
	case JobNone:
		return b == JobNone
	}
	return false
}

// The party-match purposes (READ, party_protocol.md: the objective radio's
// order at c:0x73f820 stored unmapped by c:0x73f370).
const (
	PurposeHunting uint8 = 0
	PurposeQuest   uint8 = 1
	PurposeTrade   uint8 = 2
	PurposeThief   uint8 = 3
)

// JobFitsPurpose is the person-to-purpose rule (READ, GS Party_UserMatches
// 0x5bf240, SM 0x44f7f0): a trader or hunter lists and joins only purpose 2, a
// thief only 3, no job any purpose but 2 and 3. Lane S3 uses it.
func JobFitsPurpose(job, purpose uint8) bool {
	switch job {
	case JobTrader, JobHunter:
		return purpose == PurposeTrade
	case JobThief:
		return purpose == PurposeThief
	case JobNone:
		return purpose != PurposeTrade && purpose != PurposeThief
	}
	return false
}

// The removal reasons, the second argument of GS Party_RemoveMember 0x5be1a0
// and the u8 of 0x3864 kind 3 (READ: the client's jump table c:0x8872e8 names
// 1 LOGOUT, 2 SECEDE, 3 SERVER_MIGRATION, 4 BOOTED; the leave handler passes 2,
// the kick handler 4).
const (
	ReasonLogout     uint8 = 1
	ReasonLeave      uint8 = 2
	ReasonServerMove uint8 = 3
	ReasonKicked     uint8 = 4
)

// The state byte, chardata+7 (READ, party_protocol.md "Server-side state
// byte"; round 359 and the round-709 specs).
const (
	StateFree    byte = 0
	StatePending byte = 1 // an invitation or a join request is pending
	StateInParty byte = 2
	// StateListedInviting is a listed character (4) with an invitation out:
	// Party_SendFormationInvitation writes (state == 4) * 2 + 1.
	StateListedInviting byte = 3
	StateListed         byte = 4 // listed in party matching, no party
)

// The party error codes this package and the session layer send (names from
// docs/protocol/error_codes.md; where each is sent is in party_protocol.md).
const (
	CodeLocked          uint16 = 0x2c06
	CodeCreateBusy      uint16 = 0x2c09 // no client text: locked, not alive, busy, or already in a party at formation
	CodeTooLowCreator   uint16 = 0x2c0a
	CodeDissolved       uint16 = 0x2c0b // the kind-1 dissolution code; the client ignores it
	CodeCreateRefused   uint16 = 0x2c0c
	CodeCantFindParty   uint16 = 0x2c0d
	CodeCantFindCreator uint16 = 0x2c0e
	CodeInvalidUser     uint16 = 0x2c0f
	CodeTimeout         uint16 = 0x2c10
	CodeExistingMember  uint16 = 0x2c12
	CodeFullExpShared   uint16 = 0x2c13
	CodeFullNotShared   uint16 = 0x2c14
	CodeJoinRefused     uint16 = 0x2c17
	CodeOtherParty      uint16 = 0x2c18
	CodeDuplicate       uint16 = 0x2c1f // an invitation or request is already pending
	CodeEntryFlags      uint16 = 0x2c20 // no client text: the match entry's flags differ
	CodeUserMismatch    uint16 = 0x2c23 // UIIT_MSG_PARTY_USER_MISSMATCH, the job rules
	CodeListed          uint16 = 0x2c25
	// The bare codes the range check returns (READ, GS 0x4a8e10): 0 not
	// found or another world, 3 type mismatch / not a PC / not alive, 4 out of
	// range. 2 is a failure to post the wait transaction.
	CodeNotFound   uint16 = 0
	CodePostFailed uint16 = 2
	CodeWrongType  uint16 = 3
	CodeTooFar     uint16 = 4
)

// InviteRangePC is the reach of an invitation aimed at a player: 600.0, 3D
// (READ, GS 0x4a8e10 picks the float at 0xb46198 when the found target's slot
// 7 IsPC returns 1; 320.0 at 0xb460dc otherwise). Out of range is the bare
// code 4.
const InviteRangePC = 600.0

// Error is a refusal carrying the engine's code.
type Error struct{ Code uint16 }

func (e *Error) Error() string { return "party: refused with code " + hex4(e.Code) }

func hex4(v uint16) string {
	const digits = "0123456789abcdef"
	return "0x" + string([]byte{digits[v>>12&0xf], digits[v>>8&0xf], digits[v>>4&0xf], digits[v&0xf]})
}

// Refusal returns the engine code of a party error, and ok=false for an error
// that is not one.
func Refusal(err error) (uint16, bool) {
	var e *Error
	if errors.As(err, &e) {
		return e.Code, true
	}
	return 0, false
}

func refuse(code uint16) error { return &Error{Code: code} }

// ErrNotInParty is returned by Remove for a character in no party.
var ErrNotInParty = errors.New("party: not in a party")

// JIDOf is a character's party id on the wire (OURS, round 710; the fixtures
// README states it). Retail's JID is vtable slot 2 GetJID; OpenSRO uses the
// low 32 bits of the character id, which is also the u32 object id OpenSRO
// already puts on the wire for a player (motion.go's 0x30BF, uint32
// (CharacterID)) and the id the client selects a player by. So a client maps
// a party JID to the spawned player whose 64-bit character id has these low
// 32 bits.
func JIDOf(characterID int64) uint32 { return uint32(characterID) }

// Member is one party member.
type Member struct {
	Session     *gateway.Session
	CharacterID int64
	Name        string
	// Level is the character's level when it joined; Form reads the
	// inviter's for MinCreatorLevel. The member records read the live level.
	Level int
	// Job is the job state (JobTrader..JobNone). Zero is read as JobNone:
	// OpenSRO has no job mode yet, and every character is a 4 (the engine's
	// initializer writes 4, GS 0x4de3eb).
	Job uint8
}

// JID is the member's id on the wire.
func (m Member) JID() uint32 { return JIDOf(m.CharacterID) }

func (m Member) job() uint8 {
	if m.Job == 0 {
		return JobNone
	}
	return m.Job
}

// Party is a group of characters. Members[0] is the leader; the rest follow in
// join order, so the longest-standing member is Members[1] (READ, SM 0x44e1a0
// sets the leader to members[0] of a join-ordered vector).
type Party struct {
	ID       uint32
	LeaderID int64
	Flags    Flags
	Members  []Member
}

// LeaderJID is the leader's id on the wire (party+0xc).
func (p *Party) LeaderJID() uint32 { return JIDOf(p.LeaderID) }

// Full reports whether the party is at its cap.
func (p *Party) Full() bool { return len(p.Members) >= p.Flags.Cap() }

// Has reports whether characterID is a member.
func (p *Party) Has(characterID int64) bool { return p.index(characterID) >= 0 }

func (p *Party) index(characterID int64) int {
	for i, m := range p.Members {
		if m.CharacterID == characterID {
			return i
		}
	}
	return -1
}

func (p *Party) clone() *Party {
	cp := *p
	cp.Members = append([]Member(nil), p.Members...)
	return &cp
}

// InviteKind is the 0x3080 kind byte: 2 to form a party with the inviter, 3
// to join the inviter's party (READ, c:0x88aa60 and GS 0x46c8e0).
type InviteKind uint8

const (
	InviteForm InviteKind = 2
	InviteJoin InviteKind = 3
)

// Invite is one pending invitation.
type Invite struct {
	Kind    InviteKind
	Inviter Member
	Target  Member
	// Flags is what the 0x3080 carries: the 0x7060 flags for a formation,
	// the party's flags for a join.
	Flags Flags
	// PartyID is the inviter's party for InviteJoin (the kind-3 transaction's
	// +0x24, not sent).
	PartyID uint32
	seq     uint64
	timer   stopper
}

type stopper interface{ Stop() bool }

// Removal describes what Remove did.
type Removal struct {
	// Before is the party as it was, the removed member included: the kind-3
	// notice goes to all of them, the leaver too (GS 0x5bc390 broadcasts
	// before removing).
	Before *Party
	// Dissolved is true when the party had exactly two members and is gone
	// (READ, SM 0x44f580 `cmp eax,2` -> 0x44eb30).
	Dissolved bool
	// After is the party after the removal; nil when Dissolved.
	After *Party
	// NewLeader is the new leader's character id when the leader left a
	// party that goes on (0 otherwise); 0x3864 kind 9 announces it.
	NewLeader int64
}

type listing struct {
	entry uint32
	flags Flags
}

// Hub tracks all live parties. Safe for concurrent use.
type Hub struct {
	mu        sync.Mutex
	parties   map[uint32]*Party
	byChar    map[int64]uint32
	bySession map[uint64]int64
	nextID    uint32
	// invites holds the pending invitations, keyed by the target character.
	invites map[int64]*Invite
	// detached holds invitations whose invitee left the world (Detach), keyed
	// by sequence: they no longer hold the invitee, but still time out.
	detached map[uint64]*Invite
	seq      uint64
	listings map[int64]listing
	// rotation is each party's item round-robin list, party+0x20 in the
	// GameServer (round 712, NextInRotation).
	rotation map[uint32][]int64

	// Timeout is the invitation timeout (InviteTimeout unless a test sets
	// it before use).
	Timeout time.Duration
	// afterFunc schedules the timeout; time.AfterFunc unless a test swaps it.
	afterFunc func(time.Duration, func()) stopper
}

// NewHub returns an empty Hub.
func NewHub() *Hub {
	return &Hub{
		parties:   make(map[uint32]*Party),
		byChar:    make(map[int64]uint32),
		bySession: make(map[uint64]int64),
		invites:   make(map[int64]*Invite),
		detached:  make(map[uint64]*Invite),
		listings:  make(map[int64]listing),
		rotation:  make(map[uint32][]int64),
		Timeout:   InviteTimeout,
		afterFunc: func(d time.Duration, f func()) stopper { return time.AfterFunc(d, f) },
	}
}

// newIDLocked is the next party id: a counter that skips 0 (READ, SM 0x44e9c0
// at manager+4).
func (h *Hub) newIDLocked() uint32 {
	h.nextID++
	if h.nextID == 0 {
		h.nextID++
	}
	return h.nextID
}

// Form creates a party of two from an accepted formation invitation: the
// inviter leads, the invitee follows. The ShardManager's refusals, in its
// order (READ, SM 0x44ed70): 0x2c09 the inviter is already in a party, 0x2c18
// the invitee is, 0x2c23 their jobs do not match, 0x2c20 the inviter's match
// entry has other flags. A member that is gone (0x2c0f) is the caller's test:
// the hub does not know who is online.
func (h *Hub) Form(inviter, invitee Member, flags Flags) (*Party, error) {
	h.mu.Lock()
	defer h.mu.Unlock()

	if _, in := h.byChar[inviter.CharacterID]; in {
		return nil, refuse(CodeCreateBusy)
	}
	if _, in := h.byChar[invitee.CharacterID]; in {
		return nil, refuse(CodeOtherParty)
	}
	if !JobsMatch(inviter.job(), invitee.job()) {
		return nil, refuse(CodeUserMismatch)
	}
	if l, ok := h.listings[inviter.CharacterID]; ok && l.flags != flags {
		return nil, refuse(CodeEntryFlags)
	}
	id := h.newIDLocked()
	p := &Party{ID: id, LeaderID: inviter.CharacterID, Flags: flags, Members: []Member{inviter, invitee}}
	h.parties[id] = p
	// INFERRED: the formation's two members enter the rotation in member
	// order (FUN_005bc210 appends each joiner; the formation path was not
	// read for its order).
	h.rotation[id] = []int64{inviter.CharacterID, invitee.CharacterID}
	for _, m := range p.Members {
		h.byChar[m.CharacterID] = id
		if m.Session != nil {
			h.bySession[m.Session.ID()] = m.CharacterID
		}
	}
	return p.clone(), nil
}

// Add puts m into partyID, after the members already there. The refusals, in
// the ShardManager's order (READ, SM 0x44f130): 0x2c0d no such party, 0x2c23
// the leader's job and m's do not match, 0x2c25 m holds a match entry, 0x2c12
// m is already a member (of this or another party: the hub keeps one party per
// character), 0x2c13/0x2c14 full.
func (h *Hub) Add(partyID uint32, m Member) (*Party, error) {
	h.mu.Lock()
	defer h.mu.Unlock()

	p, ok := h.parties[partyID]
	if !ok {
		return nil, refuse(CodeCantFindParty)
	}
	if !JobsMatch(p.Members[0].job(), m.job()) {
		return nil, refuse(CodeUserMismatch)
	}
	if _, listed := h.listings[m.CharacterID]; listed {
		return nil, refuse(CodeListed)
	}
	if _, in := h.byChar[m.CharacterID]; in {
		return nil, refuse(CodeExistingMember)
	}
	if p.Full() {
		return nil, refuse(p.Flags.FullCode())
	}
	p.Members = append(p.Members, m)
	h.byChar[m.CharacterID] = partyID
	h.rotation[partyID] = append(h.rotation[partyID], m.CharacterID)
	if m.Session != nil {
		h.bySession[m.Session.ID()] = m.CharacterID
	}
	return p.clone(), nil
}

// Remove takes characterID out of its party for reason. A party of exactly
// two is dissolved (both members leave it); otherwise the member goes and,
// if it led, the first remaining member -- the longest-standing -- leads (READ,
// SM 0x44f580, 0x44e1a0, 0x44eb30). A dissolved party's leader loses its
// listing (SM 0x44eb30 deletes it); a departing leader's listing moves to the
// new leader (SM 0x44e1a0, kind 0x12).
func (h *Hub) Remove(characterID int64, reason uint8) (Removal, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.removeLocked(characterID)
}

func (h *Hub) removeLocked(characterID int64) (Removal, error) {
	pid, in := h.byChar[characterID]
	if !in {
		return Removal{}, ErrNotInParty
	}
	p := h.parties[pid]
	r := Removal{Before: p.clone()}
	if len(p.Members) <= 2 {
		for _, m := range p.Members {
			h.forgetLocked(m)
		}
		delete(h.listings, p.LeaderID)
		delete(h.parties, pid)
		delete(h.rotation, pid)
		r.Dissolved = true
		return r, nil
	}
	i := p.index(characterID)
	h.dropFromRotationLocked(pid, characterID)
	h.forgetLocked(p.Members[i])
	p.Members = append(p.Members[:i], p.Members[i+1:]...)
	if p.LeaderID == characterID {
		p.LeaderID = p.Members[0].CharacterID
		r.NewLeader = p.LeaderID
		if l, ok := h.listings[characterID]; ok {
			delete(h.listings, characterID)
			h.listings[p.LeaderID] = l
		}
	}
	r.After = p.clone()
	return r, nil
}

// NextInRotation is GObjPC::FUN_004d4840 (round 712, party lane S2): it takes
// the member at the front of partyID's item rotation, moves it to the back and
// returns it (READ, GS: the list at party+0x20, front popped and re-appended).
// A joiner is appended at the back (FUN_005bc210) and a leaver removed
// (FUN_005bc390). false for a party that does not exist.
func (h *Hub) NextInRotation(partyID uint32) (int64, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	r := h.rotation[partyID]
	if len(r) == 0 {
		return 0, false
	}
	front := r[0]
	r = append(r[1:], front)
	h.rotation[partyID] = r
	return front, true
}

func (h *Hub) dropFromRotationLocked(partyID uint32, characterID int64) {
	r := h.rotation[partyID]
	for i, id := range r {
		if id == characterID {
			h.rotation[partyID] = append(r[:i:i], r[i+1:]...)
			return
		}
	}
}

func (h *Hub) forgetLocked(m Member) {
	delete(h.byChar, m.CharacterID)
	if m.Session != nil {
		delete(h.bySession, m.Session.ID())
	}
}

// CharacterOfSession returns the party member playing on sessionID, for the
// disconnect cleanup.
func (h *Hub) CharacterOfSession(sessionID uint64) (int64, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	c, ok := h.bySession[sessionID]
	return c, ok
}

// Get returns the party characterID belongs to.
func (h *Hub) Get(characterID int64) (*Party, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	pid, in := h.byChar[characterID]
	if !in {
		return nil, false
	}
	return h.parties[pid].clone(), true
}

// PartyByID returns the party with id.
func (h *Hub) PartyByID(id uint32) (*Party, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	p, ok := h.parties[id]
	if !ok {
		return nil, false
	}
	return p.clone(), true
}

// All returns every party, in id order (the member-update ticker walks them).
func (h *Hub) All() []*Party {
	h.mu.Lock()
	defer h.mu.Unlock()
	out := make([]*Party, 0, len(h.parties))
	for _, p := range h.parties {
		out = append(out, p.clone())
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out
}

// SetListing records that characterID holds party-match entry with flags
// (lane S3). ClearListing removes it.
func (h *Hub) SetListing(characterID int64, entry uint32, flags Flags) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.listings[characterID] = listing{entry: entry, flags: flags}
}

// ClearListing removes characterID's party-match entry.
func (h *Hub) ClearListing(characterID int64) {
	h.mu.Lock()
	defer h.mu.Unlock()
	delete(h.listings, characterID)
}

// Listing returns characterID's party-match entry.
func (h *Hub) Listing(characterID int64) (entry uint32, flags Flags, ok bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	l, ok := h.listings[characterID]
	return l.entry, l.flags, ok
}

// State is characterID's chardata+7 byte, derived (OURS: the engine stores
// the byte and moves it at each event; the hub derives the same values from
// what it holds, which agrees with the writers' table in party_protocol.md for
// every single invitation): 2 in a party; 1 when an invitation to it is
// pending, or it has a formation invitation out; 3 when listed with a
// formation invitation out; 4 when listed; else 0.
func (h *Hub) State(characterID int64) byte {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.stateLocked(characterID)
}

func (h *Hub) stateLocked(characterID int64) byte {
	if _, in := h.byChar[characterID]; in {
		return StateInParty
	}
	if _, pending := h.invites[characterID]; pending {
		return StatePending
	}
	_, listed := h.listings[characterID]
	inviting := false
	for _, inv := range h.invites {
		if inv.Kind == InviteForm && inv.Inviter.CharacterID == characterID {
			inviting = true
		}
	}
	for _, inv := range h.detached {
		if inv.Kind == InviteForm && inv.Inviter.CharacterID == characterID {
			inviting = true
		}
	}
	switch {
	case listed && inviting:
		return StateListedInviting
	case listed:
		return StateListed
	case inviting:
		return StatePending
	}
	return StateFree
}

// ErrInvitePending is Invite's refusal when the target already has an
// invitation pending (a race past the ladder's 0x2c1f check); the session
// layer sends it as the post failure, code 2.
var ErrInvitePending = errors.New("party: the target already has an invitation pending")

// Invite records a pending invitation and arms its timeout. When the timeout
// fires before TakeInvite, the invitation is dropped and onTimeout runs (on
// the timer's goroutine, outside the hub's lock) with it.
func (h *Hub) Invite(inv Invite, onTimeout func(Invite)) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	target := inv.Target.CharacterID
	if _, pending := h.invites[target]; pending {
		return ErrInvitePending
	}
	h.seq++
	inv.seq = h.seq
	stored := inv
	h.invites[target] = &stored
	seq := inv.seq
	stored.timer = h.afterFunc(h.Timeout, func() {
		h.mu.Lock()
		cur, ok := h.invites[target]
		if ok && cur.seq == seq {
			delete(h.invites, target)
		} else if cur, ok = h.detached[seq]; ok {
			delete(h.detached, seq)
		} else {
			h.mu.Unlock()
			return
		}
		got := *cur
		h.mu.Unlock()
		if onTimeout != nil {
			onTimeout(got)
		}
	})
	return nil
}

// TakeInvite removes and returns the invitation pending for target (its
// answer arrived), stopping its timeout. ok is false when none is pending:
// it timed out, or was never sent.
func (h *Hub) TakeInvite(target int64) (Invite, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	inv, ok := h.invites[target]
	if !ok {
		return Invite{}, false
	}
	delete(h.invites, target)
	if inv.timer != nil {
		inv.timer.Stop()
	}
	return *inv, true
}

// DetachSession releases the invitee of an invitation pending for the
// character playing on sessionID, which left the world: the invitee is free
// again (a fresh invitation to it is no longer refused 0x2c1f), while the
// invitation still times out and its onTimeout still runs. OURS (round 710):
// whether the original's logout cancels the transaction was not read. What is
// READ is that the transaction finds both characters by id when it is
// answered or times out (GS 0x5be350, OnTimeout 0x46ce44 -> 0x46cec0), and that
// the state byte lives in the character object a relog replaces; so a relogged
// invitee starts free, and the inviter hears the timeout.
func (h *Hub) DetachSession(sessionID uint64) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for target, inv := range h.invites {
		if inv.Target.Session != nil && inv.Target.Session.ID() == sessionID {
			delete(h.invites, target)
			h.detached[inv.seq] = inv
		}
	}
}
