package session

// The exchange (round 834): player-to-player trade on the retail wire and
// rules. docs/protocol/exchange.md has the reading and exchange_verify.md its
// review; the addresses below are theirs (s: SR_GameServer.exe, c:
// sro_client.exe).
//
// The client's messages:
//
//	C->S 0x7081 {u32 target id}            ask (s:GObjPC_HandleTradeMsg_081 0x5154e0)
//	S->C 0xB081 {1, u32 target} | {2, u16} to the asker
//	S->C 0x3080 {1, u32 asker id}          the request box, kind 1, to the target
//	C->S 0x3080 {1, u8 answer} | {2, u16}  1 accepts (s:0x46cb30), else 0x1828
//	S->C 0x3085 {u32 asker id}             to the target on accept
//	C->S 0x7034 {4, u8 bag slot}           offer an item (s:CGStorage::TradeOfferItem 0x526910)
//	C->S 0x7034 {5, u8 index}              take one back (s:0x480c70)
//	C->S 0x7034 {0xd, u64 gold}            set the gold (s:0x480f30)
//	S->C 0xB034 {1, 4, slot, index} | {1, 5, index} | {1, 0xd, u64} | {2, u16}
//	S->C 0x308C {u32 owner, u8 n, n x ([u8 slot] to the owner only, u8 index, record)}
//	C->S 0x7082 confirm, 0x7083 approve, 0x7084 cancel (all empty)
//	S->C 0xB082 / 0xB083 / 0xB084 {1} | {2, u16}
//	S->C 0x3089 {2, u64 gold}, then 0x3086 {}  the partner confirmed
//	S->C 0x3087 {} done; 0x3088 {u16 code} closed
//
// The rules, READ:
//
//   - A side's offer is seen by the other only when that side confirms
//     (0x308C to the owner alone on add and remove; gold tells the partner
//     nothing; Confirm sends the list to both, then 0x3089 and 0x3086).
//     Nothing resets a confirmation; a confirmed side's moves are refused
//     0x181f, which closes the session.
//   - Confirm and Approve test only the session's state (FUN_0047fc30,
//     exchange_verify W2): Confirm again at 2 is taken again, Approve again
//     at 3 answers {1} again; Confirm at 3 or Approve at 2 is 0x181f.
//   - The exchange runs on the second Approve: every bay item still where it
//     was (0x1841), something to exchange (0x1823), room for what comes in and
//     gold for what goes out (0x1841); incoming items go to the receiver's
//     first empty bag slots in bay order (FUN_004801b0), gold first
//     (CTradeMgr::DealIt 0x4802a0), each side's new total as 0x304E.
//   - A refusal in the close list (s:FUN_00515490) closes the session:
//     0x3088 {code} to both -- after 0xB082/0xB083's {2}, before a move's
//     0xB034 {2} and before Cancel's 0xB084 {1} (exchange_verify W5).
//     0x181b and 0x1825 close without a message (W3).
//   - Walking away does not close it; death, a warp, a logout or a
//     disconnect close it 0x182b.
//
// OURS, disclosed:
//
//   - 0x1811: retail disconnects both players and sends nothing (W3, W4) --
//     its in-memory deal can disagree with the database then. Here the
//     exchange is one transaction (txn.For(...).Run with a ledger claim, as
//     round 743's trade), which commits or leaves everything as it was, so
//     both are sent 0x3088 {0x1811} (no client text) and stay connected.
//   - The database step runs before 0xB083 {1} rather than after it, so the
//     second approver's {1} and the 0x3087 come together.
//   - The request's second check (vslot 0x244, the quest block 0x100,
//     0x185f) and GROUPMODE are not made; its first, the trade ban (0x3405),
//     is since round 840 (restriction.go). DealIt's COS check (exchange.md OPEN 3) is
//     not made.
//   - A pending party or guild invitation counts as busy (0x181e / 0x181d)
//     because every request box answers on 0x3080 with the same bytes;
//     retail keeps one trs_wait_response per player for the same reason.

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"log/slog"
	"sort"
	"sync/atomic"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/avatar"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/metrics"
	"github.com/TheOpenSRO/OpenSRO/server/internal/npcspawn"
	"github.com/TheOpenSRO/OpenSRO/server/internal/party"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/trade"
	"github.com/TheOpenSRO/OpenSRO/server/internal/txn"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

