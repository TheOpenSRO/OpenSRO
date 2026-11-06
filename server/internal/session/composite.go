package session

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"log/slog"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/berserk"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gm"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/timedjob"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// The Energy of life scroll (round 632 review): a COMPOSITE item. What
// players buy as "Energy of life" is ITEM_ETC_SECOND_HWAN_SCROLL_01..04
// (23944-23947, TypeID 3/3/13/14), whose Param2 is 1 beside the descriptor
// "[UIL1:ITEM_ETC_SECOND_HWAN,A,3600,1],[UIU1:ITEM_ETC_INCREASE_HWAN_TIME_0n]"
// (refdata.Item.CompositeDesc). READ, SR_GameServer.exe:
//
//   - The use. Item_HandleUseItem (0x00510980) checks the scroll's COOLTIME
//     (group 0xC9, 1 ms) as for every item, then CGItemExpendable::UseByKind
//     (0x0049c2b0) case 0xe calls GObjPC::FUN_0049f590. That first asks
//     FUN_0049f090, which refuses 0x1894 UIIT_SKILL_USE_FAIL_OVERLAP when a
//     type-5 timed job keyed by this scroll's ref id is already running
//     (HasTimedJob(5, id)) or, for a UIL1 entry, when a UIL1 job for its
//     item is (FUN_0049a460(UIL1, fill id)). Then, per entry:
//   - UIL1 "used item limit" (the parser, UIL slot 1 = FUN_00864500, reads
//     code, a flag -- FUN_00864240: "A" (0xb12aa4) is 0, "P" (0xb12aa8) is
//     1 -- the seconds (+0x28) and the count (+0x2c)): a type-5 timed job
//     whose packed word is remaining<<16 | max, remaining = count, or
//     count-1 when the flag is 1 (0x49fa12..0x49fa9e). For the scroll: one
//     use of ITEM_ETC_SECOND_HWAN (23937) within 3600 s.
//   - UIU1 "used item use": the named item (ITEM_ETC_INCREASE_HWAN_TIME_0n,
//     TypeID 3/3/3/10) is not a TypeID4-4 row, so its branch (0x49fc84..
//     0x49fd48) reads the item's Param1 (+0x2a0, 3600) as the job's
//     seconds, Param2 (+0x2c0, the FourCC 0x706874) and Param3 (+0x2e0,
//     5/8/11/14), refuses 0x1894 if a type-10 job with that FourCC runs
//     (FUN_00411560(10, fourcc), 0x49fd09 -> 0x49fede), and queues a type-10
//     CTJ_CharParamKeeper job: FourCC 0x706874 is param 60 slot 0 (the
//     berserk duration's base; berserk.Tracker.SetDurationBonus), so the
//     berserk lasts 60 + 5/8/11/14 s while it runs.
//   - The fill. The player spends the UIL1 grant with client message 0x715f
//     (GObjPC_HandleCompositeItemMsg_15f 0x00511640: two u32s, the second the
//     fill's ref id): no job answers 2; a remaining count of 0 answers 0x18c6
//     UIIT_MSG_PREMIUM_USE_OVER; else CUsedItemLimit::vslot_007 (0x00654080)
//     checks the fill row is a 3/3 expendable, and for TypeID3 1 requires
//     TypeID4 8, then FUN_004a05b0: dead 0x1889, berserk (GetBodyMode 1)
//     0x18ce, five orbs 0x183e. On the LAST use (remaining 1) it ends the
//     UIL1 job, ends the 0x706874 job (FUN_0049a430 / FUN_004f14c0 ->
//     FUN_004dd620, `mov ebx,0x706874` at 0x654310) and arms the fill's
//     COOLTIME (group 0xC9, 1,200,000 ms). Then FUN_004a0600 adds the fill's
//     Param1 byte (5) through AddHwanCount, and on 1 the handler decrements
//     remaining (CTJ_CompositeItemKeeper::FUN_00653f20) and answers 0xb15f.
//     vslot_007 does NOT ask IsReady: the 20 minutes gate the next SCROLL
//     (which carries the same group 0xC9), not the fill.
//
// OURS: OpenSRO's own opcodes (0x0104-0x0107) carry this, not 0x715f/0xb15f.
// OURS, the user's request: a GM account consults and arms neither the
// scroll's nor the fill's COOLTIME.
//
//   - USU1 "used skill use" (round 638 review; the premium items'
//     [USU1:SKILL_MALL_PRE_APRU_4W_01]): FUN_0049f090's pre-check
//     (0x49f4ab..0x49f4ef) looks the SKILL up by code (0x495690, else 2),
//     refuses 0x1894 when a type-0 timed job keyed by its id runs
//     (FUN_00411560(0, id)), and asks 0x650d40, which refuses a skill with
//     no 'dura' (+0x280, 0x3003) and runs the skill gate 0x58d8f0 (a
//     non-zero code is sent as 0xB070 and the use answers 2). The branch
//     (0x49fad0..0x49fb2e -> 0x49f80e -> 0x49fd46) then queues a type-0
//     job -- CTimedJobManagerForPC's switch (0x6565f0, table 0x656690)
//     makes type 0 a CTJ_SkillKeeper (0x650cd0 -> its pool 0x657180) --
//     keyed by the skill id, lasting `dura / 1000` seconds, the division
//     UNSIGNED (`mul` by 0x10624dd3, `shr 6`): the premium rows' dura is
//     2,419,200,000 ms, which the signed column holds as -1875767296. The
//     job's slot 12 (0x650e70), run as the factory 0x655be0 makes it,
//     registers the skill in the book (0x59e220), EngageSkill (0x593540)
//     and Skill_BroadcastBuffAdded_B0BD (0x59af00): an ordinary buff,
//     which every client in the zone is told of and draws on its owner --
//     the buff bar and a target's CIFBuffViewer (docs/protocol/
//     target_window_buffs.md). OpenSRO starts it on the user's buff book
//     (startCasterBuffOn) with that duration; of the skill gate 0x58d8f0
//     only the recast rule is run (round 838, itemSkillRefusal), and the
//     buff's params apply as any buff's do (round 785, buff/stats.go).
//
// Not modelled (disclosed): the berserk bonus is in memory, so a server
// restart loses it; the engine's order queues the UIL1 job before it meets a
// running 0x706874 job, OpenSRO checks both first. Round 838: the UIL1, BFI1
// and UQL1 grants are kept in timedjob.Store (retail's _TIMEDJOB) and loaded
// at the character's world entry, so they survive a restart; the UIU1
// 3/3/13/4 premium time is goldtime.go's, BFI1 and UQL1 compositeextra.go's,
// and a UIL1 fill of a return scroll runs the scroll's routine. OURS since
// the round 638 review: an entry OpenSRO does not model -- a UIU1 3/3/3/10
// row whose FourCC is not 0x706874, BCS1, PSU1 (the pet composite's own
// path, petgrowth.go) and USL1, and UQL1 on a server without a quest
// catalogue -- is SKIPPED and logged; an item none of whose entries is
// modelled is still refused.
const (
	OpCompositeUse       uint16 = 0x0104 // client -> server: spend a granted fill
	OpCompositeUseResult uint16 = 0x0105 // server -> client
	OpCompositeList      uint16 = 0x0106 // client -> server: what grants do I hold
	OpCompositeState     uint16 = 0x0107 // server -> client: the grants and the bonus (reply and push)
	OpCompositeEnd       uint16 = 0x0108 // server -> client: a grant ended (retail 0x315B)
)

