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
//     FUN_0059d870 for a row with no 'lnks' (+0x370) and Target_Required
//     (+0x94) 0, and the target test FUN_0058cc70 calls it on each target's
//     book for a Target_Required 1 row. Round 636 read it in full: its
//     'dttp', 'efr' kind-2 and GroupID branches, and the book's state bit set
//     (SkillBook::SetGroupBits 0x59dc00, tested by FUN_0059db10) that
//     Action_Overlap and 'ovl2' fill -- see overlapLocked. The category end
//     FUN_005a16c0 is EndCategory.
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
	// The rest of what FUN_0059d870 reads (round 636, see overlapLocked):
	// ActionOverlap is Action_Overlap (+0x8c) AND 0xffffff -- its three low
	// bytes, the state bits the book's bit set holds; Ovl2 is 'ovl2' value[0]
	// (+0x37c); HasDttp/Dttp0/Dttp1 'dttp' (+0x424); Efr2 an 'efr' of kind 2
	// (+0x290); Offensive FUN_00589d20's answer; Msch1 'msch' value[0] == 1
	// (+0x4a4); Dtt 'dtt' (+0x420); BasicGroup Basic_Group (+0x44).
	ActionOverlap uint32
	Ovl2          uint32
	HasDttp       bool
	Dttp0, Dttp1  uint32
	Efr2          bool
	Offensive     bool
	Msch1         bool
	Dtt           bool
	BasicGroup    string
	// Activity is Basic_Activity (+0x65) and SkcEnd 'skc' value[1]'s low
	// byte (+0x490 -> +4): the category end FUN_005a16c0 reads both.
	Activity int
	SkcEnd   uint8
	// What FUN_0059dc80 reads (the review of round 636, see linkLocked):
	// LnksGroup and LnksMax are 'lnks' value[0] and value[2] (+0x370 -> +0
	// and +8); Efr3 an 'efr' of kind 3 (+0x294), which gate row 16 requires
	// before it calls FUN_0059dc80 for an 'lnks' row (0x58e308); Qest and
	// Trap are 'qest' (+0x49c) and 'trap' (+0x4a0), which pick 0x3037 over
	// 0x3029.
	LnksGroup, LnksMax uint32
	Efr3, Qest, Trap   bool
	// Efr1 is an 'efr' of kind 1 (+0x28c): with Activity != 1 SkillAction_Buff's
	// sub-state 0 takes the target-collector path, which charges before any bit
	// test (see CheckEngage).
	Efr1 bool
	// The toggle and the protection wall (round 640, walls.go):
	// HasOnff/OnffMs/OnffMP are 'onff' (+0x284) value[0] (the drain
	// interval, ms) and value[1] (the MP each drain takes); Wall is 'pw'
	// (+0x2b4), HasWall whether the row carries it.
	HasOnff        bool
	OnffMs, OnffMP int
	HasWall        bool
	Wall           Wall
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
	// The row's recast-rule fields (round 636), copied from its Spec: what
	// FUN_0059d870 reads off an ACTIVE record's skill, and what
	// SkillAction_BuffEnd clears from the book's bit set.
	ActionOverlap uint32
	Ovl2          uint32
	HasDttp       bool
	Dttp0, Dttp1  uint32
	Efr2          bool
	Offensive     bool
	Dtt           bool
	BasicGroup    string
	Activity      int
	SkcEnd        uint8
	// FUN_0059dc80's fields (see linkLocked): the row's 'lnks' value[0] and
	// 'lks2', whether the record carries retail's link struct (ctx+0x68), and
	// the struct's linked object id (+0x10) -- always 0 here: srrevamp
	// creates no object for an 'efr' kind-3 row.
	LnksGroup    uint32
	Lks2         bool
	Linked       bool
	LinkedObject int64
	// LinkSource is a record a Target_Required 1 'lnks' row put on another
	// character: its caster holds a link for it (Books.links) until it ends.
	LinkSource bool
	// The toggle (round 640): 'onff' and when its MP was last taken --
	// EngageSkill (0x593540) stamps GetTickCount into ctx+0x60 +8 at the
	// engage, and SkillAction_Buff's sub-state 2 re-stamps it at each drain.
	HasOnff        bool
	OnffMs, OnffMP int
	LastDrain      time.Time
	// The protection wall (round 640): the row's 'pw' and the HP left in the
	// wall object EngageSkill builds at ctx+0x5c (+8 = 'pw' value[1]).
	HasWall bool
	Wall    Wall
	WallHP  int
}

