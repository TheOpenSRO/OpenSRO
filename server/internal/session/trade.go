package session

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"

	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/inventory"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/refdata"
	"github.com/OpenSRO/srrevamp/server/internal/trade"
	"github.com/OpenSRO/srrevamp/server/internal/world"
)

// Trade opcodes, our own protocol. All require a prior successful
// OpEnterWorld (target resolution reuses world.Hub.FindByName, same as
// chat/duel). No two-store transaction spans character.Store and
// inventory.Store, so execution uses careful ordering plus best-effort
// compensation on failure rather than true atomicity -- see
// executeTrade's comments for the one narrow gap that leaves (recipient
// inventory full at the last step).
const (
	OpTradeRequest       uint16 = 0x00D0 // client -> server
	OpTradeRequestResult uint16 = 0x00D1 // server -> client, ack to the requester
	OpTradeInvite        uint16 = 0x00D2 // server -> client, direct to the target
	OpTradeRespond       uint16 = 0x00D3 // client -> server
	OpTradeRespondResult uint16 = 0x00D4 // server -> client, ack to the responder
	OpTradeStarted       uint16 = 0x00D5 // server -> client, direct to both sides
	OpTradeDeclined      uint16 = 0x00D6 // server -> client, direct to the requester
	OpTradeSetOffer      uint16 = 0x00D7 // client -> server
	OpTradeOfferResult   uint16 = 0x00D8 // server -> client, ack to the offering side
	OpTradeOfferUpdated  uint16 = 0x00D9 // server -> client, direct to the other side
	OpTradeConfirm       uint16 = 0x00DA // client -> server
	OpTradeConfirmResult uint16 = 0x00DB // server -> client, ack
	OpTradeCompleted     uint16 = 0x00DC // server -> client, direct to both sides (what THEY received)
	OpTradeCancel        uint16 = 0x00DD // client -> server
	OpTradeCancelled     uint16 = 0x00DE // server -> client, direct to both sides
)

// TradeRequestRequest is the OpTradeRequest payload.
type TradeRequestRequest struct {
	CharacterName string
	TargetName    string
}

func (r *TradeRequestRequest) Encode() []byte { return encodeStrings(r.CharacterName, r.TargetName) }

func DecodeTradeRequestRequest(data []byte) (*TradeRequestRequest, error) {
	fields, err := decodeStrings(data, 2)
	if err != nil {
		return nil, fmt.Errorf("session: decoding TradeRequestRequest: %w", err)
	}
	return &TradeRequestRequest{CharacterName: fields[0], TargetName: fields[1]}, nil
}

// TradeRequestResult is the OpTradeRequestResult payload.
type TradeRequestResult struct {
	OK     bool
	Reason string
}

func (r *TradeRequestResult) Encode() []byte { return encodeOKReason(r.OK, r.Reason) }

func DecodeTradeRequestResult(data []byte) (*TradeRequestResult, error) {
	ok, reason, err := decodeOKReason(data)
	if err != nil {
		return nil, fmt.Errorf("session: decoding TradeRequestResult: %w", err)
	}
	return &TradeRequestResult{OK: ok, Reason: reason}, nil
}

// TradeInvite is the OpTradeInvite payload.
type TradeInvite struct {
	RequesterName string
}

func (r *TradeInvite) Encode() []byte { return encodeStrings(r.RequesterName) }

func DecodeTradeInvite(data []byte) (*TradeInvite, error) {
	fields, err := decodeStrings(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding TradeInvite: %w", err)
	}
	return &TradeInvite{RequesterName: fields[0]}, nil
}

// TradeRespondRequest is the OpTradeRespond payload.
type TradeRespondRequest struct {
	CharacterName string
	RequesterName string
	Accept        bool
}

func (r *TradeRespondRequest) Encode() []byte {
	out := encodeStrings(r.CharacterName, r.RequesterName)
	if r.Accept {
		return append(out, 1)
	}
	return append(out, 0)
}

func DecodeTradeRespondRequest(data []byte) (*TradeRespondRequest, error) {
	fields, rest, err := decodeStringsPrefix(data, 2)
	if err != nil {
		return nil, fmt.Errorf("session: decoding TradeRespondRequest: %w", err)
	}
	if len(rest) < 1 {
		return nil, errors.New("session: decoding TradeRespondRequest: truncated accept flag")
	}
	return &TradeRespondRequest{CharacterName: fields[0], RequesterName: fields[1], Accept: rest[0] != 0}, nil
}

// TradeRespondResult is the OpTradeRespondResult payload.
type TradeRespondResult struct {
	OK     bool
	Reason string
}

func (r *TradeRespondResult) Encode() []byte { return encodeOKReason(r.OK, r.Reason) }

