package session

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"

	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/shop"
)

// Shop opcodes, our own protocol. Requires a prior OpLogin.
const (
	OpShopBuy       uint16 = 0x0050 // client -> server
	OpShopBuyResult uint16 = 0x0051 // server -> client
)

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

// ShopHandler returns a gateway.Handler implementing OpShopBuy against svc,
// resolving the character name against whichever account authenticated on
// the connection.
func ShopHandler(chars character.Store, svc *shop.Service) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		if p.Opcode != OpShopBuy {
			return nil
		}

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
}
