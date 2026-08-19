package session

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"

	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/party"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
)

// Party opcodes, our own protocol. All require a prior OpLogin.
const (
	OpPartyCreate       uint16 = 0x0080 // client -> server
	OpPartyCreateResult uint16 = 0x0081 // server -> client
	OpPartyJoin         uint16 = 0x0082 // client -> server
	OpPartyJoinResult   uint16 = 0x0083 // server -> client
	OpPartyLeave        uint16 = 0x0084 // client -> server
	OpPartyLeaveResult  uint16 = 0x0085 // server -> client
	OpPartyMemberJoined uint16 = 0x0086 // server -> client, broadcast to other party members
	OpPartyMemberLeft   uint16 = 0x0087 // server -> client, broadcast to remaining party members
)

// PartyMemberSnapshot is one party member, as sent over the wire.
type PartyMemberSnapshot struct {
	CharacterID int64
	Name        string
}

func (m *PartyMemberSnapshot) Encode() []byte {
	return append(encodeInt64(m.CharacterID), encodeStrings(m.Name)...)
}

func decodePartyMemberSnapshot(data []byte) (*PartyMemberSnapshot, []byte, error) {
	id, rest, err := decodeInt64(data)
	if err != nil {
		return nil, nil, fmt.Errorf("character id: %w", err)
	}
	names, rest, err := decodeStringsPrefix(rest, 1)
	if err != nil {
		return nil, nil, fmt.Errorf("name: %w", err)
	}
	return &PartyMemberSnapshot{CharacterID: id, Name: names[0]}, rest, nil
}

// PartyResult is shared by OpPartyCreateResult and OpPartyJoinResult: on
// failure only Error is meaningful; on success PartyID and Members
// describe the full current roster.
type PartyResult struct {
	Error   string
	PartyID int64
	Members []PartyMemberSnapshot
}

func (r *PartyResult) Encode() []byte {
	out := encodeStrings(r.Error)
	if r.Error != "" {
		return out
	}
	out = append(out, encodeInt64(r.PartyID)...)
	countBuf := make([]byte, 2)
	binary.LittleEndian.PutUint16(countBuf, uint16(len(r.Members)))
	out = append(out, countBuf...)
	for _, m := range r.Members {
		out = append(out, m.Encode()...)
	}
	return out
}

func DecodePartyResult(data []byte) (*PartyResult, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding PartyResult: %w", err)
	}
	r := &PartyResult{Error: fields[0]}
	if r.Error != "" {
		return r, nil
	}

	partyID, rest, err := decodeInt64(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding PartyResult: party id: %w", err)
	}
	r.PartyID = partyID

	if len(rest) < 2 {
		return nil, errors.New("session: decoding PartyResult: truncated member count")
	}
	count := int(binary.LittleEndian.Uint16(rest))
	rest = rest[2:]
	for i := 0; i < count; i++ {
		var snap *PartyMemberSnapshot
		snap, rest, err = decodePartyMemberSnapshot(rest)
		if err != nil {
			return nil, fmt.Errorf("session: decoding PartyResult: member %d: %w", i, err)
		}
		r.Members = append(r.Members, *snap)
	}
	return r, nil
}

// PartyJoinRequest is the OpPartyJoin payload.
type PartyJoinRequest struct {
	CharacterName string
	PartyID       int64
}

func (r *PartyJoinRequest) Encode() []byte {
	return append(encodeStrings(r.CharacterName), encodeInt64(r.PartyID)...)
}

func DecodePartyJoinRequest(data []byte) (*PartyJoinRequest, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding PartyJoinRequest: %w", err)
	}
	partyID, _, err := decodeInt64(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding PartyJoinRequest: party id: %w", err)
	}
	return &PartyJoinRequest{CharacterName: fields[0], PartyID: partyID}, nil
}

// PartyLeaveResult is the OpPartyLeaveResult payload.
type PartyLeaveResult struct {
	OK     bool
	Reason string
}

func (r *PartyLeaveResult) Encode() []byte { return encodeOKReason(r.OK, r.Reason) }

func DecodePartyLeaveResult(data []byte) (*PartyLeaveResult, error) {
	ok, reason, err := decodeOKReason(data)
	if err != nil {
		return nil, fmt.Errorf("session: decoding PartyLeaveResult: %w", err)
	}
	return &PartyLeaveResult{OK: ok, Reason: reason}, nil
}

// PartyMemberJoined is the OpPartyMemberJoined broadcast payload.
type PartyMemberJoined struct {
	CharacterID int64
	Name        string
}

func (r *PartyMemberJoined) Encode() []byte {
	return append(encodeInt64(r.CharacterID), encodeStrings(r.Name)...)
}

func DecodePartyMemberJoined(data []byte) (*PartyMemberJoined, error) {
	id, rest, err := decodeInt64(data)
	if err != nil {
		return nil, fmt.Errorf("session: decoding PartyMemberJoined: %w", err)
	}
	names, err := decodeStrings(rest, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding PartyMemberJoined: %w", err)
	}
	return &PartyMemberJoined{CharacterID: id, Name: names[0]}, nil
}

// PartyMemberLeft is the OpPartyMemberLeft broadcast payload.
type PartyMemberLeft struct {
	CharacterID int64
}

func (r *PartyMemberLeft) Encode() []byte { return encodeInt64(r.CharacterID) }

func DecodePartyMemberLeft(data []byte) (*PartyMemberLeft, error) {
	id, _, err := decodeInt64(data)
	if err != nil {
		return nil, fmt.Errorf("session: decoding PartyMemberLeft: %w", err)
	}
	return &PartyMemberLeft{CharacterID: id}, nil
}