func DecodeTradeRespondResult(data []byte) (*TradeRespondResult, error) {
	ok, reason, err := decodeOKReason(data)
	if err != nil {
		return nil, fmt.Errorf("session: decoding TradeRespondResult: %w", err)
	}
	return &TradeRespondResult{OK: ok, Reason: reason}, nil
}

// TradeStarted is the OpTradeStarted payload.
type TradeStarted struct {
	PartnerName string
}

func (r *TradeStarted) Encode() []byte { return encodeStrings(r.PartnerName) }

func DecodeTradeStarted(data []byte) (*TradeStarted, error) {
	fields, err := decodeStrings(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding TradeStarted: %w", err)
	}
	return &TradeStarted{PartnerName: fields[0]}, nil
}

// TradeDeclined is the OpTradeDeclined payload.
type TradeDeclined struct {
	TargetName string
}

func (r *TradeDeclined) Encode() []byte { return encodeStrings(r.TargetName) }

func DecodeTradeDeclined(data []byte) (*TradeDeclined, error) {
	fields, err := decodeStrings(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding TradeDeclined: %w", err)
	}
	return &TradeDeclined{TargetName: fields[0]}, nil
}

// TradeOffer is the wire shape of trade.Offer, shared by OpTradeSetOffer
// (request) and OpTradeOfferUpdated (notification).
type TradeOffer struct {
	Gold     int64
	ItemSlot int32
	Quantity int32
}

func (o *TradeOffer) encodeFields() []byte {
	out := encodeInt64(o.Gold)
	buf := make([]byte, 8)
	binary.LittleEndian.PutUint32(buf[0:4], uint32(o.ItemSlot))
	binary.LittleEndian.PutUint32(buf[4:8], uint32(o.Quantity))
	return append(out, buf...)
}

func decodeOfferFields(data []byte) (*TradeOffer, error) {
	if len(data) < 16 {
		return nil, errors.New("truncated offer")
	}
	gold, rest, err := decodeInt64(data)
	if err != nil {
		return nil, err
	}
	return &TradeOffer{
		Gold:     gold,
		ItemSlot: int32(binary.LittleEndian.Uint32(rest[0:4])),
		Quantity: int32(binary.LittleEndian.Uint32(rest[4:8])),
	}, nil
}

// TradeSetOfferRequest is the OpTradeSetOffer payload.
type TradeSetOfferRequest struct {
	CharacterName string
	Offer         TradeOffer
}

func (r *TradeSetOfferRequest) Encode() []byte {
	return append(encodeStrings(r.CharacterName), r.Offer.encodeFields()...)
}

func DecodeTradeSetOfferRequest(data []byte) (*TradeSetOfferRequest, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding TradeSetOfferRequest: %w", err)
	}
	offer, err := decodeOfferFields(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding TradeSetOfferRequest: offer: %w", err)
	}
	return &TradeSetOfferRequest{CharacterName: fields[0], Offer: *offer}, nil
}

// TradeOfferResult is the OpTradeOfferResult payload.
type TradeOfferResult struct {
	OK     bool
	Reason string
}

func (r *TradeOfferResult) Encode() []byte { return encodeOKReason(r.OK, r.Reason) }

func DecodeTradeOfferResult(data []byte) (*TradeOfferResult, error) {
	ok, reason, err := decodeOKReason(data)
	if err != nil {
		return nil, fmt.Errorf("session: decoding TradeOfferResult: %w", err)
	}
	return &TradeOfferResult{OK: ok, Reason: reason}, nil
}

// TradeOfferUpdated is the OpTradeOfferUpdated payload.
type TradeOfferUpdated struct {
	Offer TradeOffer
}

func (r *TradeOfferUpdated) Encode() []byte { return r.Offer.encodeFields() }

func DecodeTradeOfferUpdated(data []byte) (*TradeOfferUpdated, error) {
	offer, err := decodeOfferFields(data)
	if err != nil {
		return nil, fmt.Errorf("session: decoding TradeOfferUpdated: %w", err)
	}
	return &TradeOfferUpdated{Offer: *offer}, nil
}

// TradeConfirmRequest is the OpTradeConfirm payload.
type TradeConfirmRequest struct {
	CharacterName string
}

func (r *TradeConfirmRequest) Encode() []byte { return encodeStrings(r.CharacterName) }

func DecodeTradeConfirmRequest(data []byte) (*TradeConfirmRequest, error) {
	fields, err := decodeStrings(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding TradeConfirmRequest: %w", err)
	}
	return &TradeConfirmRequest{CharacterName: fields[0]}, nil
}

// TradeConfirmResult is the OpTradeConfirmResult payload.
type TradeConfirmResult struct {
	OK     bool
	Reason string
}