// The authored texts of the codes this path answers (textuisystem.txt,
// Media.pk2): 0x1894 UIIT_SKILL_USE_FAIL_OVERLAP, 0x18c6
// UIIT_MSG_PREMIUM_USE_OVER, 0x183e UIIT_MSG_STRGERR_CANNOT_BE_USED.
const (
	compositeOverlapRefusal = "The selected item cannot be used together or the skill is already in use."
	compositeUsedUpRefusal  = "Exceeded one day use limit."
	compositeCannotUse      = "The selected item is unusable."
	// reuseDelayRefusal is 0x185b's authored text,
	// UIIT_MSG_STRGERR_WAIT_FOR_REUSE_DELAY (composite review); every item
	// path's reuse refusal uses it. It replaced OpenSRO's own "wait for the
	// reuse delay".
	reuseDelayRefusal = "Still have time to reuse the item."
)

// hwanTimeFourCC is the UIU1 buff item's Param2, the "ParamKeeper FourCC"
// CTJ_CharParamKeeper maps to param 60 (0x6552fe). The only one OpenSRO
// models.
const hwanTimeFourCC = 0x706874

// compositeEntry is one parsed "[FOURCC:...]" element.
type compositeEntry struct {
	fourCC  string
	code    string
	flagP   bool // UIL1's second field: "P" (1) rather than "A" (0)
	seconds int
	count   int
}

// parseCompositeDesc splits a CompositeDesc into its entries. UIL1 carries
// "code,A|P,seconds,count" (FUN_00864500 reads them with atol); UIU1 carries
// the code alone. An element that does not parse fails the whole list, as
// ReferenceData::FUN_00864bc0 asserts on it.
func parseCompositeDesc(desc string) ([]compositeEntry, error) {
	var out []compositeEntry
	rest := strings.TrimSpace(desc)
	for rest != "" {
		rest = strings.TrimLeft(rest, ", ")
		if rest == "" {
			break
		}
		if rest[0] != '[' {
			return nil, fmt.Errorf("composite: %q: want '['", rest)
		}
		end := strings.IndexByte(rest, ']')
		if end < 0 {
			return nil, fmt.Errorf("composite: %q: no ']'", rest)
		}
		body := rest[1:end]
		rest = rest[end+1:]
		colon := strings.IndexByte(body, ':')
		if colon < 0 {
			return nil, fmt.Errorf("composite: %q: no ':'", body)
		}
		e := compositeEntry{fourCC: body[:colon]}
		fields := strings.Split(body[colon+1:], ",")
		for i := range fields {
			fields[i] = strings.TrimSpace(fields[i])
		}
		e.code = fields[0]
		switch e.fourCC {
		case "BFI1":
			// BUFF_ITEM::vslot_001 (0x8646b0): code, A|P, seconds (round 838).
			if len(fields) != 3 || (fields[1] != "A" && fields[1] != "P") {
				return nil, fmt.Errorf("composite: BFI1 %q: want code,A|P,seconds", body)
			}
			e.flagP = fields[1] == "P"
			var err error
			if e.seconds, err = strconv.Atoi(fields[2]); err != nil {
				return nil, fmt.Errorf("composite: BFI1 seconds: %w", err)
			}
		}
		if e.fourCC == "UIL1" || e.fourCC == "UQL1" {
			if len(fields) != 4 || (fields[1] != "A" && fields[1] != "P") {
				return nil, fmt.Errorf("composite: %s %q: want code,A|P,seconds,count", e.fourCC, body)
			}
			e.flagP = fields[1] == "P"
			var err error
			if e.seconds, err = strconv.Atoi(fields[2]); err != nil {
				return nil, fmt.Errorf("composite: UIL1 seconds: %w", err)
			}
			if e.count, err = strconv.Atoi(fields[3]); err != nil {
				return nil, fmt.Errorf("composite: UIL1 count: %w", err)
			}
		}
		out = append(out, e)
	}
	return out, nil
}

// compositeGrant is a running UIL1 job: remaining uses of an item until a
// time, and the scroll that granted it (the type-5 job's key).
type compositeGrant struct {
	fillID    int64
	scrollID  int64
	remaining int
	max       int
	until     time.Time
	gen       uint64 // which put this is (a timer ends only its own)
	// Round 864: the UIL1 entry's seconds are a PERIOD, not the grant's
	// life (READ, s:0x49f605..0x49f63f and 0x49fa3d..0x49fa9e): the job
	// lasts the composite's Param1 (ref+0x2a0) from the use, and the entry's
	// seconds (+0x28) mark a period whose end (job +0x80) refills the uses
	// (refill, CUsedItemLimit::FUN_00653a40). period 0 is a grant kept before
	// round 864, which never refills.
	period    time.Duration
	periodEnd time.Time
}

// refill is CUsedItemLimit::FUN_00653a40 (READ, s:0x653a40..0x653aea), run
// when the period's end is reached (FUN_00653a10 answers end - now < 1): k =
// (now - end) / period whole periods past, the end moves to end + (k + 1) x
// period -- the first boundary after now, the boundaries anchored at the
// use -- and the uses go back to the maximum (setter +0x48 with max << 16 |
// max). It reports whether it refilled. (k is a byte there, `mov bl,al`;
// a 28-day job never reaches 256 periods of a day.)
func (g *compositeGrant) refill(now time.Time) bool {
	if g.period <= 0 || now.Before(g.periodEnd) {
		return false
	}
	k := now.Sub(g.periodEnd) / g.period
	g.periodEnd = g.periodEnd.Add((k + 1) * g.period)
	g.remaining = g.max
	return true
}

