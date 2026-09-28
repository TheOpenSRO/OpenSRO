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
//     greater (skillparam.BuffEndsAt). The extension ctx+0x24 is 0 here
//     (nothing srrevamp builds sets it; OPEN what does in retail).
//   - The END effects: SkillBook::Update (0x59bb80) erases the record,
//     removes its contributions (ParamKeeper_RemoveContributionsOf, 0x4b3660,
//     keyed by the record) and queues its token for 0xB072.
//   - The RECAST rule, Skill_CheckUseConditions (0x58d8f0) row 16 at 0x58e2fd
//     -> FUN_0059d870, for an action-kind-3 skill: for each active record whose
//     skill is kind 3 without 'cbuf' (+0x358), a record of the SAME GroupID
//     (+0x8) refuses the cast with 0x300c SKILL_USE_FAIL_OVERLAP when the new
//     row's Basic_Level (+0x64) is LOWER than the active one's; otherwise the
//     active record's end flag (+0x10) is cleared -- it ends -- and the cast
//     goes ahead. See Book.Start.
//   - The DISPEL, 0x4ae520 -> FUN_0059ef90 / FUN_0059eff0: the record of that
//     skill id (in sub-state 1 or 2), matching the token when one is given
//     (token 0 matches any); a skill carrying 'nbuf' (+0x35c) whose record's
//     ctx+0x20 is not 1 is refused silently. ctx+0x20 is 1 when the record's
//     target is its own caster (SkillAction_Buff writes 1 at 0x5830b0's
//     `puVar8 == param_2` store and 2 for another target) -- so an 'nbuf'
//     buff someone else cast on you cannot be cancelled. See Book.Cancel.
//   - The run-speed writes: ApplySkillParamsToChar (0x594ac0) writes 'hste'
//     value[0] into params 23 and 24 at slot 2 ONLY while the character's
//     speed holder (pc+0xc24) is empty, and then makes this record the holder
//     either way; SkillAction_BuffEnd (0x5829d0) empties the holder when an
//     'hste' record ends (its `book[0x7d] = 0`, book = pc+0xa30, so pc+0xc24).
//     'hst3' is written, value[0] into 23 and 24 at slot 2, only by a row that
//     carries neither 'hste' nor 'hst2'. Slot 2 reduces as the product of
//     (1 + e/100) (GParamKeeper FUN_004b2e60).
//
// OURS, disclosed: the record's shape, the token allocator (a server-wide
// counter), and that only 'hste' and 'hst3' contributions are recorded --
// they are the only ones something in srrevamp consumes (the run speed). The
// other publishing codes are listed OPEN in docs/protocol/skill_buffs.md.
package buff

import (
	"math"
	"sort"
	"sync"
	"sync/atomic"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/skillparam"
)

// The run-speed params, 'hste'/'hst3' publish both (skillparam.Contributions).
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
	// Hste and Hst3 are the rows' 'hste'/'hst3' value[0], with HasHste /
	// HasHst3 / HasHst2 saying whether the row carries each run at all.
	Hste, Hst3                int
	HasHste, HasHst3, HasHst2 bool
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
	// HasHste marks a record whose end empties the speed holder.
	HasHste       bool
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

// SpeedFactor is the slot-2 product the record contributes to param p.
func (r Record) speedFactor(p int) float64 {
	f := 1.0
	for _, c := range r.Contributions {
		if c.Param == p && c.Slot == skillparam.SlotMult {
			f *= 1 + c.Value/100
		}
	}
	return f
}

type book struct {
	records []Record
	// speedHolder is pc+0xc24, the token of the 'hste' record that holds the
	// speed writes; 0 when empty.
	speedHolder uint32
}

// Books holds every character's book.
type Books struct {
	mu    sync.Mutex
	next  atomic.Uint32
	books map[int64]*book
}

// NewBooks returns an empty set of books.
func NewBooks() *Books { return &Books{books: map[int64]*book{}} }

// NextToken allocates a server-unique token, never 0 (0 means "any" in a
// cancel). OURS.
func (b *Books) NextToken() uint32 {
	for {
		if t := b.next.Add(1); t != 0 {
			return t
		}
	}
}

// Refusal is why Start refused.
type Refusal int

const (
	// NotRefused: the buff started.
	NotRefused Refusal = iota
	// RefusedOverlap is 0x300c SKILL_USE_FAIL_OVERLAP: an active record of
	// the same GroupID is of a higher level.
	RefusedOverlap
)

// CheckOverlap is the gate's half of the recast rule, run BEFORE anything is
// spent (the gate precedes EngageSkill): whether a cast of spec on owner
// would be refused. Start applies the same rule.
func (b *Books) CheckOverlap(ownerID int64, spec Spec) Refusal {
	b.mu.Lock()
	defer b.mu.Unlock()
	bk := b.books[ownerID]
	if bk == nil {
		return NotRefused
	}
	for _, r := range bk.records {
		if !r.Cbuf && r.GroupID == spec.GroupID && spec.Level < r.Level {
			return RefusedOverlap
		}
	}
	return NotRefused
}