// Wall is a row's 'pw' (+0x2b4), READ (docs/protocol/skill_buffs.md "The
// protection walls"): Mask the damage types it covers (bit 4 physical, bit
// 8 magical), HP its hit points, Def and DefPct the flat defence and the
// defence percent the absorbed blow is mitigated by in place of the
// caster's own params 5 and 7.
type Wall struct {
	Mask   uint32
	HP     int
	Def    int
	DefPct int
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

// attached is whether the record carries the attached object FUN_0059d870's
// 'efr' kind-2 branch looks up (ctx+0x6c). SkillAction_Buff (0x5830b0)
// builds it on the record it registers for an 'efr' kind-2 row without
// 'dtt' (`puVar12[0xa4] != 0 && puVar12[0x108] == 0`) and stores the
// CASTER's id at its +0x10 (`= param_2[2]`) -- READ. That record is the
// caster's own (registered through the caster's book, +0x1d8); a record
// srrevamp builds on another character's book carries none (INFERRED: the
// target records are built by the other branches, which do not write
// ctx+0x6c).
func (r Record) attached() bool { return r.Efr2 && !r.Dtt && r.SelfCast() }

// engageBits is what SkillAction_Buff's sub-state 1 (0x5830b0, READ) sets in
// the book's bit set when the record engages, besides 'ovl2' value[0]:
// nothing for an 'lnks' row cast on oneself (it calls FUN_0059aff0
// instead); for a record on another character ('ctx+0x20 == 2') 'ovl2'
// value[0] when the row has one, else nothing when it has 'dttp'; otherwise
// Action_Overlap.
func engageBits(spec Spec, self bool) uint32 {
	if spec.Lnks && self {
		return 0
	}
	if !self {
		if spec.Ovl2 != 0 {
			return spec.Ovl2
		}
		if spec.HasDttp {
			return 0
		}
	}
	return spec.ActionOverlap
}

// endBits is what SkillAction_BuffEnd (0x5829d0, READ) clears, besides
// 'ovl2' value[0]: local_18 starts as Action_Overlap; a record carrying the
// 'lnks' link struct (ctx+0x68, which SkillAction_Buff builds for every
// 'lnks' row) that is not a record on another character zeroes it; a record
// on another character ('ctx+0x20 == 2') whose row has 'ovl2' clears 'ovl2'
// value[0] instead.
func (r Record) endBits() uint32 {
	if r.Lnks && r.SelfCast() {
		return 0
	}
	if !r.SelfCast() && r.Ovl2 != 0 {
		return r.Ovl2
	}
	return r.ActionOverlap
}

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
	// bits is the book's state bit set at book+0x1b0 (pc+0xbe0), four
	// 64-bit words indexed by a byte value (READ, round 636):
	// SkillBook::SetGroupBits (0x59dc00) sets or clears the bit of each
	// non-zero byte among a mask's three low bytes, and FUN_0059db10 tests
	// them. It is not reference-counted: clearing a bit clears it whoever
	// else set it, as retail's does.
	bits [4]uint64
	// wallHolder is book+0x1dc (pc+0xc0c, `in_EAX[0x303]`), the token of the
	// record whose wall the owner's blows meet (round 640): EngageSkill writes
	// it for a 'pw' row, SkillAction_BuffEnd and the wall's break clear it.
	// 0 when none.
	wallHolder uint32
}

// setGroupBits is SkillBook::SetGroupBits (0x59dc00): for each of the three
// low bytes of mask (shifts 0, 8, 16) that is not 0, set its bit, or clear
// it when clear is true.
func (bk *book) setGroupBits(mask uint32, clear bool) {
	for sh := 0; sh < 24; sh += 8 {
		b := byte(mask >> sh)
		if b == 0 {
			continue
		}
		if clear {
			bk.bits[b>>6] &^= 1 << (b & 63)
		} else {
			bk.bits[b>>6] |= 1 << (b & 63)
		}
	}
}

