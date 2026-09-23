package session

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"

	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/guild"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
)

// Guild opcodes, our own protocol. All require a prior OpLogin. Unlike
// party, guild membership is persistent and Store has no notion of which
// members are currently online, so there are no broadcast opcodes here --
// a client learns about roster changes by re-requesting (join/leave both
// return the current roster to the caller).
const (
	OpGuildCreate       uint16 = 0x0090 // client -> server
	OpGuildCreateResult uint16 = 0x0091 // server -> client
	OpGuildJoin         uint16 = 0x0092 // client -> server
	OpGuildJoinResult   uint16 = 0x0093 // server -> client
	OpGuildLeave        uint16 = 0x0094 // client -> server
	OpGuildLeaveResult  uint16 = 0x0095 // server -> client
	OpGuildInfo         uint16 = 0x0096 // client -> server
	OpGuildInfoResult   uint16 = 0x0097 // server -> client
)

// GuildMemberSnapshot is one guild member, as sent over the wire.
type GuildMemberSnapshot struct {
	CharacterID int64
	Name        string
	Role        int32
}

func (m *GuildMemberSnapshot) Encode() []byte {
	out := append(encodeInt64(m.CharacterID), encodeStrings(m.Name)...)
	roleBuf := make([]byte, 4)
	binary.LittleEndian.PutUint32(roleBuf, uint32(m.Role))
	return append(out, roleBuf...)
}

func decodeGuildMemberSnapshot(data []byte) (*GuildMemberSnapshot, []byte, error) {
	id, rest, err := decodeInt64(data)
	if err != nil {
		return nil, nil, fmt.Errorf("character id: %w", err)
	}
	names, rest, err := decodeStringsPrefix(rest, 1)
	if err != nil {
		return nil, nil, fmt.Errorf("name: %w", err)
	}
	if len(rest) < 4 {
		return nil, nil, errors.New("truncated role")
	}
	role := int32(binary.LittleEndian.Uint32(rest))
	return &GuildMemberSnapshot{CharacterID: id, Name: names[0], Role: role}, rest[4:], nil
}

// GuildResult is shared by OpGuildCreateResult and OpGuildJoinResult: on
// failure only Error is meaningful; on success GuildID/Name/LeaderID and
// Members describe the full current roster.
type GuildResult struct {
	Error    string
	GuildID  int64
	Name     string
	LeaderID int64
	Members  []GuildMemberSnapshot
}

func (r *GuildResult) Encode() []byte {
	out := encodeStrings(r.Error)
	if r.Error != "" {
		return out
	}
	out = append(out, encodeInt64(r.GuildID)...)
	out = append(out, encodeStrings(r.Name)...)
	out = append(out, encodeInt64(r.LeaderID)...)
	countBuf := make([]byte, 2)
	binary.LittleEndian.PutUint16(countBuf, uint16(len(r.Members)))
	out = append(out, countBuf...)
	for _, m := range r.Members {
		out = append(out, m.Encode()...)
	}
	return out
}

func DecodeGuildResult(data []byte) (*GuildResult, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding GuildResult: %w", err)
	}
	r := &GuildResult{Error: fields[0]}
	if r.Error != "" {
		return r, nil
	}

	guildID, rest, err := decodeInt64(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding GuildResult: guild id: %w", err)
	}
	r.GuildID = guildID

	names, rest, err := decodeStringsPrefix(rest, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding GuildResult: name: %w", err)
	}
	r.Name = names[0]

	leaderID, rest, err := decodeInt64(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding GuildResult: leader id: %w", err)
	}
	r.LeaderID = leaderID

	if len(rest) < 2 {
		return nil, errors.New("session: decoding GuildResult: truncated member count")
	}
	count := int(binary.LittleEndian.Uint16(rest))
	rest = rest[2:]
	for i := 0; i < count; i++ {
		var snap *GuildMemberSnapshot
		snap, rest, err = decodeGuildMemberSnapshot(rest)
		if err != nil {
			return nil, fmt.Errorf("session: decoding GuildResult: member %d: %w", i, err)
		}
		r.Members = append(r.Members, *snap)
	}
	return r, nil
}

