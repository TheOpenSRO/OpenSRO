package party

// Party matching: the listings, their pages and the join request (round 713,
// lane S3). docs/protocol/party_protocol.md "Party matching" and
// party_rules.md "Party matching" (round 709) are the contract; every rule
// below is the ShardManager's (SR_ShardManager.exe, this package's build),
// READ at the address given, unless it says OURS.
//
// Who holds what. The Hub keeps which character holds which entry number and
// with which flags (SetListing / ClearListing): it already moves a departing
// leader's entry to the new leader and drops a dissolved party's (SM 0x44e1a0,
// 0x44eb30), and its invite ladder reads it. The Matcher keeps the rest of
// each listing -- purpose, level range, title, time, the pending mark -- keyed
// by entry number, and finds an entry's owner through the Hub, so the owner is
// always the current leader without a second copy to keep in step.
//
// Locks: the Matcher calls into the Hub while holding its own lock; the Hub
// never calls the Matcher, so the order is always Matcher then Hub.

import (
	"sort"
	"sync"
	"time"
)

// PageSize is how many listings a page holds: the page builder closes a page
// at 23 (READ, SM 0x451630, `cmp al,0x17` at 0x4517ed).
const PageSize = 23

// MaxPages is the most pages the ShardManager builds (READ, SM 0x450d20
// asserts more than 0xfe; the page count goes out as a u8).
const MaxPages = 0xfe

// JoinTimeout is the ShardManager's wait for the leader's answer: 15.0 s, the
// float at SM 0x79b018 stored at the job's +0x2c by 0x4206f0 and ticked in
// seconds by 0x421de0 (READ). Its expiry answers 2, "no reply" (SM 0x420e10
// -> 0x44fbe0(.., 2)). With a stock client the leader's own popup answers 2
// after 10 s first (READ, c:0x7406de, c:0x73fb70); this is the backstop.
const JoinTimeout = 15 * time.Second

// More party-match codes (names from docs/protocol/error_codes.md).
const (
	CodeMatchFull      uint16 = 0x2c08 // UIIT_MSG_PARTYERR_ALREADY_FULL
	CodeRecordAgain    uint16 = 0x2c1b // UIIT_MSG_PARTYMATCH_RECORD_ERROR_AGAIN
	CodeNoEntry        uint16 = 0x2c1c // UIIT_MSG_PARTYERR_CANT_FIND_PARTY (no such entry)
	CodeNotLeader      uint16 = 0x2c1d // UIIT_MSG_PARTYMATCH_RECORD_ERROR_PARTYLEADER
	CodeJoinLevel      uint16 = 0x2c1e // UIIT_MSG_PARTYMATCH_JOIN_ERROR_LEVEL
	CodeMatchStateBusy uint16 = 0x2c24 // UIIT_MSG_PARTYMATCH_JOIN_ERROR_DUPLE (register with a state byte not 0 or 2)
	// CodeFlagsChanged is the bare 5 the change refuses with when the flags
	// differ from the entry's (READ, SM 0x4513c0); no client message.
	CodeFlagsChanged uint16 = 5
)

// Listing is one party-match entry as the ShardManager keeps it (READ, SM
// 0x451290 / 0x451110 fill +0 number, +8 flags, +9 purpose, +0xa/+0xb levels,
// +0xc title, +0x30 time; +0x34 the pending mark).
type Listing struct {
	Number   uint32
	Flags    Flags
	Purpose  uint8
	MinLevel uint8
	MaxLevel uint8
	Title    string
	// Time is the second u32 of a list row: SM writes _time32 into +0x30 at
	// register and change (READ that it is written there; INFERRED a time,
	// its client use OPEN). OURS: seconds since the Unix epoch, as _time32
	// counts.
	Time uint32
	// Pending is +0x34: a join request to this entry waits on the leader
	// (READ, SM 0x44f850 sets it, refuses a second request 0x2c1f).
	Pending bool
}

