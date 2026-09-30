package session

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"

	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/friend"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/world"
)

// Friend opcodes, our own protocol. All require a prior OpLogin.
//
// OpFriendRequest resolves its target by name via world.Hub.FindByName --
// same as chat/duel/trade, the target must be online to be friended. This
// is a real limitation for a *persistent* social feature (you can't send
// a request to someone who's logged off), but there's no character-name
// lookup that isn't either account-scoped (resolveCharacterID) or
// online-scoped (world.Hub) yet; adding an unscoped one is future work.
//
// OpFriendAccept/OpFriendDecline/OpFriendRemove deliberately take a
// character ID, not a name: the client already has the ID from a prior
// OpFriendPendingListResult/OpFriendListResult, and resolving it that way
// means accepting/declining/removing works regardless of whether the
// other character is currently online -- unlike sending a request, which
// does require it.
const (
	OpFriendRequest           uint16 = 0x00E0 // client -> server
	OpFriendRequestResult     uint16 = 0x00E1 // server -> client, ack to the sender
	OpFriendRequestReceived   uint16 = 0x00E2 // server -> client, direct to the target (if online)
	OpFriendAccept            uint16 = 0x00E3 // client -> server
	OpFriendAcceptResult      uint16 = 0x00E4 // server -> client, ack to the accepter
	OpFriendAccepted          uint16 = 0x00E5 // server -> client, direct to the original requester (if online)
	OpFriendDecline           uint16 = 0x00E6 // client -> server
	OpFriendDeclineResult     uint16 = 0x00E7 // server -> client, ack
	OpFriendList              uint16 = 0x00E8 // client -> server
	OpFriendListResult        uint16 = 0x00E9 // server -> client
	OpFriendRemove            uint16 = 0x00EA // client -> server
	OpFriendRemoveResult      uint16 = 0x00EB // server -> client, ack
	OpFriendPendingList       uint16 = 0x00EC // client -> server
	OpFriendPendingListResult uint16 = 0x00ED // server -> client
)

// FriendRequestRequest is the OpFriendRequest payload.
type FriendRequestRequest struct {
	CharacterName string
	TargetName    string
}

func (r *FriendRequestRequest) Encode() []byte { return encodeStrings(r.CharacterName, r.TargetName) }

func DecodeFriendRequestRequest(data []byte) (*FriendRequestRequest, error) {
	fields, err := decodeStrings(data, 2)
	if err != nil {
		return nil, fmt.Errorf("session: decoding FriendRequestRequest: %w", err)
	}
	return &FriendRequestRequest{CharacterName: fields[0], TargetName: fields[1]}, nil
}

// FriendRequestResult is the OpFriendRequestResult payload.
type FriendRequestResult struct {
	OK     bool
	Reason string
}

func (r *FriendRequestResult) Encode() []byte { return encodeOKReason(r.OK, r.Reason) }

func DecodeFriendRequestResult(data []byte) (*FriendRequestResult, error) {
	ok, reason, err := decodeOKReason(data)
	if err != nil {
		return nil, fmt.Errorf("session: decoding FriendRequestResult: %w", err)
	}
	return &FriendRequestResult{OK: ok, Reason: reason}, nil
}

// FriendRequestReceived is the OpFriendRequestReceived payload.
type FriendRequestReceived struct {
	RequesterName string
}

func (r *FriendRequestReceived) Encode() []byte { return encodeStrings(r.RequesterName) }

func DecodeFriendRequestReceived(data []byte) (*FriendRequestReceived, error) {
	fields, err := decodeStrings(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding FriendRequestReceived: %w", err)
	}
	return &FriendRequestReceived{RequesterName: fields[0]}, nil
}

// FriendAcceptRequest is the OpFriendAccept payload.
type FriendAcceptRequest struct {
	CharacterName string
	RequesterID   int64
}

func (r *FriendAcceptRequest) Encode() []byte {
	return append(encodeStrings(r.CharacterName), encodeInt64(r.RequesterID)...)
}

func DecodeFriendAcceptRequest(data []byte) (*FriendAcceptRequest, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding FriendAcceptRequest: %w", err)
	}
	requesterID, _, err := decodeInt64(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding FriendAcceptRequest: requester id: %w", err)
	}
	return &FriendAcceptRequest{CharacterName: fields[0], RequesterID: requesterID}, nil
}

