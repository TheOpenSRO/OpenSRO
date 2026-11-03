package session

// Alchemy (round 768): the alchemy window's strengthening tab -- an elixir
// reinforce, a magic stone, an attribute stone -- run the way
// SR_GameServer.exe runs it (docs/protocol/alchemy.md, "Round 768"; the rules
// themselves are internal/alchemy's).
//
// READ (gs): the requests 0x7150/0x7151 reach GObjPC_HandleAlchemyReinforceMsg
// (0x506e20 / 0x506ee0, one body): `u8 action`; 2 starts, anything else
// cancels. A start carries `u8 op` (3 elixir, 4 magic or bless stone, 5
// attribute stone; 7 avatar and 8 advanced elixir are not built), `u8 n` and
// n inventory slots, each 13..111 (the bag, after the 13 equipment slots).
// FUN_00507cf0 checks the slots (0x5414 out of range, 3 empty), wants the
// first to be equipment (0x5408), and hands each to the operation's loader,
// which places it by kind (0x5410 not this operation's, 0x5412 twice). A
// refusal answers `u8 2, u16 code` on the operation's reply (0xB150 for
// 3/6/8, 0xB151 for 4/5) and nothing is spent. Otherwise the operation waits
// for the character's 1-second PeriodicUpdate to count to 3 and runs on the
// next tick: 3 to 4 s after the request. Then MakeAttempt checks the rest
// (slot 4: no recipe 0x5407, the elixir not for this kind 0x5409; slot 5: the
// powder's degree 0x540a) and rolls. The reply is
//
//	u8 1, u8 2, u8 success, u8 target slot (13..111),
//	[0xB150, failed: u8 destroyed], [unless destroyed: the item record]
//
// and a stone's lost roll or later refusal is `u8 2, u16 code` (0x5423 for
// the roll). A cancel before the run answers `u8 1, u8 1`; with nothing
// pending, nothing.
//
// OURS: the opcodes. OpenSRO's requests carry no retail opcode, so one
// request (0x0113) carries 0x7150's body for every operation, and the two
// replies keep retail's split: 0x0114 carries 0xB150's body, 0x0115
// 0xB151's. 0x0113..0x0115 were free on 2026-10-11 (the highest ops in
// server/internal and client/scripts/net were the recall pair, 0x0111 and
// 0x0112). The client pins them (client/scripts/net/alchemy.gd).
//
// OURS, each disclosed where it is made: the 4 s wait (no per-character
// 1-second job here; the top of the READ window); params 172 and 173, the
// stone and reinforce bonuses, are 0 (OpenSRO has no source of either); the
// magic cube and the advanced elixir are refused as not this operation's
// stuff; a slot whose item changed while the operation waited cancels it; a
// second start while one waits is dropped unanswered (the client never sends
// one); an operation whose character left the world in the wait is dropped
// with nothing spent; FUN_00502910's expiry test (0x5410 for an expired
// item) is not made -- OpenSRO has no rentals. FUN_00507fe0's 0x540f test (a
// devil's spirit needs ref Param2 == 1) is made since round 789, and op 7
// answers retail's dead end (avatar.go).

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/alchemy"
	"github.com/TheOpenSRO/OpenSRO/server/internal/durability"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/magicopt"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/txn"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

const (
	OpAlchemy                uint16 = 0x0113 // client -> server: 0x7150's body
	OpAlchemyReinforceResult uint16 = 0x0114 // server -> client: 0xB150's body
	OpAlchemyStoneResult     uint16 = 0x0115 // server -> client: 0xB151's body
)

// The request's action byte and the operations (READ, gs 0x506e20,
// FUN_00507cf0; the client's senders 0x825c50 / 0x825dc0).
const (
	AlchemyActionCancel = 1
	AlchemyActionStart  = 2

	AlchemyOpReinforce = 3
	AlchemyOpMagic     = 4
	AlchemyOpAttr      = 5
	AlchemyOpAvatar    = 7
	AlchemyOpUpper     = 8
)