const (
	OpExchangeRequest       uint16 = 0x7081
	OpExchangeRequestResult uint16 = 0xB081
	OpExchangeStarted       uint16 = 0x3085
	OpExchangeConfirm       uint16 = 0x7082
	OpExchangeConfirmResult uint16 = 0xB082
	OpExchangeApprove       uint16 = 0x7083
	OpExchangeApproveResult uint16 = 0xB083
	OpExchangeCancel        uint16 = 0x7084
	OpExchangeCancelResult  uint16 = 0xB084
	OpExchangeConfirmed     uint16 = 0x3086 // the partner confirmed
	OpExchangeDone          uint16 = 0x3087
	OpExchangeClosed        uint16 = 0x3088
	OpExchangeUpdate        uint16 = 0x3089
	OpExchangeOffer         uint16 = 0x308C
	OpRequestBox            uint16 = 0x3080

	ItemMoveExchangeAdd    byte = 4
	ItemMoveExchangeRemove byte = 5
	ItemMoveExchangeGold   byte = 0x0d

	exchangeRequestKind byte = 1 // 0x3080 kind 1 (s:0x46c8e0)
	exchangeGoldKind    byte = 2 // 0x3089 kind 2
)

// The codes (docs/protocol/error_codes.md; the client's category 1).
const (
	ExchangeOK               uint16 = 1
	ExchangeErrFail          uint16 = 2
	ExchangeErrTarget        uint16 = 3
	ExchangeErrTooFar        uint16 = 4
	ExchangeErrWornSlot      uint16 = 0x1806
	ExchangeErrEmptySlot     uint16 = 0x1809
	ExchangeErrGold          uint16 = 0x180f // NOT_ENOUGH_GOLD
	ExchangeErrDB            uint16 = 0x1811
	ExchangeErrNoSession     uint16 = 0x181b
	ExchangeErrRequester     uint16 = 0x181d
	ExchangeErrBusy          uint16 = 0x181e // BUSY
	ExchangeErrState         uint16 = 0x181f // CANNOT_DEAL_NORMALCY
	ExchangeErrPartnerGone   uint16 = 0x1820
	ExchangeErrBayFull       uint16 = 0x1821
	ExchangeErrNothing       uint16 = 0x1823 // DEAL_FAIL_NON_ITEM
	ExchangeErrBayEmpty      uint16 = 0x1824
	ExchangeErrNotParty      uint16 = 0x1825
	ExchangeErrTimeout       uint16 = 0x1826
	ExchangeErrNoTarget      uint16 = 0x1827
	ExchangeErrDenied        uint16 = 0x1828
	ExchangeErrPositive      uint16 = 0x1829
	ExchangeErrCancel        uint16 = 0x182b // EXCHANGE_CANCEL
	ExchangeErrCancelled     uint16 = 0x182c // TRADING_CANCELED_BY_USER
	ExchangeErrSameItem      uint16 = 0x182d
	ExchangeErrInExchange    uint16 = 0x1833
	ExchangeErrBlocked       uint16 = 0x1834 // STORAGE_OPERATION_BLOCKED
	ExchangeErrNoRoomPartner uint16 = 0x1836
	ExchangeErrCannotTrade   uint16 = 0x183a
	ExchangeErrDead          uint16 = 0x1840
	ExchangeErrDeal          uint16 = 0x1841
	ExchangeErrSpecialty     uint16 = 0x1850
	ExchangeErrPetOut        uint16 = 0x18b6
	ExchangeErrSpirit        uint16 = 0x18fa
)

// exchangeCloses is FUN_00515490's list: a refusal with one of these closes
// the session.
var exchangeCloses = map[uint16]bool{2: true, 3: true, 5: true, ExchangeErrNoSession: true, ExchangeErrNotParty: true,
	ExchangeErrState: true, ExchangeErrPartnerGone: true, ExchangeErrNothing: true, ExchangeErrDeal: true,
	ExchangeErrDB: true, 0x181c: true}

// ExchangeDeps is what the exchange reads and writes.
type ExchangeDeps struct {
	Chars   character.Store
	Inv     inventory.Store
	Items   ItemLookup
	Hub     *world.Hub
	Trades  *trade.Hub
	Parties *party.Hub
}

var exchangeRT atomic.Pointer[ExchangeDeps]

// ExchangeHandler serves 0x7081..0x7084. The answer (0x3080) and the moves
// (0x7034 types 4, 5, 0xd) reach the exchange through the party handler's
// answer chain and the item operation (exchangeAnswer, exchangeMove).
func ExchangeHandler(d ExchangeDeps) gateway.Handler {
	if d.Hub != nil && d.Trades != nil {
		moveTrades.Store(d.Hub, d.Trades)
	}
	dd := d
	exchangeRT.Store(&dd)
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		// Round 869: the session's own world (gameworlds.go).
		d := d
		d.Hub = d.Hub.For(sess)
		switch p.Opcode {
		case OpExchangeRequest:
			dd.request(sess, p.Data)
		case OpExchangeConfirm:
			dd.confirm(ctx, sess)
		case OpExchangeApprove:
			dd.approve(ctx, sess)
		case OpExchangeCancel:
			dd.cancel(sess)
		}
		return nil
	}
}

// --- encoding ---------------------------------------------------------------

func exchangeResult(code uint16) []byte {
	if code == ExchangeOK {
		return []byte{1}
	}
	return binary.LittleEndian.AppendUint16([]byte{2}, code)
}

