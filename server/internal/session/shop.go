package session

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"

	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/shop"
	"github.com/OpenSRO/OpenSRO/server/internal/trade"
)

// Shop opcodes, our own protocol. Requires a prior OpLogin.
const (
	OpShopBuy        uint16 = 0x0050 // client -> server
	OpShopBuyResult  uint16 = 0x0051 // server -> client
	OpShopList       uint16 = 0x0052 // client -> server
	OpShopListResult uint16 = 0x0053 // server -> client
	OpShopSell       uint16 = 0x0054 // client -> server
	OpShopSellResult uint16 = 0x0055 // server -> client
)

// ShopSellRequest is the OpShopSell payload: sell Quantity from inventory Slot.
type ShopSellRequest struct {
	CharacterName string
	Slot          int32
	Quantity      int32
}

func (r *ShopSellRequest) Encode() []byte {
	out := encodeStrings(r.CharacterName)
	buf := make([]byte, 8)
	binary.LittleEndian.PutUint32(buf[0:4], uint32(r.Slot))
	binary.LittleEndian.PutUint32(buf[4:8], uint32(r.Quantity))
	return append(out, buf...)
}

func DecodeShopSellRequest(data []byte) (*ShopSellRequest, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding ShopSellRequest: %w", err)
	}
	if len(rest) < 8 {
		return nil, errors.New("session: decoding ShopSellRequest: truncated slot/quantity")
	}
	return &ShopSellRequest{
		CharacterName: fields[0],
		Slot:          int32(binary.LittleEndian.Uint32(rest[0:4])),
		Quantity:      int32(binary.LittleEndian.Uint32(rest[4:8])),
	}, nil
}

// ShopSellResult is the OpShopSellResult payload: the outcome plus the gold
// actually credited (the server's own SellValue, so the client shows the true
// amount rather than its own estimate).
type ShopSellResult struct {
	OK           bool
	Reason       string
	GoldReceived int64
}

func (r *ShopSellResult) Encode() []byte {
	out := encodeOKReason(r.OK, r.Reason)
	return append(out, encodeInt64(r.GoldReceived)...)
}

func DecodeShopSellResult(data []byte) (*ShopSellResult, error) {
	if len(data) < 1 {
		return nil, errors.New("session: decoding ShopSellResult: empty payload")
	}
	ok := data[0] != 0
	fields, rest, err := decodeStringsPrefix(data[1:], 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding ShopSellResult: %w", err)
	}
	// The gold tail is optional so an OK/Reason-only payload still decodes.
	var gold int64
	if len(rest) >= 8 {
		gold, _, _ = decodeInt64(rest)
	}
	return &ShopSellResult{OK: ok, Reason: reason(fields), GoldReceived: gold}, nil
}

func reason(fields []string) string {
	if len(fields) > 0 {
		return fields[0]
	}
	return ""
}

// ShopBuyRequest is the OpShopBuy payload.
type ShopBuyRequest struct {
	CharacterName string
	ItemID        int64
	Quantity      int32
}

func (r *ShopBuyRequest) Encode() []byte {
	out := encodeStrings(r.CharacterName)
	out = append(out, encodeInt64(r.ItemID)...)
	qtyBuf := make([]byte, 4)
	binary.LittleEndian.PutUint32(qtyBuf, uint32(r.Quantity))
	return append(out, qtyBuf...)
}

func DecodeShopBuyRequest(data []byte) (*ShopBuyRequest, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding ShopBuyRequest: %w", err)
	}
	itemID, rest, err := decodeInt64(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding ShopBuyRequest: item id: %w", err)
	}
	if len(rest) < 4 {
		return nil, errors.New("session: decoding ShopBuyRequest: truncated quantity")
	}
	qty := int32(binary.LittleEndian.Uint32(rest))
	return &ShopBuyRequest{CharacterName: fields[0], ItemID: itemID, Quantity: qty}, nil
}

// ShopBuyResult is the OpShopBuyResult payload.
type ShopBuyResult struct {
	OK     bool
	Reason string
}

func (r *ShopBuyResult) Encode() []byte { return encodeOKReason(r.OK, r.Reason) }

func DecodeShopBuyResult(data []byte) (*ShopBuyResult, error) {
	ok, reason, err := decodeOKReason(data)
	if err != nil {
		return nil, fmt.Errorf("session: decoding ShopBuyResult: %w", err)
	}
	return &ShopBuyResult{OK: ok, Reason: reason}, nil
}

// ShopListRequest is the OpShopList payload: the item ids to price (the goods
// the NPC being talked to sells). Listing only these keeps the response small
// -- the full catalogue is ~12,000 items, far past a single frame.
type ShopListRequest struct {
	ItemIDs []int64
}