func (r *TradeConfirmResult) Encode() []byte { return encodeOKReason(r.OK, r.Reason) }

func DecodeTradeConfirmResult(data []byte) (*TradeConfirmResult, error) {
	ok, reason, err := decodeOKReason(data)
	if err != nil {
		return nil, fmt.Errorf("session: decoding TradeConfirmResult: %w", err)
	}
	return &TradeConfirmResult{OK: ok, Reason: reason}, nil
}

// TradeCompleted is the OpTradeCompleted payload: what THIS character
// received (i.e. the counterparty's offer), sent separately to each side.
// ReceivedItemID is 0 if no item was part of the received offer.
type TradeCompleted struct {
	ReceivedGold     int64
	ReceivedItemID   int64
	ReceivedQuantity int32
}

func (r *TradeCompleted) Encode() []byte {
	out := encodeInt64(r.ReceivedGold)
	out = append(out, encodeInt64(r.ReceivedItemID)...)
	buf := make([]byte, 4)
	binary.LittleEndian.PutUint32(buf, uint32(r.ReceivedQuantity))
	return append(out, buf...)
}

func DecodeTradeCompleted(data []byte) (*TradeCompleted, error) {
	gold, rest, err := decodeInt64(data)
	if err != nil {
		return nil, fmt.Errorf("session: decoding TradeCompleted: gold: %w", err)
	}
	itemID, rest, err := decodeInt64(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding TradeCompleted: item id: %w", err)
	}
	if len(rest) < 4 {
		return nil, errors.New("session: decoding TradeCompleted: truncated quantity")
	}
	return &TradeCompleted{
		ReceivedGold:     gold,
		ReceivedItemID:   itemID,
		ReceivedQuantity: int32(binary.LittleEndian.Uint32(rest)),
	}, nil
}

// TradeCancelRequest is the OpTradeCancel payload.
type TradeCancelRequest struct {
	CharacterName string
}

func (r *TradeCancelRequest) Encode() []byte { return encodeStrings(r.CharacterName) }

func DecodeTradeCancelRequest(data []byte) (*TradeCancelRequest, error) {
	fields, err := decodeStrings(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding TradeCancelRequest: %w", err)
	}
	return &TradeCancelRequest{CharacterName: fields[0]}, nil
}

// TradeCancelled is the OpTradeCancelled payload.
type TradeCancelled struct {
	CancelledByName string
}

func (r *TradeCancelled) Encode() []byte { return encodeStrings(r.CancelledByName) }

func DecodeTradeCancelled(data []byte) (*TradeCancelled, error) {
	fields, err := decodeStrings(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding TradeCancelled: %w", err)
	}
	return &TradeCancelled{CancelledByName: fields[0]}, nil
}

// TradeHandler returns a gateway.Handler implementing the client->server
// trade opcodes.
func TradeHandler(chars character.Store, inv inventory.Store, items ItemLookup, hub *world.Hub, trades *trade.Hub) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		switch p.Opcode {
		case OpTradeRequest:
			return handleTradeRequest(ctx, sess, p, chars, hub, trades)
		case OpTradeRespond:
			return handleTradeRespond(ctx, sess, p, chars, trades)
		case OpTradeSetOffer:
			return handleTradeSetOffer(ctx, sess, p, chars, inv, items, trades)
		case OpTradeConfirm:
			return handleTradeConfirm(ctx, sess, p, chars, inv, items, trades)
		case OpTradeCancel:
			return handleTradeCancel(ctx, sess, p, chars, hub, trades)
		default:
			return nil
		}
	}
}

func handleTradeRequest(ctx context.Context, sess *gateway.Session, p *proto.Packet, chars character.Store, hub *world.Hub, trades *trade.Hub) error {
	req, err := DecodeTradeRequestRequest(p.Data)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpTradeRequestResult, Data: (&TradeRequestResult{Reason: "malformed request"}).Encode()})
	}
	characterID, errStr := resolveCharacterID(ctx, sess, chars, req.CharacterName)
	if errStr != "" {
		return sess.Send(&proto.Packet{Opcode: OpTradeRequestResult, Data: (&TradeRequestResult{Reason: errStr}).Encode()})
	}
	targetEntity, ok := hub.FindByName(req.TargetName)
	if !ok {
		return sess.Send(&proto.Packet{Opcode: OpTradeRequestResult, Data: (&TradeRequestResult{Reason: "player not found"}).Encode()})
	}

	requester := trade.Member{Session: sess, CharacterID: characterID, Name: req.CharacterName}
	target := trade.Member{Session: targetEntity.Session, CharacterID: targetEntity.CharacterID, Name: targetEntity.Name}
	if err := trades.Request(requester, target); err != nil {
		return sess.Send(&proto.Packet{Opcode: OpTradeRequestResult, Data: (&TradeRequestResult{Reason: tradeErrorMessage(err)}).Encode()})
	}

	if err := sess.Send(&proto.Packet{Opcode: OpTradeRequestResult, Data: (&TradeRequestResult{OK: true}).Encode()}); err != nil {
		return err
	}
	invite := &TradeInvite{RequesterName: req.CharacterName}
	return target.Session.Send(&proto.Packet{Opcode: OpTradeInvite, Data: invite.Encode()})
}