// CompositeKeeper holds every character's UIL1 grants (CTJ_CompositeItemKeeper
// in the engine). Process-wide and in memory.
//
// A grant ENDS by a timer, not lazily (composite review): retail's
// CUsedItemLimit job sends 0x315B {compositeRefId, limitedRefId} when it
// ends (0x653e80), and the client's handler (FUN_008993b0) removes the map
// entry and the kind-5 icon. OpenSRO sends OpCompositeEnd to the session the
// character last used the keeper through (bind), when the grant runs out and
// when its last use consumes it.
type CompositeKeeper struct {
	mu       sync.Mutex
	grants   map[int64]map[int64]*compositeGrant // character -> fill id -> grant
	sessions map[int64]*gateway.Session          // character -> the session to push to
	gen      uint64                              // stamps each put, so a stale timer ends nothing
	// Round 838: the BFI1 and UQL1 grants (compositeextra.go), the store
	// every grant is kept in across a restart, the scroll caster a return
	// scroll's fill runs through, and the characters whose kept grants were
	// loaded.
	extras  map[int64][]*compositeExtra
	store   timedjob.Store
	scrolls *ScrollCaster
	loaded  map[int64]bool
	// zerk is the berserk tracker a period refill's state push reads the
	// bonus from (round 864; SetBerserk).
	zerk *berserk.Tracker
	// items is the item table the dropped-fill repair reads (round 864
	// follow-up; SetItems, compositerepair.go).
	items ItemLookup
}

// SetBerserk names the tracker a period refill's push reads (round 864).
func (k *CompositeKeeper) SetBerserk(z *berserk.Tracker) {
	k.mu.Lock()
	defer k.mu.Unlock()
	k.zerk = z
}

func NewCompositeKeeper() *CompositeKeeper {
	return &CompositeKeeper{grants: map[int64]map[int64]*compositeGrant{}, sessions: map[int64]*gateway.Session{},
		extras: map[int64][]*compositeExtra{}, loaded: map[int64]bool{}}
}

// SetStore keeps the grants in store (round 838): each put, use and end is
// written, and a character's are loaded at its world entry.
func (k *CompositeKeeper) SetStore(store timedjob.Store) {
	k.mu.Lock()
	defer k.mu.Unlock()
	k.store = store
}

// SetScrolls names the caster a return scroll's fill runs through (round
// 838).
func (k *CompositeKeeper) SetScrolls(s *ScrollCaster) {
	k.mu.Lock()
	defer k.mu.Unlock()
	k.scrolls = s
}

// bind records the session a character's end pushes go to.
func (k *CompositeKeeper) bind(characterID int64, sess *gateway.Session) {
	if sess == nil {
		return
	}
	k.mu.Lock()
	defer k.mu.Unlock()
	k.sessions[characterID] = sess
}

// running returns the character's unexpired grants, dropping expired ones.
func (k *CompositeKeeper) running(characterID int64, now time.Time) []*compositeGrant {
	k.mu.Lock()
	defer k.mu.Unlock()
	var out []*compositeGrant
	m := k.grants[characterID]
	var refilled []compositeGrant
	for id, g := range m {
		if !now.Before(g.until) {
			delete(m, id)
			continue
		}
		if g.refill(now) {
			refilled = append(refilled, *g)
		}
		cp := *g
		out = append(out, &cp)
	}
	if m != nil && len(m) == 0 {
		delete(k.grants, characterID)
	}
	k.mu.Unlock()
	for _, g := range refilled {
		k.saveGrant(characterID, g)
	}
	k.mu.Lock()
	return out
}

func (k *CompositeKeeper) get(characterID, fillID int64, now time.Time) (*compositeGrant, bool) {
	k.mu.Lock()
	defer k.mu.Unlock()
	g, ok := k.grants[characterID][fillID]
	if !ok || !now.Before(g.until) {
		return nil, false
	}
	refilled := g.refill(now)
	cp := *g
	if refilled {
		k.mu.Unlock()
		k.saveGrant(characterID, cp)
		k.mu.Lock()
	}
	return &cp, true
}

// put stores a grant and starts its end timer, `lasts` of real time from now
// (the grant's until is on the handler's clock, which tests move).
func (k *CompositeKeeper) put(characterID int64, g compositeGrant, lasts time.Duration) {
	k.mu.Lock()
	m := k.grants[characterID]
	if m == nil {
		m = map[int64]*compositeGrant{}
		k.grants[characterID] = m
	}
	k.gen++
	g.gen = k.gen
	m[g.fillID] = &g
	k.mu.Unlock()
	k.saveGrant(characterID, g)
	gen := g.gen
	time.AfterFunc(lasts, func() { k.expire(characterID, g.fillID, gen) })
	k.armPeriod(characterID, g.fillID, gen, g.periodEnd)
}

// armPeriod starts the timer for a grant's next period end: the job's tick
// (CUsedItemLimit::FUN_00653c30, slot 2) refills it there and sends 0x3161
// {composite, fill}, whose client handler (c:0x899420 -> FUN_00805480) sets
// the fill's count back to its UIL1 maximum (READ). OpenSRO pushes the
// whole OpCompositeState instead (OURS: its own opcodes). The tick runs only
// while the character is in the world; a refill missed while away happens
// at the next read (refill), as the job's load (slot 1, FUN_00653b40) does.
func (k *CompositeKeeper) armPeriod(characterID, fillID int64, gen uint64, periodEnd time.Time) {
	if periodEnd.IsZero() {
		return
	}
	wait := time.Until(periodEnd)
	if d := periodEnd.Sub(useItemClock()); d < wait {
		wait = d
	}
	if wait < 0 {
		wait = 0
	}
	time.AfterFunc(wait, func() { k.periodTick(characterID, fillID, gen) })
}

// periodTick is the period end's refill and push, for the grant the timer
// was started for.
func (k *CompositeKeeper) periodTick(characterID, fillID int64, gen uint64) {
	now := useItemClock()
	k.mu.Lock()
	g, ok := k.grants[characterID][fillID]
	if !ok || g.gen != gen || !now.Before(g.until) {
		k.mu.Unlock()
		return
	}
	refilled := g.refill(now)
	cp := *g
	sess := k.sessions[characterID]
	zerk := k.zerk
	k.mu.Unlock()
	if refilled {
		k.saveGrant(characterID, cp)
		slog.Info("composite: period refill", "character_id", characterID, "item", fillID, "uses", cp.max, "next", cp.periodEnd)
		if sess != nil && zerk != nil {
			_ = sendCompositeState(sess, k, zerk, characterID, now)
		}
	}
	k.armPeriod(characterID, fillID, gen, cp.periodEnd)
}

