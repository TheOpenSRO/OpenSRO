package session

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"log/slog"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/guild"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
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
	// which OpenSRO does not model, so the client asks instead.
	OpGuildPoints       uint16 = 0x0098 // client -> server
	OpGuildPointsResult uint16 = 0x0099 // server -> client
	// OpGuildLevel reports the requester's guild's level and what the next
	// one costs, and with LevelUp set asks to raise it (round 528): the
	// engine's level-up request is handled by CGuild::HandleLevelUp
	// (0x005c63d0) and answered with 0xb0fa. Placeholder scaffolding like the
	// rest of this block (docs/protocol/PROTOCOL_DECISION.md). 0x009a/0x009b
	// were unused in server/internal and client/scripts when claimed.
	OpGuildLevel       uint16 = 0x009A // client -> server
	OpGuildLevelResult uint16 = 0x009B // server -> client
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

// GuildLevelRequest is the OpGuildLevel payload: a character name, then one
// byte, 1 to level the guild up and 0 only to report its level.
type GuildLevelRequest struct {
	CharacterName string
	LevelUp       bool
}

func (r *GuildLevelRequest) Encode() []byte {
	flag := byte(0)
	if r.LevelUp {
		flag = 1
	}
	return append(encodeStrings(r.CharacterName), flag)
}

func DecodeGuildLevelRequest(data []byte) (*GuildLevelRequest, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding GuildLevelRequest: %w", err)
	}
	if len(rest) != 1 || rest[0] > 1 {
		return nil, errors.New("session: decoding GuildLevelRequest: want one 0/1 byte after the name")
	}
	return &GuildLevelRequest{CharacterName: fields[0], LevelUp: rest[0] == 1}, nil
}

// GuildLevelResult is the OpGuildLevelResult payload. Error, then Code, are
// always sent; on failure (Error != "") nothing follows. Code is the engine's
// refusal code for a level-up the engine would refuse (guild.LevelUpCode:
// 0x4c07, 0x4c0d, 0x4c1e, 0x4c21, 0x4c31, 0x4c32), which the client can show
// in the game's own words, and 0 for OpenSRO's own failures. On success:
// the guild's id, its Level (u8), whether this reply raised it (u8), the
// member cap at that level (u16, guild.MaxMembersFor) and what the next level
// costs in gold and guild points (s64 each, guild.LevelUpCost; both 0 at
// guild.MaxLevel).
type GuildLevelResult struct {
	Error           string
	Code            uint16
	GuildID         int64
	Level           int
	LevelledUp      bool
	MaxMembers      int
	NextGold        int64
	NextGuildPoints int64
}

func (r *GuildLevelResult) Encode() []byte {
	out := encodeStrings(r.Error)
	out = binary.LittleEndian.AppendUint16(out, r.Code)
	if r.Error != "" {
		return out
	}
	out = append(out, encodeInt64(r.GuildID)...)
	levelled := byte(0)
	if r.LevelledUp {
		levelled = 1
	}
	out = append(out, byte(r.Level), levelled)
	out = binary.LittleEndian.AppendUint16(out, uint16(r.MaxMembers))
	out = append(out, encodeInt64(r.NextGold)...)
	return append(out, encodeInt64(r.NextGuildPoints)...)
}

func DecodeGuildLevelResult(data []byte) (*GuildLevelResult, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding GuildLevelResult: %w", err)
	}
	if len(rest) < 2 {
		return nil, errors.New("session: decoding GuildLevelResult: truncated code")
	}
	r := &GuildLevelResult{Error: fields[0], Code: binary.LittleEndian.Uint16(rest)}
	rest = rest[2:]
	if r.Error != "" {
		return r, nil
	}
	if r.GuildID, rest, err = decodeInt64(rest); err != nil {
		return nil, fmt.Errorf("session: decoding GuildLevelResult: guild id: %w", err)
	}
	if len(rest) < 4 {
		return nil, errors.New("session: decoding GuildLevelResult: truncated level")
	}
	r.Level = int(rest[0])
	r.LevelledUp = rest[1] != 0
	r.MaxMembers = int(binary.LittleEndian.Uint16(rest[2:]))
	rest = rest[4:]
	if r.NextGold, rest, err = decodeInt64(rest); err != nil {
		return nil, fmt.Errorf("session: decoding GuildLevelResult: next gold: %w", err)
	}
	if r.NextGuildPoints, _, err = decodeInt64(rest); err != nil {
		return nil, fmt.Errorf("session: decoding GuildLevelResult: next guild points: %w", err)
	}
	return r, nil
}