func handleTradeRespond(ctx context.Context, sess *gateway.Session, p *proto.Packet, chars character.Store, trades *trade.Hub) error {
	req, err := DecodeTradeRespondRequest(p.Data)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpTradeRespondResult, Data: (&TradeRespondResult{Reason: "malformed request"}).Encode()})
	}
	characterID, errStr := resolveCharacterID(ctx, sess, chars, req.CharacterName)
	if errStr != "" {
		return sess.Send(&proto.Packet{Opcode: OpTradeRespondResult, Data: (&TradeRespondResult{Reason: errStr}).Encode()})
	}

	responder := trade.Member{Session: sess, CharacterID: characterID, Name: req.CharacterName}
	requester, err := trades.Respond(responder, req.Accept)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpTradeRespondResult, Data: (&TradeRespondResult{Reason: tradeErrorMessage(err)}).Encode()})
	}

	if err := sess.Send(&proto.Packet{Opcode: OpTradeRespondResult, Data: (&TradeRespondResult{OK: true}).Encode()}); err != nil {
		return err
	}

	if !req.Accept {
		declined := &TradeDeclined{TargetName: req.CharacterName}
		return requester.Session.Send(&proto.Packet{Opcode: OpTradeDeclined, Data: declined.Encode()})
	}

	if err := sess.Send(&proto.Packet{Opcode: OpTradeStarted, Data: (&TradeStarted{PartnerName: requester.Name}).Encode()}); err != nil {
		return err
	}
	return requester.Session.Send(&proto.Packet{Opcode: OpTradeStarted, Data: (&TradeStarted{PartnerName: req.CharacterName}).Encode()})
}

func handleTradeSetOffer(ctx context.Context, sess *gateway.Session, p *proto.Packet, chars character.Store, inv inventory.Store, items ItemLookup, trades *trade.Hub) error {
	req, err := DecodeTradeSetOfferRequest(p.Data)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpTradeOfferResult, Data: (&TradeOfferResult{Reason: "malformed request"}).Encode()})
	}
	characterID, errStr := resolveCharacterID(ctx, sess, chars, req.CharacterName)
	if errStr != "" {
		return sess.Send(&proto.Packet{Opcode: OpTradeOfferResult, Data: (&TradeOfferResult{Reason: errStr}).Encode()})
	}

	offer := trade.Offer{Gold: req.Offer.Gold, ItemSlot: int(req.Offer.ItemSlot), Quantity: int(req.Offer.Quantity)}

	// THE ITEM'S OWN TRADE FLAG, CHECKED WHEN THE ITEM IS OFFERED -- where the
	// engine checks it. CGStorage::TradeOfferItem (`0x00526910`) reads the
	// offered slot's item and, before it ever reaches
	// TradeMgr::OfferItemToPartner, refuses with 0x183a
	// UIIT_MSG_STRGERR_CANNOT_BE_TRADED when vtable slot 0xc4 (IGObj::CanTrade,
	// docs/protocol/item_capability_flags.md) returns zero. So a refused offer
	// is never stored, never voids either side's confirmation, and never
	// reaches the partner; executeTrade keeps its own check for an item moved
	// into the offered slot afterwards.
	reason, err := offerTradeFlagRefusal(ctx, inv, items, characterID, offer)
	if err != nil {
		return fmt.Errorf("trade: checking offer: %w", err)
	}
	if reason != "" {
		return sess.Send(&proto.Packet{Opcode: OpTradeOfferResult, Data: (&TradeOfferResult{Reason: reason}).Encode()})
	}

	sessn, err := trades.SetOffer(characterID, offer)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpTradeOfferResult, Data: (&TradeOfferResult{Reason: tradeErrorMessage(err)}).Encode()})
	}

	if err := sess.Send(&proto.Packet{Opcode: OpTradeOfferResult, Data: (&TradeOfferResult{OK: true}).Encode()}); err != nil {
		return err
	}

	other, _, _ := sessn.Other(characterID)
	updated := &TradeOfferUpdated{Offer: req.Offer}
	return other.Session.Send(&proto.Packet{Opcode: OpTradeOfferUpdated, Data: updated.Encode()})
}

