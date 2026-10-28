package session

// The players' stalls (round 839, lane S): retail's CFleaMarket on the retail
// wire and rules. docs/protocol/stall.md has the reading; s: is
// SR_GameServer.exe, c: sro_client.exe. READ unless marked.
//
//	C->S 0x70B1 {str name}                    open (s:0x515f10)
//	S->C 0xB0B1 {1} | {2, u16}
//	S->C 0x30B8 {u32 owner, str name, u32 decoration}   to view (s:0x4723c0)
//	C->S 0x70B2 {}                            close, the owner (s:0x516130)
//	S->C 0xB0B2 {1} | {2, u16}
//	S->C 0x30B9 {u32 owner, u16 reason}       to view (s:0x472cf0)
//	C->S 0x70B3 {u32 owner}                   enter (s:0x516270)
//	S->C 0xB0B3 {1, u32 owner, str welcome, u8 open, u8 value4, list, u8 n, n x u32} | {2, u16}
//	C->S 0x70B4 {u8 slot}                     buy (s:0x516560)
//	S->C 0xB0B4 {1, u8 slot} | {2, u16}
//	C->S 0x70B5 {}                            leave, a visitor (s:0x5164c0)
//	S->C 0xB0B5 {1} | {2, u16}
//	C->S 0x70BA {u8 type, ...}                the owner's update (s:0x5161b0 -> 0x472e20)
//	S->C 0xB0BA {1, u8 type, ...} to every participant | {2, u16} to the owner
//	S->C 0x30B7 {1|2, u32 uid} | {3, u8 slot, str buyer, list}  to the participants
//	S->C 0x30BB {u32 owner, str name}         to view, a rename
//
// A list (FUN_00471f90) is, for each used slot i: u8 i, the item record
// (vslot 0x498 mode 1), u8 bag slot (+13), u16 count, u64 price; then 0xFF.
// Strings are u16 length + bytes.
//
// OURS, disclosed:
//
//   - The restriction slots (FUN_004f0a00: the trade ban 0x3405, the chat ban
//     that renames a stall), the quest block 0x200 (0x3c32 / 0x3c33), the
//     murderer state (0x3c39) and the battle arena / flag world refusal have
//     no OpenSRO state and are not made.
//   - The sale is one transaction (txn.For(...).Run with a ledger claim, as
//     the exchange's): the item, both golds and the sale row commit together
//     or not at all. Retail moves them in memory first and queues the DB job;
//     a failed job closes the stall 0x3c2f and logs both players out. Here a
//     failed transaction leaves everything as it was, so the stall is closed
//     0x3c2f and both stay connected. A sale whose owner leaves meanwhile
//     completes (the stores are the sale); the stall is gone after it.
//   - The listing is checked again inside the transaction: the bag slot must
//     still hold the item, count and instance listed (0x3c10 otherwise).
//     Retail re-links its pointer by slot and DBID; the owner's bag is locked
//     the whole time anyway (StorageOperation at INTERACTMODE 4, READ).
//   - A seller whose gold would pass the int64 range is refused 2 (retail
//     clamps only at 0, s:0x4e4b60; no OpenSRO character can get there).
//   - The buyer's name in 0x30B7 is the character's (the job alias while a
//     suit is worn), never "unknown": OpenSRO answers after the commit while
//     the buyer is still known.

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"sort"
	"sync/atomic"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/avatar"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/npcspawn"
	"github.com/TheOpenSRO/OpenSRO/server/internal/party"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/stall"
	"github.com/TheOpenSRO/OpenSRO/server/internal/trade"
	"github.com/TheOpenSRO/OpenSRO/server/internal/txn"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

const (
	OpStallOpen         uint16 = 0x70B1
	OpStallOpenResult   uint16 = 0xB0B1
	OpStallClose        uint16 = 0x70B2
	OpStallCloseResult  uint16 = 0xB0B2
	OpStallEnter        uint16 = 0x70B3
	OpStallEnterResult  uint16 = 0xB0B3
	OpStallBuy          uint16 = 0x70B4
	OpStallBuyResult    uint16 = 0xB0B4
	OpStallLeave        uint16 = 0x70B5
	OpStallLeaveResult  uint16 = 0xB0B5
	OpStallUnused       uint16 = 0x70B6 // index 0x0b6 (s:0x516250) skips its payload
	OpStallUpdate       uint16 = 0x70BA
	OpStallUpdateResult uint16 = 0xB0BA
	OpStallEvent        uint16 = 0x30B7
	OpStallAppear       uint16 = 0x30B8
	OpStallGone         uint16 = 0x30B9
	OpStallRenamed      uint16 = 0x30BB
)

// 0x30B7's kinds (FUN_00472490, FUN_004725d0, s:0x47375a).
const (
	StallEventLeft   byte = 1
	StallEventCame   byte = 2
	StallEventSold   byte = 3
	stallListEnd     byte = 0xFF
	stallReplyOK     byte = 1
	stallReplyRefuse byte = 2
)

