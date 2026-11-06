package session

import (
	"context"
	"encoding/binary"
	"errors"
	"log/slog"
	"sync"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/berserk"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/timedjob"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// The composite's BFI1 and UQL1 entries (round 838), both type-5
// CTJ_CompositeItemKeeper jobs keyed by the composite scroll. READ,
// SR_GameServer.exe:
//
//   - BFI1 "[BFI1:<item>,A|P,<seconds>]", a buff item: BUFF_ITEM::vslot_001
//     (0x8646b0) reads the code, the flag and the seconds (no count). The
//     pre-check (0x49f3d9, shared with UIL1) refuses 0x1894 while a BFI1 job
//     for that item runs (FUN_0049a460('BFI1', id)); the branch
//     (0x49f847..0x49f91a) needs the item to be a 3/3/3/4 stall decoration
//     (0x489120, else nothing is queued) and queues the job with end = now +
//     seconds and the decoration's id; its work object CBuffItem (0x6544b0)
//     sends 0x315C at the start (0x654580) and 0x315D at a refresh
//     (0x654630), {u32 key, u32 seconds left, u32 decoration}, and 0x315E at
//     the end (0x654710), {u32 key, u32 decoration}. The client only records
//     it (0x899480 -> FUN_00805290, CIFMagicStateBoard +0x394, no icon). When
//     the player opens a stall with one recorded, the client asks
//     UIIT_MSG_PREMIUM_AVATAR_SHOP_USE ("Establish as an avatar stall?") and on
//     Yes sends 0x7160 {u32 key, u32 decoration} per entry (FUN_00803e00);
//     the server (FUN_00511730) finds the job by (BFI1, decoration), re-checks
//     the 3/3/3/4 and sets PC+0x21d4 = the decoration (FUN_004f0f20 at
//     0x654857), answering 0xB160 {1, key, decoration} or {2, u16 code}. That
//     override lasts one stall: stall close (FUN_00472cf0, 0x472d55) clears
//     it, and the job's end does not. The stall's look (getter 0x4f0f00,
//     into 0x30B8 and the spawn's stall branch) is the override when set,
//     else the character's own permanent decoration -- the one a used 3/3/3/4
//     item writes (vslot_307 case 4 -> FUN_004a3f10), which is a different
//     store.
//   - UQL1 "[UQL1:<quest>,A|P,<seconds>,<count>]", a used quest limit: the
//     UIL1 parser (FUN_00864500); the pre-check needs the quest to exist; the
//     branch (0x49fb41..0x49fbed) queues the job with the quest, the seconds
//     and count<<16 | count (the flag is not read). Its CUsedQuestLimit
//     (0x6543d0) sends nothing (+0xc = 0 gates every 0x3159..0x315B). The
//     premium's QSP_ALL_POTION_3 is questdata 224, "<Premium> Seed of
//     Purification", the hard-coded CQSP_ALL_POTION_3 (0x88e7c0): its seed
//     drops need the grant, a running unpaused Gold Time in the battle state
//     and a count left, and each turn-in spends one of the 4 completions.
//
// OURS: both are kept in timedjob.Store. OpenSRO has no stalls and does not
// run quest 224 (OPEN): the BFI1 grant is told to the client and answers
// 0x7160 with the override (StallDecorationOverride / ClearStallDecoration
// for the stall code to read and clear), and the UQL1 grant is kept and
// counted (UseQuestGrant) for the quest when it exists.
const (
	OpBuffItemStart   uint16 = 0x315C // server -> client: a BFI1 grant
	OpBuffItemRefresh uint16 = 0x315D
	OpBuffItemEnd     uint16 = 0x315E
	OpAvatarStallUse  uint16 = 0x7160 // client -> server: use a BFI1 decoration for this stall
	OpAvatarStallAck  uint16 = 0xB160
)

// compositeExtra is one running BFI1 or UQL1 grant.
type compositeExtra struct {
	fourCC    string
	refID     int64 // the decoration item, or the quest id
	scrollID  int64
	until     time.Time
	remaining int
	max       int
	gen       uint64
}

// putExtra stores e for characterID and starts its end timer.
func (k *CompositeKeeper) putExtra(characterID int64, e compositeExtra, now time.Time, save bool) {
	k.mu.Lock()
	k.gen++
	e.gen = k.gen
	list := k.extras[characterID][:0:0]
	for _, x := range k.extras[characterID] {
		if !(x.fourCC == e.fourCC && x.refID == e.refID) {
			list = append(list, x)
		}
	}
	cp := e
	k.extras[characterID] = append(list, &cp)
	store, sess := k.store, k.sessions[characterID]
	k.mu.Unlock()
	if save && store != nil {
		_ = store.Put(context.Background(), timedjob.Job{CharID: characterID, Type: timedjob.TypeComposite, Sub: e.fourCC,
			Ref: e.refID, Key: e.scrollID, Start: now, End: e.until, V1: int64(e.remaining), V2: int64(e.max)})
	}
	if e.fourCC == "BFI1" {
		sendBuffItem(sess, OpBuffItemStart, e, now)
	}
	gen := e.gen
	time.AfterFunc(e.until.Sub(now), func() { k.expireExtra(characterID, e.fourCC, e.refID, gen) })
}

// extra returns characterID's running grant of that kind for refID.
func (k *CompositeKeeper) extra(characterID int64, fourCC string, refID int64, now time.Time) (compositeExtra, bool) {
	k.mu.Lock()
	defer k.mu.Unlock()
	for _, x := range k.extras[characterID] {
		if x.fourCC == fourCC && x.refID == refID && now.Before(x.until) {
			return *x, true
		}
	}
	return compositeExtra{}, false
}

// expireExtra ends the grant the timer was started for.
func (k *CompositeKeeper) expireExtra(characterID int64, fourCC string, refID int64, gen uint64) {
	k.mu.Lock()
	var ended *compositeExtra
	list := k.extras[characterID]
	for i, x := range list {
		if x.gen == gen && x.fourCC == fourCC && x.refID == refID {
			ended = x
			k.extras[characterID] = append(list[:i:i], list[i+1:]...)
			break
		}
	}
	if len(k.extras[characterID]) == 0 {
		delete(k.extras, characterID)
	}
	store, sess := k.store, k.sessions[characterID]
	k.mu.Unlock()
	if ended == nil {
		return
	}
	if store != nil {
		_ = store.Delete(context.Background(), characterID, timedjob.TypeComposite, fourCC, refID)
	}
	if fourCC == "BFI1" {
		sendBuffItemEnd(sess, *ended)
	}
	slog.Info("composite: grant ended", "character_id", characterID, "entry", fourCC, "ref", refID)
}

// UseQuestGrant spends one of characterID's UQL1 completions of quest
// (CGObjPC::UseQuestByCompositeItem 0x4f0f70: remaining > 0, then - 1);
// false when none is left or none runs.
func (k *CompositeKeeper) UseQuestGrant(characterID, quest int64) bool {
	now := useItemClock()
	k.mu.Lock()
	var hit *compositeExtra
	for _, x := range k.extras[characterID] {
		if x.fourCC == "UQL1" && x.refID == quest && now.Before(x.until) && x.remaining > 0 {
			hit = x
			break
		}
	}
	if hit == nil {
		k.mu.Unlock()
		return false
	}
	hit.remaining--
	cp, store := *hit, k.store
	k.mu.Unlock()
	if store != nil {
		_ = store.Put(context.Background(), timedjob.Job{CharID: characterID, Type: timedjob.TypeComposite, Sub: "UQL1",
			Ref: quest, Key: cp.scrollID, Start: now, End: cp.until, V1: int64(cp.remaining), V2: int64(cp.max)})
	}
	return true
}

// buffItemBody is 0x315C / 0x315D's {u32 key, u32 seconds left, u32
// decoration}.
func buffItemBody(e compositeExtra, now time.Time) []byte {
	out := binary.LittleEndian.AppendUint32(nil, uint32(e.scrollID))
	out = binary.LittleEndian.AppendUint32(out, uint32(secondsLeft(e.until, now)))
	return binary.LittleEndian.AppendUint32(out, uint32(e.refID))
}

func sendBuffItem(sess *gateway.Session, op uint16, e compositeExtra, now time.Time) {
	if sess != nil {
		_ = sess.Send(&proto.Packet{Opcode: op, Data: buffItemBody(e, now)})
	}
}

func sendBuffItemEnd(sess *gateway.Session, e compositeExtra) {
	if sess == nil {
		return
	}
	out := binary.LittleEndian.AppendUint32(nil, uint32(e.scrollID))
	_ = sess.Send(&proto.Packet{Opcode: OpBuffItemEnd, Data: binary.LittleEndian.AppendUint32(out, uint32(e.refID))})
}

// compositeArrived loads the arriving character's kept grants once (the
// UIL1 fills, BFI1, UQL1) and tells its client: the fills' state, and each
// BFI1 again as 0x315D.
func compositeArrived(ctx context.Context, arrived world.Entity) {
	k := compositeKeeperNow()
	if k == nil {
		return
	}
	now := useItemClock()
	k.bind(arrived.CharacterID, arrived.Session)
	k.mu.Lock()
	first := !k.loaded[arrived.CharacterID]
	k.loaded[arrived.CharacterID] = true
	store := k.store
	k.mu.Unlock()
	if first && store != nil {
		jobs, err := store.List(ctx, arrived.CharacterID)
		if err == nil {
			for _, j := range jobs {
				if j.Type != timedjob.TypeComposite {
					continue
				}
				if !now.Before(j.End) {
					_ = store.Delete(ctx, j.CharID, j.Type, j.Sub, j.Ref)
					continue
				}
				switch j.Sub {
				case "UIL1":
					if _, running := k.get(arrived.CharacterID, j.Ref, now); !running {
						g := compositeGrant{fillID: j.Ref, scrollID: j.Key, remaining: int(j.V1), max: int(j.V2), until: j.End}
						// Round 864: the refill period and its end (V3, V4);
						// the load refills a period passed while away
						// (slot 1, FUN_00653b40 -> FUN_00653a40).
						if j.V3 > 0 && j.V4 > 0 {
							g.period = time.Duration(j.V3) * time.Second
							g.periodEnd = time.Unix(j.V4, 0)
							g.refill(now)
						}
						k.put(arrived.CharacterID, g, j.End.Sub(now))
					}
				case "BFI1", "UQL1":
					if _, running := k.extra(arrived.CharacterID, j.Sub, j.Ref, now); !running {
						k.putExtra(arrived.CharacterID, compositeExtra{fourCC: j.Sub, refID: j.Ref, scrollID: j.Key,
							until: j.End, remaining: int(j.V1), max: int(j.V2)}, now, false)
					}
				}
			}
			k.restoreDroppedFills(ctx, arrived.CharacterID, jobs, now)
		}
	}
	k.mu.Lock()
	var bfi []compositeExtra
	for _, x := range k.extras[arrived.CharacterID] {
		if x.fourCC == "BFI1" && now.Before(x.until) {
			bfi = append(bfi, *x)
		}
	}
	k.mu.Unlock()
	if !first {
		for _, e := range bfi {
			sendBuffItem(arrived.Session, OpBuffItemRefresh, e, now)
		}
	}
	// Round 864 follow-up: the fills' state is pushed with the entry, as
	// the job's load sends 0x3159 (slot 1, s:0x653b40, READ). The client's
	// own OpCompositeList can come before this hook has loaded the kept rows
	// (MEASURED on a lane server: the list was answered empty 7 s before the
	// load), which left no icon until the next state.
	k.mu.Lock()
	zerk := k.zerk
	k.mu.Unlock()
	if zerk != nil && arrived.Session != nil && len(k.running(arrived.CharacterID, now)) > 0 {
		_ = sendCompositeState(arrived.Session, k, zerk, arrived.CharacterID, now)
	}
}

// The keeper the world-entry hook reaches (set by SetCompositeKeeper).
var compositeKeeperPtr struct {
	mu sync.Mutex
	k  *CompositeKeeper
}

// SetCompositeKeeper names the server's keeper for the world-entry hook
// (round 838).
func SetCompositeKeeper(k *CompositeKeeper) {
	compositeKeeperPtr.mu.Lock()
	defer compositeKeeperPtr.mu.Unlock()
	compositeKeeperPtr.k = k
}

func compositeKeeperNow() *CompositeKeeper {
	compositeKeeperPtr.mu.Lock()
	defer compositeKeeperPtr.mu.Unlock()
	return compositeKeeperPtr.k
}

// The stall decoration a BFI1 grant set for the stall being opened
// (PC+0x21d4), by character.
var stallDecoOverride sync.Map // int64 -> int64

// StallDecorationOverride is the decoration a BFI1 grant put on
// characterID's next stall (0x7160), if any. The stall's look is this when
// set, else the character's own permanent decoration (getter 0x4f0f00).
func StallDecorationOverride(characterID int64) (int64, bool) {
	v, ok := stallDecoOverride.Load(characterID)
	if !ok {
		return 0, false
	}
	return v.(int64), true
}

// ClearStallDecoration is the stall close's reset of the override
// (FUN_00472cf0, 0x472d55).
func ClearStallDecoration(characterID int64) { stallDecoOverride.Delete(characterID) }

// AvatarStallHandler serves 0x7160 (FUN_00511730): the BFI1 job for the
// decoration must run, and its item be a 3/3/3/4; the override is set and
// 0xB160 {1, key, decoration} answers, else {2, u16 code}.
func AvatarStallHandler(hub *world.Hub, items ItemLookup) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		if p.Opcode != OpAvatarStallUse || hub == nil {
			return nil
		}
		refuse := func(code uint16) error {
			return sess.Send(&proto.Packet{Opcode: OpAvatarStallAck, Data: binary.LittleEndian.AppendUint16([]byte{2}, code)})
		}
		if len(p.Data) < 8 {
			return refuse(2)
		}
		key := int64(binary.LittleEndian.Uint32(p.Data[0:4]))
		deco := int64(binary.LittleEndian.Uint32(p.Data[4:8]))
		e, ok := hub.EntityBySession(sess.ID())
		k := compositeKeeperNow()
		if !ok || k == nil {
			return refuse(2)
		}
		if _, running := k.extra(e.CharacterID, "BFI1", deco, useItemClock()); !running {
			return refuse(2)
		}
		it, err := items.GetItem(ctx, deco)
		if err != nil || it == nil || !isBFI1Decoration(it) {
			return refuse(2)
		}
		stallDecoOverride.Store(e.CharacterID, deco)
		out := binary.LittleEndian.AppendUint32([]byte{1}, uint32(key))
		return sess.Send(&proto.Packet{Opcode: OpAvatarStallAck, Data: binary.LittleEndian.AppendUint32(out, uint32(deco))})
	}
}

