// Package buff is the per-character book of active timed buffs (round 616,
// docs/protocol/skill_buffs.md): the engine's active-effect book at char+0xa30
// reduced to what srrevamp models -- one record per applied action-kind-3
// skill, its duration, the ParamKeeper contributions it made, and the rules
// that start, refuse, end and cancel it.
//
// What is READ from SR_GameServer.exe, and where:
//
//   - The END rule: SkillAction_Buff (0x5830b0) sub-state 2 ends the record
//     when `GetTickCount() - record+8 > dura[0] + ctx+0x24` -- strictly
//     greater (skillparam.BuffEndsAt). The extension ctx+0x24 is 0 here: its
//     setter in 0x5830b0 adds a value found by FUN_005a0330 (a lookup in the
//     book's map at +0x244, keyed by the row's 'RPBU'/'STDU'/'DTDR' word) --
//     the caster's passive records, which srrevamp does not keep (OPEN).
//   - The END effects: SkillBook::Update (0x59bb80) erases the record,
//     removes its contributions (ParamKeeper_RemoveContributionsOf, 0x4b3660,
//     keyed by the record) and queues its token for 0xB072.
//   - The RECAST rule: Skill_CheckUseConditions (0x58d8f0) row 16 calls
//     FUN_0059d870 only for a row with no 'lnks' (+0x370) and Target_Required
//     (+0x94) 0; see CheckOverlap for the branch srrevamp models and the ones
//     it does not.
//   - The DISPEL, 0x4ae520 -> FUN_0059ef90 / FUN_0059eff0: the record of that
//     skill id (in sub-state 1 or 2), matching the token when one is given
//     (token 0 matches any); a skill carrying 'nbuf' (+0x35c) whose record's
//     ctx+0x20 is not 1 is refused silently. SkillAction_Buff stores 1 there
//     when the target object is the caster and 2 on a record built for
//     another target (READ stores; "1 = cast on oneself" INFERRED from them).
//   - The run-speed writes, ApplySkillParamsToChar (0x594ac0), with the speed
//     holder pc+0xc24:
//     'hste' (+0x2b8): value[0] into params 23 and 24 at slot 2 only while
//     the holder is empty; the record becomes the holder either way.
//     'hst2' (+0x2bc), on a row without 'hste': the holder's own 23/24
//     contributions are removed (Param_RefreshContributions 0x4b3570 ->
//     FUN_004b31a0 -> FUN_004b2e00, which erases the entry keyed by the
//     holder), value[0] is written into 23 and 24 at slot 2, and the record
//     becomes the holder only when there was none.
//     'hst3' (+0x2c0), on a row with neither: value[0] into 23 and 24.
//     SkillAction_BuffEnd (0x5829d0): an 'hste' record's end empties the
//     holder (`book[0x7d] = 0`, the book at pc+0xa30); an 'hst2' record's end
//     empties it when the record IS the holder, and otherwise writes the
//     holder's 'hste' value[0] back into 23 and 24.
//     Slot 2 reduces as the product of (1 + e/100) (GParamKeeper FUN_004b2e60).
//
// OURS, disclosed: the record's shape, the token allocator (a server-wide
// counter), and that only the run-speed contributions are recorded -- they
// are the only ones something in srrevamp consumes. The other publishing
// codes are listed OPEN in docs/protocol/skill_buffs.md.
package buff

import (
	"math"
	"sort"
	"sync"
	"sync/atomic"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/skillparam"
)

// The run-speed params, 'hste'/'hst2'/'hst3' publish both
// (skillparam.Contributions).
const (
	ParamWalkSpeed = 23
	ParamRunSpeed  = 24
)

// Contribution is one ParamKeeper write a record made.
type Contribution struct {
	Param int
	Slot  skillparam.Slot
	Value float64
}