// FriendAcceptResult is the OpFriendAcceptResult payload.
type FriendAcceptResult struct {
	OK     bool
	Reason string
}

func (r *FriendAcceptResult) Encode() []byte { return encodeOKReason(r.OK, r.Reason) }

func DecodeFriendAcceptResult(data []byte) (*FriendAcceptResult, error) {
	ok, reason, err := decodeOKReason(data)
	if err != nil {
		return nil, fmt.Errorf("session: decoding FriendAcceptResult: %w", err)
	}
	return &FriendAcceptResult{OK: ok, Reason: reason}, nil
}

// FriendAccepted is the OpFriendAccepted payload.
type FriendAccepted struct {
	AccepterName string
}

func (r *FriendAccepted) Encode() []byte { return encodeStrings(r.AccepterName) }

func DecodeFriendAccepted(data []byte) (*FriendAccepted, error) {
	fields, err := decodeStrings(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding FriendAccepted: %w", err)
	}
	return &FriendAccepted{AccepterName: fields[0]}, nil
}

// FriendDeclineRequest is the OpFriendDecline payload.
type FriendDeclineRequest struct {
	CharacterName string
	RequesterID   int64
}

func (r *FriendDeclineRequest) Encode() []byte {
	return append(encodeStrings(r.CharacterName), encodeInt64(r.RequesterID)...)
}

func DecodeFriendDeclineRequest(data []byte) (*FriendDeclineRequest, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding FriendDeclineRequest: %w", err)
	}
	requesterID, _, err := decodeInt64(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding FriendDeclineRequest: requester id: %w", err)
	}
	return &FriendDeclineRequest{CharacterName: fields[0], RequesterID: requesterID}, nil
}

// FriendDeclineResult is the OpFriendDeclineResult payload.
type FriendDeclineResult struct {
	OK     bool
	Reason string
}

func (r *FriendDeclineResult) Encode() []byte { return encodeOKReason(r.OK, r.Reason) }

func DecodeFriendDeclineResult(data []byte) (*FriendDeclineResult, error) {
	ok, reason, err := decodeOKReason(data)
	if err != nil {
		return nil, fmt.Errorf("session: decoding FriendDeclineResult: %w", err)
	}
	return &FriendDeclineResult{OK: ok, Reason: reason}, nil
}

// FriendSnapshot is one friends-list entry, as sent over the wire.
type FriendSnapshot struct {
	CharacterID int64
	Name        string
	Online      bool
}

func (f *FriendSnapshot) Encode() []byte {
	out := append(encodeInt64(f.CharacterID), encodeStrings(f.Name)...)
	if f.Online {
		return append(out, 1)
	}
	return append(out, 0)
}

func decodeFriendSnapshot(data []byte) (*FriendSnapshot, []byte, error) {
	id, rest, err := decodeInt64(data)
	if err != nil {
		return nil, nil, fmt.Errorf("character id: %w", err)
	}
	names, rest, err := decodeStringsPrefix(rest, 1)
	if err != nil {
		return nil, nil, fmt.Errorf("name: %w", err)
	}
	if len(rest) < 1 {
		return nil, nil, errors.New("truncated online flag")
	}
	return &FriendSnapshot{CharacterID: id, Name: names[0], Online: rest[0] != 0}, rest[1:], nil
}

// FriendListResult is the OpFriendListResult payload.
type FriendListResult struct {
	Error   string
	Friends []FriendSnapshot
}

func (r *FriendListResult) Encode() []byte {
	out := encodeStrings(r.Error)
	if r.Error != "" {
		return out
	}
	countBuf := make([]byte, 2)
	binary.LittleEndian.PutUint16(countBuf, uint16(len(r.Friends)))
	out = append(out, countBuf...)
	for _, f := range r.Friends {
		out = append(out, f.Encode()...)
	}
	return out
}