// The reply's envelope (READ, the client's handlers 0x8729e0 / 0x872cd0).
const (
	alchemyOK            = 1
	alchemyRefused       = 2
	alchemyKindCancelled = 1
	alchemyKindDone      = 2
)

// The request-time refusals FUN_00507cf0 adds to the family's 0x54xx codes
// (READ, asm 0x507e74..0x507f5f): a slot outside 13..111, and an empty one.
const (
	AlchemyErrInvalidSlot = 0x5414 // UIIT_MSG_REINFORCERR_INVALID_ITEM_SLOT
	AlchemyErrEmptySlot   = 3
)

// AlchemyFirstBagSlot is the wire slot of bag index 0: the 13 equipment
// slots come first (equipment.MaxEquipSlots). The last wire slot the server
// accepts is 111.
const (
	AlchemyFirstBagSlot = 13
	AlchemyLastBagSlot  = 111
)

// AlchemyDelay is how long an operation waits before it runs: OURS, 4 s, the
// top of the READ window (the 4th tick of a 1-second job, 3 to 4 s after the
// request). The client's own gauge fills in 3.0 s (READ, c:0xd8adc4), so the
// answer lands after it.
var AlchemyDelay = 4 * time.Second

// alchemyAfter runs f after d; a test replaces it.
var alchemyAfter = func(d time.Duration, f func()) { time.AfterFunc(d, f) }

// alchemyRand is the operations' rand(); a test replaces it.
var alchemyRand alchemy.Rand = defaultCombatRand{}

// AlchemyRequest is the OpAlchemy payload.
type AlchemyRequest struct {
	Action int
	Op     int
	// Slots are the wire slots, bag index + 13.
	Slots []int
}

// DecodeAlchemyRequest reads `u8 action`, and for a start `u8 op, u8 n, n x
// u8 slot`.
func DecodeAlchemyRequest(data []byte) (*AlchemyRequest, error) {
	if len(data) < 1 {
		return nil, errors.New("session: decoding AlchemyRequest: empty")
	}
	r := &AlchemyRequest{Action: int(data[0])}
	if r.Action != AlchemyActionStart {
		return r, nil
	}
	if len(data) < 3 {
		return nil, fmt.Errorf("session: decoding AlchemyRequest: %d bytes", len(data))
	}
	r.Op = int(data[1])
	n := int(data[2])
	if len(data) != 3+n {
		return nil, fmt.Errorf("session: decoding AlchemyRequest: %d slots in %d bytes", n, len(data))
	}
	for _, b := range data[3:] {
		r.Slots = append(r.Slots, int(b))
	}
	return r, nil
}

// Encode is the client's form, for tests.
func (r *AlchemyRequest) Encode() []byte {
	if r.Action != AlchemyActionStart {
		return []byte{byte(r.Action)}
	}
	out := []byte{byte(r.Action), byte(r.Op), byte(len(r.Slots))}
	for _, s := range r.Slots {
		out = append(out, byte(s))
	}
	return out
}

// AlchemyResult is either reply's payload.
type AlchemyResult struct {
	OK        bool
	Code      uint16 // a refusal's
	Cancelled bool
	Success   bool
	// Slot is the wire slot of the target.
	Slot int
	// Destroyed is sent only on a failed elixir reinforce (0xB150).
	Destroyed bool
	// Record is the target afterwards, nil when it was destroyed.
	Record *ItemInfo
}

// EncodeReinforce is 0xB150's body, EncodeStone 0xB151's: the same but for
// the destroyed byte.
func (r *AlchemyResult) EncodeReinforce() []byte { return r.encode(true) }
func (r *AlchemyResult) EncodeStone() []byte     { return r.encode(false) }

