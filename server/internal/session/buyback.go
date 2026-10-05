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

// Buy back (round 728; the rules are shop/buyback.go's). OpenSRO's own
// messages, like the rest of its shop protocol (retail moves items with
// 0x7034 and its sub-kinds, which OpenSRO does not speak yet).
const (
	OpShopBuybackList       uint16 = 0x0118 // client -> server: my buy-back row
	OpShopBuybackListResult uint16 = 0x0119 // server -> client
	OpShopBuyback           uint16 = 0x011A // client -> server: buy entry N back
	OpShopBuybackResult     uint16 = 0x011B // server -> client
)

// ShopBuybackEntry is one row entry: what was sold, how many, and the gold one
// unit costs to buy back.
type ShopBuybackEntry struct {
	ItemID   int64
	Quantity int32
	Unit     int64
}

// ShopBuybackListResult is OpShopBuybackListResult's payload: an error, or the
// book newest first.
type ShopBuybackListResult struct {
	Error   string
	Entries []ShopBuybackEntry
}

func (r *ShopBuybackListResult) Encode() []byte {
	out := encodeStrings(r.Error)
	if r.Error != "" {
		return out
	}
	out = append(out, byte(len(r.Entries)))
	for _, e := range r.Entries {
		out = append(out, encodeInt64(e.ItemID)...)
		q := make([]byte, 4)
		binary.LittleEndian.PutUint32(q, uint32(e.Quantity))
		out = append(out, q...)
		out = append(out, encodeInt64(e.Unit)...)
	}
	return out
}

func DecodeShopBuybackListResult(data []byte) (*ShopBuybackListResult, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding ShopBuybackListResult: %w", err)
	}
	r := &ShopBuybackListResult{Error: fields[0]}
	if r.Error != "" {
		return r, nil
	}
	if len(rest) < 1 {
		return nil, errors.New("session: decoding ShopBuybackListResult: truncated count")
	}
	n := int(rest[0])
	rest = rest[1:]
	for i := 0; i < n; i++ {
		if len(rest) < 20 {
			return nil, fmt.Errorf("session: decoding ShopBuybackListResult: entry %d truncated", i)
		}
		var e ShopBuybackEntry
		e.ItemID, rest, _ = decodeInt64(rest)
		e.Quantity = int32(binary.LittleEndian.Uint32(rest[0:4]))
		rest = rest[4:]
		e.Unit, rest, _ = decodeInt64(rest)
		r.Entries = append(r.Entries, e)
	}
	return r, nil
}

// ShopBuybackRequest is OpShopBuyback's payload: buy entry Index back.
type ShopBuybackRequest struct {
	CharacterName string
	Index         int32
}

func (r *ShopBuybackRequest) Encode() []byte {
	out := encodeStrings(r.CharacterName)
	b := make([]byte, 4)
	binary.LittleEndian.PutUint32(b, uint32(r.Index))
	return append(out, b...)
}

func DecodeShopBuybackRequest(data []byte) (*ShopBuybackRequest, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding ShopBuybackRequest: %w", err)
	}
	if len(rest) < 4 {
		return nil, errors.New("session: decoding ShopBuybackRequest: truncated index")
	}
	return &ShopBuybackRequest{CharacterName: fields[0], Index: int32(binary.LittleEndian.Uint32(rest))}, nil
}

// ShopBuybackResult is OpShopBuybackResult's payload: the outcome and the gold
// paid.
type ShopBuybackResult struct {
	OK       bool
	Reason   string
	GoldPaid int64
}

func (r *ShopBuybackResult) Encode() []byte {
	return append(encodeOKReason(r.OK, r.Reason), encodeInt64(r.GoldPaid)...)
}

func DecodeShopBuybackResult(data []byte) (*ShopBuybackResult, error) {
	if len(data) < 1 {
		return nil, errors.New("session: decoding ShopBuybackResult: empty payload")
	}
	ok := data[0] != 0
	fields, rest, err := decodeStringsPrefix(data[1:], 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding ShopBuybackResult: %w", err)
	}
	r := &ShopBuybackResult{OK: ok, Reason: reason(fields)}
	if len(rest) >= 8 {
		r.GoldPaid, _, _ = decodeInt64(rest)
	}
	return r, nil
}

func buybackEntries(svc *shop.Service, characterID int64) []ShopBuybackEntry {
	book := svc.SoldList(characterID)
	out := make([]ShopBuybackEntry, len(book))
	for i, e := range book {
		out[i] = ShopBuybackEntry{ItemID: e.ItemID, Quantity: int32(e.Quantity), Unit: e.Unit}
	}
	return out
}

func handleShopBuybackList(ctx context.Context, sess *gateway.Session, p *proto.Packet, chars character.Store, svc *shop.Service) error {
	req, err := DecodeCharacterNameRequest(p.Data)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpShopBuybackListResult, Data: (&ShopBuybackListResult{Error: "malformed request"}).Encode()})
	}
	characterID, errStr := resolveCharacterID(ctx, sess, chars, req.Name)
	if errStr != "" {
		return sess.Send(&proto.Packet{Opcode: OpShopBuybackListResult, Data: (&ShopBuybackListResult{Error: errStr}).Encode()})
	}
	return sess.Send(&proto.Packet{Opcode: OpShopBuybackListResult, Data: (&ShopBuybackListResult{Entries: buybackEntries(svc, characterID)}).Encode()})
}

func handleShopBuyback(ctx context.Context, sess *gateway.Session, p *proto.Packet, chars character.Store, svc *shop.Service, trades *trade.Hub) error {
	req, err := DecodeShopBuybackRequest(p.Data)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpShopBuybackResult, Data: (&ShopBuybackResult{Reason: "malformed request"}).Encode()})
	}
	characterID, errStr := resolveCharacterID(ctx, sess, chars, req.CharacterName)
	if errStr != "" {
		return sess.Send(&proto.Packet{Opcode: OpShopBuybackResult, Data: (&ShopBuybackResult{Reason: errStr}).Encode()})
	}
	// 0x1c0b IM_BUSY while a trade holds the character (tradebusy.go).
	if trades.Busy(characterID) {
		return sess.Send(&proto.Packet{Opcode: OpShopBuybackResult, Data: (&ShopBuybackResult{Reason: tradeBusyReason}).Encode()})
	}
	paid, err := svc.Buyback(ctx, characterID, int(req.Index))
	if err != nil {
		result := &ShopBuybackResult{}
		switch {
		case errors.Is(err, shop.ErrNoSuchBuyback):
			result.Reason = "nothing to buy back there"
		case errors.Is(err, character.ErrInsufficientGold):
			result.Reason = "insufficient gold"
		default:
			result.Reason = "buy back failed"
		}
		return sess.Send(&proto.Packet{Opcode: OpShopBuybackResult, Data: result.Encode()})
	}
	return sess.Send(&proto.Packet{Opcode: OpShopBuybackResult, Data: (&ShopBuybackResult{OK: true, GoldPaid: paid}).Encode()})
}