// saveGrant writes a UIL1 grant to the store (round 838).
func (k *CompositeKeeper) saveGrant(characterID int64, g compositeGrant) {
	k.mu.Lock()
	store := k.store
	k.mu.Unlock()
	if store == nil {
		return
	}
	// Round 864: V3 the period in seconds, V4 its end (unix seconds); 0 on
	// a row kept before then (no refill).
	var periodEnd int64
	if !g.periodEnd.IsZero() {
		periodEnd = g.periodEnd.Unix()
	}
	_ = store.Put(context.Background(), timedjob.Job{CharID: characterID, Type: timedjob.TypeComposite, Sub: "UIL1",
		Ref: g.fillID, Key: g.scrollID, Start: useItemClock(), End: g.until, V1: int64(g.remaining), V2: int64(g.max),
		V3: int64(g.period / time.Second), V4: periodEnd})
}

// dropGrant removes a UIL1 grant's row (round 838).
func (k *CompositeKeeper) dropGrant(characterID, fillID int64) {
	k.mu.Lock()
	store := k.store
	k.mu.Unlock()
	if store != nil {
		_ = store.Delete(context.Background(), characterID, timedjob.TypeComposite, "UIL1", fillID)
	}
}

// expire is the timer's end: the grant, if it is still the one the timer was
// started for, is removed and the end is pushed.
func (k *CompositeKeeper) expire(characterID, fillID int64, gen uint64) {
	k.mu.Lock()
	g, ok := k.grants[characterID][fillID]
	if !ok || g.gen != gen {
		k.mu.Unlock()
		return
	}
	ended := *g
	k.removeLocked(characterID, fillID)
	sess := k.sessions[characterID]
	k.mu.Unlock()
	k.dropGrant(characterID, fillID)
	sendCompositeEnd(sess, ended)
}

func (k *CompositeKeeper) setRemaining(characterID, fillID int64, remaining int) {
	k.mu.Lock()
	g, ok := k.grants[characterID][fillID]
	var cp compositeGrant
	if ok {
		g.remaining = remaining
		cp = *g
	}
	k.mu.Unlock()
	if ok {
		k.saveGrant(characterID, cp)
	}
}

// end removes a consumed grant and pushes its end.
func (k *CompositeKeeper) end(characterID, fillID int64) {
	k.mu.Lock()
	g, ok := k.grants[characterID][fillID]
	if !ok {
		k.mu.Unlock()
		return
	}
	ended := *g
	k.removeLocked(characterID, fillID)
	sess := k.sessions[characterID]
	k.mu.Unlock()
	k.dropGrant(characterID, fillID)
	sendCompositeEnd(sess, ended)
}

// removeLocked drops a grant and the character's map once it is empty.
func (k *CompositeKeeper) removeLocked(characterID, fillID int64) {
	m := k.grants[characterID]
	delete(m, fillID)
	if len(m) == 0 {
		delete(k.grants, characterID)
	}
}

// Forget is the logout (composite review): the character's session binding
// goes, and so do its expired grants and an empty map. A RUNNING grant stays
// until its timer ends it -- the engine keeps timed jobs across a relog --
// so what is kept is bounded by the grants still running.
func (k *CompositeKeeper) Forget(characterID int64, now time.Time) {
	k.mu.Lock()
	defer k.mu.Unlock()
	delete(k.sessions, characterID)
	m := k.grants[characterID]
	for id, g := range m {
		if !now.Before(g.until) {
			delete(m, id)
		}
	}
	if len(m) == 0 {
		delete(k.grants, characterID)
	}
}

// OpCompositeEnd's payload: the granted item and the composite that granted
// it, retail 0x315B's {compositeRefId, limitedRefId} in our widths.
type CompositeEnd struct {
	ItemID   int64
	ScrollID int64
}

func (e *CompositeEnd) Encode() []byte {
	return append(encodeInt64(e.ItemID), encodeInt64(e.ScrollID)...)
}

func DecodeCompositeEnd(data []byte) (*CompositeEnd, error) {
	a, rest, err := decodeInt64(data)
	if err != nil {
		return nil, fmt.Errorf("session: decoding CompositeEnd: %w", err)
	}
	b, _, err := decodeInt64(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding CompositeEnd: %w", err)
	}
	return &CompositeEnd{ItemID: a, ScrollID: b}, nil
}

func sendCompositeEnd(sess *gateway.Session, g compositeGrant) {
	if sess == nil {
		return
	}
	// A closed session's send fails; the grant has ended either way.
	_ = sess.Send(&proto.Packet{Opcode: OpCompositeEnd, Data: (&CompositeEnd{ItemID: g.fillID, ScrollID: g.scrollID}).Encode()})
}

// itemByCode is the lookup a composite needs; both refdata stores have it.
type itemByCode interface {
	GetItemByCode(ctx context.Context, code string) (*refdata.Item, error)
}

// isCompositeScroll reports whether the use goes to UseByKind case 0xe:
// TypeID 3/3/13/14 with a composite list.
func isCompositeScroll(it *refdata.Item) bool {
	return it.TypeID1 == equipment.TypeItem && it.TypeID2 == equipment.TypeExpendable &&
		it.TypeID3 == 13 && it.TypeID4 == 14 && it.CompositeDesc != ""
}

// compositePlan is what a scroll's use will create, resolved before
// anything is spent.
type compositePlan struct {
	grants     []compositeGrant
	grantFor   []time.Duration
	bonusSecs  int // the param-60 value (Param3 of the UIU1 item)
	bonusFor   time.Duration
	bonusValid bool
	// skills are the USU1 entries' buffs, each with its job's duration.
	skills   []*refdata.Skill
	skillFor []time.Duration
	// skipped names the entries OpenSRO does not model (OURS, logged).
	skipped []string
	// Round 838: the premium (a UIU1 3/3/13/4 row, goldtime.go) and the
	// BFI1 / UQL1 grants (compositeextra.go).
	premium *refdata.Item
	extras  []compositeExtra
}

// skillByCode resolves a USU1 entry's skill (0x495690).
type skillByCode interface {
	GetSkillByCode(ctx context.Context, code string) (*refdata.Skill, error)
}

// usu1Duration is the skill job's length: 'dura' (+0x280) read UNSIGNED and
// divided by 1000 into whole seconds (0x49fb11..0x49fb20).
func usu1Duration(duraMs int) time.Duration {
	return time.Duration(uint32(duraMs)/1000) * time.Second
}