func handleTradeConfirm(ctx context.Context, sess *gateway.Session, p *proto.Packet, chars character.Store, inv inventory.Store, items ItemLookup, trades *trade.Hub) error {
	req, err := DecodeTradeConfirmRequest(p.Data)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpTradeConfirmResult, Data: (&TradeConfirmResult{Reason: "malformed request"}).Encode()})
	}
	characterID, errStr := resolveCharacterID(ctx, sess, chars, req.CharacterName)
	if errStr != "" {
		return sess.Send(&proto.Packet{Opcode: OpTradeConfirmResult, Data: (&TradeConfirmResult{Reason: errStr}).Encode()})
	}

	tradeSess, bothConfirmed, err := trades.Confirm(characterID)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpTradeConfirmResult, Data: (&TradeConfirmResult{Reason: tradeErrorMessage(err)}).Encode()})
	}
	if err := sess.Send(&proto.Packet{Opcode: OpTradeConfirmResult, Data: (&TradeConfirmResult{OK: true}).Encode()}); err != nil {
		return err
	}
	if !bothConfirmed {
		return nil
	}

	itemA, itemB, failReason, err := executeTrade(ctx, chars, inv, items, tradeSess)
	if err != nil {
		return fmt.Errorf("trade: executing: %w", err)
	}
	trades.End(characterID)

	if failReason != "" {
		cancelled := &TradeCancelled{CancelledByName: ""} // system cancellation, not either player
		tradeSess.A.Session.Send(&proto.Packet{Opcode: OpTradeCancelled, Data: cancelled.Encode()})
		tradeSess.B.Session.Send(&proto.Packet{Opcode: OpTradeCancelled, Data: cancelled.Encode()})
		return nil
	}

	// A gave itemA/OfferA and receives OfferB/itemB; B is the mirror.
	completedForA := &TradeCompleted{ReceivedGold: tradeSess.OfferB.Gold, ReceivedItemID: itemB, ReceivedQuantity: int32(tradeSess.OfferB.Quantity)}
	completedForB := &TradeCompleted{ReceivedGold: tradeSess.OfferA.Gold, ReceivedItemID: itemA, ReceivedQuantity: int32(tradeSess.OfferA.Quantity)}
	tradeSess.A.Session.Send(&proto.Packet{Opcode: OpTradeCompleted, Data: completedForA.Encode()})
	return tradeSess.B.Session.Send(&proto.Packet{Opcode: OpTradeCompleted, Data: completedForB.Encode()})
}

func handleTradeCancel(ctx context.Context, sess *gateway.Session, p *proto.Packet, chars character.Store, hub *world.Hub, trades *trade.Hub) error {
	req, err := DecodeTradeCancelRequest(p.Data)
	if err != nil {
		return nil
	}
	characterID, errStr := resolveCharacterID(ctx, sess, chars, req.CharacterName)
	if errStr != "" {
		return nil
	}

	cancelled := &TradeCancelled{CancelledByName: req.CharacterName}
	tradeSess, ok := trades.End(characterID)
	if !ok {
		// NO OPEN TRADE: WITHDRAW WHAT THIS CHARACTER ASKED FOR (round 499).
		// A pending request holds both parties (INTERACTMODE 1 from
		// CTradeMgr::OpenTradeSession 0x0047f620 -- see trade.Hub.Busy), so a
		// cancel that left it standing would leave both unable to use an NPC
		// service until the target answered. Each target is told through the
		// world hub (the pending map keeps no target Member), and the
		// canceller gets the same OpTradeCancelled an open trade's cancel
		// sends both sides.
		targets := trades.WithdrawRequest(characterID)
		if len(targets) == 0 {
			return nil
		}
		for _, targetID := range targets {
			if target, online := hub.EntityByCharacterID(targetID); online && target.Session != nil {
				target.Session.Send(&proto.Packet{Opcode: OpTradeCancelled, Data: cancelled.Encode()})
			}
		}
		return sess.Send(&proto.Packet{Opcode: OpTradeCancelled, Data: cancelled.Encode()})
	}
	tradeSess.A.Session.Send(&proto.Packet{Opcode: OpTradeCancelled, Data: cancelled.Encode()})
	return tradeSess.B.Session.Send(&proto.Packet{Opcode: OpTradeCancelled, Data: cancelled.Encode()})
}

// errOfferInvalid means an offer's item slot no longer has enough of the
// item it claimed (changed by some other action between offering and
// confirming).
var errOfferInvalid = errors.New("trade: offer no longer valid")

