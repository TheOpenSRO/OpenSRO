package session

import (
	"context"
	"encoding/binary"
	"errors"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/mall"
	"github.com/TheOpenSRO/OpenSRO/server/internal/npctalk"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/shop"
	"github.com/TheOpenSRO/OpenSRO/server/internal/storage"
	"github.com/TheOpenSRO/OpenSRO/server/internal/trade"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// The retail item operation (round 728, after its review): 0x7034 / 0xB034
// for the four moves this round put on the retail wire, and 0x7168 / 0xB168
// for the buy back. READ: the client's serializer c:0x7923a0 and record parser
// c:0x87eb50, the GameServer's handlers (docs/rounds/r728_review.md, "The
// retail layouts"). Bag slots on the wire are the bag index + 13.
//
//	0x7034 type 0 (bag -> bag, the split): u8 src, u8 dst, u16 count
//	0x7034 type 9 (sell):                  u8 src, u16 count, u32 NPC uid
//	0x7034 type 2 (deposit):               u8 src, u8 dst (warehouse), u32 NPC uid
//	0x7034 type 0x24 (bag -> avatar):      u8 src (bag), u8 dst (avatar slot 0..4)   round 789, avatar.go
//	0x7034 type 0x23 (avatar -> bag):      u8 src (avatar slot), u8 dst (bag, discarded)
//	0x7168 (buy back):                     u32 NPC uid, u8 index (0 = oldest)
//
//	0xB034 success: u8 1, u8 type, then the record:
//	  type 0:    u8 src, u8 dst, u16 count, u8 n (0 here) [n x u8,u8,u8,u16]
//	  type 9:    u8 src, u16 count, u32 NPC uid, u8 book size (1..5) or 0xFF
//	  type 2:    u8 src, u8 dst
//	  type 0x22: u8 dst, u8 index, u16 count (the buy back's success)
//	0xB034 failure: u8 2, u16 code
//	0xB168 (buy back failure only): u8 2, u16 code
//
// Round 837: type 0x18 is the item mall's buy (mall.go, internal/mall).
//
// OpenSRO's other item moves (bag -> bag without a count, buy, withdraw, the
// gold) stay on OpenSRO's own messages for now; any other 0x7034 type is
// refused 0x1811 (OURS: retail's StorageOperation refuses a type-0x22 request
// with 0x1811, gs:0x50f5c0).
//
// The NPC uid is read and not checked: retail requires a live NPC
// interaction (gs:0x511860 HasAvailableInteraction, answering 3), which needs
// round 727's NPC state, not on this branch (OPEN).
const (
	OpItemMove        uint16 = 0x7034
	OpItemMoveResult  uint16 = 0xB034
	OpItemBuyback     uint16 = 0x7168
	OpItemBuybackFail uint16 = 0xB168
	ItemMoveBagToBag  byte   = 0
	ItemMoveDeposit   byte   = 2
	ItemMoveSell      byte   = 9
	ItemMoveBuyback   byte   = 0x22
	ItemWireBagOffset        = 13
	itemOpOK          byte   = 1
	itemOpFail        byte   = 2
)

// The refusal codes (READ unless marked, r728_review.md).
const (
	ItemErrNotEnoughGold uint16 = 0x180f // UIIT_MSG_STRGERR_NOT_ENOUGH_GOLD
	ItemErrBagFull       uint16 = 0x1807 // UIIT_MSG_STRGERR_INVENTORY_FULL
	ItemErrEmptySource   uint16 = 0x1809
	ItemErrPastStack     uint16 = 0x1814 // a split count above the stack
	ItemErrCountBelowOne uint16 = 0x1829
	ItemErrDB            uint16 = 0x1811
	ItemErrCreate        uint16 = 0x1842
	ItemErrNoSuchEntry   uint16 = 0x18d3 // UIIT_MSG_ERROR_RE_BUY_OBJECT_CANT
	ItemErrCannotSell    uint16 = 0x183b // UIIT_MSG_STRGERR_CANNOT_DEAL_AT_SHOP
	ItemErrBusy          uint16 = 0x1c0b // IM_BUSY (tradebusy.go)
)

// ItemMoveRequest is a decoded 0x7034 of one of the types above. Bag slots
// are bag indexes (the +13 removed).
type ItemMoveRequest struct {
	Type  byte
	Src   int
	Dst   int
	Count int
	NPC   uint32
}

// ErrItemMoveShort is a truncated 0x7034 body.
var ErrItemMoveShort = errors.New("session: truncated item move")

// DecodeItemMove reads a 0x7034 body.
func DecodeItemMove(b []byte) (*ItemMoveRequest, error) {
	if len(b) < 1 {
		return nil, ErrItemMoveShort
	}
	r := &ItemMoveRequest{Type: b[0]}
	b = b[1:]
	switch r.Type {
	case ItemMoveBagToBag:
		if len(b) < 4 {
			return nil, ErrItemMoveShort
		}
		r.Src, r.Dst, r.Count = int(b[0])-ItemWireBagOffset, int(b[1])-ItemWireBagOffset, int(binary.LittleEndian.Uint16(b[2:]))
	case ItemMoveSell:
		if len(b) < 7 {
			return nil, ErrItemMoveShort
		}
		r.Src, r.Count, r.NPC = int(b[0])-ItemWireBagOffset, int(binary.LittleEndian.Uint16(b[1:])), binary.LittleEndian.Uint32(b[3:])
	case ItemMoveDeposit:
		if len(b) < 6 {
			return nil, ErrItemMoveShort
		}
		r.Src, r.Dst, r.NPC = int(b[0])-ItemWireBagOffset, int(b[1]), binary.LittleEndian.Uint32(b[2:])
	}
	return r, nil
}

// EncodeItemFail is a failure: u8 2, u16 code (0xB034 and 0xB168 alike).
func EncodeItemFail(code uint16) []byte {
	return binary.LittleEndian.AppendUint16([]byte{itemOpFail}, code)
}

// EncodeSplitResult is 0xB034 type 0's success.
func EncodeSplitResult(src, dst, count int) []byte {
	out := []byte{itemOpOK, ItemMoveBagToBag, byte(src + ItemWireBagOffset), byte(dst + ItemWireBagOffset)}
	out = binary.LittleEndian.AppendUint16(out, uint16(count))
	return append(out, 0)
}

// EncodeSellResult is 0xB034 type 9's success, the book byte last.
func EncodeSellResult(src, count int, npc uint32, book byte) []byte {
	out := []byte{itemOpOK, ItemMoveSell, byte(src + ItemWireBagOffset)}
	out = binary.LittleEndian.AppendUint16(out, uint16(count))
	out = binary.LittleEndian.AppendUint32(out, npc)
	return append(out, book)
}

// EncodeDepositResult is 0xB034 type 2's success.
func EncodeDepositResult(src, dst int) []byte {
	return []byte{itemOpOK, ItemMoveDeposit, byte(src + ItemWireBagOffset), byte(dst)}
}

// EncodeBuybackResult is the buy back's success, 0xB034 type 0x22.
func EncodeBuybackResult(dst, index, count int) []byte {
	out := []byte{itemOpOK, ItemMoveBuyback, byte(dst + ItemWireBagOffset), byte(index)}
	return binary.LittleEndian.AppendUint16(out, uint16(count))
}

// ItemOpDeps is what the retail item operation needs.
type ItemOpDeps struct {
	Hub     *world.Hub
	Inv     inventory.Store
	Shop    *shop.Service
	Storage *storage.Service
	Trades  *trade.Hub
	// Round 789: the avatar moves (types 0x23 and 0x24, avatar.go) need the
	// avatar inventory (nil: SetAvatarStore's), the item table and the
	// characters (for CanBeEquipedAt's gender, level and stats).
	Avatars inventory.Store
	Items   ItemLookup
	Chars   character.Store
}

// avatarDeps is d as the avatar moves take it.
func (d ItemOpDeps) avatarDeps() AvatarDeps {
	av, items := d.Avatars, d.Items
	if reg := avatarRegistryOf(); reg != nil {
		if av == nil {
			av = reg.store
		}
		if items == nil {
			items = reg.items
		}
	}
	return AvatarDeps{Chars: d.Chars, Inv: d.Inv, Avatars: av, Items: items, Hub: d.Hub, Trades: d.Trades}
}

// ItemOpHandler returns the gateway.Handler for 0x7034 and 0x7168.
func ItemOpHandler(d ItemOpDeps) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		switch p.Opcode {
		case OpItemMove:
			return handleItemMove(ctx, sess, p.Data, d)
		case OpItemBuyback:
			return handleItemBuyback(ctx, sess, p.Data, d)
		}
		return nil
	}
}