// isBFI1Decoration is the 3/3/3/4 test BFI1's branch and 0x7160 make
// (0x489120: 3/3/3, and TID & 0xf800 == 0x2000).
func isBFI1Decoration(it *refdata.Item) bool {
	return it != nil && it.TypeID1 == equipment.TypeItem && it.TypeID2 == equipment.TypeExpendable &&
		it.TypeID3 == 3 && it.TypeID4 == 4
}

// useScrollFill spends one use of a return scroll's UIL1 grant g on the
// scroll's own routine (round 838; CUsedItemLimit::vslot_007, READ): a dead
// user is refused 0x1889 (only 3/3/13/6 is used dead); then FUN_004a0380
// (3/3/3/1, 0x654258) or FUN_004a00c0 with the request's option (3/3/3/3,
// 0x65423b) -- ScrollCaster.begin, every refusal of the scroll's own use --
// and, when it starts, the grant's count goes down by one
// (CTJ_CompositeItemKeeper::FUN_00653f20; the last use ends it). No scroll is
// spent and no COOLTIME is armed.
func useScrollFill(ctx context.Context, sess *gateway.Session, hub *world.Hub, keeper *CompositeKeeper, zerk *berserk.Tracker,
	characterID int64, fill *refdata.Item, g *compositeGrant, req *CompositeUseRequest, fail func(string, int64) error) error {
	if deadBySession(hub, sess) {
		return fail(deadRefusal, req.ItemID)
	}
	keeper.mu.Lock()
	sc := keeper.scrolls
	keeper.mu.Unlock()
	if sc == nil {
		return fail("that cannot be used", req.ItemID)
	}
	// Round 864: a return scroll's fill never ends its grant (vslot_007's
	// TypeID3 3 branch, s:0x654258..0x65427b, then FUN_006538d0(1,
	// remaining - 1), READ): only the TypeID3 1 fill's last use ends the job.
	// MEASURED: after the third instant return the grant stays at 0 ("0Unit"
	// in the tooltip, the button greyed) and the icon stays.
	spend := func() error {
		keeper.setRemaining(characterID, req.ItemID, g.remaining-1)
		return nil
	}
	delay, code, err := sc.begin(ctx, sess, characterID, fill, req.Option, req.Target, spend)
	var refused scrollRefusedText
	if errors.As(err, &refused) {
		return fail(refused.why, req.ItemID)
	}
	if err != nil {
		return fail("using failed", req.ItemID)
	}
	if code != 0 {
		return fail(scrollReason(code), req.ItemID)
	}
	slog.Info("composite: scroll fill", "character_id", characterID, "item", fill.ID, "option", req.Option,
		"left", g.remaining-1, "delay", delay)
	if err := sess.Send(&proto.Packet{Opcode: OpCompositeUseResult, Data: (&CompositeUseResult{
		ItemID: req.ItemID, Remaining: int32(g.remaining - 1), CastMs: uint32(delay / time.Millisecond)}).Encode()}); err != nil {
		return err
	}
	return sendCompositeState(sess, keeper, zerk, characterID, useItemClock())
}