// Joiner is what the ShardManager reads off a join request about the
// requester (READ, SM 0x44f850: its party +0x68, its own entry +0x24c, the
// record's level, the job state).
type Joiner struct {
	CharacterID int64
	Level       uint8
	Job         uint8
}

// JoinJob is a join request waiting on the entry's leader: the ShardManager's
// trs job (job +4 its id, +8 the requester, +0x10 the leader; SM 0x420530,
// 0x44f850).
type JoinJob struct {
	ID        uint32
	Entry     uint32
	Requester int64
	Leader    int64
	timer     stopper
}

// Matcher holds the party-match listings and the pending join requests.
// Safe for concurrent use.
type Matcher struct {
	hub *Hub

	mu       sync.Mutex
	counter  uint32
	listings map[uint32]*Listing
	jobs     map[uint32]*JoinJob
	jobSeq   uint32

	// Timeout is the join-request backstop (JoinTimeout unless a test sets
	// it before use).
	Timeout time.Duration
	// Now and afterFunc are the clock and the timer; tests swap them.
	Now       func() time.Time
	afterFunc func(time.Duration, func()) stopper
}

// NewMatcher returns an empty Matcher over hub.
func NewMatcher(hub *Hub) *Matcher {
	return &Matcher{
		hub:       hub,
		listings:  make(map[uint32]*Listing),
		jobs:      make(map[uint32]*JoinJob),
		Timeout:   JoinTimeout,
		Now:       time.Now,
		afterFunc: func(d time.Duration, f func()) stopper { return time.AfterFunc(d, f) },
	}
}

// newNumberLocked is the next entry number: a counter at manager+0x8c that
// only grows and skips 0 (READ, SM 0x451290 / 0x44def0). Numbers are not
// reused for the life of the server.
func (m *Matcher) newNumberLocked() uint32 {
	m.counter++
	if m.counter == 0 {
		m.counter++
	}
	return m.counter
}

func (m *Matcher) stamp() uint32 { return uint32(m.Now().Unix()) }

// ListingOwner returns the character holding entry, through the Hub's
// listings (which follow a new leader and vanish with a dissolved party).
func (h *Hub) ListingOwner(entry uint32) (int64, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for c, l := range h.listings {
		if l.entry == entry {
			return c, true
		}
	}
	return 0, false
}

// setRequest and clearRequest mark a character's join request pending (its
// state byte 1) or ended.
func (h *Hub) setRequest(characterID int64) {
	h.mu.Lock()
	h.requests[characterID] = struct{}{}
	h.mu.Unlock()
}

func (h *Hub) clearRequest(characterID int64) {
	h.mu.Lock()
	delete(h.requests, characterID)
	h.mu.Unlock()
}

// Register is the ShardManager's register (READ, SM 0x450680 -> 0x451290 /
// 0x451110), in its order:
//   - 0x2c1b the character already holds an entry (+0x24c);
//   - in a party: 0x2c20 the entry's flags are not the party's; the party
//     gone 0x2c0d; not its leader 0x2c1d; the party full 0x2c08 (by its own
//     cap, SM 0x44de70); the listing takes the party's flags;
//   - not in a party: the listing carries the entry's flags, and becomes the
//     party's type when someone joins.
//
// The GameServer's checks (CheckCanCreateForMatch and the purpose rule) are
// the session layer's and come first. A character that is gone (0x2c0f) is
// the caller's test. On success the entry number is assigned and the Hub
// records the listing.
func (m *Matcher) Register(characterID int64, e Entry) (Listing, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, _, listed := m.hub.Listing(characterID); listed {
		return Listing{}, refuse(CodeRecordAgain)
	}
	flags := e.Flags
	if p, in := m.hub.Get(characterID); in {
		if p.Flags != e.Flags {
			return Listing{}, refuse(CodeEntryFlags)
		}
		if p.LeaderID != characterID {
			return Listing{}, refuse(CodeNotLeader)
		}
		if p.Full() {
			return Listing{}, refuse(CodeMatchFull)
		}
		flags = p.Flags
	}
	l := &Listing{Number: m.newNumberLocked(), Flags: flags, Purpose: e.Purpose, MinLevel: e.MinLevel,
		MaxLevel: e.MaxLevel, Title: e.Title, Time: m.stamp()}
	m.listings[l.Number] = l
	m.hub.SetListing(characterID, l.Number, flags)
	return *l, nil
}

