package session

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
	"github.com/OpenSRO/OpenSRO/server/internal/trade"
	"github.com/OpenSRO/OpenSRO/server/internal/txn"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
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
			return handleTradeRespond(ctx, sess, p, chars, hub, trades)
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

// tradeRequestTimeout is trade.RequestTimeout, the engine's 30 s wait for an
// answer. It is a variable only so a test can shorten it.
var tradeRequestTimeout = trade.RequestTimeout

// tradeTooFarReason refuses a trade request, or its acceptance, when the two
// players are trade.RequestRange or more apart. The engine answers 4,
// UIIT_STT_ERR_COMMON_TOO_FAR (docs/protocol/error_codes.md). Our result
// carries a text, so the wording is OpenSRO's own.
const tradeTooFarReason = "too far away"

// tradeInRange reports whether a and b stand closer than trade.RequestRange:
// the 3-D distance GObjPC_HandleTradeMsg_081 (`0x005154e0`) takes with
// FUN_00405270 and holds against 320.0 at `0x51571c`, strictly below it
// (see trade.RequestRange). Two players in different zones are out of range:
// with -single-frame off each zone is its own frame (its centre region,
// worldmap.FrameFor) and its own hub bucket, so coordinates from two zones
// name places in different frames and cannot be compared. Under -single-frame
// (round 571) every framed zone shares one frame and one bucket
// (worldmap.WorldBucket), so a.Zone == b.Zone and the distance below is taken
// in that one frame. The engine's nearest case is FUN_00430ba0, which gives a
// 1e38 offset (.rdata 0xb45c44) when one position is in a dungeon and the
// other is not.
func tradeInRange(a, b world.Entity) bool {
	if a.Zone != b.Zone {
		return false
	}
	dx, dy, dz := a.Pos.X-b.Pos.X, a.Pos.Y-b.Pos.Y, a.Pos.Z-b.Pos.Z
	return math.Sqrt(dx*dx+dy*dy+dz*dz) < trade.RequestRange
}