// planComposite resolves the scroll's entries and runs FUN_0049f090's and
// the UIU1 branch's refusals. It returns a reply text on refusal.
func planComposite(ctx context.Context, items combat.ItemLookup, keeper *CompositeKeeper, zerk *berserk.Tracker,
	characterID int64, scroll *refdata.Item, now time.Time) (compositePlan, string) {
	var plan compositePlan
	byCode, ok := items.(itemByCode)
	if !ok {
		return plan, "that cannot be used"
	}
	entries, err := parseCompositeDesc(scroll.CompositeDesc)
	if err != nil || len(entries) == 0 {
		return plan, "that cannot be used"
	}
	for _, g := range keeper.running(characterID, now) {
		if g.scrollID == scroll.ID { // HasTimedJob(5, scroll id)
			return plan, compositeOverlapRefusal
		}
	}
	for _, e := range entries {
		if e.fourCC == "USU1" {
			// FUN_0049f090's USU1 pre-check, then the branch (see the header).
			bySkill, ok := items.(skillByCode)
			if !ok {
				return plan, "that cannot be used"
			}
			ref, err := bySkill.GetSkillByCode(ctx, e.code)
			if err != nil || ref == nil {
				return plan, "that cannot be used"
			}
			if ref.DuraMs == 0 { // 0x650d40: no 'dura' is 0x3003
				return plan, "that cannot be used"
			}
			// FUN_00411560(0, skill id): the same skill's job running is
			// 0x1894; then (round 838, itemskill.go) the character visuals'
			// rule (OURS) and the book's recast rule, before anything is
			// spent -- the job's start would otherwise meet the engage test
			// after the spend.
			refs, _ := items.(SkillRefStore)
			if refusal := itemSkillRefusal(ctx, refs, characterID, ref); refusal != "" {
				return plan, refusal
			}
			plan.skills = append(plan.skills, ref)
			plan.skillFor = append(plan.skillFor, usu1Duration(ref.DuraMs))
			continue
		}
		switch e.fourCC {
		case "UIL1", "UIU1", "BFI1":
		case "UQL1":
			// The pre-check needs the quest (round 838). A server with no
			// quest catalogue cannot name it: the entry is skipped (OURS).
			rt := questRT.Load()
			if rt == nil || rt.cat == nil {
				plan.skipped = append(plan.skipped, e.fourCC+":"+e.code)
				continue
			}
			q, ok := rt.cat.ByCode[e.code]
			if !ok || q == nil {
				return plan, "that cannot be used"
			}
			if _, running := keeper.extra(characterID, "UQL1", q.ID, now); running {
				return plan, compositeOverlapRefusal
			}
			plan.extras = append(plan.extras, compositeExtra{fourCC: "UQL1", refID: q.ID, scrollID: scroll.ID,
				until: now.Add(time.Duration(e.seconds) * time.Second), remaining: e.count, max: e.count})
			continue
		default:
			// OURS: a kind OpenSRO does not model is skipped (header).
			plan.skipped = append(plan.skipped, e.fourCC+":"+e.code)
			continue
		}
		part, err := byCode.GetItemByCode(ctx, e.code)
		if err != nil || part == nil {
			return plan, "that cannot be used"
		}
		switch e.fourCC {
		case "BFI1":
			// FUN_0049a460('BFI1', id) in the pre-check, then the branch's
			// 3/3/3/4 test: any other row queues nothing (round 838).
			if _, running := keeper.extra(characterID, "BFI1", part.ID, now); running {
				return plan, compositeOverlapRefusal
			}
			if !isBFI1Decoration(part) {
				continue
			}
			plan.extras = append(plan.extras, compositeExtra{fourCC: "BFI1", refID: part.ID, scrollID: scroll.ID,
				until: now.Add(time.Duration(e.seconds) * time.Second)})
		case "UIL1":
			if _, running := keeper.get(characterID, part.ID, now); running { // FUN_0049a460(UIL1, id)
				return plan, compositeOverlapRefusal
			}
			remaining := e.count
			if e.flagP {
				remaining = e.count - 1
			}
			// Round 864: the job lasts the composite's Param1 from the use
			// (s:0x49f61b..0x49f63f: esi = the scroll's ref, TimeSpan of
			// ref+0x2a0 added to now; the UIL1 job takes that end,
			// 0x49fa97), and the entry's seconds are its refill period
			// (0x49fa46: TimeSpan of entry+0x28, the job's +0x7c / +0x80).
			// MEASURED: the premium's 0x3159 carries 2,419,200 s left (its
			// Param1), not the entry's 86,400. A row with no Param1 keeps
			// the entry's seconds as its life (OURS).
			period := time.Duration(e.seconds) * time.Second
			lasts := period
			if scroll.RestoreHP > 0 {
				lasts = time.Duration(scroll.RestoreHP) * time.Second
			}
			plan.grants = append(plan.grants, compositeGrant{
				fillID: part.ID, scrollID: scroll.ID, remaining: remaining, max: e.count,
				until: now.Add(lasts), period: period, periodEnd: now.Add(period),
			})
			plan.grantFor = append(plan.grantFor, lasts)
		case "UIU1":
			// FUN_0049f590's UIU1 branch: a 3/3/13/4 row (FUN_004929c0,
			// 0x4929c0: TypeID 3/3/13, and TID & 0xf800 == 0x2000) makes a
			// type-3 job with its Param1, which
			// OpenSRO does not model -- refused. Otherwise FUN_00488db0
			// (0x49fc8d; 0x488db0: TID bit 1 clear, TypeID 3/3/3/10) must
			// answer 1 for the type-10 job; on 0 the branch jumps to
			// 0x49fd55 and makes NO job, silently -- mirrored by skipping the
			// entry. Of a 3/3/3/10 row, only CTJ_CharParamKeeper's 0x706874
			// (param 60) is modelled; the table's other keys (urep, ursp,
			// urse -> params 256/258/258, 0x6552d0) are refused. Its
			// Param1..3 are exported as RestoreHP, the packed ReinforceRate1
			// (Param2, u32) and ReinforceRate2 (Param3).
			if isPremiumTime(part) {
				// The premium time (round 838, goldtime.go): a type-3 job,
				// refused 0x1894 while any runs (0x49f44a..0x49f47d). A
				// server without its store skips it (OURS).
				if goldTimeDepsNow() == nil {
					plan.skipped = append(plan.skipped, e.fourCC+":"+e.code)
					continue
				}
				if goldTimeRunning(characterID) {
					return plan, compositeOverlapRefusal
				}
				plan.premium = part
				continue
			}
			if !(part.TypeID1 == equipment.TypeItem && part.TypeID2 == equipment.TypeExpendable &&
				part.TypeID3 == 3 && part.TypeID4 == 10) {
				continue
			}
			if part.ReinforceRate1 != hwanTimeFourCC {
				plan.skipped = append(plan.skipped, e.fourCC+":"+e.code)
				continue
			}
			if secs, _ := zerk.DurationBonus(characterID, now); secs != 0 { // FUN_00411560(10, fourcc)
				return plan, compositeOverlapRefusal
			}
			plan.bonusSecs = int(part.ReinforceRate2)
			plan.bonusFor = time.Duration(part.RestoreHP) * time.Second
			plan.bonusValid = true
		}
	}
	if len(plan.grants) == 0 && !plan.bonusValid && len(plan.skills) == 0 && plan.premium == nil && len(plan.extras) == 0 {
		// Nothing OpenSRO models: the item is refused, not spent.
		return plan, "that cannot be used"
	}
	return plan, ""
}