// shopListMaxIDs caps a list request so a client cannot ask the server to
// build an unbounded response.
const shopListMaxIDs = 500

func (r *ShopListRequest) Encode() []byte {
	out := make([]byte, 2)
	binary.LittleEndian.PutUint16(out, uint16(len(r.ItemIDs)))
	for _, id := range r.ItemIDs {
		out = append(out, encodeInt64(id)...)
	}
	return out
}

func DecodeShopListRequest(data []byte) (*ShopListRequest, error) {
	if len(data) < 2 {
		return &ShopListRequest{}, nil
	}
	count := int(binary.LittleEndian.Uint16(data))
	rest := data[2:]
	ids := make([]int64, 0, count)
	for i := 0; i < count; i++ {
		var id int64
		var err error
		id, rest, err = decodeInt64(rest)
		if err != nil {
			return nil, fmt.Errorf("session: decoding ShopListRequest: id %d: %w", i, err)
		}
		ids = append(ids, id)
	}
	return &ShopListRequest{ItemIDs: ids}, nil
}

// ShopCatalogEntry is one purchasable item, as sent over the wire.
type ShopCatalogEntry struct {
	ItemID         int64
	Price          int64
	ItemClass      int32
	PhysAttackMax  float32
	PhysDefenseMax float32
}

func (e *ShopCatalogEntry) Encode() []byte {
	out := append(encodeInt64(e.ItemID), encodeInt64(e.Price)...)
	buf := make([]byte, 4)
	binary.LittleEndian.PutUint32(buf, uint32(e.ItemClass))
	out = append(out, buf...)
	out = append(out, encodeFloat32(e.PhysAttackMax)...)
	out = append(out, encodeFloat32(e.PhysDefenseMax)...)
	return out
}

func decodeShopCatalogEntry(data []byte) (*ShopCatalogEntry, []byte, error) {
	itemID, rest, err := decodeInt64(data)
	if err != nil {
		return nil, nil, fmt.Errorf("item id: %w", err)
	}
	price, rest, err := decodeInt64(rest)
	if err != nil {
		return nil, nil, fmt.Errorf("price: %w", err)
	}
	if len(rest) < 4 {
		return nil, nil, errors.New("truncated item class")
	}
	itemClass := int32(binary.LittleEndian.Uint32(rest))
	rest = rest[4:]
	physAttack, rest, err := decodeFloat32(rest)
	if err != nil {
		return nil, nil, fmt.Errorf("phys attack: %w", err)
	}
	physDefense, rest, err := decodeFloat32(rest)
	if err != nil {
		return nil, nil, fmt.Errorf("phys defense: %w", err)
	}
	return &ShopCatalogEntry{
		ItemID: itemID, Price: price, ItemClass: itemClass,
		PhysAttackMax: physAttack, PhysDefenseMax: physDefense,
	}, rest, nil
}

// ShopListResult is the OpShopListResult payload.
type ShopListResult struct {
	Error   string
	Entries []ShopCatalogEntry
}

func (r *ShopListResult) Encode() []byte {
	out := encodeStrings(r.Error)
	if r.Error != "" {
		return out
	}
	countBuf := make([]byte, 2)
	binary.LittleEndian.PutUint16(countBuf, uint16(len(r.Entries)))
	out = append(out, countBuf...)
	for _, e := range r.Entries {
		out = append(out, e.Encode()...)
	}
	return out
}

func DecodeShopListResult(data []byte) (*ShopListResult, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding ShopListResult: %w", err)
	}
	r := &ShopListResult{Error: fields[0]}
	if r.Error != "" {
		return r, nil
	}

	if len(rest) < 2 {
		return nil, errors.New("session: decoding ShopListResult: truncated entry count")
	}
	count := int(binary.LittleEndian.Uint16(rest))
	rest = rest[2:]
	for i := 0; i < count; i++ {
		var entry *ShopCatalogEntry
		entry, rest, err = decodeShopCatalogEntry(rest)
		if err != nil {
			return nil, fmt.Errorf("session: decoding ShopListResult: entry %d: %w", i, err)
		}
		r.Entries = append(r.Entries, *entry)
	}
	return r, nil
}

// ShopHandler returns a gateway.Handler implementing OpShopBuy/OpShopList
// against svc, resolving the character name against whichever account
// authenticated on the connection. A buy or sell by a character trades holds
// is refused as busy (tradebusy.go); trades may be nil.
func ShopHandler(chars character.Store, svc *shop.Service, trades *trade.Hub) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		switch p.Opcode {
		case OpShopBuy:
			return handleShopBuy(ctx, sess, p, chars, svc, trades)
		case OpShopList:
			return handleShopList(ctx, sess, p, svc)
		case OpShopSell:
			return handleShopSell(ctx, sess, p, chars, svc, trades)
		default:
			return nil
		}
	}
}