// EncodeExchangeAccepted is 0xB081's success.
func EncodeExchangeAccepted(target uint32) []byte {
	return binary.LittleEndian.AppendUint32([]byte{1}, target)
}

// EncodeExchangeRequestBox is 0x3080 kind 1.
func EncodeExchangeRequestBox(asker uint32) []byte {
	return binary.LittleEndian.AppendUint32([]byte{exchangeRequestKind}, asker)
}

// EncodeExchangeGold is 0x3089 kind 2.
func EncodeExchangeGold(gold int64) []byte {
	return binary.LittleEndian.AppendUint64([]byte{exchangeGoldKind}, uint64(gold))
}

// exchangeRecord is the full item record (the item's vslot 0x498 mode 1,
// AppendItemRecord's layout; exchange_verify "Item record").
func exchangeRecord(ctx context.Context, items ItemLookup, it trade.Item) []byte {
	if items != nil {
		if ref, err := items.GetItem(ctx, it.ItemID); err == nil && ref != nil && !isEquipment(ref) {
			sl := inventory.Slot{Index: it.Slot, ItemID: it.ItemID, Quantity: it.Quantity}
			sl.SetInstance(it.Inst)
			return AppendItemRecord(nil, ItemInfo{RefItemID: uint32(it.ItemID), Tail: retailItemTail(ctx, ref, sl, time.Now())})
		}
	}
	if ii, ok := itemInfoFor(ctx, items, it.Slot, it.ItemID, it.Inst); ok {
		return AppendItemRecord(nil, ii)
	}
	return AppendItemRecord(nil, ItemInfo{RefItemID: uint32(it.ItemID)})
}

// EncodeExchangeOffer is 0x308C: owner's bay as the receiver sees it, the
// bag slot written only when the receiver is the owner (s:0x480e50).
func EncodeExchangeOffer(ctx context.Context, items ItemLookup, owner int64, bay []trade.Item, toOwner bool) []byte {
	out := binary.LittleEndian.AppendUint32(nil, uint32(owner))
	out = append(out, byte(len(bay)))
	for i, it := range bay {
		if toOwner {
			out = append(out, byte(it.Slot+ItemWireBagOffset))
		}
		out = append(out, byte(i))
		out = append(out, exchangeRecord(ctx, items, it)...)
	}
	return out
}

func sendExchange(sess *gateway.Session, op uint16, data []byte) {
	if sess != nil {
		sendToPeer(sess, &proto.Packet{Opcode: op, Data: data})
	}
}

// --- closing -----------------------------------------------------------------

// close is CTradeMgr::SendItemExchangeResult (s:0x4806d0): the session gone,
// both players out of the exchange, and 0x3087 (code 1) or 0x3088 {code} to
// each in the game. 0x181b and 0x1825 send nothing (W3).
func (d *ExchangeDeps) close(id uint32, code uint16) {
	parties, ok := d.Trades.Close(id)
	if !ok || code == ExchangeErrNoSession || code == ExchangeErrNotParty {
		return
	}
	for _, p := range parties {
		e, online := d.Hub.EntityByCharacterID(p.CharacterID)
		if !online {
			continue
		}
		if code == ExchangeOK {
			sendExchange(e.Session, OpExchangeDone, nil)
		} else {
			sendExchange(e.Session, OpExchangeClosed, binary.LittleEndian.AppendUint16(nil, code))
		}
	}
}

// exchangeEnd closes characterID's session with code, if any: death, a warp
// and the logout (0x182b).
func exchangeEnd(characterID int64, code uint16) {
	d := exchangeRT.Load()
	if d == nil || d.Trades == nil {
		return
	}
	if id := d.Trades.SessionOf(characterID); id != 0 {
		d.close(id, code)
	}
}

// exchangeEstablished reports whether characterID is in an accepted
// exchange (INTERACTMODE 2).
func exchangeEstablished(characterID int64) bool {
	d := exchangeRT.Load()
	return d != nil && d.Trades != nil && d.Trades.Established(characterID)
}

// ExchangeDisconnectHandler closes a leaving player's exchange 0x182b
// (s:FUN_004def00). It must run before WorldDisconnectHandler.
func ExchangeDisconnectHandler(hub *world.Hub) func(sess *gateway.Session) {
	return func(sess *gateway.Session) {
		// Round 869: the session's own world (gameworlds.go).
		hub := hub.For(sess)
		if e, ok := hub.EntityBySession(sess.ID()); ok {
			exchangeEnd(e.CharacterID, ExchangeErrCancel)
		}
	}
}

// --- the request ------------------------------------------------------------

// busyFor is GObjPC::FUN_004ea050's INTERACTMODE half for OpenSRO's states:
// a session, an open NPC talk, or a pending party or guild invitation.
func (d *ExchangeDeps) busyFor(e world.Entity) bool {
	if d.Trades.Busy(e.CharacterID) || npcTalkOpen(e.Session.ID()) {
		return true
	}
	if d.Parties != nil && d.Parties.State(e.CharacterID) == party.StatePending {
		return true
	}
	guildInvites.mu.Lock()
	_, guildPending := guildInvites.m[e.CharacterID]
	guildInvites.mu.Unlock()
	return guildPending
}