func DecodeFriendListResult(data []byte) (*FriendListResult, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding FriendListResult: %w", err)
	}
	r := &FriendListResult{Error: fields[0]}
	if r.Error != "" {
		return r, nil
	}

	if len(rest) < 2 {
		return nil, errors.New("session: decoding FriendListResult: truncated friend count")
	}
	count := int(binary.LittleEndian.Uint16(rest))
	rest = rest[2:]
	for i := 0; i < count; i++ {
		var snap *FriendSnapshot
		snap, rest, err = decodeFriendSnapshot(rest)
		if err != nil {
			return nil, fmt.Errorf("session: decoding FriendListResult: friend %d: %w", i, err)
		}
		r.Friends = append(r.Friends, *snap)
	}
	return r, nil
}

// FriendRemoveRequest is the OpFriendRemove payload.
type FriendRemoveRequest struct {
	CharacterName string
	FriendID      int64
}

func (r *FriendRemoveRequest) Encode() []byte {
	return append(encodeStrings(r.CharacterName), encodeInt64(r.FriendID)...)
}

func DecodeFriendRemoveRequest(data []byte) (*FriendRemoveRequest, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding FriendRemoveRequest: %w", err)
	}
	friendID, _, err := decodeInt64(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding FriendRemoveRequest: friend id: %w", err)
	}
	return &FriendRemoveRequest{CharacterName: fields[0], FriendID: friendID}, nil
}

// FriendRemoveResult is the OpFriendRemoveResult payload.
type FriendRemoveResult struct {
	OK     bool
	Reason string
}

func (r *FriendRemoveResult) Encode() []byte { return encodeOKReason(r.OK, r.Reason) }

func DecodeFriendRemoveResult(data []byte) (*FriendRemoveResult, error) {
	ok, reason, err := decodeOKReason(data)
	if err != nil {
		return nil, fmt.Errorf("session: decoding FriendRemoveResult: %w", err)
	}
	return &FriendRemoveResult{OK: ok, Reason: reason}, nil
}

// PendingRequestSnapshot is one incoming friend request, as sent over the
// wire.
type PendingRequestSnapshot struct {
	RequesterID   int64
	RequesterName string
}

func (r *PendingRequestSnapshot) Encode() []byte {
	return append(encodeInt64(r.RequesterID), encodeStrings(r.RequesterName)...)
}

func decodePendingRequestSnapshot(data []byte) (*PendingRequestSnapshot, []byte, error) {
	id, rest, err := decodeInt64(data)
	if err != nil {
		return nil, nil, fmt.Errorf("requester id: %w", err)
	}
	names, rest, err := decodeStringsPrefix(rest, 1)
	if err != nil {
		return nil, nil, fmt.Errorf("requester name: %w", err)
	}
	return &PendingRequestSnapshot{RequesterID: id, RequesterName: names[0]}, rest, nil
}

// FriendPendingListResult is the OpFriendPendingListResult payload.
type FriendPendingListResult struct {
	Error    string
	Requests []PendingRequestSnapshot
}

func (r *FriendPendingListResult) Encode() []byte {
	out := encodeStrings(r.Error)
	if r.Error != "" {
		return out
	}
	countBuf := make([]byte, 2)
	binary.LittleEndian.PutUint16(countBuf, uint16(len(r.Requests)))
	out = append(out, countBuf...)
	for _, req := range r.Requests {
		out = append(out, req.Encode()...)
	}
	return out
}

func DecodeFriendPendingListResult(data []byte) (*FriendPendingListResult, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding FriendPendingListResult: %w", err)
	}
	r := &FriendPendingListResult{Error: fields[0]}
	if r.Error != "" {
		return r, nil
	}

	if len(rest) < 2 {
		return nil, errors.New("session: decoding FriendPendingListResult: truncated request count")
	}
	count := int(binary.LittleEndian.Uint16(rest))
	rest = rest[2:]
	for i := 0; i < count; i++ {
		var snap *PendingRequestSnapshot
		snap, rest, err = decodePendingRequestSnapshot(rest)
		if err != nil {
			return nil, fmt.Errorf("session: decoding FriendPendingListResult: request %d: %w", i, err)
		}
		r.Requests = append(r.Requests, *snap)
	}
	return r, nil
}