func (r *AlchemyResult) encode(reinforce bool) []byte {
	if !r.OK {
		return []byte{alchemyRefused, byte(r.Code), byte(r.Code >> 8)}
	}
	if r.Cancelled {
		return []byte{alchemyOK, alchemyKindCancelled}
	}
	out := []byte{alchemyOK, alchemyKindDone, boolByte(r.Success), byte(r.Slot)}
	if reinforce && !r.Success {
		out = append(out, boolByte(r.Destroyed))
	}
	if r.Record != nil && (r.Success || !r.Destroyed) {
		out = AppendItemRecord(out, *r.Record)
	}
	return out
}

// DecodeAlchemyResult reads either reply; reinforce says which.
func DecodeAlchemyResult(data []byte, reinforce bool) (*AlchemyResult, error) {
	bad := fmt.Errorf("session: decoding AlchemyResult: % x", data)
	if len(data) < 2 {
		return nil, bad
	}
	if data[0] == alchemyRefused {
		if len(data) != 3 {
			return nil, bad
		}
		return &AlchemyResult{Code: uint16(data[1]) | uint16(data[2])<<8}, nil
	}
	if data[0] != alchemyOK {
		return nil, bad
	}
	if data[1] == alchemyKindCancelled {
		return &AlchemyResult{OK: true, Cancelled: true}, nil
	}
	if data[1] != alchemyKindDone || len(data) < 4 {
		return nil, bad
	}
	r := &AlchemyResult{OK: true, Success: data[2] != 0, Slot: int(data[3])}
	rest := data[4:]
	if reinforce && !r.Success {
		if len(rest) < 1 {
			return nil, bad
		}
		r.Destroyed, rest = rest[0] != 0, rest[1:]
	}
	if r.Success || !r.Destroyed {
		rec, _, err := ReadItemRecord(rest)
		if err != nil {
			return nil, err
		}
		r.Record = &rec
	}
	return r, nil
}

// alchemyResultOp is the reply an operation answers on (READ, the jump table
// at gs 0x507fc8): 0xB150 for the reinforces, 0xB151 for the stones.
func alchemyResultOp(op int) uint16 {
	if op == AlchemyOpMagic || op == AlchemyOpAttr {
		return OpAlchemyStoneResult
	}
	return OpAlchemyReinforceResult
}

func alchemySend(sess *gateway.Session, op int, r *AlchemyResult) error {
	if alchemyResultOp(op) == OpAlchemyStoneResult {
		return sess.Send(&proto.Packet{Opcode: OpAlchemyStoneResult, Data: r.EncodeStone()})
	}
	return sess.Send(&proto.Packet{Opcode: OpAlchemyReinforceResult, Data: r.EncodeReinforce()})
}

// The operation's slot array (READ, the PC's +0x2242 + 12n): 0 the target, 1
// the elixir or stone, 3 the lucky powder.
const (
	alchemySlotTarget = 0
	alchemySlotStuff  = 1
	alchemySlotPowder = 3
	alchemySlots      = 4
)

// alchemyLoaded is one loaded slot: the bag index and what was there.
type alchemyLoaded struct {
	bag  int
	item *refdata.Item
	slot inventory.Slot
}

type alchemyJob struct {
	op    int
	slots [alchemySlots]*alchemyLoaded
	gen   uint64
}

// AlchemyDeps are what the handler needs.
type AlchemyDeps struct {
	Hub     *world.Hub
	Inv     inventory.Store
	Items   ItemLookup
	Options *magicopt.Table
	Logger  *slog.Logger
}

type alchemist struct {
	AlchemyDeps
	mu   sync.Mutex
	jobs map[int64]*alchemyJob
	gen  uint64
}

// AlchemyHandler answers OpAlchemy.
func AlchemyHandler(d AlchemyDeps) gateway.Handler {
	a := &alchemist{AlchemyDeps: d, jobs: map[int64]*alchemyJob{}}
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		if p.Opcode != OpAlchemy {
			return nil
		}
		return a.handle(ctx, sess, p)
	}
}

func (a *alchemist) debug(msg string, attrs ...any) {
	if a.Logger != nil {
		a.Logger.Debug(msg, attrs...)
	}
}