// offerItemID resolves the item ID currently sitting in offer's ItemSlot
// for characterID, validating there's still enough quantity there.
// Returns 0, nil if the offer has no item component.
// offerItemID resolves an offer's bag slot to its item id and the instance
// in it -- the instance crosses to the other party unchanged.
func offerItemID(ctx context.Context, inv inventory.Store, characterID int64, offer trade.Offer) (int64, inventory.Instance, error) {
	if offer.ItemSlot < 0 {
		return 0, inventory.Instance{}, nil
	}
	slots, err := inv.List(ctx, characterID)
	if err != nil {
		return 0, inventory.Instance{}, err
	}
	for _, s := range slots {
		if s.Index == offer.ItemSlot {
			if s.Quantity < offer.Quantity {
				return 0, inventory.Instance{}, errOfferInvalid
			}
			return s.ItemID, s.Instance(), nil
		}
	}
	return 0, inventory.Instance{}, errOfferInvalid
}

// executeTrade performs the actual gold/item transfer once both sides have
// confirmed. Returns a non-empty failReason (and no error) for an
// orderly, expected failure (insufficient gold, an offer that's gone
// stale) that should cancel the trade cleanly; returns a non-nil error
// only for unexpected store failures.
//
// Not a true cross-store transaction: gold moves via character.Store,
// items via inventory.Store, and there's no shared transaction spanning
// both. Ordering (validate both offers -> deduct both golds, with refund
// on the second failing -> remove both items, with refund on the second
// failing -> credit everything) minimizes the window, and the one gap
// left is documented at the final AddItem calls below.
func executeTrade(ctx context.Context, chars character.Store, inv inventory.Store, items ItemLookup, sess *trade.Session) (itemA, itemB int64, failReason string, err error) {
	var instA, instB inventory.Instance
	itemA, instA, err = offerItemID(ctx, inv, sess.A.CharacterID, sess.OfferA)
	if err != nil {
		if errors.Is(err, errOfferInvalid) {
			return 0, 0, "offer no longer valid", nil
		}
		return 0, 0, "", err
	}
	itemB, instB, err = offerItemID(ctx, inv, sess.B.CharacterID, sess.OfferB)
	if err != nil {
		if errors.Is(err, errOfferInvalid) {
			return 0, 0, "offer no longer valid", nil
		}
		return 0, 0, "", err
	}

	// THE ITEM'S OWN TRADE FLAG, RE-CHECKED AT COMMIT. The engine's trade-offer
	// handler (CGStorage::TradeOfferItem, `0x00526910`) calls CanTrade (vtable
	// slot 49) and returns 0x183a UIIT_MSG_STRGERR_CANNOT_BE_TRADED when the
	// flag is clear; handleTradeSetOffer applies that at offer time (round
	// 482, offerTradeFlagRefusal). This is the commit-time re-check: an
	// inventory move between offering and confirming can put an untradeable
	// item into the offered slot, and the offer names a slot, not an item. In
	// a real itemdata the flag is clear on every starter item (all 52 `_A_DEF`
	// rows) and every quest item (all 558 `ITEM_QNO_` rows). See
	// refdata.Item.CanTrade.
	if reason, err := tradeFlagRefusal(ctx, items, sess, itemA, itemB); err != nil || reason != "" {
		return 0, 0, reason, err
	}

	// THE RECIPIENT-CAPACITY PRE-CHECK, added 2026-09-16 and taken from the
	// engine. Nothing has moved yet at this point, so a refusal here is free.
	if reason, err := tradeSpaceShortfall(ctx, inv, sess); err != nil || reason != "" {
		return 0, 0, reason, err
	}

	if sess.OfferA.Gold > 0 {
		if err := chars.DeductGold(ctx, sess.A.CharacterID, sess.OfferA.Gold); err != nil {
			if errors.Is(err, character.ErrInsufficientGold) {
				return 0, 0, "insufficient gold", nil
			}
			return 0, 0, "", err
		}
	}
	if sess.OfferB.Gold > 0 {
		if err := chars.DeductGold(ctx, sess.B.CharacterID, sess.OfferB.Gold); err != nil {
			if sess.OfferA.Gold > 0 {
				chars.AddGold(ctx, sess.A.CharacterID, sess.OfferA.Gold)
			}
			if errors.Is(err, character.ErrInsufficientGold) {
				return 0, 0, "insufficient gold", nil
			}
			return 0, 0, "", err
		}
	}

	if sess.OfferA.ItemSlot >= 0 {
		if err := inv.RemoveItem(ctx, sess.A.CharacterID, sess.OfferA.ItemSlot, sess.OfferA.Quantity); err != nil {
			refundGold(ctx, chars, sess)
			return 0, 0, "offer no longer valid", nil
		}
	}
	if sess.OfferB.ItemSlot >= 0 {
		if err := inv.RemoveItem(ctx, sess.B.CharacterID, sess.OfferB.ItemSlot, sess.OfferB.Quantity); err != nil {
			refundGold(ctx, chars, sess)
			if sess.OfferA.ItemSlot >= 0 {
				inv.AddItemInstance(ctx, sess.A.CharacterID, itemA, sess.OfferA.Quantity, instA)
			}
			return 0, 0, "offer no longer valid", nil
		}
	}

	if sess.OfferA.Gold > 0 {
		chars.AddGold(ctx, sess.B.CharacterID, sess.OfferA.Gold)
	}
	if sess.OfferB.Gold > 0 {
		chars.AddGold(ctx, sess.A.CharacterID, sess.OfferB.Gold)
	}

	// Items have already left both givers' inventories at this point. If
	// AddItem fails here the item is lost rather than returned.
	//
	// THE PRE-CHECK THIS NOTE ASKED FOR NOW EXISTS -- see
	// tradeSpaceShortfall, above, which refuses before anything moves. What
	// is left is only the race: a slot that was free when the trade was
	// validated and is not by the time it commits, which needs a shared
	// transaction across the two stores rather than a better check.
	if sess.OfferA.ItemSlot >= 0 {
		if err := inv.AddItemInstance(ctx, sess.B.CharacterID, itemA, sess.OfferA.Quantity, instA); err != nil {
			return 0, 0, "", fmt.Errorf("crediting item to recipient: %w", err)
		}
	}
	if sess.OfferB.ItemSlot >= 0 {
		if err := inv.AddItemInstance(ctx, sess.A.CharacterID, itemB, sess.OfferB.Quantity, instB); err != nil {
			return 0, 0, "", fmt.Errorf("crediting item to recipient: %w", err)
		}
	}

	return itemA, itemB, "", nil
}