// useCompositeScroll is the scroll's use: COOLTIME gate, the plan's
// refusals, the spend, the jobs, the COOLTIME arm. isGM skips the COOLTIME
// (OURS).
func useCompositeScroll(ctx context.Context, sess *gateway.Session, fail func(string) error,
	inv inventory.Store, items combat.ItemLookup, keeper *CompositeKeeper, zerk *berserk.Tracker, hub *world.Hub, isGM bool,
	characterID int64, it *refdata.Item, held inventory.Slot, have int) error {
	if keeper == nil || zerk == nil {
		return fail("that cannot be used")
	}
	now := useItemClock()
	cooltime := it.CooltimeMs > 0 && !isGM
	if cooltime && !itemCooldowns.ReadyItem(characterID, it.ID, it.CooltimeGroup, now) {
		return fail(reuseDelayRefusal)
	}
	release := zerk.Turn(characterID)
	defer release()
	plan, refusal := planComposite(ctx, items, keeper, zerk, characterID, it, now)
	if refusal != "" {
		return fail(refusal)
	}
	if err := inv.RemoveItem(ctx, characterID, held.Index, 1); err != nil {
		return fail("using failed")
	}
	keeper.bind(characterID, sess)
	for i, g := range plan.grants {
		keeper.put(characterID, g, plan.grantFor[i])
	}
	if plan.bonusValid {
		zerk.SetDurationBonus(characterID, plan.bonusSecs, now, plan.bonusFor)
	}
	// Round 864, MEASURED: the use's answer starts with the fills' state
	// (0x315C, then 0x3159 per fill), then the premium time's 0x3206, then
	// the USU1 buff (0xB0BD), then 0xB04C -- the board shows the composite's
	// icon, the premium time's, the buff's, in that order. So the state goes
	// first here (it went last, after the use result, before round 864).
	if len(plan.grants) > 0 {
		if err := sendCompositeState(sess, keeper, zerk, characterID, now); err != nil {
			return err
		}
	}
	// Round 838: the premium and the BFI1 / UQL1 grants.
	if plan.premium != nil {
		startGoldTime(ctx, sess, characterID, plan.premium, now)
	}
	for _, x := range plan.extras {
		keeper.putExtra(characterID, x, now, true)
		slog.Info("composite: grant", "item", it.ID, "character_id", characterID, "entry", x.fourCC, "ref", x.refID,
			"seconds", int64(x.until.Sub(now)/time.Second), "count", x.max)
	}
	// USU1: the skill job's buff, started on the user's own book and told to
	// its zone as any buff is (round 638 review).
	for i, ref := range plan.skills {
		started := startUsu1Buff(ctx, hub, ref, plan.skillFor[i], characterID, it.ID, now)
		slog.Info("composite: USU1 skill buff", "item", it.ID, "character_id", characterID, "skill", ref.ID,
			"seconds", int64(plan.skillFor[i]/time.Second), "started", started)
	}
	if len(plan.skipped) > 0 {
		slog.Info("composite: entries not modelled, skipped", "item", it.ID, "character_id", characterID, "entries", plan.skipped)
	}
	if cooltime {
		itemCooldowns.ArmItem(characterID, it.ID, it.CooltimeGroup, time.Duration(it.CooltimeMs)*time.Millisecond, now)
	}
	if err := sess.Send(&proto.Packet{Opcode: OpUseItemResult, Data: (&UseItemResult{Remaining: int32(have - 1)}).Encode()}); err != nil {
		return err
	}
	return sendCompositeState(sess, keeper, zerk, characterID, now)
}

// CompositeUseRequest spends one use of a granted item. Round 838: a
// reverse return scroll's fill carries the scroll's option after the item
// (0x715f's u8 option when not 0, then a u32 refoptionalteleport id for 7;
// client 0x821720), the same bytes the scroll's own use carries.
type CompositeUseRequest struct {
	CharacterName string
	ItemID        int64
	Option        byte
	Target        uint32
}

func (r *CompositeUseRequest) Encode() []byte {
	out := append(encodeStrings(r.CharacterName), encodeInt64(r.ItemID)...)
	if r.Option == 0 {
		return out
	}
	out = append(out, r.Option)
	if r.Option == ReverseOptionMap {
		out = binary.LittleEndian.AppendUint32(out, r.Target)
	}
	return out
}

func DecodeCompositeUseRequest(data []byte) (*CompositeUseRequest, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding CompositeUseRequest: %w", err)
	}
	id, rest, err := decodeInt64(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding CompositeUseRequest: item: %w", err)
	}
	r := &CompositeUseRequest{CharacterName: fields[0], ItemID: id}
	if len(rest) > 0 {
		r.Option = rest[0]
		if r.Option == ReverseOptionMap && len(rest) >= 5 {
			r.Target = binary.LittleEndian.Uint32(rest[1:5])
		}
	}
	return r, nil
}

// CompositeUseResult answers a fill: the error text, the item, the uses
// left, and the orbs after it (0..berserk.Max, orbs x 20) and berserk state.
type CompositeUseResult struct {
	Error         string
	ItemID        int64
	Remaining     int32
	BerserkGauge  int32
	BerserkActive bool
	// CastMs is a return scroll fill's delay (round 838): the casting bar,
	// as the scroll's own use result carries it. A trailing u32.
	CastMs uint32
}

func (r *CompositeUseResult) Encode() []byte {
	out := append(encodeStrings(r.Error), encodeInt64(r.ItemID)...)
	buf := make([]byte, 13)
	binary.LittleEndian.PutUint32(buf[0:4], uint32(r.Remaining))
	binary.LittleEndian.PutUint32(buf[4:8], uint32(r.BerserkGauge))
	if r.BerserkActive {
		buf[8] = 1
	}
	binary.LittleEndian.PutUint32(buf[9:13], r.CastMs)
	return append(out, buf...)
}