// FriendHandler returns a gateway.Handler implementing the client->server
// friend opcodes.
func FriendHandler(chars character.Store, friends friend.Store, hub *world.Hub) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		switch p.Opcode {
		case OpFriendRequest:
			return handleFriendRequest(ctx, sess, p, chars, friends, hub)
		case OpFriendAccept:
			return handleFriendAccept(ctx, sess, p, chars, friends, hub)
		case OpFriendDecline:
			return handleFriendDecline(ctx, sess, p, chars, friends)
		case OpFriendList:
			return handleFriendList(ctx, sess, p, chars, friends, hub)
		case OpFriendRemove:
			return handleFriendRemove(ctx, sess, p, chars, friends)
		case OpFriendPendingList:
			return handleFriendPendingList(ctx, sess, p, chars, friends)
		default:
			return nil
		}
	}
}

func handleFriendRequest(ctx context.Context, sess *gateway.Session, p *proto.Packet, chars character.Store, friends friend.Store, hub *world.Hub) error {
	req, err := DecodeFriendRequestRequest(p.Data)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpFriendRequestResult, Data: (&FriendRequestResult{Reason: "malformed request"}).Encode()})
	}
	characterID, errStr := resolveCharacterID(ctx, sess, chars, req.CharacterName)
	if errStr != "" {
		return sess.Send(&proto.Packet{Opcode: OpFriendRequestResult, Data: (&FriendRequestResult{Reason: errStr}).Encode()})
	}
	targetEntity, ok := hub.FindByName(req.TargetName)
	if !ok {
		return sess.Send(&proto.Packet{Opcode: OpFriendRequestResult, Data: (&FriendRequestResult{Reason: "player not found"}).Encode()})
	}

	if err := friends.SendRequest(ctx, characterID, req.CharacterName, targetEntity.CharacterID); err != nil {
		return sess.Send(&proto.Packet{Opcode: OpFriendRequestResult, Data: (&FriendRequestResult{Reason: friendErrorMessage(err)}).Encode()})
	}
	if err := sess.Send(&proto.Packet{Opcode: OpFriendRequestResult, Data: (&FriendRequestResult{OK: true}).Encode()}); err != nil {
		return err
	}

	received := &FriendRequestReceived{RequesterName: req.CharacterName}
	sendToPeer(targetEntity.Session, &proto.Packet{Opcode: OpFriendRequestReceived, Data: received.Encode()})
	return nil
}

func handleFriendAccept(ctx context.Context, sess *gateway.Session, p *proto.Packet, chars character.Store, friends friend.Store, hub *world.Hub) error {
	req, err := DecodeFriendAcceptRequest(p.Data)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpFriendAcceptResult, Data: (&FriendAcceptResult{Reason: "malformed request"}).Encode()})
	}
	characterID, errStr := resolveCharacterID(ctx, sess, chars, req.CharacterName)
	if errStr != "" {
		return sess.Send(&proto.Packet{Opcode: OpFriendAcceptResult, Data: (&FriendAcceptResult{Reason: errStr}).Encode()})
	}

	if err := friends.AcceptRequest(ctx, characterID, req.CharacterName, req.RequesterID); err != nil {
		return sess.Send(&proto.Packet{Opcode: OpFriendAcceptResult, Data: (&FriendAcceptResult{Reason: friendErrorMessage(err)}).Encode()})
	}
	if err := sess.Send(&proto.Packet{Opcode: OpFriendAcceptResult, Data: (&FriendAcceptResult{OK: true}).Encode()}); err != nil {
		return err
	}

	if requesterEntity, online := hub.EntityByCharacterID(req.RequesterID); online {
		accepted := &FriendAccepted{AccepterName: req.CharacterName}
		sendToPeer(requesterEntity.Session, &proto.Packet{Opcode: OpFriendAccepted, Data: accepted.Encode()})
		return nil
	}
	return nil
}

func handleFriendDecline(ctx context.Context, sess *gateway.Session, p *proto.Packet, chars character.Store, friends friend.Store) error {
	req, err := DecodeFriendDeclineRequest(p.Data)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpFriendDeclineResult, Data: (&FriendDeclineResult{Reason: "malformed request"}).Encode()})
	}
	characterID, errStr := resolveCharacterID(ctx, sess, chars, req.CharacterName)
	if errStr != "" {
		return sess.Send(&proto.Packet{Opcode: OpFriendDeclineResult, Data: (&FriendDeclineResult{Reason: errStr}).Encode()})
	}

	if err := friends.DeclineRequest(ctx, characterID, req.RequesterID); err != nil {
		return sess.Send(&proto.Packet{Opcode: OpFriendDeclineResult, Data: (&FriendDeclineResult{Reason: friendErrorMessage(err)}).Encode()})
	}
	return sess.Send(&proto.Packet{Opcode: OpFriendDeclineResult, Data: (&FriendDeclineResult{OK: true}).Encode()})
}