func (d ItemOpDeps) character(sess *gateway.Session) (int64, bool) {
	if d.Hub == nil {
		return 0, false
	}
	e, ok := d.Hub.EntityBySession(sess.ID())
	if !ok {
		return 0, false
	}
	return e.CharacterID, true
}

func handleItemMove(ctx context.Context, sess *gateway.Session, data []byte, d ItemOpDeps) error {
	fail := func(code uint16) error {
		return sess.Send(&proto.Packet{Opcode: OpItemMoveResult, Data: EncodeItemFail(code)})
	}
	// Round 834: the exchange's own ops (exchange.go), the only ones
	// StorageOperation lets through at INTERACTMODE 2; every other op then
	// answers 0x1834 (s:0x50f7cd..0x50f7e3) -- the pet bag's and the
	// avatar's included. A pending request keeps the NPC-service refusal
	// below (tradebusy.go).
	if len(data) > 0 && isExchangeMove(data[0]) {
		if x := exchangeRT.Load(); x != nil {
			exchangeMove(ctx, sess, data, x)
			return nil
		}
		return fail(ItemErrDB)
	}
	if cid, ok := d.character(sess); ok && d.Trades.Established(cid) {
		return fail(ExchangeErrBlocked)
	}
	// Round 837: the item mall's buy (mall.go). StorageOperation lets op
	// 0x18 through at INTERACTMODE 1 (a pending request), so it is routed
	// before the busy test below.
	if len(data) > 0 && data[0] == mall.BuyType {
		return mallBuy(ctx, sess, data)
	}
	// The avatar moves (round 789) have StorageOperation's own framing:
	// dead 2 and INTERACTMODE 0x1834 before the type's rules (avatar.go).
	if len(data) > 0 && (data[0] == ItemMoveAvatarToBag || data[0] == ItemMoveBagToAvatar) {
		return handleAvatarMove(ctx, sess, data, d.avatarDeps())
	}
	// Round 795: the ability pet's bag (cosbag.go).
	if len(data) > 0 && isCOSBagMove(data[0]) {
		cid, ok := d.character(sess)
		if !ok {
			return fail(ItemErrDB)
		}
		return handleCOSBagMove(ctx, sess, cid, data, d.Inv)
	}
	// Round 801: the transport's specialty buy and sale
	// (specialtytrade.go).
	if len(data) > 0 && (data[0] == ItemMoveBuyToCOS || data[0] == ItemMoveSellFromCOS) {
		if cid, ok := d.character(sess); !ok || d.Trades.Busy(cid) {
			return fail(ItemErrBusy)
		}
		if data[0] == ItemMoveBuyToCOS {
			return handleBuyToCOS(ctx, sess, data, d)
		}
		return handleSellFromCOS(ctx, sess, data, d)
	}
	req, err := DecodeItemMove(data)
	if err != nil {
		return fail(ItemErrDB)
	}
	cid, ok := d.character(sess)
	if !ok {
		return fail(ItemErrDB)
	}
	if d.Trades.Busy(cid) {
		return fail(ItemErrBusy)
	}
	switch req.Type {
	case ItemMoveBagToBag:
		return itemSplit(ctx, sess, req, cid, d, fail)
	case ItemMoveSell:
		if d.Shop == nil {
			return fail(ItemErrDB)
		}
		if cosItemOut(ctx, cid, req.Src) {
			return fail(cosErrSellOut)
		}
		// A specialty NPC buys nothing but goods (GObjPC::FUN_00617f70: an
		// item that is not a good at an NPC with id 0xc, 0x1845; round 801).
		// Goods never sit in the bag (the bag's CanStoreThisItem refuses
		// them), so the bag's sale never offers one.
		if e, ok := d.Hub.EntityBySession(sess.ID()); ok {
			if pl, code := npcTarget(e, req.NPC); code == 0 && npcHas(pl.npc.Interact, npctalk.IDSpecial) {
				return fail(tradeErrDealerNoTreat)
			}
		}
		_, book, err := d.Shop.SellBooked(ctx, cid, req.Src, req.Count)
		switch {
		case err == nil:
			return sess.Send(&proto.Packet{Opcode: OpItemMoveResult, Data: EncodeSellResult(req.Src, req.Count, req.NPC, book)})
		case errors.Is(err, shop.ErrSlotEmpty):
			return fail(ItemErrEmptySource) // OURS: the empty-source code of the bag move
		case errors.Is(err, shop.ErrCannotSell):
			return fail(ItemErrCannotSell)
		case errors.Is(err, shop.ErrNothingToSell):
			return fail(ItemErrCountBelowOne) // OURS, as the bag move's
		default:
			return fail(ItemErrDB) // OURS
		}
	case ItemMoveDeposit:
		if cosItemOut(ctx, cid, req.Src) {
			return fail(cosErrStoreOut)
		}
		if d.Storage == nil {
			return fail(ItemErrDB)
		}
		err := d.Storage.DepositStack(ctx, cid, req.Src, req.Dst)
		switch {
		case err == nil:
			return sess.Send(&proto.Packet{Opcode: OpItemMoveResult, Data: EncodeDepositResult(req.Src, req.Dst)})
		case errors.Is(err, character.ErrInsufficientGold):
			return fail(ItemErrNotEnoughGold)
		case errors.Is(err, storage.ErrSlotEmpty):
			return fail(ItemErrEmptySource)
		default:
			return fail(ItemErrDB) // OURS: retail's 3, 5 and 0x1843 are not mapped
		}
	}
	return fail(ItemErrDB)
}