// request is 0x7081, GObjPC_HandleTradeMsg_081 in its order (§2.1). Its
// refusals are 0xB081 {2, code}; the asker is sent nothing on success.
func (d *ExchangeDeps) request(sess *gateway.Session, data []byte) {
	me, ok := d.Hub.EntityBySession(sess.ID())
	if !ok || len(data) < 4 {
		return
	}
	fail := func(code uint16) { sendExchange(sess, OpExchangeRequestResult, exchangeResult(code)) }
	// Round 840: the trade ban first -- 0x3405 {1, end} and no 0xB081 (W1,
	// s:0x515530).
	if restricted(context.Background(), sess, RestrictTrade) {
		return
	}
	tid := binary.LittleEndian.Uint32(data)
	if tid == uint32(me.CharacterID) || tid >= npcspawn.UIDBase {
		fail(ExchangeErrTarget)
		return
	}
	target, ok := d.Hub.EntityByCharacterID(int64(tid))
	if !ok || target.Zone != me.Zone {
		fail(ExchangeErrTarget)
		return
	}
	if me.Life != world.LifeAlive {
		fail(ExchangeErrRequester)
		return
	}
	if id := d.Trades.SessionOf(me.CharacterID); id != 0 {
		state, other := 0, int64(0)
		d.Trades.DoID(id, func(s *trade.Session) {
			state = s.State
			if i := s.Index(me.CharacterID); i >= 0 {
				other = s.P[1-i].CharacterID
			}
		})
		if state >= trade.StateEstablished {
			fail(ExchangeErrInExchange)
			return
		}
		if other == target.CharacterID {
			return // FUN_0047f5b0: the same pending request, dropped
		}
		// Another pending request: cancelled through the 084 handler.
		d.close(id, ExchangeErrCancelled)
		sendExchange(sess, OpExchangeCancelResult, exchangeResult(ExchangeOK))
	}
	if npcTalkOpen(sess.ID()) || (d.Parties != nil && d.Parties.State(me.CharacterID) == party.StatePending) {
		fail(ExchangeErrRequester)
		return
	}
	if dist3(me.Pos, target.Pos) >= trade.RequestRange {
		fail(ExchangeErrTooFar)
		return
	}
	if target.Life != world.LifeAlive || d.busyFor(target) {
		fail(ExchangeErrBusy)
		return
	}
	_, err := d.Trades.Open(trade.Party{Session: sess, CharacterID: me.CharacterID, Name: me.Name},
		trade.Party{Session: target.Session, CharacterID: target.CharacterID, Name: target.Name},
		func(id uint32) { d.close(id, ExchangeErrTimeout) })
	if err != nil {
		fail(ExchangeErrBusy)
		return
	}
	sendExchange(target.Session, OpRequestBox, EncodeExchangeRequestBox(uint32(me.CharacterID)))
}

// exchangeAnswer takes a 0x3080 answer when me is the target of a pending
// request; false otherwise (the party handler's chain asks it first).
func exchangeAnswer(sess *gateway.Session, me world.Entity, data []byte) bool {
	d := exchangeRT.Load()
	if d == nil || d.Trades == nil || len(data) < 2 {
		return false
	}
	id, pending := uint32(0), false
	d.Trades.Do(me.CharacterID, func(s *trade.Session, i int) {
		if i == 1 && s.State == trade.StateOpened {
			id, pending = s.ID, true
		}
	})
	if !pending {
		return false
	}
	if data[0] != 1 {
		// vslot 3 (s:0x46cec0): the client's own code closes it.
		code := ExchangeErrDenied
		if len(data) >= 3 {
			code = binary.LittleEndian.Uint16(data[1:])
		}
		d.close(id, code)
		return true
	}
	if data[1] != 1 {
		code := ExchangeErrDenied
		if me.Life != world.LifeAlive {
			code = ExchangeErrDead
		}
		d.close(id, code)
		return true
	}
	d.establish(id)
	return true
}

// establish is CTradeMgr::EstablishTradeSession (s:0x47f970): both in the
// game and in reach, then state 2 for the session and both sides; 0xB081
// {1, target} to the asker and 0x3085 {asker} to the target.
func (d *ExchangeDeps) establish(id uint32) {
	var asker, target int64
	d.Trades.DoID(id, func(s *trade.Session) { asker, target = s.P[0].CharacterID, s.P[1].CharacterID })
	a, aok := d.Hub.EntityByCharacterID(asker)
	b, bok := d.Hub.EntityByCharacterID(target)
	if !aok || !bok {
		d.close(id, ExchangeErrNoTarget)
		return
	}
	if a.Zone != b.Zone || dist3(a.Pos, b.Pos) >= trade.RequestRange {
		d.close(id, ExchangeErrTooFar)
		return
	}
	ok := false
	d.Trades.DoID(id, func(s *trade.Session) {
		if s.State != trade.StateOpened {
			return
		}
		s.State = trade.StateEstablished
		for _, p := range s.P {
			p.State = trade.PartOffering
		}
		s.P[0].Session, s.P[1].Session = a.Session, b.Session
		ok = true
	})
	if !ok {
		d.close(id, ExchangeErrState)
		return
	}
	cancelActions(asker)
	cancelActions(target)
	sendExchange(a.Session, OpExchangeRequestResult, EncodeExchangeAccepted(uint32(target)))
	sendExchange(b.Session, OpExchangeStarted, binary.LittleEndian.AppendUint32(nil, uint32(asker)))
}