// 0x70BA's types (the jump table at s:0x4734c0).
const (
	StallUpdatePrice   byte = 1
	StallUpdateAdd     byte = 2
	StallUpdateRemove  byte = 3
	StallUpdateValue4  byte = 4
	StallUpdateOpen    byte = 5
	StallUpdateWelcome byte = 6
	StallUpdateRename  byte = 7
)

// The codes (the client's category 10, c:0x7b8b40; docs/protocol/stall.md).
const (
	StallErrGeneric       uint16 = 2
	StallErrInvalidTarget uint16 = 3
	StallErrTooFar        uint16 = 4
	StallErrOperation     uint16 = 5
	StallErrBagSlot       uint16 = 0x3c06
	StallErrCount         uint16 = 0x3c07
	StallErrPrice         uint16 = 0x3c08
	StallErrName          uint16 = 0x3c09
	StallErrWelcome       uint16 = 0x3c0a
	StallErrClosedDeath   uint16 = 0x3c0e // MARKET_CLOSED
	StallErrNotVisitor    uint16 = 0x3c0f
	StallErrSlot          uint16 = 0x3c10
	StallErrGold          uint16 = 0x3c11 // NOT_ENOUGH_GOLD
	StallErrBagFull       uint16 = 0x3c12 // INVENTORY_FULL
	StallErrListed        uint16 = 0x3c13
	StallErrHasStall      uint16 = 0x3c14
	StallErrHostLeft      uint16 = 0x3c15 // HOST_LEFT
	StallErrBusy          uint16 = 0x3c16 // IM_BUSY
	StallErrClosedByHost  uint16 = 0x3c17 // CLOSED_BY_HOST
	StallErrNotOwner      uint16 = 0x3c2a
	StallErrHostState     uint16 = 0x3c2b // INVALID_HOST_STATE
	StallErrCannotTrade   uint16 = 0x3c2d
	StallErrNotOpen       uint16 = 0x3c2e
	StallErrDB            uint16 = 0x3c2f
	StallErrNoFreeSlot    uint16 = 0x3c30
	StallErrOpenValue     uint16 = 0x3c31
	StallErrRiding        uint16 = 0x3c34 // CANT_OPEN_MARKET_IN_RIDESTATE
	StallErrPetOut        uint16 = 0x3c3a
	StallErrJob           uint16 = 0x3c3b // UIIT_MSG_FREEMARKET_NOTUSE_JOB
	StallErrNoGroup       uint16 = 0x3c3c
	StallErrSpirit        uint16 = 0x3c55
)

// Ranges READ: 0x70B3's own 3-D distance bound (the double 100.0 at
// 0xb45af0, s:0x5163c1) and IsWithinInteractionRange's (600.0, 0xb46198).
const (
	StallEnterRange = 100.0
	stallSeeRange   = 600.0
)

// StallDeps is what the stalls read and write.
type StallDeps struct {
	Chars   character.Store
	Inv     inventory.Store
	Items   ItemLookup
	Hub     *world.Hub
	Stalls  *stall.Hub
	Trades  *trade.Hub
	Parties *party.Hub
	Sales   stall.SaleStore
}

var stallRT atomic.Pointer[StallDeps]

// stallSaleSeq numbers the sales for their ledger keys.
var stallSaleSeq atomic.Uint64

// StallHandler serves 0x70B1..0x70B6 and 0x70BA, and installs the stalls'
// INTERACTMODE in the trade hub's gates.
func StallHandler(d StallDeps) gateway.Handler {
	if d.Stalls == nil {
		d.Stalls = stall.NewHub()
	}
	dd := d
	if dd.Trades != nil {
		dd.Trades.SetModes(dd.Stalls.Mode)
	}
	stallRT.Store(&dd)
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		switch p.Opcode {
		case OpStallOpen:
			dd.open(ctx, sess, p.Data)
		case OpStallClose:
			dd.closeReq(sess)
		case OpStallEnter:
			dd.enter(ctx, sess, p.Data)
		case OpStallBuy:
			dd.buy(ctx, sess, p.Data)
		case OpStallLeave:
			dd.leaveReq(sess)
		case OpStallUnused:
			// s:0x516250 reads nothing back and answers nothing.
		case OpStallUpdate:
			dd.update(ctx, sess, p.Data)
		}
		return nil
	}
}

// --- encoding ---------------------------------------------------------------

func stallResult(code uint16) []byte {
	if code == 1 {
		return []byte{stallReplyOK}
	}
	return binary.LittleEndian.AppendUint16([]byte{stallReplyRefuse}, code)
}

func stallAppendString(out []byte, s string) []byte {
	out = binary.LittleEndian.AppendUint16(out, uint16(len(s)))
	return append(out, s...)
}