// guildLevelResult describes g as OpGuildLevelResult does.
func guildLevelResult(g *guild.Guild, levelledUp bool) *GuildLevelResult {
	gold, gp, _ := guild.LevelUpCost(g.Level)
	return &GuildLevelResult{
		GuildID: g.ID, Level: g.Level, LevelledUp: levelledUp,
		MaxMembers: guild.MaxMembersFor(g.Level), NextGold: gold, NextGuildPoints: int64(gp),
	}
}

// GuildHandler returns a gateway.Handler implementing
// OpGuildCreate/OpGuildJoin/OpGuildLeave/OpGuildInfo/OpGuildPoints/
// OpGuildLevel against guilds. hub is the world hub whose life state the
// founder's and the level-up's "must be alive" tests read (round 550); nil
// leaves HP > 0 as the whole of that test, as before.
//
// Round 814: it also answers retail's grant-name request (OpGuildGrantName,
// guildplate.go), and names guilds as the store every character's guild line
// is read from (SetGuildPlateStore).
func GuildHandler(chars character.Store, guilds guild.Store, hub *world.Hub) gateway.Handler {
	SetGuildPlateStore(guilds)
	setGuildBlockDeps(chars, hub)
	ops := guildOpsDeps{chars: chars, guilds: guilds, hub: hub}
	guildOps.Store(&ops)
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		switch p.Opcode {
		// Round 822: the original's requests (guildops.go).
		case guild.OpCreate:
			return handleRetailGuildCreate(ctx, sess, p, ops)
		case guild.OpDisband:
			return handleGuildDisband(ctx, sess, p, ops)
		case guild.OpLeave:
			return handleRetailGuildLeave(ctx, sess, p, ops)
		case guild.OpInvite:
			return handleGuildInvite(ctx, sess, p, ops)
		case guild.OpExpel:
			return handleGuildExpel(ctx, sess, p, ops)
		case OpGuildCreate:
			return handleGuildCreate(ctx, sess, p, chars, guilds, hub)
		case OpGuildJoin:
			return handleGuildJoin(ctx, sess, p, chars, guilds, hub)
		case OpGuildLeave:
			return handleGuildLeave(ctx, sess, p, chars, guilds, hub)
		case OpGuildGrantName:
			return handleGuildGrantName(ctx, sess, p, guilds, hub)
		case OpGuildInfo:
			return handleGuildInfo(ctx, sess, p, chars, guilds)
		case OpGuildPoints:
			return handleGuildPoints(ctx, sess, p, chars, guilds)
		case OpGuildLevel:
			return handleGuildLevel(ctx, sess, p, chars, guilds, hub)
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

// handleGuildLevel answers OpGuildLevel (round 528). A report (LevelUp
// false) sends the requester's guild's level and the next level's cost. A
// level-up is CGuild::HandleLevelUp's (0x005c63d0) path through
// guild.Store.LevelUp, whose ladder (guild.CheckLevelUp) is the engine's
// order: dead 0x4c07, no guild 0x4c0d, not the master 0x4c1e, level 5
// 0x4c21, gold 0x4c31, guild points 0x4c32. Alive is the world hub's life
// state (world.LifeDead, a monster's kill under -player-dead-state, round 550)
// with HP > 0 kept as the stand-in the founder check also keeps for a
// character the hub does not hold -- the engine's test is IGObj::GetLifeState
// == 1 (`mov edx,[eax+0xf8]` at 0x5c63e3, `call edx` at 0x5c63eb, `cmp al,0x1`
// at 0x5c63ed, `mov ax,0x4c07` at 0x5c63f1), else 0x4c07.
//
// The gold goes through chars.DeductGold inside the store's LevelUp (its
// pay step), so a guild never keeps a level it did not pay for. The engine
// takes it with an OffsetGold that cannot refuse, on the ShardManager job's
// reply (trs_sm_guildjob::FUN_005c8fd0); DeductGold can, when the gold was
// spent since the check, and that is reported as the gold refusal, 0x4c31.
// OPENSRO'S OWN HANDLING, the round-487 rollback's counterpart: if the
// store fails after the gold was taken (its UPDATE, read-back or commit),
// the gold is given back with AddGold, and a failed refund is logged.
//
// The refund runs on context.WithoutCancel(ctx) (round 531). ctx is the
// gateway's, which a server stop cancels; a stop that lands between the
// deduction and the guild's UPDATE fails the UPDATE with context.Canceled,
// and a refund on the same ctx would fail the same way and lose the gold.
// WithoutCancel keeps ctx's values and drops its cancellation and deadline.
// It does not close the whole window: main does not wait for connection
// goroutines (round 527, FlushAllPending's comment), so a process that
// exits before the refund's UPDATE returns still loses it. A refund that
// fails (a store already closed, among others) is logged.
//
// A commit error is not proof the level was not kept: a connection that drops
// after the server committed reports an error too (SQLStore.LevelUp). The
// refund then pays back a level the guild kept. OpenSRO takes that side of
// the ambiguity, since the other side loses the player's gold.
//
// The server pushes no gold update (as after founding): the client re-reads
// the character's stats, and the guild's points, after a level-up.
func handleGuildLevel(ctx context.Context, sess *gateway.Session, p *proto.Packet, chars character.Store, guilds guild.Store, hub *world.Hub) error {
	reply := func(r *GuildLevelResult) error {
		return sess.Send(&proto.Packet{Opcode: OpGuildLevelResult, Data: r.Encode()})
	}
	req, err := DecodeGuildLevelRequest(p.Data)
	if err != nil {
		return reply(&GuildLevelResult{Error: "malformed request"})
	}
	characterID, errStr := resolveCharacterID(ctx, sess, chars, req.CharacterName)
	if errStr != "" {
		return reply(&GuildLevelResult{Error: errStr})
	}

	if !req.LevelUp {
		g, err := guilds.GetByCharacter(ctx, characterID)
		if err != nil {
			msg := guildErrorMessage(err)
			if !errors.Is(err, guild.ErrNotInGuild) {
				msg = "failed to load guild level"
			}
			return reply(&GuildLevelResult{Error: msg})
		}
		return reply(guildLevelResult(g, false))
	}

	pc, err := chars.GetByID(ctx, characterID)
	if err != nil {
		return reply(&GuildLevelResult{Error: "lookup failed"})
	}
	var paid int64
	pay := func(gold int64) error {
		if err := chars.DeductGold(ctx, characterID, gold); err != nil {
			if errors.Is(err, character.ErrInsufficientGold) {
				return guild.ErrLevelUpGoldDeficit
			}
			return err
		}
		paid = gold
		return nil
	}
	g, err := guilds.LevelUp(ctx, characterID, pc.HP > 0 && !deadBySession(hub, sess), pc.Gold, pay)
	if err != nil {
		if paid > 0 {
			// Not ctx: a stop that cancelled the level-up must not cancel
			// its refund too (see the doc comment).
			if rerr := chars.AddGold(context.WithoutCancel(ctx), characterID, paid); rerr != nil {
				slog.Warn("guild level-up failed after its gold was taken, and the refund failed",
					"character_id", characterID, "gold", paid, "levelup_err", err, "refund_err", rerr)
			}
		}
		msg := guildErrorMessage(err)
		if guild.LevelUpCode(err) == 0 {
			msg = "failed to level up the guild"
		}
		return reply(&GuildLevelResult{Error: msg, Code: uint16(guild.LevelUpCode(err))})
	}
	// Round 822: the new level and GP to the members in the world (0x38F5
	// type 5).
	guildLevelChanged(ctx, g)
	return reply(guildLevelResult(g, true))
}

func guildMemberSnapshots(members []guild.Member) []GuildMemberSnapshot {
	out := make([]GuildMemberSnapshot, len(members))
	for i, m := range members {
		out[i] = GuildMemberSnapshot{CharacterID: m.CharacterID, Name: m.Name, Role: int32(m.Role)}
	}
	return out
}

func handleGuildCreate(ctx context.Context, sess *gateway.Session, p *proto.Packet, chars character.Store, guilds guild.Store, hub *world.Hub) error {
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
	// Alive is the life state proper since round 550: the world hub's
	// world.LifeDead, which a monster's kill sets under -player-dead-state
	// (deadBySession), with HP > 0 kept as the stand-in for a character the
	// hub does not hold (no hub, or not in the world). The engine asks
	// IGObj::GetLifeState (vtable +0xf8) for 1 in FUN_00514b20 and answers
	// 0x4c07 GUILDERR_IM_DEAD otherwise (guild.md's founder-check table, step
	// 2). HP alone let a dead character through once a GM's /heal had filled
	// its pools without reviving it.
	if err := guild.CheckCreator(founder.HP > 0 && !deadBySession(hub, sess), founder.Level, founder.Gold); err != nil {
		return sess.Send(&proto.Packet{Opcode: OpGuildCreateResult, Data: (&GuildResult{Error: guildErrorMessage(err)}).Encode()})
	}
	// Round 800: FUN_00514b20's fifth step, the job state (vtable +0x11c)
	// not 4 -> 0x4c57 UIIT_CTL_GUILD_CREATE_JOB_ERROR. The error is the
	// client's key, which it resolves (OURS: the reply carries no code).
	if inJobMode(ctx, characterID) {
		return sess.Send(&proto.Packet{Opcode: OpGuildCreateResult, Data: (&GuildResult{Error: "UIIT_CTL_GUILD_CREATE_JOB_ERROR"}).Encode()})
	}

	// The name filter (round 788): SR_ShardManager 0x43b810 runs 0x40f200 --
	// the character name's rule, with the same AbuseFilter group -- after its
	// 2..12-byte test and before the name-exists one, answering 0x4c19. Our
	// store's Create holds the in-a-guild, length and exists tests in the
	// engine's order, so the filter goes between them here: a valid-length
	// name the filter refuses, from a founder in no guild, is refused; any
	// other case is left to Create, which answers as before.
	if guild.ValidName(req.GuildName) && !NameFilter().NameOK(req.GuildName) {
		if _, err := guilds.GuildIDOf(ctx, characterID); errors.Is(err, guild.ErrNotInGuild) {
			return sess.Send(&proto.Packet{Opcode: OpGuildCreateResult, Data: (&GuildResult{Error: guildErrorMessage(guild.ErrNameNotAllowed)}).Encode()})
		}
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
		// OPENSRO'S OWN HANDLING, not the engine's. OffsetGold has no
		// refusal path, but DeductGold can fail here if the gold was spent
		// between the check above and now. Leaving the guild in place would
		// found it for free, so it is taken down again: Leave disbands a guild
		// whose last member goes (both stores). If a second character joined
		// by id in that window, Leave hands it leadership instead of
		// disbanding.
		//
		// The rollback runs on context.WithoutCancel(ctx) (round 531), as
		// handleGuildLevel's refund does: a server stop that cancels ctx
		// fails DeductGold with context.Canceled, and a Leave on the same
		// ctx would fail too and leave the guild founded for free. A process
		// that exits before Leave returns still leaves it (main does not wait
		// for connection goroutines; round 527); a Leave that fails is logged
		// below.
		if _, _, lerr := guilds.Leave(context.WithoutCancel(ctx), characterID); lerr != nil {
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
	if err := sess.Send(&proto.Packet{Opcode: OpGuildCreateResult, Data: result.Encode()}); err != nil {
		return err
	}
	// Round 814: the founder's guild line, to those who see it (READ: the
	// create job's reply trs_sm_guildjob::FUN_005c8bf0 calls FUN_004ea2f0).
	refreshGuildPlate(hub, characterID, g)
	// Round 821: the guild's block, the window's data.
	sendGuildBlock(ctx, sess, g)
	return nil
}

func handleGuildJoin(ctx context.Context, sess *gateway.Session, p *proto.Packet, chars character.Store, guilds guild.Store, hub *world.Hub) error {
	req, err := DecodeGuildJoinRequest(p.Data)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpGuildJoinResult, Data: (&GuildResult{Error: "malformed request"}).Encode()})
	}
	// Round 822: joining by id is OpenSRO's own, a backdoor beside the
	// original's invitation (guildops.go): a GM account's only (the QA bots).
	if !guildJoinAllowed(sess) {
		return sess.Send(&proto.Packet{Opcode: OpGuildJoinResult, Data: (&GuildResult{Error: "UIIT_MSG_GUILDERR_PERMISSION_DENIED"}).Encode()})
	}
	characterID, errStr := resolveCharacterID(ctx, sess, chars, req.CharacterName)
	if errStr != "" {
		return sess.Send(&proto.Packet{Opcode: OpGuildJoinResult, Data: (&GuildResult{Error: errStr}).Encode()})
	}

	// Round 800: a character in a job suit cannot join (gs:0x514c40, 0x4c56
	// UIIT_CTL_GUILD_JOIN_JOB_ERROR).
	if inJobMode(ctx, characterID) {
		return sess.Send(&proto.Packet{Opcode: OpGuildJoinResult, Data: (&GuildResult{Error: "UIIT_CTL_GUILD_JOIN_JOB_ERROR"}).Encode()})
	}
	g, err := guilds.Join(ctx, req.GuildID, characterID, req.CharacterName)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpGuildJoinResult, Data: (&GuildResult{Error: guildErrorMessage(err)}).Encode()})
	}
	result := &GuildResult{GuildID: g.ID, Name: g.Name, LeaderID: g.LeaderID, Members: guildMemberSnapshots(g.Members)}
	if err := sess.Send(&proto.Packet{Opcode: OpGuildJoinResult, Data: result.Encode()}); err != nil {
		return err
	}
	// Round 814: the new member's line (READ: the join job's reply
	// trs_sm_guildjob::FUN_005c8d40 calls FUN_004ea2f0).
	refreshGuildPlate(hub, characterID, g)
	// Round 821: the block, to the new member (s:0x5c8d40) and the members
	// in the world.
	broadcastGuildBlock(ctx, g)
	return nil
}