// GuildJoinRequest is the OpGuildJoin payload.
type GuildJoinRequest struct {
	CharacterName string
	GuildID       int64
}

func (r *GuildJoinRequest) Encode() []byte {
	return append(encodeStrings(r.CharacterName), encodeInt64(r.GuildID)...)
}

func DecodeGuildJoinRequest(data []byte) (*GuildJoinRequest, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding GuildJoinRequest: %w", err)
	}
	guildID, _, err := decodeInt64(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding GuildJoinRequest: guild id: %w", err)
	}
	return &GuildJoinRequest{CharacterName: fields[0], GuildID: guildID}, nil
}

// GuildCreateRequest is the OpGuildCreate payload: a character name and the
// guild name to found.
type GuildCreateRequest struct {
	CharacterName string
	GuildName     string
}

func (r *GuildCreateRequest) Encode() []byte {
	return append(encodeStrings(r.CharacterName), encodeStrings(r.GuildName)...)
}

func DecodeGuildCreateRequest(data []byte) (*GuildCreateRequest, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding GuildCreateRequest: %w", err)
	}
	guildNames, _, err := decodeStringsPrefix(rest, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding GuildCreateRequest: guild name: %w", err)
	}
	return &GuildCreateRequest{CharacterName: fields[0], GuildName: guildNames[0]}, nil
}

// GuildLeaveResult is the OpGuildLeaveResult payload.
type GuildLeaveResult struct {
	OK     bool
	Reason string
}

func (r *GuildLeaveResult) Encode() []byte { return encodeOKReason(r.OK, r.Reason) }

func DecodeGuildLeaveResult(data []byte) (*GuildLeaveResult, error) {
	ok, reason, err := decodeOKReason(data)
	if err != nil {
		return nil, fmt.Errorf("session: decoding GuildLeaveResult: %w", err)
	}
	return &GuildLeaveResult{OK: ok, Reason: reason}, nil
}

// GuildHandler returns a gateway.Handler implementing
// OpGuildCreate/OpGuildJoin/OpGuildLeave against guilds.
func GuildHandler(chars character.Store, guilds guild.Store) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		switch p.Opcode {
		case OpGuildCreate:
			return handleGuildCreate(ctx, sess, p, chars, guilds)
		case OpGuildJoin:
			return handleGuildJoin(ctx, sess, p, chars, guilds)
		case OpGuildLeave:
			return handleGuildLeave(ctx, sess, p, chars, guilds)
		case OpGuildInfo:
			return handleGuildInfo(ctx, sess, p, chars, guilds)
		default:
			return nil
		}
	}
}

// handleGuildInfo answers "am I already in a guild?" -- important
// specifically because guild membership is persistent: a client that just
// logged in (possibly for the first time this session) otherwise has no
// way to learn about an existing guild except by trying to Create/Join and
// getting ErrAlreadyInGuild back. Reuses GuildResult's shape: GuildID == 0
// and no members means "not in a guild" (real guild IDs start at 1).
func handleGuildInfo(ctx context.Context, sess *gateway.Session, p *proto.Packet, chars character.Store, guilds guild.Store) error {
	req, err := DecodeCharacterNameRequest(p.Data)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpGuildInfoResult, Data: (&GuildResult{Error: "malformed request"}).Encode()})
	}
	characterID, errStr := resolveCharacterID(ctx, sess, chars, req.Name)
	if errStr != "" {
		return sess.Send(&proto.Packet{Opcode: OpGuildInfoResult, Data: (&GuildResult{Error: errStr}).Encode()})
	}

	g, err := guilds.GetByCharacter(ctx, characterID)
	if errors.Is(err, guild.ErrNotInGuild) {
		return sess.Send(&proto.Packet{Opcode: OpGuildInfoResult, Data: (&GuildResult{}).Encode()})
	}
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpGuildInfoResult, Data: (&GuildResult{Error: "failed to load guild info"}).Encode()})
	}
	result := &GuildResult{GuildID: g.ID, Name: g.Name, LeaderID: g.LeaderID, Members: guildMemberSnapshots(g.Members)}
	return sess.Send(&proto.Packet{Opcode: OpGuildInfoResult, Data: result.Encode()})
}