func handleFriendList(ctx context.Context, sess *gateway.Session, p *proto.Packet, chars character.Store, friends friend.Store, hub *world.Hub) error {
	req, err := DecodeCharacterNameRequest(p.Data)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpFriendListResult, Data: (&FriendListResult{Error: "malformed request"}).Encode()})
	}
	characterID, errStr := resolveCharacterID(ctx, sess, chars, req.Name)
	if errStr != "" {
		return sess.Send(&proto.Packet{Opcode: OpFriendListResult, Data: (&FriendListResult{Error: errStr}).Encode()})
	}

	list, err := friends.ListFriends(ctx, characterID)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpFriendListResult, Data: (&FriendListResult{Error: "failed to load friends"}).Encode()})
	}

	snapshots := make([]FriendSnapshot, len(list))
	for i, f := range list {
		_, online := hub.EntityByCharacterID(f.CharacterID)
		snapshots[i] = FriendSnapshot{CharacterID: f.CharacterID, Name: f.Name, Online: online}
	}
	return sess.Send(&proto.Packet{Opcode: OpFriendListResult, Data: (&FriendListResult{Friends: snapshots}).Encode()})
}

func handleFriendRemove(ctx context.Context, sess *gateway.Session, p *proto.Packet, chars character.Store, friends friend.Store) error {
	req, err := DecodeFriendRemoveRequest(p.Data)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpFriendRemoveResult, Data: (&FriendRemoveResult{Reason: "malformed request"}).Encode()})
	}
	characterID, errStr := resolveCharacterID(ctx, sess, chars, req.CharacterName)
	if errStr != "" {
		return sess.Send(&proto.Packet{Opcode: OpFriendRemoveResult, Data: (&FriendRemoveResult{Reason: errStr}).Encode()})
	}

	if err := friends.RemoveFriend(ctx, characterID, req.FriendID); err != nil {
		return sess.Send(&proto.Packet{Opcode: OpFriendRemoveResult, Data: (&FriendRemoveResult{Reason: friendErrorMessage(err)}).Encode()})
	}
	return sess.Send(&proto.Packet{Opcode: OpFriendRemoveResult, Data: (&FriendRemoveResult{OK: true}).Encode()})
}

func handleFriendPendingList(ctx context.Context, sess *gateway.Session, p *proto.Packet, chars character.Store, friends friend.Store) error {
	req, err := DecodeCharacterNameRequest(p.Data)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpFriendPendingListResult, Data: (&FriendPendingListResult{Error: "malformed request"}).Encode()})
	}
	characterID, errStr := resolveCharacterID(ctx, sess, chars, req.Name)
	if errStr != "" {
		return sess.Send(&proto.Packet{Opcode: OpFriendPendingListResult, Data: (&FriendPendingListResult{Error: errStr}).Encode()})
	}

	list, err := friends.ListPendingRequests(ctx, characterID)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpFriendPendingListResult, Data: (&FriendPendingListResult{Error: "failed to load requests"}).Encode()})
	}

	snapshots := make([]PendingRequestSnapshot, len(list))
	for i, r := range list {
		snapshots[i] = PendingRequestSnapshot{RequesterID: r.RequesterID, RequesterName: r.RequesterName}
	}
	return sess.Send(&proto.Packet{Opcode: OpFriendPendingListResult, Data: (&FriendPendingListResult{Requests: snapshots}).Encode()})
}

func friendErrorMessage(err error) string {
	switch {
	case errors.Is(err, friend.ErrCannotFriendSelf):
		return "cannot friend yourself"
	case errors.Is(err, friend.ErrAlreadyFriends):
		return "already friends"
	case errors.Is(err, friend.ErrRequestAlreadySent):
		return "request already sent"
	case errors.Is(err, friend.ErrNoSuchRequest):
		return "no such request"
	case errors.Is(err, friend.ErrNotFriends):
		return "not friends"
	default:
		return "operation failed"
	}
}