func DecodeCompositeUseResult(data []byte) (*CompositeUseResult, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding CompositeUseResult: %w", err)
	}
	id, rest, err := decodeInt64(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding CompositeUseResult: item: %w", err)
	}
	if len(rest) < 9 {
		return nil, errors.New("session: decoding CompositeUseResult: truncated")
	}
	r := &CompositeUseResult{Error: fields[0], ItemID: id,
		Remaining:     int32(binary.LittleEndian.Uint32(rest[0:4])),
		BerserkGauge:  int32(binary.LittleEndian.Uint32(rest[4:8])),
		BerserkActive: rest[8] != 0}
	if len(rest) >= 13 {
		r.CastMs = binary.LittleEndian.Uint32(rest[9:13])
	}
	return r, nil
}

// CompositeGrantState is one running grant as the client sees it.
type CompositeGrantState struct {
	ItemID      int64
	ScrollID    int64 // the composite item that granted it: retail's icon and gauge come from it
	Remaining   int32
	Max         int32
	SecondsLeft int32
}

// CompositeState is every running grant, plus the param-60 bonus (seconds
// added to a berserk, and how long it still runs; 0/0 for none).
type CompositeState struct {
	Grants           []CompositeGrantState
	BonusSeconds     int32
	BonusSecondsLeft int32
}

func (s *CompositeState) Encode() []byte {
	out := make([]byte, 2, 2+len(s.Grants)*28+8)
	binary.LittleEndian.PutUint16(out, uint16(len(s.Grants)))
	for _, g := range s.Grants {
		b := make([]byte, 28)
		binary.LittleEndian.PutUint64(b[0:8], uint64(g.ItemID))
		binary.LittleEndian.PutUint64(b[8:16], uint64(g.ScrollID))
		binary.LittleEndian.PutUint32(b[16:20], uint32(g.Remaining))
		binary.LittleEndian.PutUint32(b[20:24], uint32(g.Max))
		binary.LittleEndian.PutUint32(b[24:28], uint32(g.SecondsLeft))
		out = append(out, b...)
	}
	tail := make([]byte, 8)
	binary.LittleEndian.PutUint32(tail[0:4], uint32(s.BonusSeconds))
	binary.LittleEndian.PutUint32(tail[4:8], uint32(s.BonusSecondsLeft))
	return append(out, tail...)
}

func DecodeCompositeState(data []byte) (*CompositeState, error) {
	if len(data) < 2 {
		return nil, errors.New("session: decoding CompositeState: truncated")
	}
	n := int(binary.LittleEndian.Uint16(data))
	if len(data) < 2+n*28+8 {
		return nil, errors.New("session: decoding CompositeState: truncated")
	}
	s := &CompositeState{}
	for i := 0; i < n; i++ {
		b := data[2+i*28:]
		s.Grants = append(s.Grants, CompositeGrantState{
			ItemID:      int64(binary.LittleEndian.Uint64(b[0:8])),
			ScrollID:    int64(binary.LittleEndian.Uint64(b[8:16])),
			Remaining:   int32(binary.LittleEndian.Uint32(b[16:20])),
			Max:         int32(binary.LittleEndian.Uint32(b[20:24])),
			SecondsLeft: int32(binary.LittleEndian.Uint32(b[24:28])),
		})
	}
	t := data[2+n*28:]
	s.BonusSeconds = int32(binary.LittleEndian.Uint32(t[0:4]))
	s.BonusSecondsLeft = int32(binary.LittleEndian.Uint32(t[4:8]))
	return s, nil
}

func secondsLeft(until, now time.Time) int32 {
	d := until.Sub(now)
	if d <= 0 {
		return 0
	}
	return int32((d + time.Second - 1) / time.Second)
}

func sendCompositeState(sess *gateway.Session, keeper *CompositeKeeper, zerk *berserk.Tracker, characterID int64, now time.Time) error {
	st := &CompositeState{}
	for _, g := range keeper.running(characterID, now) {
		st.Grants = append(st.Grants, CompositeGrantState{ItemID: g.fillID, ScrollID: g.scrollID, Remaining: int32(g.remaining),
			Max: int32(g.max), SecondsLeft: secondsLeft(g.until, now)})
	}
	if secs, until := zerk.DurationBonus(characterID, now); secs != 0 {
		st.BonusSeconds, st.BonusSecondsLeft = int32(secs), secondsLeft(until, now)
	}
	return sess.Send(&proto.Packet{Opcode: OpCompositeState, Data: st.Encode()})
}

