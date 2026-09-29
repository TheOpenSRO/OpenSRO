package session

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/berserk"
	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/equipment"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/gm"
	"github.com/OpenSRO/srrevamp/server/internal/inventory"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/refdata"
	"github.com/OpenSRO/srrevamp/server/internal/world"
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
// OURS: srrevamp's own opcodes (0x0104-0x0107) carry this, not 0x715f/0xb15f.
// OURS, the user's request: a GM account consults and arms neither the
// scroll's nor the fill's COOLTIME.
//
// Not modelled (disclosed): the grant and the bonus are in memory, so a
// server restart loses them (the engine's timed jobs survive a relog through
// their __time32_t stamps -- srrevamp's survive a relog too, not a restart);
// the UIU1 branch for a TypeID4-4 item (a skill-like buff, FUN_0049a400) and
// every other FourCC (BCS1, BFI1, PSU1, UQL1, USL1, USU1) are refused as
// "that cannot be used"; the engine's order queues the UIL1 job before it
// meets a running 0x706874 job, srrevamp checks both first.
const (
	OpCompositeUse       uint16 = 0x0104 // client -> server: spend a granted fill
	OpCompositeUseResult uint16 = 0x0105 // server -> client
	OpCompositeList      uint16 = 0x0106 // client -> server: what grants do I hold
	OpCompositeState     uint16 = 0x0107 // server -> client: the grants and the bonus (reply and push)
)

// The authored texts of the codes this path answers (textuisystem.txt,
// Media.pk2): 0x1894 UIIT_SKILL_USE_FAIL_OVERLAP, 0x18c6
// UIIT_MSG_PREMIUM_USE_OVER, 0x183e UIIT_MSG_STRGERR_CANNOT_BE_USED.
const (
	compositeOverlapRefusal = "The selected item cannot be used together or the skill is already in use."
	compositeUsedUpRefusal  = "Exceeded one day use limit."
	compositeCannotUse      = "The selected item is unusable."
)

// hwanTimeFourCC is the UIU1 buff item's Param2, the "ParamKeeper FourCC"
// CTJ_CharParamKeeper maps to param 60 (0x6552fe). The only one srrevamp
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
		if e.fourCC == "UIL1" {
			if len(fields) != 4 || (fields[1] != "A" && fields[1] != "P") {
				return nil, fmt.Errorf("composite: UIL1 %q: want code,A|P,seconds,count", body)
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
}

// CompositeKeeper holds every character's UIL1 grants (CTJ_CompositeItemKeeper
// in the engine). Process-wide and in memory.
type CompositeKeeper struct {
	mu     sync.Mutex
	grants map[int64]map[int64]*compositeGrant // character -> fill id -> grant
}

func NewCompositeKeeper() *CompositeKeeper {
	return &CompositeKeeper{grants: map[int64]map[int64]*compositeGrant{}}
}

// running returns the character's unexpired grants, dropping expired ones.
func (k *CompositeKeeper) running(characterID int64, now time.Time) []*compositeGrant {
	k.mu.Lock()
	defer k.mu.Unlock()
	var out []*compositeGrant
	for id, g := range k.grants[characterID] {
		if !now.Before(g.until) {
			delete(k.grants[characterID], id)
			continue
		}
		cp := *g
		out = append(out, &cp)
	}
	return out
}

func (k *CompositeKeeper) get(characterID, fillID int64, now time.Time) (*compositeGrant, bool) {
	k.mu.Lock()
	defer k.mu.Unlock()
	g, ok := k.grants[characterID][fillID]
	if !ok || !now.Before(g.until) {
		return nil, false
	}
	cp := *g
	return &cp, true
}

func (k *CompositeKeeper) put(characterID int64, g compositeGrant) {
	k.mu.Lock()
	defer k.mu.Unlock()
	m := k.grants[characterID]
	if m == nil {
		m = map[int64]*compositeGrant{}
		k.grants[characterID] = m
	}
	m[g.fillID] = &g
}

func (k *CompositeKeeper) setRemaining(characterID, fillID int64, remaining int) {
	k.mu.Lock()
	defer k.mu.Unlock()
	if g, ok := k.grants[characterID][fillID]; ok {
		g.remaining = remaining
	}
}

func (k *CompositeKeeper) end(characterID, fillID int64) {
	k.mu.Lock()
	defer k.mu.Unlock()
	delete(k.grants[characterID], fillID)
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
	bonusSecs  int // the param-60 value (Param3 of the UIU1 item)
	bonusFor   time.Duration
	bonusValid bool
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
		part, err := byCode.GetItemByCode(ctx, e.code)
		if err != nil || part == nil {
			return plan, "that cannot be used"
		}
		switch e.fourCC {
		case "UIL1":
			if _, running := keeper.get(characterID, part.ID, now); running { // FUN_0049a460(UIL1, id)
				return plan, compositeOverlapRefusal
			}
			remaining := e.count
			if e.flagP {
				remaining = e.count - 1
			}
			plan.grants = append(plan.grants, compositeGrant{
				fillID: part.ID, scrollID: scroll.ID, remaining: remaining, max: e.count,
				until: now.Add(time.Duration(e.seconds) * time.Second),
			})
		case "UIU1":
			// Only the 3/3/3/10 param-keeper buff with FourCC 0x706874 is
			// modelled; its Param1..3 are exported as RestoreHP, the packed
			// ReinforceRate1 (Param2, u32) and ReinforceRate2 (Param3).
			if part.TypeID4 == 4 || part.ReinforceRate1 != hwanTimeFourCC {
				return plan, "that cannot be used"
			}
			if secs, _ := zerk.DurationBonus(characterID, now); secs != 0 { // FUN_00411560(10, fourcc)
				return plan, compositeOverlapRefusal
			}
			plan.bonusSecs = int(part.ReinforceRate2)
			plan.bonusFor = time.Duration(part.RestoreHP) * time.Second
			plan.bonusValid = true
		default:
			return plan, "that cannot be used"
		}
	}
	return plan, ""
}