// itemKind reports TypeID1..4 as one comparable tuple.
func itemKind(it *refdata.Item, t1, t2, t3, t4 int) bool {
	return it.TypeID1 == t1 && it.TypeID2 == t2 && it.TypeID3 == t3 && (t4 < 0 || it.TypeID4 == t4)
}

func (a *alchemist) handle(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
	req, err := DecodeAlchemyRequest(p.Data)
	if err != nil {
		a.debug("alchemy: malformed request", "err", err)
		return nil
	}
	if a.Hub == nil {
		return nil
	}
	ent, ok := a.Hub.EntityBySession(sess.ID())
	if !ok {
		return nil
	}
	charID := ent.CharacterID
	if req.Action != AlchemyActionStart {
		// The cancel: only an operation that has not run yet.
		a.mu.Lock()
		job := a.jobs[charID]
		delete(a.jobs, charID)
		a.mu.Unlock()
		if job == nil {
			return nil
		}
		return alchemySend(sess, job.op, &AlchemyResult{OK: true, Cancelled: true})
	}
	refuse := func(code uint16, why string) error {
		a.debug("alchemy refused", "character_id", charID, "op", req.Op, "code", code, "why", why)
		return alchemySend(sess, req.Op, &AlchemyResult{Code: code})
	}
	a.mu.Lock()
	busy := a.jobs[charID] != nil
	a.mu.Unlock()
	if busy {
		// OURS: the client refuses a second start while busy; the server
		// answers nothing to one that arrives anyway.
		a.debug("alchemy: a second start while one is pending", "character_id", charID)
		return nil
	}
	if a.Inv == nil || a.Items == nil {
		return refuse(alchemy.ErrNotReinforceStuff, "no inventory or item table")
	}
	switch req.Op {
	case AlchemyOpReinforce, AlchemyOpMagic, AlchemyOpAttr:
	case AlchemyOpAvatar:
		// Round 789: op 7, the avatar enchant, is dead in this build: its
		// _BlessItem never has an option name and ends in 2, nothing spent
		// (avatar.go, avatarEnchantRefusal). The request's own checks come
		// first, as retail's.
		return refuse(avatarEnchantRefusal(ctx, a.Inv, a.Items, charID, req.Slots), "the avatar enchant is dead in retail")
	default:
		return refuse(alchemy.ErrNotReinforceStuff, "operation not built")
	}
	bag, err := a.Inv.List(ctx, charID)
	if err != nil {
		return refuse(alchemy.ErrNotReinforceStuff, "reading the bag: "+err.Error())
	}
	job := &alchemyJob{op: req.Op}
	for i, wire := range req.Slots {
		if wire < AlchemyFirstBagSlot || wire > AlchemyLastBagSlot {
			return refuse(AlchemyErrInvalidSlot, "slot out of range")
		}
		idx := wire - AlchemyFirstBagSlot
		var found *inventory.Slot
		for k := range bag {
			if bag[k].Index == idx {
				found = &bag[k]
			}
		}
		if found == nil {
			return refuse(AlchemyErrEmptySlot, "slot empty")
		}
		it, err := a.Items.GetItem(ctx, found.ItemID)
		if err != nil {
			return refuse(alchemy.ErrNotReinforceStuff, "unknown item")
		}
		if i == 0 && !isEquipment(it) {
			return refuse(alchemy.ErrOnlyEquipCanBeReinforced, "the first slot is not equipment")
		}
		// FUN_00507fe0 (READ gs:0x507fe0, round 789): a devil's spirit whose
		// itemdata Param2 (ref +0x2c0, RestoreHPPct's column 120) is not 1
		// cannot be reinforced, 0x540f (MEASURED: the two 7-day event rows).
		if i == 0 && timeLimited(it) && it.RestoreHPPct != 1 {
			return refuse(alchemy.ErrTargetCannotBeReinforced, "a devil's spirit whose Param2 is not 1")
		}
		at, code := alchemyLoadSlot(req.Op, it, found)
		if code != alchemy.Success {
			return refuse(uint16(code), "the loader refused it")
		}
		if job.slots[at] != nil {
			return refuse(alchemy.ErrStuffLoadedTwice, "slot loaded twice")
		}
		job.slots[at] = &alchemyLoaded{bag: idx, item: it, slot: *found}
	}
	a.mu.Lock()
	a.gen++
	job.gen = a.gen
	a.jobs[charID] = job
	a.mu.Unlock()
	alchemyAfter(AlchemyDelay, func() { a.run(sess, charID, job) })
	return nil
}