func refundGold(ctx context.Context, chars character.Store, sess *trade.Session) {
	if sess.OfferA.Gold > 0 {
		chars.AddGold(ctx, sess.A.CharacterID, sess.OfferA.Gold)
	}
	if sess.OfferB.Gold > 0 {
		chars.AddGold(ctx, sess.B.CharacterID, sess.OfferB.Gold)
	}
}

// TradeDisconnectHandler returns a func suitable for gateway.Server's
// OnDisconnect hook: withdraws any pending trade request the disconnecting
// session was part of and, if they were mid-trade, cancels it (no
// gold/items have moved yet at that point -- SetOffer only records
// intent, nothing is deducted until both sides confirm) and notifies
// their partner.
func TradeDisconnectHandler(hub *world.Hub, trades *trade.Hub) func(sess *gateway.Session) {
	return func(sess *gateway.Session) {
		entity, ok := hub.EntityBySession(sess.ID())
		if !ok {
			return
		}
		characterID := entity.CharacterID

		if requester, notifiable := trades.CancelPendingFor(characterID); notifiable {
			declined := &TradeDeclined{TargetName: entity.Name}
			requester.Session.Send(&proto.Packet{Opcode: OpTradeDeclined, Data: declined.Encode()})
		}

		if tradeSess, ok := trades.End(characterID); ok {
			cancelled := &TradeCancelled{CancelledByName: entity.Name}
			other, _, _ := tradeSess.Other(characterID)
			other.Session.Send(&proto.Packet{Opcode: OpTradeCancelled, Data: cancelled.Encode()})
		}
	}
}

func tradeErrorMessage(err error) string {
	switch {
	case errors.Is(err, trade.ErrCannotTradeSelf):
		return "cannot trade with yourself"
	case errors.Is(err, trade.ErrAlreadyTrading):
		return "already trading"
	case errors.Is(err, trade.ErrTargetBusy):
		return "target is busy"
	case errors.Is(err, trade.ErrNoPendingRequest):
		return "no pending request"
	case errors.Is(err, trade.ErrNotTrading):
		return "not trading"
	case errors.Is(err, trade.ErrInvalidOffer):
		return "invalid offer"
	default:
		return "operation failed"
	}
}