// Start applies spec to ownerID at now. It returns the new record, the
// records the recast rule ended (same GroupID, not 'cbuf', level not above
// the new one's), and a refusal when an active record of the same GroupID is
// of a higher level -- nothing changes then.
func (b *Books) Start(ownerID int64, spec Spec, now time.Time) (rec Record, ended []Record, refused Refusal) {
	b.mu.Lock()
	defer b.mu.Unlock()
	bk := b.books[ownerID]
	if bk == nil {
		bk = &book{}
		b.books[ownerID] = bk
	}
	for _, r := range bk.records {
		if !r.Cbuf && r.GroupID == spec.GroupID && spec.Level < r.Level {
			return Record{}, nil, RefusedOverlap
		}
	}
	kept := bk.records[:0]
	for _, r := range bk.records {
		if !r.Cbuf && r.GroupID == spec.GroupID {
			bk.endLocked(r)
			ended = append(ended, r)
			continue
		}
		kept = append(kept, r)
	}
	bk.records = kept

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
		HasHste:  spec.HasHste,
	}
	if spec.DuraMs > 0 {
		rec.Dura = time.Duration(spec.DuraMs) * time.Millisecond
	}
	switch {
	case spec.HasHste:
		if bk.speedHolder == 0 {
			v := float64(spec.Hste)
			rec.Contributions = append(rec.Contributions,
				Contribution{ParamWalkSpeed, skillparam.SlotMult, v},
				Contribution{ParamRunSpeed, skillparam.SlotMult, v})
		}
		bk.speedHolder = rec.Token
	case !spec.HasHst2 && spec.HasHst3:
		v := float64(spec.Hst3)
		rec.Contributions = append(rec.Contributions,
			Contribution{ParamWalkSpeed, skillparam.SlotMult, v},
			Contribution{ParamRunSpeed, skillparam.SlotMult, v})
	}
	bk.records = append(bk.records, rec)
	return rec, ended, NotRefused
}

// endLocked is SkillAction_BuffEnd's speed-holder step for r.
func (bk *book) endLocked(r Record) {
	if r.HasHste {
		bk.speedHolder = 0
	}
}

// Expire ends every record past its end at now, by owner.
func (b *Books) Expire(now time.Time) map[int64][]Record {
	b.mu.Lock()
	defer b.mu.Unlock()
	var out map[int64][]Record
	for owner, bk := range b.books {
		kept := bk.records[:0]
		for _, r := range bk.records {
			if r.Expired(now) {
				bk.endLocked(r)
				if out == nil {
					out = map[int64][]Record{}
				}
				out[owner] = append(out[owner], r)
				continue
			}
			kept = append(kept, r)
		}
		bk.records = kept
		if len(bk.records) == 0 && bk.speedHolder == 0 {
			delete(b.books, owner)
		}
	}
	return out
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
func (b *Books) Cancel(ownerID, skillID int64, token uint32) (Record, CancelResult) {
	b.mu.Lock()
	defer b.mu.Unlock()
	bk := b.books[ownerID]
	if bk == nil {
		return Record{}, CancelNotFound
	}
	for i, r := range bk.records {
		if r.SkillID != skillID || (token != 0 && r.Token != token) {
			continue
		}
		if r.Nbuf && !r.SelfCast() {
			return r, CancelRefusedNbuf
		}
		bk.endLocked(r)
		bk.records = append(bk.records[:i], bk.records[i+1:]...)
		return r, Cancelled
	}
	return Record{}, CancelNotFound
}

// EndAll ends every record of ownerID and forgets its book.
func (b *Books) EndAll(ownerID int64) []Record {
	b.mu.Lock()
	defer b.mu.Unlock()
	bk := b.books[ownerID]
	if bk == nil {
		return nil
	}
	delete(b.books, ownerID)
	return append([]Record(nil), bk.records...)
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

// Factor is the slot-2 product of every active contribution to param p on
// ownerID: param = base x Factor (slots 0, 1 and 3 carry nothing from a buff
// srrevamp records).
func (b *Books) Factor(ownerID int64, p int) float64 {
	b.mu.Lock()
	defer b.mu.Unlock()
	bk := b.books[ownerID]
	f := 1.0
	if bk == nil {
		return f
	}
	for _, r := range bk.records {
		f *= r.speedFactor(p)
	}
	return f
}

// RunSpeed is ownerID's run speed from base (characterdata Speed2) through
// its active contributions to param 24, rounded to the nearest unit for the
// wire (OURS: the engine keeps a float).
func (b *Books) RunSpeed(ownerID int64, base float64) uint32 {
	return uint32(math.Round(base * b.Factor(ownerID, ParamRunSpeed)))
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