// alchemyLoadSlot is each operation's slot-0 loader (READ): where an item
// goes, or why it does not.
//   - Reinforce (0x505bd0): equipment to the target, refused past +249
//     (0x540f); an elixir (3/3/10/1) to the stuff slot; a lucky powder
//     (3/3/10/2) to the powder slot. The magic cube (3/2/3/1) is not built
//     (OURS: refused as not reinforce stuff).
//   - Magic stone (0x503ee0): equipment, or a magic (3/3/11/1) or bless
//     (3/3/11/7) stone.
//   - Attribute stone (0x5029a0): equipment, or 3/3/11/2. (The binary has
//     no refusal for anything else -- it stores at index -1; OURS: 0x5410.)
func alchemyLoadSlot(op int, it *refdata.Item, s *inventory.Slot) (int, int) {
	if isEquipment(it) {
		if op == AlchemyOpReinforce && int(s.OptLevel) >= alchemy.MaxPlus {
			return 0, alchemy.ErrTargetCannotBeReinforced
		}
		return alchemySlotTarget, alchemy.Success
	}
	switch op {
	case AlchemyOpReinforce:
		if itemKind(it, 3, 3, 10, 1) {
			return alchemySlotStuff, alchemy.Success
		}
		if itemKind(it, 3, 3, 10, 2) {
			return alchemySlotPowder, alchemy.Success
		}
	case AlchemyOpMagic:
		if itemKind(it, 3, 3, 11, 1) || itemKind(it, 3, 3, 11, 7) {
			return alchemySlotStuff, alchemy.Success
		}
	case AlchemyOpAttr:
		if itemKind(it, 3, 3, 11, 2) {
			return alchemySlotStuff, alchemy.Success
		}
	}
	return 0, alchemy.ErrNotReinforceStuff
}

// elixirSuits is CEnchant_Reinforce slot 4's match (0x505cb0; READ): the
// target's TypeID3 is one of the four bytes of the elixir's Param1 or Param5.
func elixirSuits(elixir *refdata.Item, typeID3 int) bool {
	for _, w := range []uint32{elixir.Param1, elixir.Param5} {
		for k := 0; k < 4; k++ {
			if int((w>>(8*k))&0xff) == typeID3 {
				return true
			}
		}
	}
	return false
}

// alchemyTarget reads a bag item into the engine's form. An option id the
// table does not know keeps tag 0 (no rule matches it).
func (a *alchemist) alchemyTarget(l *alchemyLoaded) *alchemy.Target {
	it, s := l.item, l.slot
	t := &alchemy.Target{
		TypeID3: it.TypeID3, TypeID4: it.TypeID4, CodeName: it.CodeName, ItemClass: it.ItemClass,
		Cash: it.CashItem, MaxOptions: it.MaxMagicOptions,
		OptLevel: int(s.OptLevel), Variance: s.Variance, Durability: s.Durability,
	}
	for _, p := range s.MagParams {
		o := alchemy.Option{ID: inventory.MagParamOption(p), Value: inventory.MagParamValue(p)}
		if r := a.Options.ByID(o.ID); r != nil {
			o.Tag = r.Tag
		}
		t.Options = append(t.Options, o)
	}
	return t
}

// alchemyInstance is the target written back.
func alchemyInstance(old inventory.Slot, t *alchemy.Target) inventory.Instance {
	inst := old.Instance()
	inst.OptLevel = uint8(t.OptLevel)
	inst.Variance = t.Variance
	inst.MagParams = nil
	for _, o := range t.Options {
		inst.MagParams = append(inst.MagParams, inventory.MagParam(o.ID, o.Value))
	}
	inst.Durability = t.Durability
	return inst
}