// Spec is what starting a buff needs from the skill row.
type Spec struct {
	SkillID  int64
	GroupID  int64
	Level    int
	CasterID int64
	// DuraMs is 'dura' value[0]; 0 or less is a buff with no duration (a
	// toggle or a summon -- their own end rules are OPEN), which lasts until
	// it is cancelled or cleared.
	DuraMs int
	Cbuf   bool
	Nbuf   bool
	// Lnks and Lks2 are the row's 'lnks' (+0x370) and 'lks2' (+0x374);
	// TargetRequired is +0x94. All three steer the recast rule.
	Lnks, Lks2     bool
	TargetRequired bool
	// Hste, Hst2 and Hst3 are the rows' 'hste'/'hst2'/'hst3' value[0], with
	// the Has* flags saying whether the row carries each run at all.
	Hste, Hst2, Hst3          int
	HasHste, HasHst2, HasHst3 bool
}

// Record is one active buff.
type Record struct {
	Token    uint32
	OwnerID  int64
	CasterID int64
	SkillID  int64
	GroupID  int64
	Level    int
	Start    time.Time
	// Dura is 0 for a buff with no duration.
	Dura time.Duration
	Cbuf bool
	Nbuf bool
	Lnks bool
	// HasHste / Hste and HasHst2 drive the speed holder at the record's end.
	HasHste       bool
	Hste          int
	HasHst2       bool
	Contributions []Contribution
}

// Timed reports whether the record ends on its own.
func (r Record) Timed() bool { return r.Dura > 0 }

// EndsAt is skillparam.BuffEndsAt for the record, with no extension.
func (r Record) EndsAt() time.Time {
	endMs := skillparam.BuffEndsAt(r.Start.UnixMilli(), r.Dura.Milliseconds(), 0)
	return time.UnixMilli(endMs)
}

// Expired is the engine's test on its millisecond clock: elapsed STRICTLY
// greater than the duration, i.e. now past EndsAt.
func (r Record) Expired(now time.Time) bool {
	return r.Timed() && now.UnixMilli() > r.EndsAt().UnixMilli()
}

// Remaining is what is left at now, 0 once past the end; -1 for a record
// with no duration.
func (r Record) Remaining(now time.Time) time.Duration {
	if !r.Timed() {
		return -1
	}
	left := r.Dura - now.Sub(r.Start)
	if left < 0 {
		return 0
	}
	return left
}

// SelfCast is the record's ctx+0x20 == 1: its target is its own caster.
func (r Record) SelfCast() bool { return r.CasterID == r.OwnerID }

func speedPair(v int) []Contribution {
	return []Contribution{
		{ParamWalkSpeed, skillparam.SlotMult, float64(v)},
		{ParamRunSpeed, skillparam.SlotMult, float64(v)},
	}
}

func withoutSpeed(cs []Contribution) []Contribution {
	var out []Contribution
	for _, c := range cs {
		if c.Param != ParamWalkSpeed && c.Param != ParamRunSpeed {
			out = append(out, c)
		}
	}
	return out
}

type book struct {
	records []Record
	// speedHolder is pc+0xc24, the token of the record holding the speed
	// writes; 0 when empty.
	speedHolder uint32
}

func (bk *book) index(token uint32) int {
	for i, r := range bk.records {
		if r.Token == token {
			return i
		}
	}
	return -1
}

func (bk *book) factor(p int) float64 {
	f := 1.0
	for _, r := range bk.records {
		for _, c := range r.Contributions {
			if c.Param == p && c.Slot == skillparam.SlotMult {
				f *= 1 + c.Value/100
			}
		}
	}
	return f
}

// endLocked is SkillAction_BuffEnd's speed-holder step for r, which has
// already left bk.records.
func (bk *book) endLocked(r Record) {
	switch {
	case r.HasHste:
		bk.speedHolder = 0
	case r.HasHst2:
		if bk.speedHolder == r.Token {
			bk.speedHolder = 0
		} else if i := bk.index(bk.speedHolder); i >= 0 && bk.records[i].HasHste {
			h := &bk.records[i]
			h.Contributions = append(withoutSpeed(h.Contributions), speedPair(h.Hste)...)
		}
		// A holder without 'hste' is retail's "HST2 Changed param skill
		// error" log line: nothing is written.
	}
}