// --- the moves --------------------------------------------------------------

// isExchangeMove reports whether a 0x7034 type is the exchange's.
func isExchangeMove(t byte) bool {
	return t == ItemMoveExchangeAdd || t == ItemMoveExchangeRemove || t == ItemMoveExchangeGold
}

// exchangeMove is StorageOperation's ops 4, 5 and 0xd. A refusal in the
// close list closes the session first and then answers 0xB034 {2, code}
// (exchange_verify W5).
func exchangeMove(ctx context.Context, sess *gateway.Session, data []byte, d *ExchangeDeps) {
	me, ok := d.Hub.EntityBySession(sess.ID())
	if !ok || len(data) < 1 {
		return
	}
	fail := func(code uint16) {
		if exchangeCloses[code] {
			if id := d.Trades.SessionOf(me.CharacterID); id != 0 {
				d.close(id, code)
			}
		}
		sendExchange(sess, OpItemMoveResult, EncodeItemFail(code))
	}
	switch data[0] {
	case ItemMoveExchangeAdd:
		if len(data) < 2 {
			fail(ExchangeErrFail)
			return
		}
		d.offerItem(ctx, sess, me, int(data[1]), fail)
	case ItemMoveExchangeRemove:
		if len(data) < 2 {
			fail(ExchangeErrFail)
			return
		}
		d.takeBack(ctx, sess, me, int(data[1]), fail)
	case ItemMoveExchangeGold:
		if len(data) < 9 {
			fail(ExchangeErrFail)
			return
		}
		d.setGold(ctx, sess, me, int64(binary.LittleEndian.Uint64(data[1:])), fail)
	}
}

// offerItem is TradeOfferItem + OfferItemToPartner, the checks in their
// order (§2.3).
func (d *ExchangeDeps) offerItem(ctx context.Context, sess *gateway.Session, me world.Entity, wire int, fail func(uint16)) {
	if wire < ItemWireBagOffset {
		fail(ExchangeErrWornSlot)
		return
	}
	slot := wire - ItemWireBagOffset
	slots, err := d.Inv.List(ctx, me.CharacterID)
	if err != nil {
		fail(ExchangeErrFail)
		return
	}
	var sl *inventory.Slot
	for i := range slots {
		if slots[i].Index == slot {
			sl = &slots[i]
		}
	}
	if sl == nil {
		fail(ExchangeErrEmptySlot)
		return
	}
	var ref *refdata.Item
	if d.Items != nil {
		ref, _ = d.Items.GetItem(ctx, sl.ItemID)
	}
	if ref != nil && !ref.CanTrade {
		fail(ExchangeErrCannotTrade)
		return
	}
	if cosItemOut(ctx, me.CharacterID, slot) {
		fail(ExchangeErrPetOut)
		return
	}
	if ref != nil && avatar.IsDevilSpirit(ref) && avatar.Awake(sl.Durability, time.Now()) {
		fail(ExchangeErrSpirit)
		return
	}
	// The partner's free bag slots, for check 12 (read before the lock).
	partner := int64(0)
	d.Trades.Do(me.CharacterID, func(s *trade.Session, i int) { partner = s.P[1-i].CharacterID })
	partnerFree := -1
	if partner != 0 {
		partnerFree = d.freeSlots(ctx, partner)
	}
	item := trade.Item{Slot: slot, ItemID: sl.ItemID, Quantity: sl.Quantity, Inst: sl.Instance()}
	code := ExchangeErrNoSession
	var bay []trade.Item
	index := 0
	d.Trades.Do(me.CharacterID, func(s *trade.Session, i int) {
		p, other := s.P[i], s.P[1-i]
		_, otherOnline := d.Hub.EntityByCharacterID(other.CharacterID)
		switch {
		case s.State != trade.StateEstablished || p.State != trade.PartOffering:
			code = ExchangeErrState
		case p.HasSlot(slot):
			code = ExchangeErrSameItem
		case len(p.Bay) >= trade.MaxBay:
			code = ExchangeErrBayFull
		case !otherOnline:
			code = ExchangeErrPartnerGone
		case partnerFree >= 0 && partnerFree < len(p.Bay)+1:
			code = ExchangeErrNoRoomPartner
		case ref != nil && ref.TypeID1 == 3 && ref.TypeID2 == 3 && ref.TypeID3 == 8:
			code = ExchangeErrSpecialty
		default:
			index = len(p.Bay)
			p.Bay = append(p.Bay, item)
			bay = append([]trade.Item(nil), p.Bay...)
			code = ExchangeOK
		}
	})
	if code != ExchangeOK {
		fail(code)
		return
	}
	sendExchange(sess, OpExchangeOffer, EncodeExchangeOffer(ctx, d.Items, me.CharacterID, bay, true))
	sendExchange(sess, OpItemMoveResult, []byte{itemOpOK, ItemMoveExchangeAdd, byte(wire), byte(index)})
}