// clampDurability is ClampDurabilityToMax after a change (READ: MakeAttempt
// calls it when the item survives a flawed or successful attempt): the
// current durability no higher than the max the variance and the durability
// options give (alchemy.MaxDurability).
func (a *alchemist) clampDurability(t *alchemy.Target, it *refdata.Item) {
	if t.Durability == durability.Untracked || !durability.Tracked(it.DurabilityMin, it.DurabilityMax) {
		return
	}
	base := durability.MaxDurability(it.DurabilityMin, it.DurabilityMax, t.Variance)
	if m := alchemy.MaxDurability(base, t.Options, a.Options); t.Durability > m {
		t.Durability = m
	}
}

// run is the operation's execution, AlchemyDelay after the request.
func (a *alchemist) run(sess *gateway.Session, charID int64, job *alchemyJob) {
	a.mu.Lock()
	if a.jobs[charID] != job {
		a.mu.Unlock()
		return // cancelled, or replaced
	}
	delete(a.jobs, charID)
	a.mu.Unlock()
	// The character must still be in the world on this session (round 768's
	// review F3): a logout in the wait must not destroy or spend anything
	// afterwards. OURS: retail stops the operation with the character.
	if ent, ok := a.Hub.EntityBySession(sess.ID()); !ok || ent.CharacterID != charID {
		a.debug("alchemy dropped: the character left the world while it waited", "character_id", charID)
		return
	}
	ctx := context.Background()
	refuse := func(code int, why string) {
		a.debug("alchemy refused at the attempt", "character_id", charID, "op", job.op, "code", code, "why", why)
		_ = alchemySend(sess, job.op, &AlchemyResult{Code: uint16(code)})
	}
	cancel := func(why string) {
		a.debug("alchemy interrupted", "character_id", charID, "why", why)
		_ = alchemySend(sess, job.op, &AlchemyResult{OK: true, Cancelled: true})
	}
	// The items must still be where they were loaded (OURS: retail holds
	// the item objects, and the client locks the slots while it waits).
	bag, err := a.Inv.List(ctx, charID)
	if err != nil {
		cancel("reading the bag: " + err.Error())
		return
	}
	if !alchemyUnchanged(bag, job) {
		cancel("an item moved while the operation waited")
		return
	}
	target, stuff, powder := job.slots[alchemySlotTarget], job.slots[alchemySlotStuff], job.slots[alchemySlotPowder]
	// CEnchant::vslot_004, the shared precondition (READ, 0x501cd0).
	if target == nil {
		refuse(alchemy.ErrNoSourceItem, "no target")
		return
	}
	if stuff == nil {
		refuse(alchemy.ErrRecipeNotLoaded, "no elixir or stone")
		return
	}
	t := a.alchemyTarget(target)
	var spend []*alchemyLoaded // what the attempt uses up
	res := &AlchemyResult{OK: true, Slot: target.bag + AlchemyFirstBagSlot}
	destroyed := false
	switch job.op {
	case AlchemyOpReinforce:
		if !elixirSuits(stuff.item, t.TypeID3) {
			refuse(alchemy.ErrRecipeMismatch, "the elixir is not for this kind")
			return
		}
		var powderTiers *[3]uint32
		if powder != nil {
			if powder.item.Param1 != uint32(t.Degree()) {
				refuse(alchemy.ErrEquipClassMismatchProbUp, "the powder's degree")
				return
			}
			tiers := powder.item.ReinforceRates()
			powderTiers = &tiers
		}
		r := alchemy.Reinforce(t, stuff.item.ReinforceRates(), powderTiers, 0, a.Options, alchemyRand)
		res.Success, res.Destroyed, destroyed = r.Success, r.Destroyed, r.Destroyed
		spend = append(spend, stuff)
		if powder != nil {
			spend = append(spend, powder)
		}
		a.debug("alchemy reinforce", "character_id", charID, "rate", r.Rate, "success", r.Success, "destroyed", r.Destroyed, "plus", t.OptLevel)
	case AlchemyOpMagic, AlchemyOpAttr:
		s := alchemy.Stone{Param1: int(stuff.item.Param1), Rate: int(stuff.item.ReinforceRate3),
			Desc1: stuff.item.Desc1, Desc4: stuff.item.Desc4, Assimilation: int(stuff.slot.OptLevel)}
		var r alchemy.StoneResult
		if job.op == AlchemyOpMagic {
			r = alchemy.MagicStone(t, s, 0, a.Options, alchemyRand)
		} else {
			r = alchemy.AttrStone(t, s, 0, a.Options, alchemyRand)
		}
		a.debug("alchemy stone", "character_id", charID, "op", job.op, "rate", r.Rate, "code", r.Code, "before", r.Before, "after", r.After, "assimilated", r.Assimilated)
		if r.Code == alchemy.ErrEnchantFailed {
			// The lost roll spends the stone and leaves the item.
			if err := a.spend(ctx, charID, job, []*alchemyLoaded{stuff}); err != nil {
				cancel("spending the stone: " + err.Error())
				return
			}
			refuse(r.Code, "the roll failed")
			return
		}
		if r.Code != alchemy.Success {
			refuse(r.Code, "refused after the roll")
			return
		}
		res.Success = true
		spend = append(spend, stuff)
	}
	if !destroyed {
		a.clampDurability(t, target.item)
	}
	inst := alchemyInstance(target.slot, t)
	err = txn.For(a.Inv).Run(ctx, func(ctx context.Context) error {
		now, err := a.Inv.List(ctx, charID)
		if err != nil {
			return err
		}
		if !alchemyUnchanged(now, job) {
			return errAlchemyMoved
		}
		if destroyed {
			if err := a.Inv.RemoveItem(ctx, charID, target.bag, target.slot.Quantity); err != nil {
				return err
			}
		} else if err := a.Inv.SetInstance(ctx, charID, target.bag, inst); err != nil {
			return err
		}
		return a.spendIn(ctx, charID, spend)
	})
	if err != nil {
		cancel("writing the result: " + err.Error())
		return
	}
	if !destroyed {
		if info, ok := itemInfoFor(ctx, a.Items, target.bag, target.slot.ItemID, inst); ok {
			res.Record = &info
		}
	}
	_ = alchemySend(sess, job.op, res)
}