// Books holds every character's book.
type Books struct {
	mu    sync.Mutex
	next  atomic.Uint32
	books map[int64]*book
	// base is the owners' base run speed (param 24's base), for the speed
	// each operation reports.
	base float64
}

// NewBooks returns an empty set of books whose owners run at baseRunSpeed.
func NewBooks(baseRunSpeed float64) *Books {
	return &Books{books: map[int64]*book{}, base: baseRunSpeed}
}

// NextToken allocates a server-unique token, never 0 (0 means "any" in a
// cancel). OURS.
func (b *Books) NextToken() uint32 {
	for {
		if t := b.next.Add(1); t != 0 {
			return t
		}
	}
}

// Speed is an owner's run speed after an operation and whether the
// operation changed it, both read under the lock that made the change.
type Speed struct {
	RunSpeed uint32
	Changed  bool
}

func (b *Books) speedLocked(bk *book) uint32 {
	f := 1.0
	if bk != nil {
		f = bk.factor(ParamRunSpeed)
	}
	return uint32(math.Round(b.base * f))
}

// Refusal is why Start refused.
type Refusal int

const (
	// NotRefused: the buff started.
	NotRefused Refusal = iota
	// RefusedOverlap is 0x300c SKILL_USE_FAIL_OVERLAP.
	RefusedOverlap
)

// overlapLocked is FUN_0059d870's GroupID branch. It is reached two ways:
//
//   - gate row 16 (0x58e2fd), on the CASTER's book, for a row with no 'lnks'
//     and Target_Required 0;
//   - the target test FUN_0058cc70, on each TARGET's book (0x58d2ca..0x58d2d3,
//     `push caster; push skill; lea ecx,[target+0xa30]; call 0x59d870`, a 0
//     answer refusing 0x300c) -- every Target_Required 1 row, 'lnks' or not
//     (an 'lnks' row first runs FUN_0059dc80 on the caster's book at
//     0x58d294, not modelled). The one skip (0x58d2ac..0x58d2c8): the target
//     is the caster and the caster's running action (+0xc08 -> +0x18 -> +8)
//     is this very skill; srrevamp keeps no running action, so it never
//     applies (round 622's review; until then a Target_Required 1 row got no
//     check here at all).
//
// It returns the index of the active record the cast would end (-1 for none)
// and a refusal.
//
// Per active record, in book order (the retail list's order is INFERRED to
// be the same), skipping a record whose skill carries 'cbuf' (+0x358):
//
//   - the 'dttp' (+0x424) branch -- both rows carry 'dttp' with one value[0]
//     -- is NOT modelled: srrevamp does not export 'dttp' (36 retail rows,
//     SKILL_CH_FIRE_DESCRY_*), and for them this applies the GroupID branch
//     where retail applies its own (OPEN);
//   - the '+0x290' branch (no code maps to that field) is NOT modelled (OPEN);
//   - the GroupID branch, modelled: the new row carries no 'lks2' (+0x374),
//     the active record is not an 'lnks' record the owner cast on itself
//     (`piVar4[0xdc] == 0 || ctx+0x20 != 1`), the new GroupID (+0x8) is not 0
//     and equals the active one's -> refused when the new Basic_Level (+0x64)
//     is lower, otherwise that record's end flag is cleared (it ends) and the
//     cast goes ahead. The first match decides.
//
// Falling off the end of the list, FUN_0059d870 then tests the row's
// Action_Overlap bytes (+0x8c) and 'ovl2' (+0x37c) against the character's
// state bits and running action (FUN_0059db10) -- NOT modelled (OPEN).
func overlapLocked(bk *book, spec Spec) (int, Refusal) {
	if bk == nil || (spec.Lnks && !spec.TargetRequired) {
		return -1, NotRefused
	}
	for i, r := range bk.records {
		if r.Cbuf {
			continue
		}
		if !spec.Lks2 && !(r.Lnks && r.SelfCast()) && spec.GroupID != 0 && spec.GroupID == r.GroupID {
			if spec.Level < r.Level {
				return -1, RefusedOverlap
			}
			return i, NotRefused
		}
	}
	return -1, NotRefused
}