// Change is the ShardManager's change entry (READ, SM 0x450990 ->
// 0x4513c0): 0x2c1c the character holds no entry; 0x2c1d it is not the
// entry's owner; 5 the flags differ from the entry's (they cannot be changed
// this way either). The purpose, level range and title are replaced and the
// time renewed. Returns the entry number.
func (m *Matcher) Change(characterID int64, e Entry) (uint32, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	num, _, listed := m.hub.Listing(characterID)
	if !listed {
		return 0, refuse(CodeNoEntry)
	}
	l, ok := m.listings[num]
	if !ok {
		return 0, refuse(CodeNoEntry)
	}
	if owner, ok := m.hub.ListingOwner(num); !ok || owner != characterID {
		return 0, refuse(CodeNotLeader)
	}
	if l.Flags != e.Flags {
		return 0, refuse(CodeFlagsChanged)
	}
	l.Purpose, l.MinLevel, l.MaxLevel, l.Title = e.Purpose, e.MinLevel, e.MaxLevel, e.Title
	l.Time = m.stamp()
	return num, nil
}

// Delete is the ShardManager's delete (READ, SM 0x450ba0 -> 0x451490): 0x2c1c
// no such entry; 0x2c1d the character does not own it. (Its third refusal,
// 0x2c0d when the entry's party is not the owner's, cannot arise here: the
// Hub moves an entry only with its party's leadership.)
func (m *Matcher) Delete(characterID int64, number uint32) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.listings[number]; !ok {
		return refuse(CodeNoEntry)
	}
	owner, ok := m.hub.ListingOwner(number)
	if !ok {
		delete(m.listings, number)
		return refuse(CodeNoEntry)
	}
	if owner != characterID {
		return refuse(CodeNotLeader)
	}
	delete(m.listings, number)
	m.hub.ClearListing(characterID)
	return nil
}

// Withdraw drops characterID's entry with no reply: the ShardManager's user
// cleanup for a party-less owner who leaves the world (READ, SM 0x4296f0 ->
// 0x451590). An owner in a party is the Hub's (Remove moves or drops it).
func (m *Matcher) Withdraw(characterID int64) {
	m.mu.Lock()
	defer m.mu.Unlock()
	num, _, listed := m.hub.Listing(characterID)
	if !listed {
		return
	}
	if _, in := m.hub.Get(characterID); in {
		return
	}
	delete(m.listings, num)
	m.hub.ClearListing(characterID)
}

// Get returns listing number, its current owner, and whether both exist. An
// entry whose owner is gone from the Hub is dropped.
func (m *Matcher) Get(number uint32) (Listing, int64, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	l, ok := m.listings[number]
	if !ok {
		return Listing{}, 0, false
	}
	owner, ok := m.hub.ListingOwner(number)
	if !ok {
		delete(m.listings, number)
		return Listing{}, 0, false
	}
	return *l, owner, true
}

// Row is a listing with what its list row needs from the owner.
type Row struct {
	Listing
	Owner int64
}

// RowInfo is what a list row reads about an entry's owner: its name and race
// (SM 0x44f640: char+0x1a8, char+0x250), and the member count (the owner's
// party size, 1 without one). ok is false for an owner no longer in the world:
// the page builder then deletes the entry (READ, SM 0x451630 on 0x44f640
// returning 0).
type RowInfo func(owner int64) (name string, race uint8, ok bool)