// takeBack is op 5 (s:0x480c70).
func (d *ExchangeDeps) takeBack(ctx context.Context, sess *gateway.Session, me world.Entity, index int, fail func(uint16)) {
	code := ExchangeErrNoSession
	var bay []trade.Item
	d.Trades.Do(me.CharacterID, func(s *trade.Session, i int) {
		p, other := s.P[i], s.P[1-i]
		_, otherOnline := d.Hub.EntityByCharacterID(other.CharacterID)
		switch {
		case s.State != trade.StateEstablished || p.State != trade.PartOffering:
			code = ExchangeErrState
		case len(p.Bay) == 0:
			code = ExchangeErrBayEmpty
		case index >= len(p.Bay) || index >= trade.MaxBay:
			code = ExchangeErrWornSlot
		case !otherOnline:
			code = ExchangeErrPartnerGone
		default:
			p.Bay = append(p.Bay[:index:index], p.Bay[index+1:]...)
			bay = append([]trade.Item(nil), p.Bay...)
			code = ExchangeOK
		}
	})
	if code != ExchangeOK {
		fail(code)
		return
	}
	sendExchange(sess, OpExchangeOffer, EncodeExchangeOffer(ctx, d.Items, me.CharacterID, bay, true))
	sendExchange(sess, OpItemMoveResult, []byte{itemOpOK, ItemMoveExchangeRemove, byte(index)})
}

// setGold is op 0xd (s:0x480f30): the amount replaces the last; it is not
// reserved, and the partner is told nothing.
func (d *ExchangeDeps) setGold(ctx context.Context, sess *gateway.Session, me world.Entity, gold int64, fail func(uint16)) {
	if gold <= 0 {
		fail(ExchangeErrPositive)
		return
	}
	if gold > trade.MaxGold {
		fail(ExchangeErrFail)
		return
	}
	carried := int64(-1)
	if c, err := d.Chars.GetByID(ctx, me.CharacterID); err == nil && c != nil {
		carried = c.Gold
	}
	code := ExchangeErrNoSession
	d.Trades.Do(me.CharacterID, func(s *trade.Session, i int) {
		p, other := s.P[i], s.P[1-i]
		_, otherOnline := d.Hub.EntityByCharacterID(other.CharacterID)
		switch {
		case s.State != trade.StateEstablished || p.State != trade.PartOffering:
			code = ExchangeErrState
		case !otherOnline:
			code = ExchangeErrPartnerGone
		case carried < 0 || gold > carried:
			code = ExchangeErrGold
		default:
			p.Gold = gold
			code = ExchangeOK
		}
	})
	if code != ExchangeOK {
		fail(code)
		return
	}
	out := []byte{itemOpOK, ItemMoveExchangeGold}
	sendExchange(sess, OpItemMoveResult, binary.LittleEndian.AppendUint64(out, uint64(gold)))
}

// freeSlots is CountEmptySlot(0xd, -1): the empty bag slots within the
// bag's size.
func (d *ExchangeDeps) freeSlots(ctx context.Context, characterID int64) int {
	return len(d.emptySlots(ctx, characterID, nil))
}