// CheckOverlap is the gate's half of the recast rule, run BEFORE anything is
// spent (the gate precedes EngageSkill): whether a cast of spec on owner
// would be refused. Start applies the same rule.
func (b *Books) CheckOverlap(ownerID int64, spec Spec) Refusal {
	b.mu.Lock()
	defer b.mu.Unlock()
	_, r := overlapLocked(b.books[ownerID], spec)
	return r
}

// Start applies spec to ownerID at now. It returns the new record, the
// record the recast rule ended (if any), a refusal (nothing changes then),
// and the owner's run speed afterwards. The ended record goes out of the book
// before the new one engages: in retail its end flag is cleared at the gate
// and the book update ends it, while the new record engages from the cast --
// the relative order of the two is INFERRED.
func (b *Books) Start(ownerID int64, spec Spec, now time.Time) (rec Record, ended []Record, refused Refusal, sp Speed) {
	b.mu.Lock()
	defer b.mu.Unlock()
	bk := b.books[ownerID]
	if bk == nil {
		bk = &book{}
		b.books[ownerID] = bk
	}
	before := b.speedLocked(bk)
	i, refused := overlapLocked(bk, spec)
	if refused != NotRefused {
		return Record{}, nil, refused, Speed{RunSpeed: before}
	}
	if i >= 0 {
		old := bk.records[i]
		bk.records = append(bk.records[:i], bk.records[i+1:]...)
		bk.endLocked(old)
		ended = append(ended, old)
	}

	rec = Record{
		Token:    b.NextToken(),
		OwnerID:  ownerID,
		CasterID: spec.CasterID,
		SkillID:  spec.SkillID,
		GroupID:  spec.GroupID,
		Level:    spec.Level,
		Start:    now,
		Cbuf:     spec.Cbuf,
		Nbuf:     spec.Nbuf,
		Lnks:     spec.Lnks,
		HasHste:  spec.HasHste,
		Hste:     spec.Hste,
		HasHst2:  spec.HasHst2 && !spec.HasHste,
	}
	if spec.DuraMs > 0 {
		rec.Dura = time.Duration(spec.DuraMs) * time.Millisecond
	}
	switch {
	case spec.HasHste:
		if bk.speedHolder == 0 {
			rec.Contributions = append(rec.Contributions, speedPair(spec.Hste)...)
		}
		bk.speedHolder = rec.Token
	case spec.HasHst2:
		if j := bk.index(bk.speedHolder); j >= 0 {
			h := &bk.records[j]
			h.Contributions = withoutSpeed(h.Contributions)
		}
		rec.Contributions = append(rec.Contributions, speedPair(spec.Hst2)...)
		if bk.speedHolder == 0 {
			bk.speedHolder = rec.Token
		}
	case spec.HasHst3:
		rec.Contributions = append(rec.Contributions, speedPair(spec.Hst3)...)
	}
	bk.records = append(bk.records, rec)
	after := b.speedLocked(bk)
	return rec, ended, NotRefused, Speed{RunSpeed: after, Changed: after != before}
}

// DueOwners returns the owners with a record past its end at now.
func (b *Books) DueOwners(now time.Time) []int64 {
	b.mu.Lock()
	defer b.mu.Unlock()
	var out []int64
	for owner, bk := range b.books {
		for _, r := range bk.records {
			if r.Expired(now) {
				out = append(out, owner)
				break
			}
		}
	}
	return out
}

// ExpireOwner ends every record of ownerID past its end at now.
func (b *Books) ExpireOwner(ownerID int64, now time.Time) ([]Record, Speed) {
	return b.endWhere(ownerID, func(r Record) bool { return r.Expired(now) })
}

// Expire ends every record past its end at now, by owner.
func (b *Books) Expire(now time.Time) map[int64][]Record {
	var out map[int64][]Record
	for _, owner := range b.DueOwners(now) {
		if ended, _ := b.ExpireOwner(owner, now); len(ended) > 0 {
			if out == nil {
				out = map[int64][]Record{}
			}
			out[owner] = ended
		}
	}
	return out
}