func stallReadString(b []byte) (string, []byte, bool) {
	if len(b) < 2 {
		return "", nil, false
	}
	n := int(binary.LittleEndian.Uint16(b))
	if len(b) < 2+n {
		return "", nil, false
	}
	return string(b[2 : 2+n]), b[2+n:], true
}

// EncodeStallAppear is 0x30B8.
func EncodeStallAppear(owner uint32, name string, decoration uint32) []byte {
	out := binary.LittleEndian.AppendUint32(nil, owner)
	out = stallAppendString(out, name)
	return binary.LittleEndian.AppendUint32(out, decoration)
}

// EncodeStallGone is 0x30B9.
func EncodeStallGone(owner uint32, reason uint16) []byte {
	return binary.LittleEndian.AppendUint16(binary.LittleEndian.AppendUint32(nil, owner), reason)
}

// EncodeStallRenamed is 0x30BB.
func EncodeStallRenamed(owner uint32, name string) []byte {
	return stallAppendString(binary.LittleEndian.AppendUint32(nil, owner), name)
}

// appendStallList is FUN_00471f90.
func appendStallList(ctx context.Context, items ItemLookup, out []byte, slots [stall.MaxSlots]stall.Listing) []byte {
	for i, l := range slots {
		if !l.Used {
			continue
		}
		out = append(out, byte(i))
		out = append(out, exchangeRecord(ctx, items, trade.Item{Slot: l.BagSlot, ItemID: l.ItemID, Quantity: l.Quantity, Inst: l.Inst})...)
		out = append(out, byte(l.BagSlot+ItemWireBagOffset))
		out = binary.LittleEndian.AppendUint16(out, uint16(l.Quantity))
		out = binary.LittleEndian.AppendUint64(out, uint64(l.Price))
	}
	return append(out, stallListEnd)
}

// EncodeStallEntered is 0xB0B3's success for viewer: the other visitors are
// the participants from index 1 without the receiver (s:0x473560).
func EncodeStallEntered(ctx context.Context, items ItemLookup, s stall.Stall, viewer int64) []byte {
	out := binary.LittleEndian.AppendUint32([]byte{stallReplyOK}, uint32(s.Owner.CharacterID))
	out = stallAppendString(out, s.Welcome)
	open := byte(0)
	if s.Open {
		open = 1
	}
	out = append(out, open, s.Value4)
	out = appendStallList(ctx, items, out, s.Slots)
	var others []uint32
	for _, v := range s.Visitors {
		if v.CharacterID != viewer {
			others = append(others, uint32(v.CharacterID))
		}
	}
	out = append(out, byte(len(others)))
	for _, id := range others {
		out = binary.LittleEndian.AppendUint32(out, id)
	}
	return out
}

// EncodeStallMember is 0x30B7 kinds 1 and 2.
func EncodeStallMember(kind byte, uid uint32) []byte {
	return binary.LittleEndian.AppendUint32([]byte{kind}, uid)
}

// EncodeStallSold is 0x30B7 kind 3.
func EncodeStallSold(ctx context.Context, items ItemLookup, slot int, buyer string, slots [stall.MaxSlots]stall.Listing) []byte {
	out := stallAppendString([]byte{StallEventSold, byte(slot)}, buyer)
	return appendStallList(ctx, items, out, slots)
}

func sendStall(sess *gateway.Session, op uint16, data []byte) {
	if sess != nil {
		sendToPeer(sess, &proto.Packet{Opcode: op, Data: data})
	}
}

// toMembers is CFleaMarket::BroadcastToParticipants (s:0x473c60).
func toMembers(members []stall.Member, op uint16, data []byte) {
	for _, m := range members {
		sendStall(m.Session, op, data)
	}
}

// --- state ------------------------------------------------------------------

// stallOf answers a stalling owner's name and decoration for the spawn
// record (CGObjPC::vslot_293, s:0x4e5ee6..0x4e5f4f).
func stallOf(characterID int64) (string, uint32, bool) {
	d := stallRT.Load()
	if d == nil {
		return "", 0, false
	}
	s, ok := d.Stalls.Get(characterID)
	if !ok {
		return "", 0, false
	}
	return s.Name, uint32(s.Decoration), true
}

// worldBusy is FUN_00515d10 on the normal world (0x529880): not in a stall,
// alive, INTERACTMODE 0 and GROUPMODE neither PARTY_SETUP nor
// SOLOPARTY_SETUP -- OpenSRO's pending party invitation.
func (d *StallDeps) worldBusy(e world.Entity) bool {
	if e.Life != world.LifeAlive || d.Stalls.StallOf(e.CharacterID) != 0 {
		return true
	}
	if d.Trades.Busy(e.CharacterID) || npcTalkOpen(e.Session.ID()) {
		return true
	}
	return d.Parties != nil && d.Parties.State(e.CharacterID) == party.StatePending
}

// --- open and close ---------------------------------------------------------

