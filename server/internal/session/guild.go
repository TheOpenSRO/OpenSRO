package session

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"log/slog"

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
	// OpGuildPoints asks for the guild's points (round 525): GatheredSP and
	// each member's GP_Donation, the two totals CGuild::AddPoints (0x5c4110)
	// raises. Placeholder scaffolding like the rest of this block
	// (docs/protocol/PROTOCOL_DECISION.md): the engine pushes the same two
	// numbers as 0x38F5 types 5 and 6 through CGuild::BroadcastToLocalMember,
	// which srrevamp does not model, so the client asks instead.
	OpGuildPoints       uint16 = 0x0098 // client -> server
	OpGuildPointsResult uint16 = 0x0099 // server -> client
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

// GuildPointsMember is one member's share of the guild's points on the wire:
// the name and _GUILDMEMBER.GP_Donation (guild.Member.GPDonation).
type GuildPointsMember struct {
	Name       string
	GPDonation int64
}

// GuildPointsResult is the OpGuildPointsResult payload: on failure only Error
// is meaningful; on success the guild's id, its GatheredSP and every member's
// GPDonation, in roster order.
type GuildPointsResult struct {
	Error      string
	GuildID    int64
	GatheredSP int64
	Members    []GuildPointsMember
}

func (r *GuildPointsResult) Encode() []byte {
	out := encodeStrings(r.Error)
	if r.Error != "" {
		return out
	}
	out = append(out, encodeInt64(r.GuildID)...)
	out = append(out, encodeInt64(r.GatheredSP)...)
	countBuf := make([]byte, 2)
	binary.LittleEndian.PutUint16(countBuf, uint16(len(r.Members)))
	out = append(out, countBuf...)
	for _, m := range r.Members {
		out = append(out, encodeStrings(m.Name)...)
		out = append(out, encodeInt64(m.GPDonation)...)
	}
	return out
}

func DecodeGuildPointsResult(data []byte) (*GuildPointsResult, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding GuildPointsResult: %w", err)
	}
	r := &GuildPointsResult{Error: fields[0]}
	if r.Error != "" {
		return r, nil
	}
	if r.GuildID, rest, err = decodeInt64(rest); err != nil {
		return nil, fmt.Errorf("session: decoding GuildPointsResult: guild id: %w", err)
	}
	if r.GatheredSP, rest, err = decodeInt64(rest); err != nil {
		return nil, fmt.Errorf("session: decoding GuildPointsResult: gathered sp: %w", err)
	}
	if len(rest) < 2 {
		return nil, errors.New("session: decoding GuildPointsResult: truncated member count")
	}
	count := int(binary.LittleEndian.Uint16(rest))
	rest = rest[2:]
	for i := 0; i < count; i++ {
		var names []string
		if names, rest, err = decodeStringsPrefix(rest, 1); err != nil {
			return nil, fmt.Errorf("session: decoding GuildPointsResult: member %d name: %w", i, err)
		}
		var donation int64
		if donation, rest, err = decodeInt64(rest); err != nil {
			return nil, fmt.Errorf("session: decoding GuildPointsResult: member %d donation: %w", i, err)
		}
		r.Members = append(r.Members, GuildPointsMember{Name: names[0], GPDonation: donation})
	}
	return r, nil
}

// GuildHandler returns a gateway.Handler implementing
// OpGuildCreate/OpGuildJoin/OpGuildLeave/OpGuildInfo/OpGuildPoints against
// guilds.
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
		case OpGuildPoints:
			return handleGuildPoints(ctx, sess, p, chars, guilds)
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

