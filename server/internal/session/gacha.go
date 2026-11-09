package session

// Magic POP (round 838, lane 5): the gacha machine's draw and Gori's coupon
// exchange. READ from SR_GameServer.exe (s:) and sro_client.exe (c:) unless a
// line says otherwise; internal/gacha has the tables and the draw's rule,
// docs/protocol/magic_pop.md the whole flow.
//
//   - Opening: the machine's spawn offers 0x11 (npcspawn.GachaMachine); the
//     client's talk line 0x27 sends the open 0x7046 {npc, 0x11}, answered
//     {1, 0x11} with INTERACTMODE 6 by the generic open (npctalk.go), and
//     the client builds its window (c:0x79c060).
//   - The draw, 0x7118 C->S {u32 npc uid, u32 GachaID, u8 bag slot + 13}
//     (handler s:0x511570 -> s:0x4c7e20). The interaction range first
//     (IsWithinInteractionRange, filter 0x146), then in order: the NPC offers
//     0x11 (else 0x1c0f); the slot is inside the bag (else 0x1806); the NPC
//     is in the gacha map (else 0x1c0f); the slot holds an item (else
//     0x1809); it is a Magic POP card, TypeID 3/3/14/1 (s:0x488e70, else
//     0x1806); it has not expired (0x183d -- not modelled: OpenSRO has no
//     rental items); then the draw (gacha.Table.Draw, missing rows 2).
//   - The card becomes its coupon IN PLACE (s:0x4edd20): Param2's
//     descriptor (ITEM_MALL_GACHA_CARD_WIN) on a win, Param1's
//     (ITEM_MALL_GACHA_CARD_LOSE) on a loss, its param list {prize RefItemID,
//     Count} -- kept in the instance's MagParams, the same per-item u64
//     list retail writes them to (data+0x60/+0x68). Any failure there is 5.
//     There is no bag-space check (READ: nothing to place).
//   - The answer, 0xB118 {u8 1, u8 win} (the coupon's Param1: 1 WIN, 0
//     LOSE) or {u8 2, u16 code}; and, for a win whose row is Visible, 0x3120
//     {u32 prize RefItemID, u16 count} to everyone (s:0x5f8620; the scope is
//     INFERRED). No row of this archive is Visible.
//   - Gori's exchange, 0x7119 C->S {u32 npc uid} (s:0x5115e0 -> s:0x4c8130):
//     the NPC offers 0x12 (else 0x1c0f); every coupon (3/3/14/2) in the bag
//     becomes its prize -- a 3/3 prize with the coupon's count, any other
//     one count 1 (s:0x4ed910). No 0xB119 on success; a failure {2, u16 5}.
//
// OURS, disclosed:
//
//   - Retail tells the client about each changed slot with 0x3040 (the item
//     update); OpenSRO sends no 0x3040 here -- its client re-lists its bag
//     after 0xB118 and after sending 0x7119 (the session's messages are
//     handled in order, so the list carries the exchange), and writes
//     retail's UIIT_MSG_GACHA_EXCHANGE line for each coupon slot that changed.
//   - An exchanged prize gets a fresh instance (variance, durability) as a
//     new item does; the archive's [BIIV] free params of the flag rows (the
//     'V'/'M'/'O'/'D' stats retail writes at the exchange) are not applied
//     (OPEN).
//   - A slot below 13 (an equipment slot) is refused 0x1806: OpenSRO's bag
//     indexes start after the worn slots.