// open is 0x70B1 (FleaMarket_HandleOpenStall, s:0x515f10) in its order.
func (d *StallDeps) open(ctx context.Context, sess *gateway.Session, data []byte) {
	me, ok := d.Hub.EntityBySession(sess.ID())
	if !ok {
		return
	}
	fail := func(code uint16) { sendStall(sess, OpStallOpenResult, stallResult(code)) }
	name, _, ok := stallReadString(data)
	if !ok {
		fail(StallErrName)
		return
	}
	switch {
	case d.worldBusy(me):
		fail(StallErrBusy)
		return
	case riderMount(me.CharacterID) != nil:
		fail(StallErrRiding)
		return
	case inJobMode(ctx, me.CharacterID):
		fail(StallErrJob)
		return
	}
	// FUN_004b1480(4) while SIT stands the character up; vslot 0x6a8 halts
	// the mover (s:0x516057, 0x51606e).
	now := time.Now()
	if motions.state(me.CharacterID, now) == MotionSit {
		if v, ok := motions.request(me.CharacterID, MotionSit, now); ok {
			broadcastMotion(d.Hub, me, v)
		}
	}
	haltForState(d.Hub, me.CharacterID)
	// FUN_00474210: one stall an owner (0x3c14), then the name (0x3c09,
	// FUN_00471d90).
	if d.Stalls.StallOf(me.CharacterID) == me.CharacterID {
		fail(StallErrHasStall)
		return
	}
	if len(name) == 0 || len(name) > stall.MaxText {
		fail(StallErrName)
		return
	}
	deco := StallDecorationOf(ctx, d.Chars, me.CharacterID)
	if _, err := d.Stalls.Open(stall.Member{CharacterID: me.CharacterID, Session: sess, Name: me.Name}, name, deco); err != nil {
		fail(StallErrHasStall)
		return
	}
	sendAboutPlayerPacket(d.Hub, me.CharacterID, true, OpStallAppear, EncodeStallAppear(uint32(me.CharacterID), name, uint32(deco)))
	fail(1)
	slog.Info("stall: opened", "character", me.CharacterID, "name", name, "decoration", deco)
}

// closeReq is 0x70B2 (s:0x516130).
func (d *StallDeps) closeReq(sess *gateway.Session) {
	me, ok := d.Hub.EntityBySession(sess.ID())
	if !ok {
		return
	}
	if d.Stalls.Mode(me.CharacterID) != stall.ModeOwner {
		sendStall(sess, OpStallCloseResult, stallResult(StallErrNotOwner))
		return
	}
	d.closeStall(me.CharacterID, StallErrClosedByHost)
	sendStall(sess, OpStallCloseResult, stallResult(1))
}

// closeStall is FUN_00472cf0: every participant out, the BFI1 override
// cleared, 0x30B9 {owner, reason} to the owner's view. Visitors get no
// packet of their own; 0x30B9 closes their windows (c:0x8721b0).
func (d *StallDeps) closeStall(owner int64, reason uint16) {
	s, ok := d.Stalls.Close(owner)
	if !ok {
		return
	}
	ClearStallDecoration(owner)
	sendAboutPlayerPacket(d.Hub, owner, true, OpStallGone, EncodeStallGone(uint32(owner), reason))
	// A visitor out of the owner's view still has the window open: it is
	// told too (OURS: retail's view always holds them, the 100-unit entry).
	for _, v := range s.Visitors {
		if v.Session != nil && s.Owner.Session != nil && !d.Hub.Sees(v.Session.ID(), s.Owner.Session.ID()) {
			sendStall(v.Session, OpStallGone, EncodeStallGone(uint32(owner), reason))
		}
	}
	slog.Info("stall: closed", "character", owner, "reason", fmt.Sprintf("0x%x", reason), "visitors", len(s.Visitors))
}

// stallEnd is the close paths of a leaving character (s:0x4def00 warp,
// logout and disconnect 0x3c15; death 0x3c0e, s:0x529ca4 / 0x52cf05): an
// owner's stall closes, a visitor leaves without 0xB0B5.
func stallEnd(characterID int64, reason uint16) {
	d := stallRT.Load()
	if d == nil {
		return
	}
	switch d.Stalls.Mode(characterID) {
	case stall.ModeOwner:
		d.closeStall(characterID, reason)
	case stall.ModeVisitor:
		d.leave(characterID)
	}
}

// StallDisconnectHandler closes a leaving owner's stall 0x3c15 and takes a
// leaving visitor out. It must run before WorldDisconnectHandler.
func StallDisconnectHandler(hub *world.Hub) func(sess *gateway.Session) {
	return func(sess *gateway.Session) {
		if e, ok := hub.EntityBySession(sess.ID()); ok {
			stallEnd(e.CharacterID, StallErrHostLeft)
		}
	}
}

// --- visiting ---------------------------------------------------------------