func handleGuildLeave(ctx context.Context, sess *gateway.Session, p *proto.Packet, chars character.Store, guilds guild.Store, hub *world.Hub) error {
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
	if err := sess.Send(&proto.Packet{Opcode: OpGuildLeaveResult, Data: (&GuildLeaveResult{OK: true}).Encode()}); err != nil {
		return err
	}
	// Round 814: the line goes (OURS: the original's removal path is OPEN).
	refreshGuildPlate(hub, characterID, nil)
	return nil
}

func guildErrorMessage(err error) string {
	switch {
	case errors.Is(err, guild.ErrNameTaken):
		return "guild name already taken"
	case errors.Is(err, guild.ErrInvalidNameLength):
		// 0x4c18 GUILDERR_INVALID_GUILDNAME_LEN; the range is guild.ValidName's.
		return "guild name must be 2 to 12 characters"
	case errors.Is(err, guild.ErrNameNotAllowed):
		// 0x4c19 GUILDERR_NOT_ALLOWED_GUILDNAME. Our wording: OpenSRO's guild
		// wire (0x0090/0x0091) carries a text, not the code.
		return "that guild name is not allowed"
	case errors.Is(err, guild.ErrCreatorDead):
		// 0x4c07 GUILDERR_IM_DEAD. Our wording; the client's text is not used.
		return "cannot found a guild while dead"
	case errors.Is(err, guild.ErrCreatorLevelTooLow):
		// 0x4c0a GUILDERR_TOO_LOW_CREATOR_LEVEL.
		return fmt.Sprintf("a guild founder must be at least level %d", guild.MinCreatorLevel)
	case errors.Is(err, guild.ErrNotEnoughGold):
		// 0x4c0c GUILDERR_NOT_ENOUGH_GOLD.
		return fmt.Sprintf("founding a guild requires %d gold", guild.CreateGoldRequired)
	case errors.Is(err, guild.ErrLevelUpDead):
		// 0x4c07 GUILDERR_IM_DEAD. Our wording.
		return "cannot level up the guild while dead"
	case errors.Is(err, guild.ErrNotGuildMaster):
		// 0x4c1e GUILDERR_PERMISSION_DENIED.
		return "only the guild master can level up the guild"
	case errors.Is(err, guild.ErrLevelUpFull):
		// 0x4c21 ERROR_GUILD_LEVEL_UP_FULL.
		return fmt.Sprintf("the guild is already at the maximum level, %d", guild.MaxLevel)
	case errors.Is(err, guild.ErrLevelUpGoldDeficit):
		// 0x4c31 ERROR_GUILD_LEVEL_UP_GOLD_DEFICIT.
		return "not enough gold to level up the guild"
	case errors.Is(err, guild.ErrLevelUpGPDeficit):
		// 0x4c32 ERROR_GUILD_LEVEL_UP_GP_DEFICIT.
		return "not enough guild points to level up the guild"
	case errors.Is(err, guild.ErrGuildFull):
		// 0x4c13 GUILDERR_MEMBER_FULL; the cap is guild.MaxMembersFor(level).
		return "the guild is full"
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