import (
	"context"
	"encoding/binary"
	"errors"
	"log/slog"
	"math/rand"
	"sync"

	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gacha"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/metrics"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/txn"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Magic POP's messages, retail's opcodes.
const (
	OpGachaPlay           uint16 = 0x7118 // C->S the draw
	OpGachaPlayResult     uint16 = 0xB118 // S->C {1, win} | {2, u16 code}
	OpGachaExchange       uint16 = 0x7119 // C->S Gori's exchange
	OpGachaExchangeResult uint16 = 0xB119 // S->C {2, u16 5} (a failure only)
	OpGachaAnnounce       uint16 = 0x3120 // S->C {u32 ref, u16 count}: a Visible prize won
)

// The NPC interaction ids (npcspawn).
const (
	gachaMachineID  byte = 0x11
	gachaOperatorID byte = 0x12
)

// gachaBagBase is the slot number's offset on the wire: the bag's first slot
// is 13, after the worn slots (retail's numbering).
const gachaBagBase = 13

// The card and the coupon kinds: TypeID 3/3/14/1 and 3/3/14/2.
func isGachaCard(it *refdata.Item) bool {
	return it != nil && it.TypeID1 == equipment.TypeItem && it.TypeID2 == equipment.TypeExpendable &&
		it.TypeID3 == 14 && it.TypeID4 == 1
}

func isGachaCoupon(it *refdata.Item) bool {
	return it != nil && it.TypeID1 == equipment.TypeItem && it.TypeID2 == equipment.TypeExpendable &&
		it.TypeID3 == 14 && it.TypeID4 == 2
}

// GachaDeps is what the handler needs. Items must answer GetItemByCode too
// (the coupon is named by the card's descriptors). Rand, when set, answers
// rand() % n (tests); nil uses math/rand.
type GachaDeps struct {
	Table  *gacha.Table
	Inv    inventory.Store
	Items  ItemLookup
	Hub    *world.Hub
	Logger *slog.Logger
	Rand   func(n int) int
}

// gachaPlay is the decoded 0x7118.
type gachaPlay struct {
	NPC     uint32
	GachaID uint32
	Slot    byte
}

func decodeGachaPlay(b []byte) (gachaPlay, bool) {
	if len(b) < 9 {
		return gachaPlay{}, false
	}
	return gachaPlay{NPC: binary.LittleEndian.Uint32(b), GachaID: binary.LittleEndian.Uint32(b[4:]), Slot: b[8]}, true
}

func gachaFail(code uint16) []byte {
	return binary.LittleEndian.AppendUint16([]byte{2}, code)
}

// GachaHandler answers 0x7118 and 0x7119.
func GachaHandler(d GachaDeps) gateway.Handler {
	var mu sync.Mutex
	rnd := d.Rand
	if rnd == nil {
		src := rand.New(rand.NewSource(rand.Int63()))
		rnd = func(n int) int {
			mu.Lock()
			defer mu.Unlock()
			return src.Intn(n)
		}
	}
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		// Round 869: the session's own world (gameworlds.go).
		d := d
		d.Hub = d.Hub.For(sess)
		switch p.Opcode {
		case OpGachaPlay:
			res := d.play(ctx, sess, p.Data, rnd)
			if res == nil {
				return nil
			}
			return sess.Send(&proto.Packet{Opcode: OpGachaPlayResult, Data: res})
		case OpGachaExchange:
			return d.exchange(ctx, sess, p.Data)
		}
		return nil
	}
}

// gachaNPC resolves the NPC the request names and tests the range and the
// interaction id: 0x1c0f when it does not offer id.
func gachaNPC(hub *world.Hub, sess *gateway.Session, uid uint32, id byte) (world.Entity, npcPlacement, uint16, bool) {
	// Round 869: the session's own world (gameworlds.go).
	hub = hub.For(sess)
	if hub == nil {
		return world.Entity{}, npcPlacement{}, 0, false
	}
	e, ok := hub.EntityBySession(sess.ID())
	if !ok {
		return e, npcPlacement{}, 0, false
	}
	pl, code := npcTarget(e, uid)
	if code != 0 {
		return e, pl, code, true
	}
	for _, b := range pl.npc.Interact {
		if b == id {
			return e, pl, 0, true
		}
	}
	return e, pl, gacha.CodeNotMachine, true
}