// itemSplit is gs:0x4b2450's bag -> bag (READ): a count below 1 0x1829; an
// empty source 0x1809; into an empty slot the whole stack moves, a count
// above the stack 0x1814, a smaller count splits; onto an occupied slot it
// merges or swaps (inventory.MoveItem).
func itemSplit(ctx context.Context, sess *gateway.Session, req *ItemMoveRequest, cid int64, d ItemOpDeps, fail func(uint16) error) error {
	if req.Count < 1 {
		return fail(ItemErrCountBelowOne)
	}
	slots, err := d.Inv.List(ctx, cid)
	if err != nil {
		return fail(ItemErrDB)
	}
	var stack, dstHeld int
	for _, s := range slots {
		if s.Index == req.Src {
			stack = s.Quantity
		}
		if s.Index == req.Dst {
			dstHeld = s.Quantity
		}
	}
	if stack <= 0 {
		return fail(ItemErrEmptySource)
	}
	switch {
	case dstHeld > 0 || req.Count == stack:
		err = d.Inv.MoveItem(ctx, cid, req.Src, req.Dst)
	case req.Count > stack:
		return fail(ItemErrPastStack)
	default:
		sp, ok := d.Inv.(inventory.Splitter)
		if !ok {
			return fail(ItemErrDB)
		}
		err = sp.SplitItem(ctx, cid, req.Src, req.Dst, req.Count)
	}
	if err != nil {
		return fail(ItemErrDB) // OURS: the store's own refusals (a bad slot) have no read code
	}
	return sess.Send(&proto.Packet{Opcode: OpItemMoveResult, Data: EncodeSplitResult(req.Src, req.Dst, req.Count)})
}