// bitsHit is FUN_0059db10's test against the bit set (READ): for each of
// mask's three low bytes other than 0, 0x1d and 0x23, whether its bit is
// set. The function also answers 1 when the byte appears among the RUNNING
// action's Action_Overlap / 'ovl2' bytes (book+0x1d8, a buff between its
// cast and its engage); srrevamp engages a buff at its cast and keeps no
// running action, so that half has nothing to test.
func (bk *book) bitsHit(mask uint32) bool {
	for sh := 0; sh < 24; sh += 8 {
		b := byte(mask >> sh)
		if b == 0 || b == 0x1d || b == 0x23 {
			continue
		}
		if bk.bits[b>>6]&(1<<(b&63)) != 0 {
			return true
		}
	}
	return false
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

// endLocked is SkillAction_BuffEnd's speed-holder and bit-set steps for r,
// which has already left bk.records.
func (bk *book) endLocked(r Record) {
	bk.setGroupBits(r.endBits(), true)
	bk.setGroupBits(r.Ovl2, true)
	// SkillAction_BuffEnd (0x5829d0): a 'pw' row's end writes 0 into
	// book[0x77] -- whichever record held it (READ: no comparison).
	if r.HasWall {
		bk.wallHolder = 0
	}
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
	// gmSpeed is the GM console's /speed multiplier per owner (OURS).
	gmSpeed map[int64]float64
	// links are each caster's link records (linkEntry), by caster.
	links map[int64][]linkEntry
}

// NewBooks returns an empty set of books whose owners run at baseRunSpeed.
func NewBooks(baseRunSpeed float64) *Books {
	return &Books{books: map[int64]*book{}, base: baseRunSpeed, gmSpeed: map[int64]float64{}, links: map[int64][]linkEntry{}}
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

func (b *Books) speedLocked(ownerID int64, bk *book) uint32 {
	f := 1.0
	if bk != nil {
		f = bk.factor(ParamRunSpeed)
	}
	if g, ok := b.gmSpeed[ownerID]; ok {
		f *= g
	}
	return uint32(math.Round(b.base * f))
}

// MaxGMSpeedFactor bounds /speed (OURS, a test tool).
const MaxGMSpeedFactor = 10.0

// SetGMSpeedFactor is the GM console's /speed (OURS, a test tool; no retail
// counterpart, and nothing retail-shaped is claimed for it): a multiplier on
// ownerID's run speed on top of its buffs, kept outside the book so a death
// (EndAll) leaves it; the session layer clears it when the character leaves
// the world (round 636's review). 1, or a factor <= 0, clears it. It
// returns the owner's run speed afterwards, Changed when it moved.
func (b *Books) SetGMSpeedFactor(ownerID int64, f float64) Speed {
	b.mu.Lock()
	defer b.mu.Unlock()
	before := b.speedLocked(ownerID, b.books[ownerID])
	if f <= 0 || f == 1 {
		delete(b.gmSpeed, ownerID)
	} else {
		if f > MaxGMSpeedFactor {
			f = MaxGMSpeedFactor
		}
		b.gmSpeed[ownerID] = f
	}
	after := b.speedLocked(ownerID, b.books[ownerID])
	return Speed{RunSpeed: after, Changed: after != before}
}

// GMSpeedFactor is ownerID's /speed multiplier and whether one is set.
func (b *Books) GMSpeedFactor(ownerID int64) (float64, bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	f, ok := b.gmSpeed[ownerID]
	return f, ok
}

// Refusal is why Start refused.
type Refusal int

const (
	// NotRefused: the buff started.
	NotRefused Refusal = iota
	// RefusedOverlap is 0x300c SKILL_USE_FAIL_OVERLAP.
	RefusedOverlap
	// RefusedOverlapCount is 0x3029 UIIT_STT_SKILL_USE_FAIL_OVERLAP_COUNT,
	// FUN_0059dc80's count reaching 'lnks' value[2].
	RefusedOverlapCount
	// RefusedTrapExists is 0x3037 UIIT_MSG_QUEST_ERR_CANNOT_MAKE_TRAP: the
	// same count, for a row carrying both 'qest' and 'trap'.
	RefusedTrapExists
	// RefusedSilent is SkillAction_Buff sub-state 0's bit test on the caster's
	// book (0x583ffb..0x584044, READ): an 'ovl2' or Action_Overlap byte set.
	// Retail ends the action with 0xB071 kind 2 and error 0 BEFORE the costs
	// are taken (vslot 0x308 runs only on the other path), and the client's
	// kind-2 handler (FUN_00a56680 -> FUN_00a50a00) ends the cast without a
	// refusal text. See CheckEngage.
	RefusedSilent
	// RefusedEngage is sub-state 1's test (the engage): Action_Overlap set on
	// the owner's book. Retail has taken the costs by then and has sent the
	// cast's success; the buff just does not start.
	RefusedEngage
)

// linkEntry is the second record retail's Target_Required 1 branch of
// SkillAction_Buff builds for the CASTER of an 'lnks' row cast on another
// character (0x5830b0, READ: a record with the link struct at ctx+0x68,
// +0xc the caster's id, +0x10 the target's id; ctx+0x20 FUN_005a9ae0's
// default 1). srrevamp keeps it out of the caster's visible book (OURS: no
// icon, no bits -- an 'lnks' record cast on oneself sets none, READ) and
// ends it with the target's record (INFERRED); FUN_0059dc80 counts it.
type linkEntry struct {
	SkillID     int64
	LnksGroup   uint32
	Lks2        bool
	Activity    int
	Object      int64
	Owner       int64
	TargetToken uint32
}

// linked is whether a record of spec that ownerID holds carries retail's
// 'lnks' link struct (ctx+0x68) with its ctx+0x20 == 1 -- the records
// FUN_0059dc80 counts. SkillAction_Buff (0x5830b0) builds that struct in two
// places (READ): the 'efr' kind-3 branch (a Target_Required 0 row, whose
// record is the caster's own; ctx+0x20 keeps FUN_005a9ae0's default 1), with
// +0x10 the id of the object that branch creates; and the Target_Required 1
// branch, as a second record for the caster whose +0x10 is the target's id.
// srrevamp creates no object: the first is the 'lnks' + 'efr' kind-3 row's
// own record, cast by its owner (INFERRED that srrevamp's record stands for
// retail's link record; retail's also ends when the object goes, which is
// OPEN here); the second is a linkEntry (Books.links).
func linked(spec Spec, ownerID int64) bool {
	return spec.Lnks && spec.Efr3 && spec.CasterID == ownerID
}

// linkGateApplies is gate row 16's call of FUN_0059dc80 (0x58e2db..0x58e324,
// READ): a row with 'lnks' (+0x370) and an 'efr' of kind 3 (+0x294), with 0
// as the linked object. Its other caller is linkTargetApplies.
func linkGateApplies(spec Spec) bool {
	return spec.Lnks && !spec.TargetRequired && spec.Efr3
}

// linkTargetApplies is the target test's call of FUN_0059dc80
// (FUN_0058cc70, 0x58d27d..0x58d2a6, READ): every 'lnks' row, on the
// CASTER's book, with the target as the linked object, before the target's
// FUN_0059d870 (0x58d2d3).
func linkTargetApplies(spec Spec) bool {
	return spec.Lnks && spec.TargetRequired
}

// linkLocked is FUN_0059dc80 (READ, asm 0x59dc80..0x59dde2; EAX the book, EBX
// the new row, the stack argument the linked object -- 0 from the gate). It
// walks the book's list (book+0x268) and considers a record only when its
// skill has a non-zero Basic_Activity (+0x65), its ctx+0x20 is 1 and it
// carries the link struct (ctx+0x68), and its 'lnks' value[0] equals the new
// row's. For such a record:
//
//   - the same skill id (+4): with neither row carrying 'lks2' (+0x374) the
//     record is counted (0x59dd72), unless the object argument names the
//     record's linked object (link+0x10), which refuses 0x300c; with both
//     carrying it, that same match refuses 0x300c and nothing is counted;
//     with only one carrying it, nothing is counted;
//   - another skill id: with neither carrying 'lks2', a non-zero 'lnks'
//     value[0] refuses 0x300c at once (0x59dda3..0x59ddae); with both
//     carrying it, a match on the linked object is counted; otherwise the
//     record is passed over.
//
// After each record that reaches the count (0x59dd77), a non-zero 'lnks'
// value[2] equal to the count refuses: 0x3037 when the row carries both
// 'qest' (+0x49c) and 'trap' (+0x4a0), else 0x3029. The gate passes no
// object (linkedID 0 is "none"); the target test passes the target, which a
// caster's link entry names.
func linkLocked(bk *book, links []linkEntry, spec Spec, linkedID int64) Refusal {
	var cands []linkEntry
	if bk != nil {
		for _, r := range bk.records {
			if r.SelfCast() && r.Linked {
				cands = append(cands, linkEntry{SkillID: r.SkillID, LnksGroup: r.LnksGroup, Lks2: r.Lks2,
					Activity: r.Activity, Object: r.LinkedObject})
			}
		}
	}
	// The caster's link records follow its own records (INFERRED order:
	// retail registers each after the cast that made it).
	cands = append(cands, links...)
	count := uint32(0)
	for _, r := range cands {
		if r.Activity == 0 || r.LnksGroup != spec.LnksGroup {
			continue
		}
		match := linkedID != 0 && linkedID == r.Object
		if r.SkillID == spec.SkillID {
			switch {
			case !spec.Lks2 && !r.Lks2:
				if match {
					return RefusedOverlap
				}
				count++
			case spec.Lks2 && r.Lks2:
				if match {
					return RefusedOverlap
				}
			}
		} else {
			switch {
			case !spec.Lks2 && !r.Lks2:
				if r.LnksGroup != 0 {
					return RefusedOverlap
				}
				continue
			case spec.Lks2 && r.Lks2:
				if match {
					count++
				}
			default:
				continue
			}
		}
		if spec.LnksMax != 0 && count == spec.LnksMax {
			if spec.Qest && spec.Trap {
				return RefusedTrapExists
			}
			return RefusedOverlapCount
		}
	}
	return NotRefused
}

// overlapLocked is FUN_0059d870 (READ in full in round 636; asm
// 0x59d870..0x59db06). It is reached two ways:
//
//   - gate row 16 (0x58e2fd), on the CASTER's book, for a row with no 'lnks'
//     and Target_Required 0 (a row with 'lnks' calls FUN_0059dc80 there
//     instead -- see below);
//   - the target test FUN_0058cc70, on each TARGET's book (0x58d2ca..0x58d2d3,
//     `push caster; push skill; lea ecx,[target+0xa30]; call 0x59d870`, a 0
//     answer refusing 0x300c) -- every Target_Required 1 row, 'lnks' or not.
//     The one skip (0x58d2ac..0x58d2c8): the target is the caster and the
//     caster's running action (+0xc08 -> +0x18 -> +8) is this very skill;
//     srrevamp keeps no running action, so it never applies.
//
// It returns the records the cast ends (none, one, or -- the 'efr' kind-2
// branch -- the record and the caster's record of its skill, usually the
// same one) and a refusal.
//
// When the new row is action kind 3 and not 'msch' value[0] == 1 (+0x4a4),
// it walks the book's records in order (the retail list's order is INFERRED
// to be insertion order) and passes over every record whose skill is not
// kind 3 or carries 'cbuf' (+0x358). For each other record, the first branch
// that applies:
//
//  1. 'dttp' (+0x424) on both rows with the same value[0]: when the caster is
//     the book's owner (`*book == caster`, 0x59d937) the cast is allowed at
//     once and nothing ends; otherwise a record its owner cast on itself
//     (ctx+0x20 == 1) is passed over, a lower value[1] (unsigned, `jb`) is
//     refused, and an equal or higher one ends that record.
//  2. 'efr' kind 2 (+0x290) on the new row and FUN_00589d20 (the "offensive"
//     test) answering 0 for it: the record ends -- together with the record
//     of its skill on the object its ctx+0x6c names -- when it has the same
//     Basic_Group string (+0x44, FUN_00425210), a Basic_Level not above the
//     new one, 'efr' kind 2 itself, FUN_00589d20 0, and that attached object
//     (Record.attached); otherwise it is passed over. The GroupID branch is
//     NOT tried for such a row.
//  3. the GroupID branch: the new row carries no 'lks2' (+0x374), the record
//     is not an 'lnks' record its owner cast on itself (`old+0x370 == 0 ||
//     ctx+0x20 != 1`), the new GroupID (+0x8) is not 0 and equals the
//     record's -> refused when the new Basic_Level (+0x64, unsigned byte) is
//     lower, otherwise the record ends and the cast goes ahead.
//
// A record that ends here has its end flag (+0x10) cleared and goes at the
// next book update (INFERRED to precede the new record's engage).
//
// Falling off the list -- or for any other row -- the cast is refused when
// FUN_0059db10 finds one of 'ovl2' value[0]'s bytes, or of Action_Overlap's,
// set in the book's bit set (bitsHit). This is what keeps a second Fire
// Protection off (its records carry 'cbuf', so the list passes them over,
// and every FIRE_GANGGI row carries overlap byte 3) and what refuses Grass
// Walk - Speed while Grass Walk - Flow runs (groups 260 and 262 differ; both
// carry byte 6) -- MEASURED on the retail rows, docs/protocol/skill_buffs.md.
//
// Both calls of FUN_0059dc80 -- the gate's and the target test's -- are
// linkLocked (gateLocked).
func overlapLocked(bk *book, ownerID int64, spec Spec) ([]int, Refusal) {
	if bk == nil {
		return nil, NotRefused
	}
	if !spec.Msch1 {
		for i, r := range bk.records {
			if r.Cbuf {
				continue
			}
			// 1. 'dttp'.
			if spec.HasDttp && r.HasDttp && spec.Dttp0 == r.Dttp0 {
				if spec.CasterID == ownerID {
					return nil, NotRefused
				}
				if r.SelfCast() {
					continue
				}
				if spec.Dttp1 < r.Dttp1 {
					return nil, RefusedOverlap
				}
				return []int{i}, NotRefused
			}
			// 2. 'efr' kind 2.
			if spec.Efr2 && !spec.Offensive {
				if r.BasicGroup != spec.BasicGroup || spec.Level < r.Level || !r.Efr2 || r.Offensive || !r.attached() {
					continue
				}
				// FUN_0059ef90 on the attached object's book: its first
				// record of the old skill (the object is r's caster, whose
				// book this is when r is attached).
				ends := []int{i}
				for j, o := range bk.records {
					if o.SkillID == r.SkillID {
						if j != i {
							ends = append(ends, j)
						}
						break
					}
				}
				return ends, NotRefused
			}
			// 3. GroupID.
			if !spec.Lks2 && !(r.Lnks && r.SelfCast()) && spec.GroupID != 0 && spec.GroupID == r.GroupID {
				if spec.Level < r.Level {
					return nil, RefusedOverlap
				}
				return []int{i}, NotRefused
			}
		}
	}
	if spec.Ovl2 != 0 && bk.bitsHit(spec.Ovl2) {
		return nil, RefusedOverlap
	}
	if bk.bitsHit(spec.ActionOverlap) {
		return nil, RefusedOverlap
	}
	return nil, NotRefused
}

// gateApplies is whether a cast of spec meets FUN_0059d870 at all: gate row
// 16 calls it for a row with no 'lnks' and Target_Required 0; the target
// test calls it for every Target_Required 1 row. A Target_Required 0 row with
// 'lnks' meets FUN_0059dc80 instead when it carries an 'efr' of kind 3
// (linkGateApplies), and no check at all otherwise (0x58e308 -> 0x58e32d).
func gateApplies(spec Spec) bool {
	return !(spec.Lnks && !spec.TargetRequired)
}

// CheckOverlap is the gate's half of the recast rule, run BEFORE anything is
// spent (the gate precedes EngageSkill): whether a cast of spec on owner
// would be refused. Start applies the same rule.
func (b *Books) CheckOverlap(ownerID int64, spec Spec) Refusal {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.gateLocked(ownerID, spec)
}

// gateLocked is the request's recast checks: FUN_0059dc80 then
// FUN_0059d870, as gate row 16 and the target test call them.
func (b *Books) gateLocked(ownerID int64, spec Spec) Refusal {
	if linkGateApplies(spec) {
		return linkLocked(b.books[ownerID], b.links[ownerID], spec, 0)
	}
	if linkTargetApplies(spec) {
		if r := linkLocked(b.books[spec.CasterID], b.links[spec.CasterID], spec, ownerID); r != NotRefused {
			return r
		}
	}
	if !gateApplies(spec) {
		return NotRefused
	}
	_, r := overlapLocked(b.books[ownerID], ownerID, spec)
	return r
}

// CheckEngage is SkillAction_Buff's sub-state 0 bit test (0x583ffb..0x584044,
// READ), run on the CASTER's book (EDI = param_2 + 0xa30, the acting
// character) after the casting time and before the costs: 'ovl2' value[0],
// then Action_Overlap, through FUN_0059db10. A hit ends the action silently
// and charges nothing (RefusedSilent). It is not run for an 'efr' kind-3 row
// (the trap branch, `puVar12[0xa5] != 0`) nor for an 'efr' kind-1 row whose
// Basic_Activity is not 1 (the collector branch, which charges first and
// tests each target with FUN_0059d870 instead). On the caster's own book the
// records the gate ends are gone by then (INFERRED order, as in Start).
func (b *Books) CheckEngage(casterID, ownerID int64, spec Spec) Refusal {
	b.mu.Lock()
	defer b.mu.Unlock()
	if spec.Efr3 || (spec.Efr1 && spec.Activity != 1) {
		return NotRefused
	}
	bk := b.books[casterID]
	if bk == nil {
		return NotRefused
	}
	scratch := *bk
	if casterID == ownerID && gateApplies(spec) {
		ends, r := overlapLocked(bk, ownerID, spec)
		if r != NotRefused {
			return r
		}
		for _, i := range ends {
			scratch.setGroupBits(bk.records[i].endBits(), true)
			scratch.setGroupBits(bk.records[i].Ovl2, true)
		}
	}
	if spec.Ovl2 != 0 && scratch.bitsHit(spec.Ovl2) {
		return RefusedSilent
	}
	if scratch.bitsHit(spec.ActionOverlap) {
		return RefusedSilent
	}
	return NotRefused
}

// unlinkLocked drops the caster's link record for r, a record that ended.
func (b *Books) unlinkLocked(r Record) {
	if !r.LinkSource {
		return
	}
	ls := b.links[r.CasterID]
	for i, l := range ls {
		if l.TargetToken == r.Token && l.Owner == r.OwnerID {
			ls = append(ls[:i:i], ls[i+1:]...)
			break
		}
	}
	if len(ls) == 0 {
		delete(b.links, r.CasterID)
	} else {
		b.links[r.CasterID] = ls
	}
}

// Start applies spec to ownerID at now. It returns the new record, the
// records the recast rule ended, a refusal (nothing changes then), and the
// owner's run speed afterwards. The ended records go out of the book (and
// their bits out of its bit set) before the new one engages: in retail
// their end flag is cleared at the gate and the book update ends them, while
// the new record engages from the cast -- the relative order is INFERRED.
//
// The engage itself (SkillAction_Buff sub-state 1, READ) tests
// Action_Overlap once more, for every row but an 'lnks' row cast on oneself,
// and does not engage when a bit is set (it returns 2 without the buff):
// RefusedEngage, after the costs (the caller keeps them). Start also runs
// both calls of FUN_0059dc80 (gateLocked's) and, for a Target_Required 1
// 'lnks' row cast on another, files the caster's link entry. Then it sets engageBits and 'ovl2' value[0] in the
// bit set.
func (b *Books) Start(ownerID int64, spec Spec, now time.Time) (rec Record, ended []Record, refused Refusal, sp Speed) {
	b.mu.Lock()
	defer b.mu.Unlock()
	bk := b.books[ownerID]
	if bk == nil {
		bk = &book{}
		b.books[ownerID] = bk
	}
	before := b.speedLocked(ownerID, bk)
	var ends []int
	if linkGateApplies(spec) {
		if refused = linkLocked(bk, b.links[ownerID], spec, 0); refused != NotRefused {
			return Record{}, nil, refused, Speed{RunSpeed: before}
		}
	}
	if linkTargetApplies(spec) {
		if refused = linkLocked(b.books[spec.CasterID], b.links[spec.CasterID], spec, ownerID); refused != NotRefused {
			return Record{}, nil, refused, Speed{RunSpeed: before}
		}
	}
	if gateApplies(spec) {
		ends, refused = overlapLocked(bk, ownerID, spec)
		if refused != NotRefused {
			return Record{}, nil, refused, Speed{RunSpeed: before}
		}
	}
	self := spec.CasterID == ownerID
	if !(spec.Lnks && self) {
		// The engage test runs after the ended records' bits are gone; test
		// it on a scratch copy first so a refusal changes nothing.
		scratch := *bk
		for _, i := range ends {
			scratch.setGroupBits(bk.records[i].endBits(), true)
			scratch.setGroupBits(bk.records[i].Ovl2, true)
		}
		if scratch.bitsHit(spec.ActionOverlap) {
			return Record{}, nil, RefusedEngage, Speed{RunSpeed: before}
		}
	}
	if len(ends) > 0 {
		sort.Sort(sort.Reverse(sort.IntSlice(ends)))
		for _, i := range ends {
			old := bk.records[i]
			bk.records = append(bk.records[:i], bk.records[i+1:]...)
			bk.endLocked(old)
			b.unlinkLocked(old)
			ended = append([]Record{old}, ended...)
		}
	}

	rec = Record{
		Token:         b.NextToken(),
		OwnerID:       ownerID,
		CasterID:      spec.CasterID,
		SkillID:       spec.SkillID,
		GroupID:       spec.GroupID,
		Level:         spec.Level,
		Start:         now,
		Cbuf:          spec.Cbuf,
		Nbuf:          spec.Nbuf,
		Lnks:          spec.Lnks,
		HasHste:       spec.HasHste,
		Hste:          spec.Hste,
		HasHst2:       spec.HasHst2 && !spec.HasHste,
		ActionOverlap: spec.ActionOverlap,
		Ovl2:          spec.Ovl2,
		HasDttp:       spec.HasDttp,
		Dttp0:         spec.Dttp0,
		Dttp1:         spec.Dttp1,
		Efr2:          spec.Efr2,
		Offensive:     spec.Offensive,
		Dtt:           spec.Dtt,
		BasicGroup:    spec.BasicGroup,
		Activity:      spec.Activity,
		SkcEnd:        spec.SkcEnd,
		LnksGroup:     spec.LnksGroup,
		Lks2:          spec.Lks2,
		Linked:        linked(spec, ownerID),
		LinkSource:    linkTargetApplies(spec) && spec.CasterID != ownerID,
	}
	if spec.DuraMs > 0 {
		rec.Dura = time.Duration(spec.DuraMs) * time.Millisecond
	}
	// EngageSkill (0x593540, READ): an 'onff' row's drain clock starts at the
	// engage; a 'pw' row builds the wall object with 'pw' value[1] as its HP
	// and becomes the owner's wall (`in_EAX[0x303] = record`, overwriting any
	// other).
	if spec.HasOnff {
		rec.HasOnff, rec.OnffMs, rec.OnffMP, rec.LastDrain = true, spec.OnffMs, spec.OnffMP, now
	}
	if spec.HasWall {
		rec.HasWall, rec.Wall, rec.WallHP = true, spec.Wall, spec.Wall.HP
		bk.wallHolder = rec.Token
	}
	bk.setGroupBits(engageBits(spec, self), false)
	bk.setGroupBits(spec.Ovl2, false)
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
	if rec.LinkSource {
		b.links[spec.CasterID] = append(b.links[spec.CasterID], linkEntry{SkillID: spec.SkillID,
			LnksGroup: spec.LnksGroup, Lks2: spec.Lks2, Activity: spec.Activity, Object: ownerID,
			Owner: ownerID, TargetToken: rec.Token})
	}
	after := b.speedLocked(ownerID, bk)
	return rec, ended, NotRefused, Speed{RunSpeed: after, Changed: after != before}
}

// Category end events, the masks FUN_005a16c0's callers pass (READ, round
// 636): CategoryMove from the movement handler GObjPC::FUN_004b0ea0 (slot
// 377, 0x4b0ff3, with no row), CategorySkillUse from FUN_0059b480 (0x59b745,
// with the skill's row) -- which builds a skill use's context -- and
// CategoryBerserk from GObjPC_HandleBerserkMsg_0a7 (0x515c43, no row).
// 0x4d2592 (GObjPC::FUN_004d2200, the pet-control handler) passes a register
// whose value was not traced (OPEN).
const (
	CategoryMove     uint8 = 1
	CategorySkillUse uint8 = 2
	CategoryBerserk  uint8 = 4
)

// categoryPair is FUN_005a1840(row, record's row) (READ): per byte position
// (shifts 0, 8, 16), the new row's Action_Overlap byte 0x1d against the
// record's 0x1d, or its 0x23 against the record's 0x23 or 0x1d. A nil row
// (the move and berserk callers) answers false.
func categoryPair(rowOverlap uint32, hasRow bool, recOverlap uint32) bool {
	if !hasRow {
		return false
	}
	for sh := 0; sh < 24; sh += 8 {
		a, c := byte(rowOverlap>>sh), byte(recOverlap>>sh)
		switch a {
		case 0x1d:
			if c == 0x1d {
				return true
			}
		case 0x23:
			if c == 0x23 || c == 0x1d {
				return true
			}
		}
	}
	return false
}

// EndCategory is FUN_005a16c0(book, mask, row) (READ): it ends every record
// whose skill has a non-zero Basic_Activity (+0x65), that its owner cast on
// itself (ctx+0x20 == 1), and whose 'skc' value[1] byte intersects mask or
// whose Action_Overlap pairs with the row's (categoryPair). hasRow false is
// a caller passing no row.
func (b *Books) EndCategory(ownerID int64, mask uint8, rowOverlap uint32, hasRow bool) ([]Record, Speed) {
	return b.endWhere(ownerID, func(r Record) bool {
		return r.Activity != 0 && r.SelfCast() &&
			(r.SkcEnd&mask != 0 || categoryPair(rowOverlap, hasRow, r.ActionOverlap))
	})
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
		return nil, Speed{RunSpeed: b.speedLocked(ownerID, nil)}
	}
	before := b.speedLocked(ownerID, bk)
	var ended []Record
	for i := 0; i < len(bk.records); {
		if r := bk.records[i]; end(r) {
			bk.records = append(bk.records[:i], bk.records[i+1:]...)
			bk.endLocked(r)
			b.unlinkLocked(r)
			ended = append(ended, r)
			continue
		}
		i++
	}
	after := b.speedLocked(ownerID, bk)
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
		delete(b.links, ownerID)
		return nil, Speed{RunSpeed: b.speedLocked(ownerID, nil)}
	}
	before := b.speedLocked(ownerID, bk)
	delete(b.books, ownerID)
	for _, r := range bk.records {
		b.unlinkLocked(r)
	}
	// The owner's own link records go with its book (the book teardown
	// FUN_0059c820). Retail's link record also ends the target's record when
	// it ends (SkillAction_BuffEnd's ctx+0x68 branch); srrevamp leaves the
	// target's record to its own end (OPEN).
	delete(b.links, ownerID)
	after := b.speedLocked(ownerID, nil)
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
	return b.speedLocked(ownerID, b.books[ownerID])
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