// Page is a list page as the ShardManager answers it (READ, SM 0x450d20 and
// the page builder 0x451630):
//   - the listings in entry-number order, PageSize to a page, at most
//     MaxPages pages; an entry whose owner is gone is dropped on the way;
//   - a page index past the end is page 0;
//   - with no listings at all: no pages, index 0, no rows;
//   - when the requester holds an entry, or is in a party whose leader holds
//     one, that entry is written first and the count is one more -- it then
//     appears twice on its own page, and the client skips the second copy
//     (READ, c:0x73a770).
//
// err is 0x2c0d when the requester's own entry is recorded in the Hub but
// missing here (SM 0x450d20's not-found branch).
func (m *Matcher) Page(requester int64, index uint8, info RowInfo) (pages, at uint8, rows []ListEntry, err error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	nums := make([]uint32, 0, len(m.listings))
	for n := range m.listings {
		nums = append(nums, n)
	}
	sort.Slice(nums, func(i, j int) bool { return nums[i] < nums[j] })
	var valid []ListEntry
	for _, n := range nums {
		r, ok := m.rowLocked(n, info)
		if !ok {
			continue
		}
		valid = append(valid, r)
	}

	var own *ListEntry
	ownNum, _, listed := m.hub.Listing(requester)
	if !listed {
		if p, in := m.hub.Get(requester); in {
			ownNum, _, listed = m.hub.Listing(p.LeaderID)
		}
	}
	if listed {
		r, ok := m.rowLocked(ownNum, info)
		if !ok {
			return 0, 0, nil, refuse(CodeCantFindParty)
		}
		own = &r
	}

	n := (len(valid) + PageSize - 1) / PageSize
	if n > MaxPages {
		n = MaxPages
	}
	if n == 0 {
		return 0, 0, nil, nil
	}
	if int(index) >= n {
		index = 0
	}
	lo := int(index) * PageSize
	hi := lo + PageSize
	if hi > len(valid) {
		hi = len(valid)
	}
	if own != nil {
		rows = append(rows, *own)
	}
	rows = append(rows, valid[lo:hi]...)
	return uint8(n), index, rows, nil
}

// rowLocked builds entry n's list row, dropping the entry when its owner is
// gone.
func (m *Matcher) rowLocked(n uint32, info RowInfo) (ListEntry, bool) {
	l, ok := m.listings[n]
	if !ok {
		return ListEntry{}, false
	}
	owner, ok := m.hub.ListingOwner(n)
	if !ok {
		delete(m.listings, n)
		return ListEntry{}, false
	}
	name, race, ok := info(owner)
	if !ok {
		delete(m.listings, n)
		m.hub.ClearListing(owner)
		return ListEntry{}, false
	}
	count := uint8(1)
	if p, in := m.hub.Get(owner); in {
		count = uint8(len(p.Members))
	}
	return ListEntry{Number: l.Number, Time: l.Time, Name: name, Race: race, Count: count, Flags: l.Flags,
		Purpose: l.Purpose, MinLevel: l.MinLevel, MaxLevel: l.MaxLevel, Title: l.Title}, true
}