// play runs one draw and returns 0xB118's payload (nil: no answer, the
// sender is not in the world).
func (d GachaDeps) play(ctx context.Context, sess *gateway.Session, data []byte, rnd func(int) int) []byte {
	req, ok := decodeGachaPlay(data)
	if !ok {
		return gachaFail(gacha.CodeNoRow)
	}
	e, pl, code, ok := gachaNPC(d.Hub, sess, req.NPC, gachaMachineID)
	if !ok {
		return nil
	}
	if code != 0 {
		return gachaFail(code)
	}
	if d.Inv == nil || d.Items == nil {
		return gachaFail(gacha.CodeFailed)
	}
	cid := e.CharacterID
	bag := int(req.Slot) - gachaBagBase
	if bag < 0 || bag >= inventory.PlacementCapacityOf(ctx, d.Inv, cid) {
		return gachaFail(gacha.CodeBadSlot)
	}
	m, ok := d.Table.Machine(int64(pl.npc.RefID))
	if !ok {
		return gachaFail(gacha.CodeNotMachine)
	}
	slots, err := d.Inv.List(ctx, cid)
	if err != nil {
		return gachaFail(gacha.CodeFailed)
	}
	var held *inventory.Slot
	for i := range slots {
		if slots[i].Index == bag {
			held = &slots[i]
			break
		}
	}
	if held == nil || held.Quantity < 1 {
		return gachaFail(gacha.CodeEmptySlot)
	}
	card, err := d.Items.GetItem(ctx, held.ItemID)
	if err != nil || !isGachaCard(card) {
		return gachaFail(gacha.CodeBadSlot)
	}
	out, drawCode := d.Table.Draw(m, int64(req.GachaID), rnd)
	if drawCode != 0 {
		return gachaFail(uint16(drawCode))
	}
	// The coupon: Param2's descriptor on a win, Param1's on a loss.
	couponCode := card.Desc1
	if out.Win {
		couponCode = card.Desc2
	}
	coupon, err := gachaItemByCode(ctx, d.Items, couponCode)
	if err != nil || coupon == nil {
		d.log("gacha: the card's coupon is unknown", "card", card.CodeName, "coupon", couponCode, "err", err)
		return gachaFail(gacha.CodeFailed)
	}
	inst := inventory.Instance{Durability: held.Durability, MagParams: []uint64{uint64(out.Row.RefItemID), uint64(out.Row.Count)}}
	if err := replaceInPlace(ctx, d.Inv, cid, bag, held.ItemID, coupon.ID, 1, inst); err != nil {
		d.log("gacha: turning the card failed", "character_id", cid, "slot", bag, "err", err)
		return gachaFail(gacha.CodeFailed)
	}
	win := byte(0)
	if out.Win {
		win = 1
	}
	metrics.GachaDraw()
	d.log("gacha draw", "character_id", cid, "npc", pl.npc.Code, "gacha_id", req.GachaID, "win", out.Win,
		"prize", out.Row.RefItemID, "count", out.Row.Count, "coupon", coupon.CodeName, "slot", bag)
	if out.Win && out.Row.Visible && d.Hub != nil {
		msg := binary.LittleEndian.AppendUint32(nil, uint32(out.Row.RefItemID))
		msg = binary.LittleEndian.AppendUint16(msg, uint16(out.Row.Count))
		// Round 869 lane W2: every world, every process.
		pkt := &proto.Packet{Opcode: OpGachaAnnounce, Data: msg}
		for _, other := range allEntitiesAnywhere(d.Hub) {
			other.Session.Send(pkt)
		}
		if clusterOn() {
			sendEverywhere(0, pkt)
		}
	}
	return []byte{1, win}
}