// PartyHandler returns a gateway.Handler implementing
// OpPartyCreate/OpPartyJoin/OpPartyLeave against parties.
func PartyHandler(chars character.Store, parties *party.Hub) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		switch p.Opcode {
		case OpPartyCreate:
			return handlePartyCreate(ctx, sess, p, chars, parties)
		case OpPartyJoin:
			return handlePartyJoin(ctx, sess, p, chars, parties)
		case OpPartyLeave:
			return handlePartyLeave(ctx, sess, p, chars, parties)
		default:
			return nil
		}
	}
}

func partyMemberSnapshots(members []party.Member) []PartyMemberSnapshot {
	out := make([]PartyMemberSnapshot, len(members))
	for i, m := range members {
		out[i] = PartyMemberSnapshot{CharacterID: m.CharacterID, Name: m.Name}
	}
	return out
}

func broadcastToPartyExcept(members []party.Member, exceptSessionID uint64, opcode uint16, data []byte) {
	for _, m := range members {
		if m.Session.ID() == exceptSessionID {
			continue
		}
		m.Session.Send(&proto.Packet{Opcode: opcode, Data: data})
	}
}

func handlePartyCreate(ctx context.Context, sess *gateway.Session, p *proto.Packet, chars character.Store, parties *party.Hub) error {
	req, err := DecodeCharacterCreateRequest(p.Data) // reuse: {Name string}
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpPartyCreateResult, Data: (&PartyResult{Error: "malformed request"}).Encode()})
	}
	characterID, errStr := resolveCharacterID(ctx, sess, chars, req.Name)
	if errStr != "" {
		return sess.Send(&proto.Packet{Opcode: OpPartyCreateResult, Data: (&PartyResult{Error: errStr}).Encode()})
	}

	pt, err := parties.Create(party.Member{Session: sess, CharacterID: characterID, Name: req.Name})
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpPartyCreateResult, Data: (&PartyResult{Error: partyErrorMessage(err)}).Encode()})
	}
	result := &PartyResult{PartyID: pt.ID, Members: partyMemberSnapshots(pt.Members)}
	return sess.Send(&proto.Packet{Opcode: OpPartyCreateResult, Data: result.Encode()})
}

func handlePartyJoin(ctx context.Context, sess *gateway.Session, p *proto.Packet, chars character.Store, parties *party.Hub) error {
	req, err := DecodePartyJoinRequest(p.Data)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpPartyJoinResult, Data: (&PartyResult{Error: "malformed request"}).Encode()})
	}
	characterID, errStr := resolveCharacterID(ctx, sess, chars, req.CharacterName)
	if errStr != "" {
		return sess.Send(&proto.Packet{Opcode: OpPartyJoinResult, Data: (&PartyResult{Error: errStr}).Encode()})
	}

	pt, err := parties.Join(req.PartyID, party.Member{Session: sess, CharacterID: characterID, Name: req.CharacterName})
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpPartyJoinResult, Data: (&PartyResult{Error: partyErrorMessage(err)}).Encode()})
	}

	result := &PartyResult{PartyID: pt.ID, Members: partyMemberSnapshots(pt.Members)}
	if err := sess.Send(&proto.Packet{Opcode: OpPartyJoinResult, Data: result.Encode()}); err != nil {
		return err
	}

	joined := &PartyMemberJoined{CharacterID: characterID, Name: req.CharacterName}
	broadcastToPartyExcept(pt.Members, sess.ID(), OpPartyMemberJoined, joined.Encode())
	return nil
}

func handlePartyLeave(ctx context.Context, sess *gateway.Session, p *proto.Packet, chars character.Store, parties *party.Hub) error {
	req, err := DecodeCharacterCreateRequest(p.Data) // reuse: {Name string}
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpPartyLeaveResult, Data: (&PartyLeaveResult{Reason: "malformed request"}).Encode()})
	}
	characterID, errStr := resolveCharacterID(ctx, sess, chars, req.Name)
	if errStr != "" {
		return sess.Send(&proto.Packet{Opcode: OpPartyLeaveResult, Data: (&PartyLeaveResult{Reason: errStr}).Encode()})
	}

	_, remaining, err := parties.Leave(characterID)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpPartyLeaveResult, Data: (&PartyLeaveResult{Reason: partyErrorMessage(err)}).Encode()})
	}

	if err := sess.Send(&proto.Packet{Opcode: OpPartyLeaveResult, Data: (&PartyLeaveResult{OK: true}).Encode()}); err != nil {
		return err
	}

	if remaining != nil {
		left := &PartyMemberLeft{CharacterID: characterID}
		broadcastToPartyExcept(remaining.Members, sess.ID(), OpPartyMemberLeft, left.Encode())
	}
	return nil
}

// PartyDisconnectHandler returns a func suitable for gateway.Server's
// OnDisconnect hook: removes the disconnecting session's character from
// its party (if any) and notifies whoever's left.
func PartyDisconnectHandler(parties *party.Hub) func(sess *gateway.Session) {
	return func(sess *gateway.Session) {
		characterID, _, remaining, ok, err := parties.LeaveBySession(sess.ID())
		if err != nil || !ok || remaining == nil {
			return
		}
		left := &PartyMemberLeft{CharacterID: characterID}
		broadcastToPartyExcept(remaining.Members, sess.ID(), OpPartyMemberLeft, left.Encode())
	}
}

func partyErrorMessage(err error) string {
	switch {
	case errors.Is(err, party.ErrPartyFull):
		return "party is full"
	case errors.Is(err, party.ErrPartyNotFound):
		return "no such party"
	case errors.Is(err, party.ErrAlreadyInParty):
		return "already in a party"
	case errors.Is(err, party.ErrNotInParty):
		return "not in a party"
	default:
		return "operation failed"
	}
}