// enter is 0x70B3 (s:0x516270) in its order.
func (d *StallDeps) enter(ctx context.Context, sess *gateway.Session, data []byte) {
	me, ok := d.Hub.EntityBySession(sess.ID())
	if !ok || len(data) < 4 {
		return
	}
	fail := func(code uint16) { sendStall(sess, OpStallEnterResult, stallResult(code)) }
	if d.worldBusy(me) {
		fail(StallErrBusy)
		return
	}
	uid := binary.LittleEndian.Uint32(data)
	// IsWithinInteractionRange(pc, target, 0x26) (s:0x4a8e10): 0 not found or
	// not seen, 3 not a player, 4 past 600; its answer goes out as it is.
	if uid >= npcspawn.UIDBase {
		fail(StallErrInvalidTarget)
		return
	}
	target, ok := d.Hub.EntityByCharacterID(int64(uid))
	if !ok || target.Zone != me.Zone || target.Session == nil || !d.Hub.Sees(sess.ID(), target.Session.ID()) {
		fail(0)
		return
	}
	dist := dist3(me.Pos, target.Pos)
	if dist > stallSeeRange || dist > StallEnterRange {
		fail(StallErrTooFar)
		return
	}
	// Not an owner, the stall full (0x3c18) or already inside (0x3c19): all
	// 0x3c2a (s:0x5163ea..0x516400).
	if d.Stalls.Mode(target.CharacterID) != stall.ModeOwner {
		fail(StallErrNotOwner)
		return
	}
	haltForState(d.Hub, me.CharacterID)
	before, s, err := d.Stalls.Join(target.CharacterID, stall.Member{CharacterID: me.CharacterID, Session: sess, Name: me.Name})
	if err != nil {
		fail(StallErrNotOwner)
		return
	}
	// FUN_004725d0: 0x30B7 {2, uid} to every participant already there.
	toMembers(before, OpStallEvent, EncodeStallMember(StallEventCame, uint32(me.CharacterID)))
	sendStall(sess, OpStallEnterResult, EncodeStallEntered(ctx, d.Items, s, me.CharacterID))
}

// leaveReq is 0x70B5 (s:0x5164c0): only a visitor; anyone else is refused
// 0x3c0f and disconnected (FUN_004df050(4), s:0x5164df).
func (d *StallDeps) leaveReq(sess *gateway.Session) {
	me, ok := d.Hub.EntityBySession(sess.ID())
	if !ok {
		return
	}
	if d.Stalls.Mode(me.CharacterID) != stall.ModeVisitor {
		sendStall(sess, OpStallLeaveResult, stallResult(StallErrNotVisitor))
		slog.Warn("stall: a leave outside a stall; disconnecting, as the original does", "character", me.CharacterID)
		go func() {
			time.Sleep(200 * time.Millisecond)
			_ = sess.Close()
		}()
		return
	}
	d.leave(me.CharacterID)
	sendStall(sess, OpStallLeaveResult, stallResult(1))
}

// leave is FUN_00515ee0 -> FUN_00472490: the visitor out, 0x30B7 {1, uid}
// to the participants left, owner included.
func (d *StallDeps) leave(visitor int64) {
	_, rest, ok := d.Stalls.Leave(visitor)
	if !ok {
		return
	}
	toMembers(rest, OpStallEvent, EncodeStallMember(StallEventLeft, uint32(visitor)))
}

// --- the owner's update -------------------------------------------------------

// update is 0x70BA (s:0x5161b0 -> FUN_00472e20): a success goes to every
// participant, a refusal to the owner alone.
func (d *StallDeps) update(ctx context.Context, sess *gateway.Session, data []byte) {
	me, ok := d.Hub.EntityBySession(sess.ID())
	if !ok {
		return
	}
	fail := func(code uint16) { sendStall(sess, OpStallUpdateResult, stallResult(code)) }
	if d.Stalls.Mode(me.CharacterID) != stall.ModeOwner {
		fail(StallErrNotOwner)
		return
	}
	if len(data) < 1 {
		fail(StallErrOperation)
		return
	}
	kind, body := data[0], data[1:]
	// Type 2 reads the bag before the lock.
	var bag *inventory.Slot
	var ref *refdata.Item
	if kind == StallUpdateAdd && len(body) >= 2 && int(body[1]) >= ItemWireBagOffset {
		slots, err := d.Inv.List(ctx, me.CharacterID)
		if err == nil {
			for i := range slots {
				if slots[i].Index == int(body[1])-ItemWireBagOffset {
					bag = &slots[i]
				}
			}
		}
		if bag != nil && d.Items != nil {
			ref, _ = d.Items.GetItem(ctx, bag.ItemID)
		}
	}
	code := uint16(1)
	var reply []byte
	var members []stall.Member
	var renamed string
	d.Stalls.Do(me.CharacterID, func(s *stall.Stall) {
		code, reply = d.applyUpdate(ctx, me.CharacterID, s, kind, body, bag, ref)
		if code == 1 {
			members = s.Members()
			if kind == StallUpdateRename {
				renamed = s.Name
			}
		}
	})
	if code != 1 {
		fail(code)
		return
	}
	toMembers(members, OpStallUpdateResult, reply)
	if kind == StallUpdateRename {
		sendAboutPlayerPacket(d.Hub, me.CharacterID, true, OpStallRenamed, EncodeStallRenamed(uint32(me.CharacterID), renamed))
	}
}