// useCompositeScroll is the scroll's use: COOLTIME gate, the plan's
// refusals, the spend, the jobs, the COOLTIME arm. isGM skips the COOLTIME
// (OURS).
func useCompositeScroll(ctx context.Context, sess *gateway.Session, fail func(string) error,
	inv inventory.Store, items combat.ItemLookup, keeper *CompositeKeeper, zerk *berserk.Tracker, isGM bool,
	characterID int64, it *refdata.Item, held inventory.Slot, have int) error {
	if keeper == nil || zerk == nil {
		return fail("that cannot be used")
	}
	now := useItemClock()
	cooltime := it.CooltimeMs > 0 && !isGM
	if cooltime && !itemCooldowns.ReadyItem(characterID, it.ID, it.CooltimeGroup, now) {
		return fail("wait for the reuse delay")
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
	for _, g := range plan.grants {
		keeper.put(characterID, g)
	}
	if plan.bonusValid {
		zerk.SetDurationBonus(characterID, plan.bonusSecs, now.Add(plan.bonusFor))
	}
	if cooltime {
		itemCooldowns.ArmItem(characterID, it.ID, it.CooltimeGroup, time.Duration(it.CooltimeMs)*time.Millisecond, now)
	}
	if err := sess.Send(&proto.Packet{Opcode: OpUseItemResult, Data: (&UseItemResult{Remaining: int32(have - 1)}).Encode()}); err != nil {
		return err
	}
	return sendCompositeState(sess, keeper, zerk, characterID, now)
}

// CompositeUseRequest spends one use of a granted item.
type CompositeUseRequest struct {
	CharacterName string
	ItemID        int64
}

func (r *CompositeUseRequest) Encode() []byte {
	return append(encodeStrings(r.CharacterName), encodeInt64(r.ItemID)...)
}

func DecodeCompositeUseRequest(data []byte) (*CompositeUseRequest, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding CompositeUseRequest: %w", err)
	}
	id, _, err := decodeInt64(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding CompositeUseRequest: item: %w", err)
	}
	return &CompositeUseRequest{CharacterName: fields[0], ItemID: id}, nil
}

// CompositeUseResult answers a fill: the error text, the item, the uses
// left, and the orbs after it (0..berserk.Max, orbs x 20) and berserk state.
type CompositeUseResult struct {
	Error         string
	ItemID        int64
	Remaining     int32
	BerserkGauge  int32
	BerserkActive bool
}

func (r *CompositeUseResult) Encode() []byte {
	out := append(encodeStrings(r.Error), encodeInt64(r.ItemID)...)
	buf := make([]byte, 9)
	binary.LittleEndian.PutUint32(buf[0:4], uint32(r.Remaining))
	binary.LittleEndian.PutUint32(buf[4:8], uint32(r.BerserkGauge))
	if r.BerserkActive {
		buf[8] = 1
	}
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
	return &CompositeUseResult{Error: fields[0], ItemID: id,
		Remaining:     int32(binary.LittleEndian.Uint32(rest[0:4])),
		BerserkGauge:  int32(binary.LittleEndian.Uint32(rest[4:8])),
		BerserkActive: rest[8] != 0}, nil
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
			return sendCompositeState(sess, keeper, zerk, characterID, useItemClock())
		case OpCompositeUse:
		default:
			return nil
		}
		req, err := DecodeCompositeUseRequest(p.Data)
		fail := func(reason string, itemID int64) error {
			return sess.Send(&proto.Packet{Opcode: OpCompositeUseResult, Data: (&CompositeUseResult{Error: reason, ItemID: itemID}).Encode()})
		}
		if err != nil {
			return fail("malformed request", 0)
		}
		characterID, errStr := resolveCharacterID(ctx, sess, chars, req.CharacterName)
		if errStr != "" {
			return fail(errStr, req.ItemID)
		}
		if keeper == nil || zerk == nil || items == nil {
			return fail("that cannot be used", req.ItemID)
		}
		username, _ := AuthenticatedUsername(sess)
		isGM := gate.Allows(username)
		now := useItemClock()
		release := zerk.Turn(characterID)
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
		// vslot_007's row test, TypeID3 1 branch: 3/3 expendable, TypeID4 8.
		// Its TypeID3 3 and 13 branches (other recovery, resurrection) are
		// not modelled.
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
		// FUN_004a0600: AddHwanCount(Param1 byte).
		zerk.Add(characterID, int(uint8(fill.RestoreHP)))
		if err := chars.SetHwanCount(ctx, characterID, zerk.Charges(characterID)); err != nil {
			return fmt.Errorf("composite: persisting berserk fill: %w", err)
		}
		if err := sess.Send(&proto.Packet{Opcode: OpCompositeUseResult, Data: (&CompositeUseResult{
			ItemID: req.ItemID, Remaining: int32(g.remaining - 1),
			BerserkGauge: int32(zerk.Gauge(characterID)), BerserkActive: zerk.Active(characterID),
		}).Encode()}); err != nil {
			return err
		}
		return sendCompositeState(sess, keeper, zerk, characterID, now)
	}
}