func handleShopBuy(ctx context.Context, sess *gateway.Session, p *proto.Packet, chars character.Store, svc *shop.Service, trades *trade.Hub) error {
	req, err := DecodeShopBuyRequest(p.Data)
	if err != nil {
		return sess.Send(&proto.Packet{
			Opcode: OpShopBuyResult,
			Data:   (&ShopBuyResult{Reason: "malformed request"}).Encode(),
		})
	}

	characterID, errStr := resolveCharacterID(ctx, sess, chars, req.CharacterName)
	if errStr != "" {
		return sess.Send(&proto.Packet{Opcode: OpShopBuyResult, Data: (&ShopBuyResult{Reason: errStr}).Encode()})
	}
	// 0x1c0b IM_BUSY while a trade holds the character (tradebusy.go).
	if trades.Busy(characterID) {
		return sess.Send(&proto.Packet{Opcode: OpShopBuyResult, Data: (&ShopBuyResult{Reason: tradeBusyReason}).Encode()})
	}

	if req.Quantity <= 0 {
		return sess.Send(&proto.Packet{
			Opcode: OpShopBuyResult,
			Data:   (&ShopBuyResult{Reason: "quantity must be positive"}).Encode(),
		})
	}

	result := &ShopBuyResult{OK: true}
	if err := svc.Buy(ctx, characterID, req.ItemID, int(req.Quantity)); err != nil {
		result.OK = false
		switch {
		case errors.Is(err, shop.ErrItemNotFound):
			result.Reason = "no such item"
		case errors.Is(err, character.ErrInsufficientGold):
			result.Reason = "insufficient gold"
		default:
			result.Reason = "purchase failed"
		}
	}
	return sess.Send(&proto.Packet{Opcode: OpShopBuyResult, Data: result.Encode()})
}

func handleShopSell(ctx context.Context, sess *gateway.Session, p *proto.Packet, chars character.Store, svc *shop.Service, trades *trade.Hub) error {
	req, err := DecodeShopSellRequest(p.Data)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpShopSellResult, Data: (&ShopSellResult{Reason: "malformed request"}).Encode()})
	}
	characterID, errStr := resolveCharacterID(ctx, sess, chars, req.CharacterName)
	if errStr != "" {
		return sess.Send(&proto.Packet{Opcode: OpShopSellResult, Data: (&ShopSellResult{Reason: errStr}).Encode()})
	}
	// 0x1c0b IM_BUSY while a trade holds the character (tradebusy.go).
	if trades.Busy(characterID) {
		return sess.Send(&proto.Packet{Opcode: OpShopSellResult, Data: (&ShopSellResult{Reason: tradeBusyReason}).Encode()})
	}

	gold, err := svc.Sell(ctx, characterID, int(req.Slot), int(req.Quantity))
	if err != nil {
		result := &ShopSellResult{}
		switch {
		case errors.Is(err, shop.ErrSlotEmpty):
			result.Reason = "nothing to sell there"
		case errors.Is(err, shop.ErrNothingToSell):
			result.Reason = "quantity must be positive"
		case errors.Is(err, shop.ErrItemNotFound):
			result.Reason = "cannot sell that item"
		default:
			result.Reason = "sale failed"
		}
		return sess.Send(&proto.Packet{Opcode: OpShopSellResult, Data: result.Encode()})
	}
	return sess.Send(&proto.Packet{Opcode: OpShopSellResult, Data: (&ShopSellResult{OK: true, GoldReceived: gold}).Encode()})
}

func handleShopList(ctx context.Context, sess *gateway.Session, p *proto.Packet, svc *shop.Service) error {
	req, err := DecodeShopListRequest(p.Data)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpShopListResult, Data: (&ShopListResult{Error: "malformed request"}).Encode()})
	}
	ids := req.ItemIDs
	if len(ids) > shopListMaxIDs {
		ids = ids[:shopListMaxIDs]
	}
	catalog, err := svc.CatalogFor(ctx, ids)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpShopListResult, Data: (&ShopListResult{Error: "failed to load catalog"}).Encode()})
	}
	entries := make([]ShopCatalogEntry, len(catalog))
	for i, c := range catalog {
		entries[i] = ShopCatalogEntry{
			ItemID: c.ItemID, Price: c.Price, ItemClass: int32(c.ItemClass),
			PhysAttackMax: float32(c.PhysAttackMax), PhysDefenseMax: float32(c.PhysDefenseMax),
		}
	}
	return sess.Send(&proto.Packet{Opcode: OpShopListResult, Data: (&ShopListResult{Entries: entries}).Encode()})
}