// Request is the ShardManager's half of a join request (READ, SM 0x44f850),
// in its order:
//
//  1. 0x2c18 the requester is in a party;
//  2. 0x2c25 the requester holds an entry;
//  3. 0x2c1c no such entry;
//  4. when the entry has a party: 0x2c13/0x2c14 it is full (by its exp bit),
//     0x2c1c its leader is gone, 0x2c23 the requester's job does not go with
//     the leader's (JobsMatch);
//  5. 0x2c23 the requester's job does not fit the entry's purpose
//     (JobFitsPurpose);
//  6. 0x2c1e the requester's level is outside [min, max], inclusive;
//  7. 0x2c1f another request to this entry is pending;
//  8. 0x2c0e the entry's leader is not in the world (online says).
//
// On success the entry is marked pending, the requester's state byte is 1,
// and a job waits JoinTimeout for the leader's answer; onTimeout runs (on the
// timer's goroutine, outside the lock) with the job if it expires first.
// leaderJob is the entry owner's job state (the ShardManager's 0x44ed20
// compares the party leader's member record).
func (m *Matcher) Request(j Joiner, number uint32, leaderJob func(owner int64) uint8, online func(int64) bool, onTimeout func(JoinJob)) (JoinJob, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	if _, in := m.hub.Get(j.CharacterID); in {
		return JoinJob{}, refuse(CodeOtherParty)
	}
	if _, _, listed := m.hub.Listing(j.CharacterID); listed {
		return JoinJob{}, refuse(CodeListed)
	}
	l, ok := m.listings[number]
	if !ok {
		return JoinJob{}, refuse(CodeNoEntry)
	}
	owner, ok := m.hub.ListingOwner(number)
	if !ok {
		delete(m.listings, number)
		return JoinJob{}, refuse(CodeNoEntry)
	}
	job := j.Job
	if job == 0 {
		job = JobNone
	}
	if p, in := m.hub.Get(owner); in {
		if p.Full() {
			return JoinJob{}, refuse(p.Flags.FullCode())
		}
		if !JobsMatch(normJob(leaderJob(p.LeaderID)), job) {
			return JoinJob{}, refuse(CodeUserMismatch)
		}
	}
	if !JobFitsPurpose(job, l.Purpose) {
		return JoinJob{}, refuse(CodeUserMismatch)
	}
	if j.Level < l.MinLevel || j.Level > l.MaxLevel {
		return JoinJob{}, refuse(CodeJoinLevel)
	}
	if l.Pending {
		return JoinJob{}, refuse(CodeDuplicate)
	}
	if !online(owner) {
		return JoinJob{}, refuse(CodeCantFindCreator)
	}
	l.Pending = true
	m.jobSeq++
	if m.jobSeq == 0 {
		m.jobSeq++
	}
	jj := &JoinJob{ID: m.jobSeq, Entry: number, Requester: j.CharacterID, Leader: owner}
	m.jobs[jj.ID] = jj
	m.hub.setRequest(j.CharacterID)
	id := jj.ID
	jj.timer = m.afterFunc(m.Timeout, func() {
		got, ok := m.TakeJob(id)
		if ok && onTimeout != nil {
			onTimeout(got)
		}
	})
	return *jj, nil
}

// IsLeaderOf reports whether job id is pending and waits on characterID's
// answer.
func (m *Matcher) IsLeaderOf(id uint32, characterID int64) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	jj, ok := m.jobs[id]
	return ok && jj.Leader == characterID
}

func normJob(j uint8) uint8 {
	if j == 0 {
		return JobNone
	}
	return j
}

// TakeJob ends job id: it is removed, its timer stopped, its entry's pending
// mark cleared and the requester's state byte released. ok is false when the
// job is not pending (it was answered or timed out).
//
// The ShardManager clears the pending mark on every answer that finds the
// requester (SM 0x44fbe0) and the GameServer drops the requester's state byte
// to 0 on any outcome but a join (GS 0x5bfac0); a join moves it to 2 through
// the party. OURS: the mark is cleared even on the paths where SM 0x44fbe0
// does not reach the clear (an accept whose requester has left), so an entry
// is never left refusing every request with 0x2c1f.
func (m *Matcher) TakeJob(id uint32) (JoinJob, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	jj, ok := m.jobs[id]
	if !ok {
		return JoinJob{}, false
	}
	delete(m.jobs, id)
	if jj.timer != nil {
		jj.timer.Stop()
	}
	if l, ok := m.listings[jj.Entry]; ok {
		l.Pending = false
	}
	m.hub.clearRequest(jj.Requester)
	return *jj, true
}