// CompositeHandler serves OpCompositeUse (the fill, 0x715f's counterpart)
// and OpCompositeList. gate names the GM accounts (OURS: no COOLTIME).
func CompositeHandler(chars character.Store, items combat.ItemLookup, keeper *CompositeKeeper, zerk *berserk.Tracker,
	gate *gm.Gate, hub *world.Hub) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		switch p.Opcode {
		case OpCompositeList:
			req, err := DecodeCharacterNameRequest(p.Data)
			if err != nil {
				return nil
			}
			characterID, errStr := resolveCharacterID(ctx, sess, chars, req.Name)
			if errStr != "" || keeper == nil || zerk == nil {
				return nil
			}
			keeper.bind(characterID, sess)
			return sendCompositeState(sess, keeper, zerk, characterID, useItemClock())
		case OpCompositeUse:
		default:
			return nil
		}
		req, err := DecodeCompositeUseRequest(p.Data)
		if err != nil {
			return sess.Send(&proto.Packet{Opcode: OpCompositeUseResult, Data: (&CompositeUseResult{Error: "malformed request"}).Encode()})
		}
		characterID, errStr := resolveCharacterID(ctx, sess, chars, req.CharacterName)
		// A refusal is followed by the state too (composite review), so a
		// client whose grant has gone (expired, or spent from another
		// session) drops its icon.
		fail := func(reason string, itemID int64) error {
			if err := sess.Send(&proto.Packet{Opcode: OpCompositeUseResult, Data: (&CompositeUseResult{Error: reason, ItemID: itemID}).Encode()}); err != nil {
				return err
			}
			if errStr == "" && keeper != nil && zerk != nil {
				return sendCompositeState(sess, keeper, zerk, characterID, useItemClock())
			}
			return nil
		}
		if errStr != "" {
			return fail(errStr, req.ItemID)
		}
		if keeper == nil || zerk == nil || items == nil {
			return fail("that cannot be used", req.ItemID)
		}
		keeper.bind(characterID, sess)
		username, _ := AuthenticatedUsername(sess)
		isGM := gate.Allows(username)
		now := useItemClock()
		// Round 864: released once, by the deferred call or early by the
		// resurrection fill, whose revive ends a berserk under the same turn
		// (endBerserk) -- taken twice it waited on itself.
		var released sync.Once
		unlockTurn := zerk.Turn(characterID)
		release := func() { released.Do(unlockTurn) }
		defer release()
		// 0x511640: no UIL1 job for the item answers 2.
		g, ok := keeper.get(characterID, req.ItemID, now)
		if !ok {
			return fail("that cannot be used", req.ItemID)
		}
		// CTJ_CompositeItemKeeper::FUN_00653f70: no use left -> 0x18c6.
		if g.remaining <= 0 {
			return fail(compositeUsedUpRefusal, req.ItemID)
		}
		fill, err := items.GetItem(ctx, req.ItemID)
		if err != nil || fill == nil {
			return fail("that cannot be used", req.ItemID)
		}
		// Round 864: a resurrection scroll's fill (vslot_007's 3/3/13/6
		// branch, resurrectfill.go).
		if isResurrectionScroll(fill) {
			release()
			return useResurrectionFill(ctx, sess, chars, hub, keeper, characterID, fill, g, req, fail)
		}
		// Round 838: a return scroll's fill (vslot_007's TypeID3 3 branch,
		// 0x654258 / 0x65423b) runs the scroll's own routine.
		if fill.TypeID1 == equipment.TypeItem && fill.TypeID2 == equipment.TypeExpendable && (IsReturnScroll(fill) || IsReverseReturnScroll(fill)) {
			return useScrollFill(ctx, sess, hub, keeper, zerk, characterID, fill, g, req, fail)
		}
		// vslot_007's row test, TypeID3 1 branch: 3/3 expendable, TypeID4 8.
		// Its TypeID3 3 branch's other kinds are not modelled.
		if fill.TypeID1 != equipment.TypeItem || fill.TypeID2 != equipment.TypeExpendable ||
			fill.TypeID3 != recoveryFamily || fill.TypeID4 != berserkPotionKind {
			return fail("that cannot be used", req.ItemID)
		}
		// FUN_004a05b0, in its order: dead, berserk, five orbs.
		if deadBySession(hub, sess) {
			return fail(deadRefusal, req.ItemID)
		}
		owned, err := chars.GetByID(ctx, characterID)
		if err != nil || owned == nil {
			return fail("lookup failed", req.ItemID)
		}
		zerk.EnsureSeeded(characterID, owned.HwanCount)
		if zerk.Active(characterID) {
			return fail(berserkPotionRefusal, req.ItemID)
		}
		if zerk.Charges(characterID) >= berserk.Orbs {
			return fail(compositeCannotUse, req.ItemID)
		}
		// NOT MODELLED (OPEN): FUN_004a0600 first calls vtable +0x4b0,
		// CGObjPC::vslot_300 (0x4ef340), with FUN_0048b840(.., 1)'s float
		// (0x4a0614..0x4a0629). vslot_300 is GObjPC::FUN_004a9430 (0x4a9430):
		// when the mobile's +0x4c0 answers non-zero it calls
		// CGObjMobile::vslot_300 (0x48b730, both move controllers' +0x18),
		// may send 0xB023 (NetProcessInNavAndSkill on the client), copies
		// the position block (+0x7c..+0x90 into +0xa10..), and resets the
		// stance when the body state is 2 or 3 -- INFERRED a movement stop.
		// Item_HandleUseItem makes the same call on one of its paths (after
		// its vtable +0xb8 / +0x44c tests), and OpenSRO's item uses do not
		// stop movement on any.
		//
		// FUN_004a0600: AddHwanCount(Param1 byte). The count is PERSISTED
		// FIRST (composite review): a store error then leaves the grant, the
		// bonus, the cooldown and the live orbs as they were.
		after := zerk.Charges(characterID) + int(uint8(fill.RestoreHP))
		if after > berserk.Orbs {
			after = berserk.Orbs
		}
		if err := chars.SetHwanCount(ctx, characterID, after); err != nil {
			return fail("using failed", req.ItemID)
		}
		// The last use ends the grant and the 0x706874 job and arms the
		// fill's COOLTIME (OURS: not for a GM).
		if g.remaining == 1 {
			keeper.end(characterID, req.ItemID)
			zerk.ClearDurationBonus(characterID)
			if fill.CooltimeMs > 0 && !isGM {
				itemCooldowns.ArmItem(characterID, fill.ID, fill.CooltimeGroup, time.Duration(fill.CooltimeMs)*time.Millisecond, now)
			}
		} else {
			keeper.setRemaining(characterID, req.ItemID, g.remaining-1)
		}
		zerk.Add(characterID, int(uint8(fill.RestoreHP)))
		if err := sess.Send(&proto.Packet{Opcode: OpCompositeUseResult, Data: (&CompositeUseResult{
			ItemID: req.ItemID, Remaining: int32(g.remaining - 1),
			BerserkGauge: int32(zerk.Gauge(characterID)), BerserkActive: zerk.Active(characterID),
		}).Encode()}); err != nil {
			return err
		}
		return sendCompositeState(sess, keeper, zerk, characterID, now)
	}
}

// BerserkDisconnectHandler forgets a leaving character's berserk and
// composite bookkeeping (composite review): the tracker's charges, active
// window, turn and an expired duration bonus (berserk.Tracker.Forget -- the
// charges are persisted and reseeded on return), and the keeper's session
// binding, expired grants and empty map (CompositeKeeper.Forget). Running
// grants and a running bonus stay until their timers end them. It runs before
// the world's own disconnect, while the hub still knows the session; a
// character still live on another session is left alone.
func BerserkDisconnectHandler(hub *world.Hub, zerk *berserk.Tracker, keeper *CompositeKeeper) func(sess *gateway.Session) {
	return func(sess *gateway.Session) {
		if hub == nil || sess == nil {
			return
		}
		e, ok := hub.EntityBySession(sess.ID())
		if !ok {
			return
		}
		if live, ok := hub.EntityByCharacterID(e.CharacterID); ok && live.Session != nil && live.Session != sess {
			return
		}
		if zerk != nil {
			zerk.Forget(e.CharacterID)
		}
		if keeper != nil {
			keeper.Forget(e.CharacterID, useItemClock())
		}
	}
}

// startUsu1Buff starts a USU1 skill job's buff on characterID, cast by
// itself, lasting lasts (usu1Duration), and tells the zone (OpBuffStart),
// under the owner's buff lock as every buff start is. Since round 838 the job
// is recorded (startSkillJobLocked, itemskill.go), so the buff outlives a
// relog as the engine's timed job does.
func startUsu1Buff(ctx context.Context, hub *world.Hub, ref *refdata.Skill, lasts time.Duration, characterID, itemID int64, now time.Time) bool {
	l := buffLock(characterID)
	l.Lock()
	defer l.Unlock()
	return startSkillJobLocked(ctx, hub, ref, lasts, characterID, itemID, now)
}