// applyUpdate is FUN_00472e20's body, under the hub's lock: the code and,
// on success, the reply.
func (d *StallDeps) applyUpdate(ctx context.Context, owner int64, s *stall.Stall, kind byte, b []byte,
	bag *inventory.Slot, ref *refdata.Item) (uint16, []byte) {
	if kind != StallUpdateValue4 && kind != StallUpdateOpen && kind != StallUpdateWelcome && s.Open {
		return StallErrHostState, nil
	}
	if s.Selling || kind < StallUpdatePrice || kind > StallUpdateRename {
		return StallErrOperation, nil
	}
	ok := []byte{stallReplyOK, kind}
	switch kind {
	case StallUpdatePrice: // s:0x472f90: {u8 slot, u16 count, u64 price, u16}
		if len(b) < 11 {
			return StallErrOperation, nil
		}
		i, qty, price := int(b[0]), int(binary.LittleEndian.Uint16(b[1:])), binary.LittleEndian.Uint64(b[3:])
		if i >= stall.MaxSlots || !s.Slots[i].Used {
			return StallErrSlot, nil
		}
		if qty != s.Slots[i].Quantity {
			return StallErrCount, nil
		}
		if price > uint64(stall.MaxPrice) {
			return StallErrPrice, nil
		}
		if ref, _ := d.itemRef(ctx, s.Slots[i].ItemID); ref != nil && ref.MaxStack > 0 && qty > ref.MaxStack {
			return StallErrCount, nil
		}
		s.Slots[i].Price = int64(price)
		out := append(ok, byte(i))
		out = binary.LittleEndian.AppendUint16(out, uint16(qty))
		out = binary.LittleEndian.AppendUint64(out, price)
		return 1, binary.LittleEndian.AppendUint16(out, 0)
	case StallUpdateAdd: // s:0x473121: {u8 slot, u8 bag, u16 count, u64 price, u32 group, u16}
		if len(b) < 16 {
			return StallErrOperation, nil
		}
		i, wire, qty := int(b[0]), int(b[1]), int(binary.LittleEndian.Uint16(b[2:]))
		price, group := binary.LittleEndian.Uint64(b[4:]), binary.LittleEndian.Uint32(b[12:])
		if i >= stall.MaxSlots {
			return StallErrSlot, nil
		}
		if s.Slots[i].Used {
			if i = s.FirstFree(); i < 0 {
				return StallErrNoFreeSlot, nil
			}
		}
		if wire < ItemWireBagOffset || bag == nil {
			return StallErrBagSlot, nil
		}
		slot := wire - ItemWireBagOffset
		// FUN_004719c0 in its order.
		switch {
		case s.ListedBagSlot(slot):
			return StallErrListed, nil
		case cosItemOut(ctx, owner, slot):
			return StallErrPetOut, nil
		case ref != nil && avatar.IsDevilSpirit(ref) && avatar.Awake(bag.Durability, time.Now()):
			return StallErrSpirit, nil
		case ref != nil && !ref.CanTrade:
			return StallErrCannotTrade, nil
		case ref != nil && ref.TypeID1 == 3 && ref.TypeID2 == 3 && ref.TypeID3 == 8:
			return StallErrCannotTrade, nil
		case qty != bag.Quantity || (ref != nil && ref.MaxStack > 0 && qty > ref.MaxStack):
			return StallErrCount, nil
		case price > uint64(stall.MaxPrice):
			return StallErrPrice, nil
		case group == 0:
			return StallErrNoGroup, nil
		}
		s.Slots[i] = stall.Listing{Used: true, BagSlot: slot, ItemID: bag.ItemID, Quantity: bag.Quantity,
			Inst: bag.Instance(), Price: int64(price), Group: group}
		return 1, appendStallList(ctx, d.Items, binary.LittleEndian.AppendUint16(ok, 0), s.Slots)
	case StallUpdateRemove: // s:0x473261: {u8 slot, u16}
		if len(b) < 1 {
			return StallErrOperation, nil
		}
		i := int(b[0])
		if i >= stall.MaxSlots || !s.Slots[i].Used {
			return StallErrSlot, nil
		}
		s.Slots[i] = stall.Listing{}
		return 1, appendStallList(ctx, d.Items, binary.LittleEndian.AppendUint16(ok, 0), s.Slots)
	case StallUpdateValue4: // s:0x47332c: {u8}
		if len(b) < 1 {
			return StallErrOperation, nil
		}
		if b[0] >= 3 {
			return StallErrHostState, nil
		}
		s.Value4 = b[0]
		return 1, append(ok, b[0])
	case StallUpdateOpen: // s:0x473381: {u8 open, u16}
		if len(b) < 1 {
			return StallErrOperation, nil
		}
		if b[0] >= 2 {
			return StallErrOpenValue, nil
		}
		s.Open = b[0] == 1
		return 1, binary.LittleEndian.AppendUint16(append(ok, b[0]), 0)
	case StallUpdateWelcome: // s:0x4733fd: {str}
		msg, _, okStr := stallReadString(b)
		if !okStr {
			return StallErrOperation, nil
		}
		if len(msg) > stall.MaxText {
			return StallErrWelcome, nil
		}
		s.Welcome = msg
		return 1, stallAppendString(ok, msg)
	case StallUpdateRename: // s:0x472eb7: {str}
		name, _, okStr := stallReadString(b)
		if !okStr {
			return StallErrOperation, nil
		}
		if len(name) == 0 || len(name) > stall.MaxText {
			return StallErrName, nil
		}
		s.Name = name
		return 1, ok
	}
	return StallErrOperation, nil
}