// handleItemBuyback is gs:0x5118a0 -> GObjPC 0x42aae0: success is an 0xB034
// type 0x22 record, failure only an 0xB168 {2, code}.
func handleItemBuyback(ctx context.Context, sess *gateway.Session, data []byte, d ItemOpDeps) error {
	fail := func(code uint16) error {
		return sess.Send(&proto.Packet{Opcode: OpItemBuybackFail, Data: EncodeItemFail(code)})
	}
	if len(data) < 5 || d.Shop == nil {
		return fail(ItemErrDB)
	}
	index := int(data[4])
	cid, ok := d.character(sess)
	if !ok {
		return fail(ItemErrDB)
	}
	if d.Trades.Busy(cid) {
		return fail(ItemErrBusy)
	}
	got, err := d.Shop.Buyback(ctx, cid, index)
	switch {
	case err == nil:
		return sess.Send(&proto.Packet{Opcode: OpItemMoveResult, Data: EncodeBuybackResult(got.Slot, index, got.Quantity)})
	case errors.Is(err, shop.ErrNoSuchBuyback):
		return fail(ItemErrNoSuchEntry)
	case errors.Is(err, shop.ErrBagFull):
		return fail(ItemErrBagFull)
	case errors.Is(err, character.ErrInsufficientGold):
		return fail(ItemErrNotEnoughGold)
	case errors.Is(err, shop.ErrBuybackCreate):
		return fail(ItemErrCreate)
	default:
		return fail(ItemErrDB)
	}
}