var errAlchemyMoved = errors.New("alchemy: an item moved")

// spend spends `used` in its own transaction, the loaded slots checked again
// inside it as the commit does (round 768's review F4).
func (a *alchemist) spend(ctx context.Context, charID int64, job *alchemyJob, used []*alchemyLoaded) error {
	return txn.For(a.Inv).Run(ctx, func(ctx context.Context) error {
		now, err := a.Inv.List(ctx, charID)
		if err != nil {
			return err
		}
		if !alchemyUnchanged(now, job) {
			return errAlchemyMoved
		}
		return a.spendIn(ctx, charID, used)
	})
}

// spendIn is ReleaseLoadedItems (0x501c00; READ): one of each loaded
// elixir, powder or stone.
func (a *alchemist) spendIn(ctx context.Context, charID int64, used []*alchemyLoaded) error {
	for _, l := range used {
		if err := a.Inv.RemoveItem(ctx, charID, l.bag, 1); err != nil {
			return err
		}
	}
	return nil
}

// alchemyUnchanged reports whether every loaded slot still holds the same
// item, count and instance.
func alchemyUnchanged(bag []inventory.Slot, job *alchemyJob) bool {
	for _, l := range job.slots {
		if l == nil {
			continue
		}
		ok := false
		for _, s := range bag {
			if s.Index == l.bag {
				ok = s.ItemID == l.slot.ItemID && s.Quantity == l.slot.Quantity && s.Instance().Equal(l.slot.Instance())
			}
		}
		if !ok {
			return false
		}
	}
	return true
}