func (d *StallDeps) itemRef(ctx context.Context, id int64) (*refdata.Item, error) {
	if d.Items == nil {
		return nil, nil
	}
	return d.Items.GetItem(ctx, id)
}

// --- the sale ---------------------------------------------------------------

var errStallRefused = errors.New("stall: refused")

// buy is 0x70B4 (s:0x516560 -> CFleaMarket::SellFMarketItem s:0x472700).
func (d *StallDeps) buy(ctx context.Context, sess *gateway.Session, data []byte) {
	me, ok := d.Hub.EntityBySession(sess.ID())
	if !ok || len(data) < 1 {
		return
	}
	fail := func(code uint16) { sendStall(sess, OpStallBuyResult, stallResult(code)) }
	owner := d.Stalls.StallOf(me.CharacterID)
	if owner == 0 || owner == me.CharacterID {
		fail(StallErrNotVisitor)
		return
	}
	slot := int(data[0])
	code := uint16(1)
	var l stall.Listing
	found := d.Stalls.Do(owner, func(s *stall.Stall) {
		switch {
		case !s.Open:
			code = StallErrNotOpen
		case s.Selling:
			code = StallErrGeneric
		case !s.HasVisitor(me.CharacterID):
			code = StallErrNotVisitor
		case slot >= stall.MaxSlots || !s.Slots[slot].Used:
			code = StallErrSlot
		default:
			l = s.Slots[slot]
			s.Selling = true
		}
	})
	if !found {
		fail(StallErrNotVisitor)
		return
	}
	if code != 1 {
		fail(code)
		return
	}
	code, toSlot := d.sell(ctx, owner, me.CharacterID, slot, l)
	var members []stall.Member
	var after [stall.MaxSlots]stall.Listing
	d.Stalls.Do(owner, func(s *stall.Stall) {
		s.Selling = false
		if code == 1 {
			// The whole stack sold: the slot cleared (s:0x472b63).
			s.Slots[slot] = stall.Listing{}
		} else if code == StallErrSlot {
			// The listing no longer matches the bag (OURS): it goes.
			s.Slots[slot] = stall.Listing{}
		}
		members = s.Members()
		after = s.Slots
	})
	if code == StallErrDB {
		fail(code)
		d.closeStall(owner, StallErrDB)
		return
	}
	if code != 1 {
		fail(code)
		return
	}
	// DealIt's OffsetGold for each side (0x304E kind 1), then the DB job's
	// answer (vslot_007 kind 1 -> s:0x4735a0): 0xB0B4 {1, slot} to the
	// buyer, 0x30B7 kind 3 to every participant.
	tellGold(ctx, d.Chars, d.Hub, me.CharacterID, false)
	tellGold(ctx, d.Chars, d.Hub, owner, false)
	sendStall(sess, OpStallBuyResult, append([]byte{stallReplyOK}, byte(slot)))
	if members == nil {
		// The owner closed the stall meanwhile: the two who traded still hear it.
		if e, ok := d.Hub.EntityByCharacterID(owner); ok {
			members = []stall.Member{{CharacterID: owner, Session: e.Session}}
		}
		members = append(members, stall.Member{CharacterID: me.CharacterID, Session: sess})
	}
	toMembers(members, OpStallEvent, EncodeStallSold(ctx, d.Items, slot, d.buyerName(ctx, me), after))
	slog.Info("stall: sold", "owner", owner, "buyer", me.CharacterID, "slot", slot, "item", l.ItemID,
		"count", l.Quantity, "price", l.Price, "to", toSlot)
}

// buyerName is the name 0x30B7 kind 3 carries: the job alias while a suit
// is worn (s:0x47375a..), else the character's.
func (d *StallDeps) buyerName(ctx context.Context, e world.Entity) string {
	if inJobMode(ctx, e.CharacterID) {
		if jr := jobRecord(ctx, e.CharacterID); jr.Alias != "" {
			return jr.Alias
		}
	}
	return e.Name
}