// handleTradeRequest follows the engine's request handler,
// GObjPC_HandleTradeMsg_081 (`0x005154e0`), in its order (round 500):
//
//  1. the target is the requester, or is not a player in the world: 3.
//     The two texts below are OpenSRO's own;
//  2. the requester is in an accepted trade (INTERACTMODE 2): 0x1833;
//  3. the requester is a party to a pending request (INTERACTMODE 1, which
//     OpenTradeSession sets on BOTH parties, so this covers the requester and
//     the target of one). If it is with this same target, the new request is
//     dropped with no reply: FUN_0047f5b0 finds the target in the pending
//     session (`+8` or `+0x48`) and the handler returns at `0x51566d`.
//     Otherwise that request is cancelled through GObjPC_HandleTradeMsg_084
//     (0x182c to both parties) and the new one goes ahead;
//  4. the two stand trade.RequestRange or more apart: 4;
//  5. the target is busy: 0x181e, from CTradeMgr::OpenTradeSession
//     (`0x0047f620`) running GObjPC::FUN_004ea050 on it (`0x47f6e0`).
//
// Not modelled, because OpenSRO has no state to test:
//   - the first two checks (FUN_004f0a00, a silent drop; vcall 0x244, 0x185f);
//   - the requester's life state and GROUPMODE, which FUN_004ea050 also
//     requires and whose failure answers 0x181d, as do the INTERACTMODE
//     values other than 0, 1, 2 and 7;
//   - the same two tests on the target, which answer 0x181e.
func handleTradeRequest(ctx context.Context, sess *gateway.Session, p *proto.Packet, chars character.Store, hub *world.Hub, trades *trade.Hub) error {
	req, err := DecodeTradeRequestRequest(p.Data)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpTradeRequestResult, Data: (&TradeRequestResult{Reason: "malformed request"}).Encode()})
	}
	characterID, errStr := resolveCharacterID(ctx, sess, chars, req.CharacterName)
	if errStr != "" {
		return sess.Send(&proto.Packet{Opcode: OpTradeRequestResult, Data: (&TradeRequestResult{Reason: errStr}).Encode()})
	}
	refuse := func(reason string) error {
		return sess.Send(&proto.Packet{Opcode: OpTradeRequestResult, Data: (&TradeRequestResult{Reason: reason}).Encode()})
	}
	// The requester must be alive (round 549): GObjPC_HandleTradeMsg_081
	// (0x005154e0) asks its own GetLifeState once the target is found
	// (0x515607) and answers 0x181d unless it is 1 (`cmp al,0x1` at 0x515611).
	// The engine tests it after the target lookup; here it comes first, so a
	// dead requester is told why rather than "player not found".
	if deadBySession(hub, sess) {
		return refuse(deadRefusal) // engine: 0x181d
	}
	targetEntity, ok := hub.FindByName(req.TargetName)
	if !ok {
		return refuse("player not found") // engine: 3
	}
	if targetEntity.CharacterID == characterID {
		return refuse(tradeErrorMessage(trade.ErrCannotTradeSelf)) // engine: 3
	}
	if trades.Established(characterID) {
		return refuse(tradeErrorMessage(trade.ErrAlreadyTrading)) // engine: 0x1833
	}
	if pending, ok := trades.PendingOf(characterID); ok {
		if pending.Requester.CharacterID == targetEntity.CharacterID || pending.TargetID == targetEntity.CharacterID {
			return nil // engine: FUN_0047f5b0 == 1, no reply
		}
		if err := cancelPendingTrade(hub, trades, characterID, req.CharacterName, sess); err != nil {
			return err
		}
	}
	self, ok := hub.EntityBySession(sess.ID())
	if !ok {
		// A requester with no position cannot be measured. The engine has no
		// such case -- every player object has a position -- so this refusal
		// and its wording are OpenSRO's own.
		return refuse("not in the world")
	}
	if !tradeInRange(self, targetEntity) {
		return refuse(tradeTooFarReason) // engine: 4
	}

	requester := trade.Member{Session: sess, CharacterID: characterID, Name: req.CharacterName}
	target := trade.Member{Session: targetEntity.Session, CharacterID: targetEntity.CharacterID, Name: targetEntity.Name}
	id, err := trades.Request(requester, target)
	if err != nil {
		return refuse(tradeErrorMessage(err)) // ErrTargetBusy: engine 0x181e
	}

	// THE ENGINE'S 30 s WAIT (trade.RequestTimeout). When it runs out
	// unanswered, the request is closed with 0x1826 UIIT_MSG_STRGERR_TIMEOUT
	// and both parties are told. OpTradeCancelled has no code field, so the
	// empty name, the same one executeTrade's failures use, marks it as a
	// system cancellation. Expire matches the request's ID, so a timer left
	// from a request that was answered or withdrawn does nothing.
	time.AfterFunc(tradeRequestTimeout, func() {
		if asker, ok := trades.Expire(target.CharacterID, id); ok {
			timedOut := (&TradeCancelled{}).Encode()
			asker.Session.Send(&proto.Packet{Opcode: OpTradeCancelled, Data: timedOut})
			target.Session.Send(&proto.Packet{Opcode: OpTradeCancelled, Data: timedOut})
		}
	})

	if err := sess.Send(&proto.Packet{Opcode: OpTradeRequestResult, Data: (&TradeRequestResult{OK: true}).Encode()}); err != nil {
		return err
	}
	invite := &TradeInvite{RequesterName: req.CharacterName}
	sendToPeer(target.Session, &proto.Packet{Opcode: OpTradeInvite, Data: invite.Encode()})
	return nil
}

// cancelPendingTrade ends the pending request characterID is a party to, on
// either side, and sends OpTradeCancelled{byName} to the other party and to
// characterID's own session. With no pending request it does nothing and sends
// nothing.
//
// This is GObjPC_HandleTradeMsg_084 (`0x005159c0`), the cancel handler. It
// closes whatever session param_1[0x730] names, through
// CTradeMgr::SendItemExchangeResult with 0x182c
// UIIT_MSG_STRGERR_TRADING_CANCELED_BY_USER. SendItemExchangeResult
// (`0x004806d0`) resets BOTH parties' INTERACTMODE and sends each of them the
// code, so either party may cancel: the requester withdraws the request, or
// the target turns it down. The request handler runs the same function to
// clear a requester's old session before it opens a new one. A target is
// found through the world hub, because the pending map keeps no target Member.
func cancelPendingTrade(hub *world.Hub, trades *trade.Hub, characterID int64, byName string, self *gateway.Session) error {
	cancelled := (&TradeCancelled{CancelledByName: byName}).Encode()
	targets := trades.WithdrawRequest(characterID)
	for _, targetID := range targets {
		if target, online := hub.EntityByCharacterID(targetID); online && target.Session != nil {
			target.Session.Send(&proto.Packet{Opcode: OpTradeCancelled, Data: cancelled})
		}
	}
	requester, incoming := trades.CancelPendingFor(characterID)
	if incoming {
		requester.Session.Send(&proto.Packet{Opcode: OpTradeCancelled, Data: cancelled})
	}
	if len(targets) == 0 && !incoming {
		return nil
	}
	return self.Send(&proto.Packet{Opcode: OpTradeCancelled, Data: cancelled})
}