// tradeSpaceShortfall reports a failReason when either side has no free
// inventory slot for the item they are about to receive. Empty reason means
// the trade fits.
//
// THIS IS THE ENGINE'S OWN RULE. The server's trade-offer handler
// (`0x00480a20`) counts the partner's empty slots and refuses when there are
// too few:
//
//	iVar7 = GStorage::CGStorage__CountEmptySlot(0xd, 0xffffffff);
//	if (iVar7 < iVar6 + 1) return 0x1836;   // NOT_ENOUGH_OPPONENT_INV_SPACE
//
// Two things in that are worth copying and one is worth noting.
//
// Worth copying: it counts EMPTY SLOTS and ignores stacking, so an item that
// would have merged into an existing stack is still required to have a slot.
// That is conservative, and this matches it -- a trade refused for space when
// it would technically have fitted is a far better failure than an item that
// vanishes.
//
// Also worth copying: the check happens before anything is removed. The engine
// goes further and refuses at OFFER time, so the player finds out while
// arranging the trade rather than on confirming it; srrevamp checks at commit,
// which closes the item-loss hole but reports later.
//
// Worth noting: the `0xd` is the engine counting from slot 13, because slots
// 0..12 are the equipment slots in the same array (see inventory.go). srrevamp
// keeps the two spaces separate, so there is no offset to apply here.
func tradeSpaceShortfall(ctx context.Context, inv inventory.Store, sess *trade.Session) (string, error) {
	for _, side := range []struct {
		recipient int64
		name      string
		receiving bool
	}{
		{sess.B.CharacterID, sess.B.Name, sess.OfferA.ItemSlot >= 0},
		{sess.A.CharacterID, sess.A.Name, sess.OfferB.ItemSlot >= 0},
	} {
		if !side.receiving {
			continue
		}
		occupied, err := inv.List(ctx, side.recipient)
		if err != nil {
			return "", fmt.Errorf("checking inventory space for %s: %w", side.name, err)
		}
		if len(occupied) >= inventory.SlotsPerCharacter {
			return side.name + "'s inventory is full", nil
		}
	}
	return "", nil
}

// offerTradeFlagRefusal reports the OpTradeOfferResult reason when the item in
// offer's slot is one the engine forbids trading. Empty reason means the offer
// may be stored.
//
// It is the offer-time half of CGStorage::TradeOfferItem (`0x00526910`):
//
//	piVar2 = (int *)GetItem(*(byte *)(param_2 + 3));
//	if (piVar2 == (int *)0x0) return 0x1809;
//	iVar3 = (**(code **)(*piVar2 + 0xc4))();   // IGObj::CanTrade, slot 49
//	if (iVar3 == 0) return 0x183a;             // CANNOT_BE_TRADED
//
// Only the 0x183a refusal is modelled here. An empty or short slot is left to
// executeTrade, which re-validates every offer at commit ("offer no longer
// valid"), and the same "no opinion" rule as tradeFlagRefusal applies: no
// reference data wired, or an item the tables do not know, refuses nothing.
func offerTradeFlagRefusal(ctx context.Context, inv inventory.Store, items ItemLookup, characterID int64, offer trade.Offer) (string, error) {
	if items == nil || inv == nil || offer.ItemSlot < 0 {
		return "", nil
	}
	itemID, _, err := offerItemID(ctx, inv, characterID, offer)
	if err != nil {
		if errors.Is(err, errOfferInvalid) {
			return "", nil
		}
		return "", err
	}
	it, err := items.GetItem(ctx, itemID)
	if err != nil {
		if errors.Is(err, refdata.ErrItemNotFound) {
			return "", nil
		}
		return "", fmt.Errorf("looking up item %d: %w", itemID, err)
	}
	if it != nil && !it.CanTrade {
		return "that item cannot be traded", nil
	}
	return "", nil
}

// tradeFlagRefusal reports a failReason when either offered item is one the
// engine forbids trading. Empty reason means both are tradeable.
//
// A DEPLOYMENT WITH NO REFERENCE DATA ENFORCES NOTHING, deliberately. `items`
// is nil on a server that has imported none, and an item the tables do not know
// returns ErrItemNotFound -- both are treated as "no opinion" rather than as a
// refusal. The alternative is worse: refdata.Item.CanTrade is a bool, so an
// unknown item would read false and every trade on an unconfigured server would
// fail. That is the same trap the CSV loader's comment warns about, which is why
// the absence is handled here at the call site rather than by defaulting the
// field.
func tradeFlagRefusal(ctx context.Context, items ItemLookup, sess *trade.Session, itemA, itemB int64) (string, error) {
	if items == nil {
		return "", nil
	}
	for _, side := range []struct {
		itemID  int64
		name    string
		offered bool
	}{
		{itemA, sess.A.Name, sess.OfferA.ItemSlot >= 0},
		{itemB, sess.B.Name, sess.OfferB.ItemSlot >= 0},
	} {
		if !side.offered || side.itemID == 0 {
			continue
		}
		it, err := items.GetItem(ctx, side.itemID)
		if err != nil {
			if errors.Is(err, refdata.ErrItemNotFound) {
				continue
			}
			return "", fmt.Errorf("looking up item %d: %w", side.itemID, err)
		}
		if it != nil && !it.CanTrade {
			return side.name + " offered an item that cannot be traded", nil
		}
	}
	return "", nil
}