// endWhere ends ownerID's records matching end, in book order.
func (b *Books) endWhere(ownerID int64, end func(Record) bool) ([]Record, Speed) {
	b.mu.Lock()
	defer b.mu.Unlock()
	bk := b.books[ownerID]
	if bk == nil {
		return nil, Speed{RunSpeed: b.speedLocked(nil)}
	}
	before := b.speedLocked(bk)
	var ended []Record
	for i := 0; i < len(bk.records); {
		if r := bk.records[i]; end(r) {
			bk.records = append(bk.records[:i], bk.records[i+1:]...)
			bk.endLocked(r)
			ended = append(ended, r)
			continue
		}
		i++
	}
	after := b.speedLocked(bk)
	if len(bk.records) == 0 && bk.speedHolder == 0 {
		delete(b.books, ownerID)
	}
	return ended, Speed{RunSpeed: after, Changed: after != before}
}

// CancelResult is what Cancel did.
type CancelResult int

const (
	// Cancelled: the record ended.
	Cancelled CancelResult = iota
	// CancelNotFound: no active record of that skill (and token).
	CancelNotFound
	// CancelRefusedNbuf: the skill carries 'nbuf' and the record is not the
	// owner's own cast -- FUN_0059eff0 returns without ending it.
	CancelRefusedNbuf
)

// Cancel is the dispel: the first active record of skillID on ownerID
// (matching token unless it is 0) ends, unless the 'nbuf' rule refuses.
func (b *Books) Cancel(ownerID, skillID int64, token uint32) (Record, CancelResult, Speed) {
	b.mu.Lock()
	bk := b.books[ownerID]
	var found *Record
	if bk != nil {
		for i := range bk.records {
			r := bk.records[i]
			if r.SkillID == skillID && (token == 0 || r.Token == token) {
				found = &r
				break
			}
		}
	}
	b.mu.Unlock()
	if found == nil {
		return Record{}, CancelNotFound, Speed{}
	}
	if found.Nbuf && !found.SelfCast() {
		return *found, CancelRefusedNbuf, Speed{}
	}
	tok := found.Token
	ended, sp := b.endWhere(ownerID, func(r Record) bool { return r.Token == tok })
	if len(ended) != 1 {
		return Record{}, CancelNotFound, Speed{}
	}
	return ended[0], Cancelled, sp
}

// EndAll ends every record of ownerID and forgets its book.
func (b *Books) EndAll(ownerID int64) ([]Record, Speed) {
	b.mu.Lock()
	defer b.mu.Unlock()
	bk := b.books[ownerID]
	if bk == nil {
		return nil, Speed{RunSpeed: b.speedLocked(nil)}
	}
	before := b.speedLocked(bk)
	delete(b.books, ownerID)
	after := b.speedLocked(nil)
	return append([]Record(nil), bk.records...), Speed{RunSpeed: after, Changed: after != before}
}

// Active returns ownerID's records, oldest first.
func (b *Books) Active(ownerID int64) []Record {
	b.mu.Lock()
	defer b.mu.Unlock()
	bk := b.books[ownerID]
	if bk == nil {
		return nil
	}
	out := append([]Record(nil), bk.records...)
	sort.SliceStable(out, func(i, j int) bool { return out[i].Start.Before(out[j].Start) })
	return out
}

// RunSpeed is ownerID's run speed through its active contributions to param
// 24, rounded to the nearest unit for the wire (OURS: the engine keeps a
// float).
func (b *Books) RunSpeed(ownerID int64) uint32 {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.speedLocked(b.books[ownerID])
}

// Contributes reports whether any of recs wrote a run-speed contribution.
func Contributes(recs ...Record) bool {
	for _, r := range recs {
		for _, c := range r.Contributions {
			if c.Param == ParamRunSpeed {
				return true
			}
		}
	}
	return false
}