// handleGuildPoints answers OpGuildPoints with the requester's guild's
// GatheredSP and each member's GPDonation (round 525). A character in no guild
// gets an Error, "not in a guild".
func handleGuildPoints(ctx context.Context, sess *gateway.Session, p *proto.Packet, chars character.Store, guilds guild.Store) error {
	req, err := DecodeCharacterNameRequest(p.Data)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpGuildPointsResult, Data: (&GuildPointsResult{Error: "malformed request"}).Encode()})
	}
	characterID, errStr := resolveCharacterID(ctx, sess, chars, req.Name)
	if errStr != "" {
		return sess.Send(&proto.Packet{Opcode: OpGuildPointsResult, Data: (&GuildPointsResult{Error: errStr}).Encode()})
	}
	g, err := guilds.GetByCharacter(ctx, characterID)
	if err != nil {
		msg := guildErrorMessage(err)
		if !errors.Is(err, guild.ErrNotInGuild) {
			msg = "failed to load guild points"
		}
		return sess.Send(&proto.Packet{Opcode: OpGuildPointsResult, Data: (&GuildPointsResult{Error: msg}).Encode()})
	}
	result := &GuildPointsResult{GuildID: g.ID, GatheredSP: g.GatheredSP}
	for _, m := range g.Members {
		result.Members = append(result.Members, GuildPointsMember{Name: m.Name, GPDonation: m.GPDonation})
	}
	return sess.Send(&proto.Packet{Opcode: OpGuildPointsResult, Data: result.Encode()})
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

	// The founder's pre-check, FUN_00514b20, is the first thing
	// CGuildManager::HandleCreateGuild (0x00514ce0) does -- before its
	// name-length test, and before the in-a-guild test that ends the same
	// function -- so it runs ahead of guilds.Create, which holds both. See
	// guild.CheckCreator for the ladder.
	founder, err := chars.GetByID(ctx, characterID)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpGuildCreateResult, Data: (&GuildResult{Error: "lookup failed"}).Encode()})
	}
	// Alive is HP > 0. The engine asks IGObj::GetLifeState (vtable +0xf8) for
	// 1; srrevamp stores no life state, and a character at 0 HP is the one
	// ApplyDamage reports as died.
	if err := guild.CheckCreator(founder.HP > 0, founder.Level, founder.Gold); err != nil {
		return sess.Send(&proto.Packet{Opcode: OpGuildCreateResult, Data: (&GuildResult{Error: guildErrorMessage(err)}).Encode()})
	}

	g, err := guilds.Create(ctx, req.GuildName, characterID, req.CharacterName)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpGuildCreateResult, Data: (&GuildResult{Error: guildErrorMessage(err)}).Encode()})
	}

	// Founding costs guild.CreateGoldRequired, taken once the guild exists:
	// the engine spends it on the create job's reply (trs_sm_guildjob::
	// FUN_005c8bf0 -> GObjPC::FUN_004e4140, OffsetGold(-500000)), after
	// uniqueness is settled. See guild.CreateGoldRequired.
	if err := chars.DeductGold(ctx, characterID, guild.CreateGoldRequired); err != nil {
		// SRREVAMP'S OWN HANDLING, not the engine's. OffsetGold has no
		// refusal path, but DeductGold can fail here if the gold was spent
		// between the check above and now. Leaving the guild in place would
		// found it for free, so it is taken down again: Leave disbands a guild
		// whose last member goes (both stores). If a second character joined
		// by id in that window, Leave hands it leadership instead of
		// disbanding.
		if _, _, lerr := guilds.Leave(ctx, characterID); lerr != nil {
			slog.Warn("guild founded but neither paid for nor rolled back",
				"character_id", characterID, "guild_id", g.ID, "deduct_err", err, "leave_err", lerr)
		}
		msg := guildErrorMessage(guild.ErrNotEnoughGold)
		if !errors.Is(err, character.ErrInsufficientGold) {
			msg = guildErrorMessage(err)
		}
		return sess.Send(&proto.Packet{Opcode: OpGuildCreateResult, Data: (&GuildResult{Error: msg}).Encode()})
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
	case errors.Is(err, guild.ErrCreatorDead):
		// 0x4c07 GUILDERR_IM_DEAD. Our wording; the client's text is not used.
		return "cannot found a guild while dead"
	case errors.Is(err, guild.ErrCreatorLevelTooLow):
		// 0x4c0a GUILDERR_TOO_LOW_CREATOR_LEVEL.
		return fmt.Sprintf("a guild founder must be at least level %d", guild.MinCreatorLevel)
	case errors.Is(err, guild.ErrNotEnoughGold):
		// 0x4c0c GUILDERR_NOT_ENOUGH_GOLD.
		return fmt.Sprintf("founding a guild requires %d gold", guild.CreateGoldRequired)
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