func guildMemberSnapshots(members []guild.Member) []GuildMemberSnapshot {
	out := make([]GuildMemberSnapshot, len(members))
	for i, m := range members {
		out[i] = GuildMemberSnapshot{CharacterID: m.CharacterID, Name: m.Name, Role: int32(m.Role)}
	}
	return out
}

func handleGuildCreate(ctx context.Context, sess *gateway.Session, p *proto.Packet, chars character.Store, guilds guild.Store) error {
	req, err := DecodeGuildCreateRequest(p.Data)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpGuildCreateResult, Data: (&GuildResult{Error: "malformed request"}).Encode()})
	}
	characterID, errStr := resolveCharacterID(ctx, sess, chars, req.CharacterName)
	if errStr != "" {
		return sess.Send(&proto.Packet{Opcode: OpGuildCreateResult, Data: (&GuildResult{Error: errStr}).Encode()})
	}

	g, err := guilds.Create(ctx, req.GuildName, characterID, req.CharacterName)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpGuildCreateResult, Data: (&GuildResult{Error: guildErrorMessage(err)}).Encode()})
	}
	result := &GuildResult{GuildID: g.ID, Name: g.Name, LeaderID: g.LeaderID, Members: guildMemberSnapshots(g.Members)}
	return sess.Send(&proto.Packet{Opcode: OpGuildCreateResult, Data: result.Encode()})
}

func handleGuildJoin(ctx context.Context, sess *gateway.Session, p *proto.Packet, chars character.Store, guilds guild.Store) error {
	req, err := DecodeGuildJoinRequest(p.Data)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpGuildJoinResult, Data: (&GuildResult{Error: "malformed request"}).Encode()})
	}
	characterID, errStr := resolveCharacterID(ctx, sess, chars, req.CharacterName)
	if errStr != "" {
		return sess.Send(&proto.Packet{Opcode: OpGuildJoinResult, Data: (&GuildResult{Error: errStr}).Encode()})
	}

	g, err := guilds.Join(ctx, req.GuildID, characterID, req.CharacterName)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpGuildJoinResult, Data: (&GuildResult{Error: guildErrorMessage(err)}).Encode()})
	}
	result := &GuildResult{GuildID: g.ID, Name: g.Name, LeaderID: g.LeaderID, Members: guildMemberSnapshots(g.Members)}
	return sess.Send(&proto.Packet{Opcode: OpGuildJoinResult, Data: result.Encode()})
}

func handleGuildLeave(ctx context.Context, sess *gateway.Session, p *proto.Packet, chars character.Store, guilds guild.Store) error {
	req, err := DecodeCharacterNameRequest(p.Data)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpGuildLeaveResult, Data: (&GuildLeaveResult{Reason: "malformed request"}).Encode()})
	}
	characterID, errStr := resolveCharacterID(ctx, sess, chars, req.Name)
	if errStr != "" {
		return sess.Send(&proto.Packet{Opcode: OpGuildLeaveResult, Data: (&GuildLeaveResult{Reason: errStr}).Encode()})
	}

	if _, _, err := guilds.Leave(ctx, characterID); err != nil {
		return sess.Send(&proto.Packet{Opcode: OpGuildLeaveResult, Data: (&GuildLeaveResult{Reason: guildErrorMessage(err)}).Encode()})
	}
	return sess.Send(&proto.Packet{Opcode: OpGuildLeaveResult, Data: (&GuildLeaveResult{OK: true}).Encode()})
}

func guildErrorMessage(err error) string {
	switch {
	case errors.Is(err, guild.ErrNameTaken):
		return "guild name already taken"
	case errors.Is(err, guild.ErrInvalidNameLength):
		// 0x4c18 GUILDERR_INVALID_GUILDNAME_LEN; the range is guild.ValidName's.
		return "guild name must be 2 to 12 characters"
	case errors.Is(err, guild.ErrGuildNotFound):
		return "no such guild"
	case errors.Is(err, guild.ErrAlreadyInGuild):
		return "already in a guild"
	case errors.Is(err, guild.ErrNotInGuild):
		return "not in a guild"
	default:
		return "operation failed"
	}
}
