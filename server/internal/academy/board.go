package academy

import (
	"sort"
	"sync"
	"time"
)

// Board is the guardian matching board (docs/protocol/academy.md 7.10): held
// in memory only, as the shard manager holds it (READ: its entries are a
// vector at mgr+0x30, dropped when the guardian logs out, m:0x459b04).
type Board struct {
	mu      sync.Mutex
	next    uint32
	byID    map[uint32]MatchEntry
	byCamp  map[uint32]uint32
	pending map[uint32]bool
}

// The board's refusals (READ m:, docs/protocol/academy.md section 11).
const (
	ErrBoardRegistered uint16 = 0x6825 // TC_ERROR_ALREADY_OPEN
	ErrBoardNoEntry    uint16 = 0x6826 // TC_ERROR_NOT_INFORMATION
	ErrBoardPending    uint16 = 0x6827
	ErrBoardRole       uint16 = 0x682a // TC_ERROR_INVITE_TYPE_DIFFERENT
)

// BoardPageRows is a list page's rows (INFERRED: the matching window's rows
// 70..81, twelve, c:ifmentormatch.txt; the shard's page size is not read).
const BoardPageRows = 12

// MatchJoinWaitSeconds is how long a join request waits for the guardian
// (READ m:0x79b018, 15.0f). The guardian's question box answers 0 on its
// own 15 s timer (READ c:0x645c46 `push 0x3a98; push 0xa`, c:0x63bf40;
// MEASURED: its 0x347F {.., 0} 15.0 s after the push), and the shard's wait
// did not end first (MEASURED: the requester got 0xB47E {01 00}, "Request
// has been cancelled.", not {01 02}).
const MatchJoinWaitSeconds = 15

// MatchJoinBackstop is OpenSRO's own wait for a guardian's answer before it
// answers the requester "no reply" (OURS): the shard's 15 s plus 2 s, so the
// guardian's box, whose 15 s start when the question arrives, answers first
// as it did in the original, and the backstop only ends a request the
// guardian's client never answers.
const MatchJoinBackstop = MatchJoinWaitSeconds*time.Second + 2*time.Second

// NewBoard is an empty board.
func NewBoard() *Board {
	return &Board{byID: map[uint32]MatchEntry{}, byCamp: map[uint32]uint32{}, pending: map[uint32]bool{}}
}

// Register lists campID; entry ids count from 1 (MEASURED: the first entry
// is 1). A camp already listed is refused ErrBoardRegistered.
func (b *Board) Register(campID uint32, flags byte, title string) (MatchEntry, uint16) {
	return b.RegisterAt(campID, flags, title, time.Now())
}

// RegisterAt is Register at the time at (the entry's Registered).
func (b *Board) RegisterAt(campID uint32, flags byte, title string, at time.Time) (MatchEntry, uint16) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if _, in := b.byCamp[campID]; in {
		return MatchEntry{}, ErrBoardRegistered
	}
	b.next++
	e := MatchEntry{ID: b.next, CampID: campID, Flags: flags, Title: title, Registered: uint32(at.Unix())}
	b.byID[e.ID] = e
	b.byCamp[campID] = e.ID
	return e, 0
}

// Modify changes campID's entry id.
func (b *Board) Modify(id, campID uint32, flags byte, title string) (MatchEntry, uint16) {
	b.mu.Lock()
	defer b.mu.Unlock()
	e, ok := b.byID[id]
	if !ok || e.CampID != campID {
		return MatchEntry{}, ErrBoardNoEntry
	}
	e.Flags, e.Title = flags, title
	b.byID[id] = e
	return e, 0
}

// Delete removes campID's entry id.
func (b *Board) Delete(id, campID uint32) uint16 {
	b.mu.Lock()
	defer b.mu.Unlock()
	e, ok := b.byID[id]
	if !ok || e.CampID != campID {
		return ErrBoardNoEntry
	}
	b.remove(e)
	return 0
}

func (b *Board) remove(e MatchEntry) {
	delete(b.byID, e.ID)
	delete(b.byCamp, e.CampID)
	delete(b.pending, e.ID)
}

// DropCamp removes campID's entry, if any (the guardian logged out, the camp
// filled or was disbanded).
func (b *Board) DropCamp(campID uint32) (MatchEntry, bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	id, ok := b.byCamp[campID]
	if !ok {
		return MatchEntry{}, false
	}
	e := b.byID[id]
	b.remove(e)
	return e, true
}

// Get is entry id.
func (b *Board) Get(id uint32) (MatchEntry, bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	e, ok := b.byID[id]
	return e, ok
}

// Entries is every entry by id.
func (b *Board) Entries() []MatchEntry {
	b.mu.Lock()
	defer b.mu.Unlock()
	out := make([]MatchEntry, 0, len(b.byID))
	for _, e := range b.byID {
		out = append(out, e)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out
}

// Page is page (0-based) of entries and the page count.
func Page(entries []MatchEntry, page int) ([]MatchEntry, int) {
	pages := (len(entries) + BoardPageRows - 1) / BoardPageRows
	if page < 0 || page >= pages {
		return nil, pages
	}
	end := min((page+1)*BoardPageRows, len(entries))
	return entries[page*BoardPageRows : end], pages
}

// Hold marks a join request pending on entry id: false when one already is
// (ErrBoardPending).
func (b *Board) Hold(id uint32) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.pending[id] {
		return false
	}
	b.pending[id] = true
	return true
}

// Release ends the pending request on id.
func (b *Board) Release(id uint32) {
	b.mu.Lock()
	defer b.mu.Unlock()
	delete(b.pending, id)
}

// RecruitsRole reports whether flags take a joiner of class.
func RecruitsRole(flags byte, class int) bool {
	switch class {
	case MemberClassStudent:
		return flags&MatchApprentices != 0
	case MemberClassSecondGuardian:
		return flags&MatchAssistants != 0
	}
	return false
}