func handleTradeRespond(ctx context.Context, sess *gateway.Session, p *proto.Packet, chars character.Store, hub *world.Hub, trades *trade.Hub) error {
	req, err := DecodeTradeRespondRequest(p.Data)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpTradeRespondResult, Data: (&TradeRespondResult{Reason: "malformed request"}).Encode()})
	}
	characterID, errStr := resolveCharacterID(ctx, sess, chars, req.CharacterName)
	if errStr != "" {
		return sess.Send(&proto.Packet{Opcode: OpTradeRespondResult, Data: (&TradeRespondResult{Reason: errStr}).Encode()})
	}
	// A dead responder cannot accept (round 549). OWN DESIGN, disclosed: the
	// request side's life-state test is read (handleTradeRequest); the
	// acceptance handler, GObjPC_HandleTradeMsg_084, was not opened for one.
	// A decline is let through, so a request to a player who died meanwhile
	// can still be closed.
	if req.Accept && deadBySession(hub, sess) {
		if requester, gone := trades.CancelPendingFor(characterID); gone {
			requester.Session.Send(&proto.Packet{Opcode: OpTradeCancelled, Data: (&TradeCancelled{}).Encode()})
		}
		return sess.Send(&proto.Packet{Opcode: OpTradeRespondResult, Data: (&TradeRespondResult{Reason: deadRefusal}).Encode()})
	}

	// THE RANGE AGAIN, ON ACCEPTANCE (round 500). CTradeMgr::
	// EstablishTradeSession (`0x0047f970`) measures the pair again and holds
	// the distance against the same 320.0 (`0x47facc`). Out of range, it
	// hands 4 to SendItemExchangeResult, which closes the pending session and
	// tells both parties. Neither party still being there closes it too, with
	// 0x1827 UIIT_MSG_STRGERR_CANNOT_FIND_TARGET (TradeMgr::FUN_0047f0b0 and
	// the FUN_00485d90 lookups). The answering player gets this handler's
	// refusal. The requester gets the system OpTradeCancelled, because that
	// message has no code field.
	if pending, ok := trades.PendingOf(characterID); req.Accept && ok && pending.TargetID == characterID {
		reason := ""
		self, selfOK := hub.EntityBySession(sess.ID())
		other, otherOK := hub.EntityByCharacterID(pending.Requester.CharacterID)
		switch {
		case !selfOK || !otherOK:
			reason = "player not found" // engine: 0x1827
		case !tradeInRange(self, other):
			reason = tradeTooFarReason // engine: 4
		}
		if reason != "" {
			if requester, gone := trades.CancelPendingFor(characterID); gone {
				requester.Session.Send(&proto.Packet{Opcode: OpTradeCancelled, Data: (&TradeCancelled{}).Encode()})
			}
			return sess.Send(&proto.Packet{Opcode: OpTradeRespondResult, Data: (&TradeRespondResult{Reason: reason}).Encode()})
		}
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
		sendToPeer(requester.Session, &proto.Packet{Opcode: OpTradeDeclined, Data: declined.Encode()})
		return nil
	}

	if err := sess.Send(&proto.Packet{Opcode: OpTradeStarted, Data: (&TradeStarted{PartnerName: requester.Name}).Encode()}); err != nil {
		return err
	}
	sendToPeer(requester.Session, &proto.Packet{Opcode: OpTradeStarted, Data: (&TradeStarted{PartnerName: req.CharacterName}).Encode()})
	return nil
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
	sendToPeer(other.Session, &proto.Packet{Opcode: OpTradeOfferUpdated, Data: updated.Encode()})
	return nil
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

	// This call's Confirm latched the trade (trade.Hub.Confirm answers
	// both-confirmed once per trade), so this is the one execution; the
	// trade ends whatever its outcome.
	itemA, itemB, failReason, err := executeTrade(ctx, chars, inv, items, tradeSess)
	trades.Finish(characterID)
	if err != nil {
		// A store failure, or a commit whose answer was lost: the ledger
		// says which (round 743's review, F2). Either way BOTH sides are
		// told -- the trade is no longer in the hub, so nothing else would
		// tell the partner, who would be left in the window.
		applied := false
		if tradeSess.ID != 0 {
			done, lerr := txn.For(chars, inv).Applied(context.WithoutCancel(ctx), tradeLedgerKey(tradeSess))
			applied = lerr == nil && done
		}
		slog.Warn("trade execution failed", "trade", tradeSess.ID, "a", tradeSess.A.CharacterID, "b", tradeSess.B.CharacterID,
			"applied", applied, "error", err)
		if !applied {
			failReason = "trade failed"
		}
	}

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
	sendToPeer(tradeSess.B.Session, &proto.Packet{Opcode: OpTradeCompleted, Data: completedForB.Encode()})
	return nil
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
		// NO OPEN TRADE: END THE PENDING REQUEST, FROM EITHER SIDE. A pending
		// request holds both parties (INTERACTMODE 1 from
		// CTradeMgr::OpenTradeSession 0x0047f620 -- see trade.Hub.Busy), so a
		// cancel that left it standing would leave both unable to use an NPC
		// service until the target answered. Round 499 let the requester
		// withdraw it. Round 500 lets the target cancel it too, as the
		// engine's cancel handler does -- see cancelPendingTrade. Both
		// parties get the same OpTradeCancelled an open trade's cancel sends.
		return cancelPendingTrade(hub, trades, characterID, req.CharacterName, sess)
	}
	tradeSess.A.Session.Send(&proto.Packet{Opcode: OpTradeCancelled, Data: cancelled.Encode()})
	sendToPeer(tradeSess.B.Session, &proto.Packet{Opcode: OpTradeCancelled, Data: cancelled.Encode()})
	return nil
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