// exchange is Gori's: every coupon becomes its prize.
func (d GachaDeps) exchange(ctx context.Context, sess *gateway.Session, data []byte) error {
	if len(data) < 4 {
		return sess.Send(&proto.Packet{Opcode: OpGachaExchangeResult, Data: gachaFail(gacha.CodeFailed)})
	}
	e, _, code, ok := gachaNPC(d.Hub, sess, binary.LittleEndian.Uint32(data), gachaOperatorID)
	if !ok {
		return nil
	}
	if code != 0 {
		return sess.Send(&proto.Packet{Opcode: OpGachaExchangeResult, Data: gachaFail(code)})
	}
	fail := func() error {
		return sess.Send(&proto.Packet{Opcode: OpGachaExchangeResult, Data: gachaFail(gacha.CodeFailed)})
	}
	if d.Inv == nil || d.Items == nil {
		return fail()
	}
	cid := e.CharacterID
	slots, err := d.Inv.List(ctx, cid)
	if err != nil {
		return fail()
	}
	for _, s := range slots {
		it, err := d.Items.GetItem(ctx, s.ItemID)
		if err != nil || !isGachaCoupon(it) || len(s.MagParams) < 2 {
			continue
		}
		prizeID := int64(s.MagParams[0])
		prize, err := d.Items.GetItem(ctx, prizeID)
		if err != nil || prize == nil {
			d.log("gacha exchange: the coupon's prize is unknown", "character_id", cid, "slot", s.Index, "prize", prizeID)
			return fail()
		}
		count := 1
		if prize.TypeID2 == equipment.TypeExpendable && s.MagParams[1] > 0 {
			count = int(s.MagParams[1])
		}
		inst, err := mallInstance(ctx, d.Items, prizeID, 0, 0, 0, nil)
		if err != nil {
			return fail()
		}
		if err := replaceInPlace(ctx, d.Inv, cid, s.Index, s.ItemID, prizeID, count, inst); err != nil {
			d.log("gacha exchange failed", "character_id", cid, "slot", s.Index, "err", err)
			return fail()
		}
		d.log("gacha exchange", "character_id", cid, "slot", s.Index, "coupon", it.CodeName, "prize", prize.CodeName, "count", count)
	}
	// No answer on success: s:0x4c8130 sends only the failure.
	return nil
}

// replaceInPlace takes the whole of slot (it must still hold wantItem) and
// puts n of newItem with inst in the same slot, in one transaction.
func replaceInPlace(ctx context.Context, inv inventory.Store, cid int64, slot int, wantItem, newItem int64, n int, inst inventory.Instance) error {
	tk, ok := inv.(inventory.Taker)
	pl, ok2 := inv.(inventory.Placer)
	if !ok || !ok2 {
		return errors.New("gacha: the bag cannot change an item in place")
	}
	return txn.For(inv).Run(ctx, func(ctx context.Context) error {
		slots, err := inv.List(ctx, cid)
		if err != nil {
			return err
		}
		have := 0
		for _, s := range slots {
			if s.Index == slot && s.ItemID == wantItem {
				have = s.Quantity
			}
		}
		if have < 1 {
			return inventory.ErrItemChanged
		}
		// A card is one item (MaxStack 1 on every 3/3/14/1 row, MEASURED);
		// retail rewrites the one instance, so a stack is refused rather
		// than split (OURS). A stack of coupons turns as a whole.
		if have > 1 && wantItem != newItem && n == 1 {
			return errors.New("gacha: a stack of more than one card")
		}
		if _, _, err := tk.TakeItem(ctx, cid, slot, have, wantItem); err != nil {
			return err
		}
		return pl.PlaceItemInstance(ctx, cid, slot, newItem, n, inst)
	})
}

// gachaItemByCode is GetItemByCode on an item lookup that has it.
func gachaItemByCode(ctx context.Context, items ItemLookup, code string) (*refdata.Item, error) {
	bc, ok := items.(interface {
		GetItemByCode(ctx context.Context, code string) (*refdata.Item, error)
	})
	if !ok {
		return nil, errors.New("gacha: the item table cannot look items up by code")
	}
	return bc.GetItemByCode(ctx, code)
}

func (d GachaDeps) log(msg string, args ...any) {
	if d.Logger != nil {
		d.Logger.Info(msg, args...)
	}
}