// emptySlots is the bag's empty slots in order, within its placement size;
// taken lists slots to count as filled.
func (d *ExchangeDeps) emptySlots(ctx context.Context, characterID int64, slots []inventory.Slot) []int {
	if slots == nil {
		var err error
		slots, err = d.Inv.List(ctx, characterID)
		if err != nil {
			return nil
		}
	}
	place := inventory.PlacementCapacityOf(ctx, d.Inv, characterID)
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

// --- confirm, approve, cancel -----------------------------------------------

// confirm is 0x7082 (s:FUN_0047fd20).
func (d *ExchangeDeps) confirm(ctx context.Context, sess *gateway.Session) {
	me, ok := d.Hub.EntityBySession(sess.ID())
	if !ok {
		return
	}
	code := ExchangeErrNoSession
	var id uint32
	var bay []trade.Item
	var gold int64
	var partner *gateway.Session
	d.Trades.Do(me.CharacterID, func(s *trade.Session, i int) {
		id = s.ID
		other := s.P[1-i]
		oe, otherOnline := d.Hub.EntityByCharacterID(other.CharacterID)
		switch {
		case s.State != trade.StateEstablished:
			code = ExchangeErrState
		case !otherOnline:
			code = ExchangeErrPartnerGone
		default:
			s.P[i].State = trade.PartConfirmed
			if other.State == trade.PartConfirmed {
				s.State = trade.StateConfirmed
			}
			bay = append([]trade.Item(nil), s.P[i].Bay...)
			gold = s.P[i].Gold
			partner = oe.Session
			code = ExchangeOK
		}
	})
	if code != ExchangeOK {
		sendExchange(sess, OpExchangeConfirmResult, exchangeResult(code))
		if id != 0 && exchangeCloses[code] {
			d.close(id, code)
		}
		return
	}
	sendExchange(sess, OpExchangeOffer, EncodeExchangeOffer(ctx, d.Items, me.CharacterID, bay, true))
	sendExchange(partner, OpExchangeOffer, EncodeExchangeOffer(ctx, d.Items, me.CharacterID, bay, false))
	sendExchange(partner, OpExchangeUpdate, EncodeExchangeGold(gold))
	sendExchange(partner, OpExchangeConfirmed, nil)
	sendExchange(sess, OpExchangeConfirmResult, exchangeResult(ExchangeOK))
}

// approve is 0x7083 (CTradeMgr::Exchange s:0x47fe40).
func (d *ExchangeDeps) approve(ctx context.Context, sess *gateway.Session) {
	me, ok := d.Hub.EntityBySession(sess.ID())
	if !ok {
		return
	}
	code := ExchangeErrNoSession
	var id uint32
	both := false
	var parties [2]trade.Party
	d.Trades.Do(me.CharacterID, func(s *trade.Session, i int) {
		id = s.ID
		if s.State != trade.StateConfirmed {
			code = ExchangeErrState
			return
		}
		if _, online := d.Hub.EntityByCharacterID(s.P[1-i].CharacterID); !online {
			code = ExchangeErrPartnerGone
			return
		}
		s.P[i].State = trade.PartApproved
		code = ExchangeOK
		if s.P[1-i].State == trade.PartApproved {
			both = true
			s.State = trade.StateDealing
			for k, p := range s.P {
				parties[k] = *p
				parties[k].Bay = append([]trade.Item(nil), p.Bay...)
			}
		}
	})
	if code != ExchangeOK {
		sendExchange(sess, OpExchangeApproveResult, exchangeResult(code))
		if id != 0 && exchangeCloses[code] {
			d.close(id, code)
		}
		return
	}
	if !both {
		sendExchange(sess, OpExchangeApproveResult, exchangeResult(ExchangeOK))
		return
	}
	code = d.deal(ctx, id, parties)
	metrics.Exchange(code == ExchangeOK)
	if code != ExchangeOK {
		sendExchange(sess, OpExchangeApproveResult, exchangeResult(code))
		d.close(id, code)
		return
	}
	// OffsetGold(delta, 0x22, 1, 0): 0x304E, unshown, for each side whose
	// gold changed (DealIt, exchange_verify).
	for k := range parties {
		if parties[1-k].Gold != parties[k].Gold {
			tellGold(ctx, d.Chars, d.Hub, parties[k].CharacterID, false)
		}
	}
	sendExchange(sess, OpExchangeApproveResult, exchangeResult(ExchangeOK))
	d.close(id, ExchangeOK)
}

// cancel is 0x7084 (s:GObjPC_HandleTradeMsg_084 0x5159c0): 0x3088 {0x182c}
// to both, then 0xB084 {1} -- a pending request included.
func (d *ExchangeDeps) cancel(sess *gateway.Session) {
	me, ok := d.Hub.EntityBySession(sess.ID())
	if !ok {
		return
	}
	id := d.Trades.SessionOf(me.CharacterID)
	if id == 0 {
		sendExchange(sess, OpExchangeCancelResult, exchangeResult(ExchangeErrNoSession))
		return
	}
	d.close(id, ExchangeErrCancelled)
	sendExchange(sess, OpExchangeCancelResult, exchangeResult(ExchangeOK))
}

// --- the deal ---------------------------------------------------------------

var errExchangeRefused = errors.New("exchange: refused")

func exchangeLedgerKey(id uint32) string {
	return fmt.Sprintf("exchange:%s:%d", txn.BootID, id)
}

// deal is CTradeMgr::Exchange's second half and DealIt as one transaction:
// the checks in their order, then the gold, then each item from its giver's
// slot to the receiver's next empty slot (computed before anything moves,
// FUN_004801b0), and the ledger row that makes it apply once.
func (d *ExchangeDeps) deal(ctx context.Context, id uint32, p [2]trade.Party) uint16 {
	refusal := ExchangeOK
	err := txn.For(d.Chars, d.Inv).Run(ctx, func(ctx context.Context) error {
		refusal = ExchangeOK
		refuse := func(code uint16) error {
			refusal = code
			return errExchangeRefused
		}
		if err := txn.Claim(ctx, exchangeLedgerKey(id)); err != nil {
			return err
		}
		var bags [2][]inventory.Slot
		for k := range p {
			slots, err := d.Inv.List(ctx, p[k].CharacterID)
			if err != nil {
				return err
			}
			bags[k] = slots
			for _, it := range p[k].Bay {
				if !bayItemStill(slots, it) {
					return refuse(ExchangeErrDeal) // VerifyLoadedItemValidity
				}
			}
		}
		if len(p[0].Bay) == 0 && len(p[1].Bay) == 0 && p[0].Gold == 0 && p[1].Gold == 0 {
			return refuse(ExchangeErrNothing)
		}
		var dest [2][]int
		for k := range p {
			free := d.emptySlots(ctx, p[k].CharacterID, bags[k])
			if len(free) < len(p[1-k].Bay) {
				return refuse(ExchangeErrDeal)
			}
			dest[k] = free[:len(p[1-k].Bay)]
		}
		var gold [2]int64
		for k := range p {
			c, err := d.Chars.GetByID(ctx, p[k].CharacterID)
			if err != nil {
				return err
			}
			if c.Gold+p[1-k].Gold-p[k].Gold < 0 {
				return refuse(ExchangeErrDeal)
			}
			gold[k] = p[1-k].Gold - p[k].Gold
		}
		// The rows locked in ascending character id (round 743's order).
		order := []int{0, 1}
		sort.Slice(order, func(a, b int) bool { return p[order[a]].CharacterID < p[order[b]].CharacterID })
		for _, k := range order {
			switch {
			case gold[k] < 0:
				if err := d.Chars.DeductGold(ctx, p[k].CharacterID, -gold[k]); err != nil {
					if errors.Is(err, character.ErrInsufficientGold) {
						return refuse(ExchangeErrDeal)
					}
					return err
				}
			case gold[k] > 0:
				if err := d.Chars.AddGold(ctx, p[k].CharacterID, gold[k]); err != nil {
					return err
				}
			}
		}
		var moved [2][]trade.Item
		for _, k := range order {
			for _, it := range p[k].Bay {
				got, err := inventory.Take(ctx, d.Inv, p[k].CharacterID, it.Slot, it.Quantity, it.ItemID, it.Inst)
				if err != nil {
					if offerGone(err) {
						return refuse(ExchangeErrDeal)
					}
					return err
				}
				moved[k] = append(moved[k], trade.Item{Slot: it.Slot, ItemID: it.ItemID, Quantity: it.Quantity, Inst: got})
			}
		}
		placer, canPlace := d.Inv.(interface {
			PlaceItemInstance(ctx context.Context, characterID int64, slot int, itemID int64, quantity int, inst inventory.Instance) error
		})
		for _, k := range order {
			for j, it := range moved[1-k] {
				var err error
				if canPlace {
					err = placer.PlaceItemInstance(ctx, p[k].CharacterID, dest[k][j], it.ItemID, it.Quantity, it.Inst)
				} else {
					err = d.Inv.AddItemInstance(ctx, p[k].CharacterID, it.ItemID, it.Quantity, it.Inst)
				}
				if err != nil {
					if errors.Is(err, inventory.ErrNoRoom) || errors.Is(err, inventory.ErrSlotTaken) {
						return refuse(ExchangeErrDeal)
					}
					return err
				}
			}
		}
		return nil
	})
	if errors.Is(err, errExchangeRefused) {
		return refusal
	}
	if err != nil {
		// A store failure, or a commit whose answer was lost: the ledger
		// says which (round 743's review, F2).
		done, lerr := txn.For(d.Chars, d.Inv).Applied(context.WithoutCancel(ctx), exchangeLedgerKey(id))
		slog.Warn("exchange: the deal failed", "session", id, "a", p[0].CharacterID, "b", p[1].CharacterID,
			"applied", lerr == nil && done, "err", err)
		if lerr == nil && done {
			return ExchangeOK
		}
		return ExchangeErrDB
	}
	return ExchangeOK
}

// bayItemStill reports whether the bag still holds the offered item at its
// slot: the same item, count and instance.
func bayItemStill(slots []inventory.Slot, it trade.Item) bool {
	for _, sl := range slots {
		if sl.Index == it.Slot {
			return sl.ItemID == it.ItemID && sl.Quantity == it.Quantity && sl.Instance().Equal(it.Inst)
		}
	}
	return false
}

// offerGone reports whether a take failed because the slot no longer holds
// what was offered (a refusal, not a store failure).
func offerGone(err error) bool {
	return errors.Is(err, inventory.ErrSlotEmpty) || errors.Is(err, inventory.ErrItemChanged) ||
		errors.Is(err, inventory.ErrInsufficientQuantity) || errors.Is(err, inventory.ErrInvalidSlot) ||
		errors.Is(err, inventory.ErrInvalidQuantity)
}