func stallLedgerKey(n uint64) string {
	return fmt.Sprintf("stall:%s:%d", txn.BootID, n)
}

// sell is the sale's checks 8 and 9 (gold 0x3c11, a free bag slot 0x3c12)
// and DealIt as one transaction: the gold from the buyer to the owner, no
// tax (s:0x4729e7..0x472a0e), the stack from the owner's bag slot to the
// buyer's first empty slot (FindFirstEmptySlot(0xd), s:0x472a59), and the
// sale row. It answers the code and the buyer's slot.
func (d *StallDeps) sell(ctx context.Context, owner, buyer int64, slot int, l stall.Listing) (uint16, int) {
	refusal := uint16(1)
	toSlot := -1
	key := stallLedgerKey(stallSaleSeq.Add(1))
	err := txn.For(d.Chars, d.Inv, d.Sales).Run(ctx, func(ctx context.Context) error {
		refusal = 1
		refuse := func(code uint16) error {
			refusal = code
			return errStallRefused
		}
		if err := txn.Claim(ctx, key); err != nil {
			return err
		}
		ownerBag, err := d.Inv.List(ctx, owner)
		if err != nil {
			return err
		}
		if !bayItemStill(ownerBag, trade.Item{Slot: l.BagSlot, ItemID: l.ItemID, Quantity: l.Quantity, Inst: l.Inst}) {
			return refuse(StallErrSlot)
		}
		b, err := d.Chars.GetByID(ctx, buyer)
		if err != nil {
			return err
		}
		if b.Gold < l.Price {
			return refuse(StallErrGold)
		}
		free := stallEmptySlots(ctx, d.Inv, buyer)
		if len(free) == 0 {
			return refuse(StallErrBagFull)
		}
		toSlot = free[0]
		o, err := d.Chars.GetByID(ctx, owner)
		if err != nil {
			return err
		}
		if o.Gold > math.MaxInt64-l.Price {
			return refuse(StallErrGeneric)
		}
		// The rows in ascending character id (round 743's lock order).
		ids := []int64{owner, buyer}
		sort.Slice(ids, func(a, c int) bool { return ids[a] < ids[c] })
		if l.Price > 0 {
			for _, id := range ids {
				if id == buyer {
					if err := d.Chars.DeductGold(ctx, buyer, l.Price); err != nil {
						if errors.Is(err, character.ErrInsufficientGold) {
							return refuse(StallErrGold)
						}
						return err
					}
				} else if err := d.Chars.AddGold(ctx, owner, l.Price); err != nil {
					return err
				}
			}
		}
		got, err := inventory.Take(ctx, d.Inv, owner, l.BagSlot, l.Quantity, l.ItemID, l.Inst)
		if err != nil {
			if offerGone(err) {
				return refuse(StallErrSlot)
			}
			return err
		}
		if placer, ok := d.Inv.(interface {
			PlaceItemInstance(ctx context.Context, characterID int64, slot int, itemID int64, quantity int, inst inventory.Instance) error
		}); ok {
			err = placer.PlaceItemInstance(ctx, buyer, toSlot, l.ItemID, l.Quantity, got)
		} else {
			err = d.Inv.AddItemInstance(ctx, buyer, l.ItemID, l.Quantity, got)
		}
		if err != nil {
			if errors.Is(err, inventory.ErrNoRoom) || errors.Is(err, inventory.ErrSlotTaken) {
				return refuse(StallErrBagFull)
			}
			return err
		}
		if d.Sales != nil {
			if err := d.Sales.RecordSale(ctx, stall.Sale{SellerID: owner, BuyerID: buyer, ItemID: l.ItemID,
				Quantity: l.Quantity, Serial: got.Serial, Price: l.Price, Slot: slot, BagSlot: l.BagSlot,
				ToSlot: toSlot}); err != nil {
				return err
			}
		}
		return nil
	})
	if errors.Is(err, errStallRefused) {
		return refusal, -1
	}
	if err != nil {
		done, lerr := txn.For(d.Chars, d.Inv, d.Sales).Applied(context.WithoutCancel(ctx), key)
		slog.Warn("stall: the sale failed", "owner", owner, "buyer", buyer, "slot", slot,
			"applied", lerr == nil && done, "error", err)
		if lerr == nil && done {
			return 1, toSlot
		}
		return StallErrDB, -1
	}
	return 1, toSlot
}

// stallEmptySlots is the buyer's empty bag slots in order, within its
// placement size.
func stallEmptySlots(ctx context.Context, inv inventory.Store, characterID int64) []int {
	slots, err := inv.List(ctx, characterID)
	if err != nil {
		return nil
	}
	place := inventory.PlacementCapacityOf(ctx, inv, characterID)
	used := make(map[int]bool, len(slots))
	for _, sl := range slots {
		used[sl.Index] = true
	}
	var out []int
	for i := 0; i < place; i++ {
		if !used[i] {
			out = append(out, i)
		}
	}
	return out
}