// errTradeRefused rolls an execution back for an orderly refusal; the
// reason travels in executeTrade's failReason.
var errTradeRefused = errors.New("trade: refused")

// offerGone reports a take refused because the offered slot no longer holds
// what was offered -- an orderly refusal, not a store failure.
func offerGone(err error) bool {
	return errors.Is(err, inventory.ErrSlotEmpty) || errors.Is(err, inventory.ErrItemChanged) ||
		errors.Is(err, inventory.ErrInsufficientQuantity) || errors.Is(err, inventory.ErrInvalidSlot) ||
		errors.Is(err, inventory.ErrInvalidQuantity)
}

// tradeLedgerKey is the trade's key in the economy ledger (txn.Claim): one
// trade applies once, even if something runs it twice.
func tradeLedgerKey(sess *trade.Session) string {
	return fmt.Sprintf("trade:%s:%d", txn.BootID, sess.ID)
}

// executeTrade performs the gold and item transfer once both sides have
// confirmed, as ONE transaction (round 743, the spec's M1): both debits,
// both items taken (under each bag's lock, checked to be the item offered),
// both credits, and the ledger row that makes the trade apply once -- all
// committed together or not at all. There is no refund or put-back code:
// any refusal or failure rolls everything back. Before round 743 gold and
// items went through separate pools and commits, and a failure between a
// debit and its credit destroyed value
// (TestTradeFailedCreditLosesNothing).
//
// Returns a non-empty failReason (and no error) for an orderly, expected
// refusal (insufficient gold, an offer that has gone stale, no room) that
// should cancel the trade cleanly; a non-nil error only for an unexpected
// store failure. Either way nothing has moved.
func executeTrade(ctx context.Context, chars character.Store, inv inventory.Store, items ItemLookup, sess *trade.Session) (itemA, itemB int64, failReason string, err error) {
	err = txn.For(chars, inv).Run(ctx, func(ctx context.Context) error {
		itemA, itemB, failReason = 0, 0, ""
		refuse := func(reason string) error {
			failReason = reason
			return errTradeRefused
		}
		if sess.ID != 0 {
			if err := txn.Claim(ctx, tradeLedgerKey(sess)); err != nil {
				return err
			}
		}
		var instA, instB inventory.Instance
		var err error
		itemA, instA, err = offerItemID(ctx, inv, sess.A.CharacterID, sess.OfferA)
		if err != nil {
			if errors.Is(err, errOfferInvalid) {
				return refuse("offer no longer valid")
			}
			return err
		}
		itemB, instB, err = offerItemID(ctx, inv, sess.B.CharacterID, sess.OfferB)
		if err != nil {
			if errors.Is(err, errOfferInvalid) {
				return refuse("offer no longer valid")
			}
			return err
		}

		// THE ITEM'S OWN TRADE FLAG, RE-CHECKED AT COMMIT. The engine's
		// trade-offer handler (CGStorage::TradeOfferItem, `0x00526910`) calls
		// CanTrade (vtable slot 49) and returns 0x183a
		// UIIT_MSG_STRGERR_CANNOT_BE_TRADED when the flag is clear;
		// handleTradeSetOffer applies that at offer time (round 482,
		// offerTradeFlagRefusal). This is the commit-time re-check: an
		// inventory move between offering and confirming can put an
		// untradeable item into the offered slot, and the offer names a slot,
		// not an item. In a real itemdata the flag is clear on every starter
		// item (all 52 `_A_DEF` rows) and every quest item (all 558
		// `ITEM_QNO_` rows). See refdata.Item.CanTrade.
		if reason, err := tradeFlagRefusal(ctx, items, sess, itemA, itemB); err != nil {
			return err
		} else if reason != "" {
			return refuse(reason)
		}

		// THE RECIPIENT-CAPACITY PRE-CHECK, added 2026-09-16 and taken from
		// the engine. A refusal here is free: the transaction rolls back.
		if reason, err := tradeSpaceShortfall(ctx, inv, sess); err != nil {
			return err
		} else if reason != "" {
			return refuse(reason)
		}

		// Both sides in ascending character id (round 743's review, F1):
		// every action that locks several characters' rows -- a trade, a
		// party's gold split -- locks them in that one order, so none can
		// wait on another in a cycle. Each side's own debit comes before its
		// credit, so incoming gold never pays for an offer.
		type side struct {
			who      int64
			offer    trade.Offer
			itemID   int64
			inst     *inventory.Instance
			incoming int64 // the partner's gold
		}
		a := side{sess.A.CharacterID, sess.OfferA, itemA, &instA, sess.OfferB.Gold}
		b := side{sess.B.CharacterID, sess.OfferB, itemB, &instB, sess.OfferA.Gold}
		sides := []*side{&a, &b}
		if b.who < a.who {
			sides[0], sides[1] = &b, &a
		}
		partner := func(x *side) *side {
			if x == &a {
				return &b
			}
			return &a
		}
		for _, x := range sides {
			if x.offer.Gold > 0 {
				if err := chars.DeductGold(ctx, x.who, x.offer.Gold); err != nil {
					if errors.Is(err, character.ErrInsufficientGold) {
						return refuse("insufficient gold")
					}
					return err
				}
			}
			if x.incoming > 0 {
				if err := chars.AddGold(ctx, x.who, x.incoming); err != nil {
					return fmt.Errorf("crediting gold to recipient: %w", err)
				}
			}
		}

		// The items, taken in the same order, each checked to still be the
		// item offered. Only a changed offer refuses; any other error (a
		// deadlock, a lost connection) is returned as it is, so Run can
		// retry it (the review's F5).
		for _, x := range sides {
			if x.offer.ItemSlot < 0 {
				continue
			}
			got, err := inventory.Take(ctx, inv, x.who, x.offer.ItemSlot, x.offer.Quantity, x.itemID, *x.inst)
			if err != nil {
				if offerGone(err) {
					return refuse("offer no longer valid")
				}
				return fmt.Errorf("taking the offered item: %w", err)
			}
			*x.inst = got
		}

		// A credit that finds no room (the race the pre-check cannot close:
		// a slot free at the check and taken since) refuses the whole trade
		// rather than losing the item, as it did before round 743.
		for _, x := range sides {
			from := partner(x)
			if from.offer.ItemSlot < 0 {
				continue
			}
			if err := inv.AddItemInstance(ctx, x.who, from.itemID, from.offer.Quantity, *from.inst); err != nil {
				if errors.Is(err, inventory.ErrNoRoom) {
					return refuse("no room")
				}
				return fmt.Errorf("crediting item to recipient: %w", err)
			}
		}
		return nil
	})
	if errors.Is(err, errTradeRefused) {
		return 0, 0, failReason, nil
	}
	if err != nil {
		// The items stay named: a caller that finds the trade applied after
		// all (a lost commit answer) reports them.
		return itemA, itemB, "", err
	}
	return itemA, itemB, "", nil
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
	case errors.Is(err, trade.ErrRequestPending):
		return "a trade request is already pending"
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
// arranging the trade rather than on confirming it; OpenSRO checks at commit,
// which closes the item-loss hole but reports later.
//
// Worth noting: the `0xd` is the engine counting from slot 13, because slots
// 0..12 are the equipment slots in the same array (see inventory.go). OpenSRO
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
		// Room is counted within the configured size: a slot held past it
		// (inventory.SetKeepHeld) takes nothing new.
		place := inventory.PlacementCapacityOf(ctx, inv, side.recipient)
		room := place
		for _, sl := range occupied {
			if sl.Index < place {
				room--
			}
		}
		if room <= 0 {
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
