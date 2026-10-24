package session

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"sync/atomic"

	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/guild"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Round 814: the guild line over a character -- `[Guild * Grant]`, or
// `[Guild]` without a grant name -- and a member setting their own grant name
// (docs/protocol/guild_plate.md). The line's data rides the player's spawn
// record (pcspawn's guild name and block, filled from guildPlateOf) and two
// retail updates; the grant name is set with retail's request and reply.
const (
	// OpGuildGrantName is the client's grant-name request (READ: the game
	// server's GObjPC_HandleGuildMsg_256 0x517b70 reads u32 target character
	// id, then the name; FUN_005c7560 validates it).
	OpGuildGrantName uint16 = 0x7256
	// OpGuildGrantNameResult answers it (READ: a refusal is
	// Msg_SendTwoFieldReply's {u8 2, u16 code}; the client's handler
	// FUN_0088f9e0 reads success as u8 1, u32, u32 -- the target, looked up
	// in the guild roster by FUN_00996040 -- and the name, and shows
	// UIIT_MSG_GUILD_NAME_GRANT_RESULT). The first u32 is INFERRED the
	// guild's id.
	OpGuildGrantNameResult uint16 = 0xB256
	// OpGuildNicknameUpdate tells the guild a member's grant name (READ: the
	// client's FUN_008905d0 reads u32, the character's name, the grant name;
	// finds the character by name and sets its nickname, CICUser+0x7c8, and
	// the guild window's row). Sent by the server's CMainProcess::FUN_005cc070
	// on the ShardManager job's reply; that it goes to the guild's members is
	// INFERRED. The first u32 is INFERRED the guild's id.
	OpGuildNicknameUpdate uint16 = 0x3256
	// OpEntityGuildUpdate re-describes one character's guild to those who see
	// it (READ: the client's FUN_0088a420 reads u32 uid, u32 guild id, the
	// guild name, and with a name the grant name, three u32, the fortress
	// role byte and FUN_005cffe0's byte -- this order, unlike the spawn's;
	// the server's FUN_004ea2f0 sends it from the guild create and join
	// replies, CGObjPC::vslot_391 and FUN_005c50b0). An empty name changes
	// nothing in the original's client (OPEN how it drops a plate); OpenSRO's
	// client drops the line (OURS).
	OpEntityGuildUpdate uint16 = 0x30FF
)

// GuildGrantNameRequest is 0x7256.
type GuildGrantNameRequest struct {
	TargetID uint32
	Nickname string
}

// Encode is the request's bytes.
func (r *GuildGrantNameRequest) Encode() []byte {
	out := binary.LittleEndian.AppendUint32(nil, r.TargetID)
	return appendWireString(out, r.Nickname)
}

// DecodeGuildGrantNameRequest reads one.
func DecodeGuildGrantNameRequest(b []byte) (*GuildGrantNameRequest, error) {
	if len(b) < 6 {
		return nil, errors.New("session: grant name request truncated")
	}
	n := int(binary.LittleEndian.Uint16(b[4:]))
	if len(b) != 6+n {
		return nil, fmt.Errorf("session: grant name request: a %d-byte name in %d bytes", n, len(b)-6)
	}
	return &GuildGrantNameRequest{TargetID: binary.LittleEndian.Uint32(b), Nickname: string(b[6:])}, nil
}

// GuildGrantNameResult is 0xB256: OK with the guild, the target and the name,
// or a refusal Code.
type GuildGrantNameResult struct {
	OK       bool
	Code     uint16
	GuildID  uint32
	TargetID uint32
	Nickname string
}

// Encode is the result's bytes.
func (r *GuildGrantNameResult) Encode() []byte {
	if !r.OK {
		return binary.LittleEndian.AppendUint16([]byte{2}, r.Code)
	}
	out := binary.LittleEndian.AppendUint32([]byte{1}, r.GuildID)
	out = binary.LittleEndian.AppendUint32(out, r.TargetID)
	return appendWireString(out, r.Nickname)
}

// GuildNicknameUpdate is 0x3256.
type GuildNicknameUpdate struct {
	GuildID       uint32
	CharacterName string
	Nickname      string
}

// Encode is the update's bytes.
func (u *GuildNicknameUpdate) Encode() []byte {
	out := binary.LittleEndian.AppendUint32(nil, u.GuildID)
	out = appendWireString(out, u.CharacterName)
	return appendWireString(out, u.Nickname)
}

// EntityGuildUpdate is 0x30FF: one character's guild line, or none (an empty
// GuildName). The three u32 and two bytes after the grant name are written
// 0 (no crests, unions or fortress roles in OpenSRO, OPEN).
type EntityGuildUpdate struct {
	UID       uint32
	GuildID   uint32
	GuildName string
	Nickname  string
}

// Encode is the update's bytes.
func (u *EntityGuildUpdate) Encode() []byte {
	out := binary.LittleEndian.AppendUint32(nil, u.UID)
	out = binary.LittleEndian.AppendUint32(out, u.GuildID)
	out = appendWireString(out, u.GuildName)
	if u.GuildName == "" {
		return out
	}
	out = appendWireString(out, u.Nickname)
	out = append(out, make([]byte, 12)...)
	return append(out, 0, 0) // the fortress role, FUN_005cffe0's byte
}

func appendWireString(out []byte, s string) []byte {
	out = binary.LittleEndian.AppendUint16(out, uint16(len(s)))
	return append(out, s...)
}

// guildPlate is what a character's guild line shows: its guild (ID 0: none)
// and its grant name.
type guildPlate struct {
	ID       uint32
	Name     string
	Nickname string
}

// guildPlates caches each character's line (characterID -> guildPlate), so
// a spawn record never waits on the guild store; dropped and re-read on
// every change (refreshGuildPlate).
var guildPlates sync.Map

// guildStoreBox holds the guild store guildPlateOf reads (GuildHandler sets
// it; nil while there is none -- every character then has no line).
type guildStoreBox struct{ s guild.Store }

var guildPlateStore atomic.Pointer[guildStoreBox]

// SetGuildPlateStore names the store character lines are read from
// (GuildHandler does it; tests too). nil reads no lines.
func SetGuildPlateStore(s guild.Store) {
	guildPlates.Range(func(k, _ any) bool {
		guildPlates.Delete(k)
		return true
	})
	if s == nil {
		guildPlateStore.Store(nil)
		setGuildBlockDeps(nil, nil)
		return
	}
	guildPlateStore.Store(&guildStoreBox{s: s})
}

// guildPlateOf is characterID's line: cached, else read from the store (a
// store error reads as no line and is not cached).
func guildPlateOf(ctx context.Context, characterID int64) guildPlate {
	if v, ok := guildPlates.Load(characterID); ok {
		return v.(guildPlate)
	}
	box := guildPlateStore.Load()
	if box == nil {
		return guildPlate{}
	}
	g, err := box.s.GetByCharacter(ctx, characterID)
	if errors.Is(err, guild.ErrNotInGuild) {
		guildPlates.Store(characterID, guildPlate{})
		return guildPlate{}
	}
	if err != nil {
		return guildPlate{}
	}
	p := plateOf(g, characterID)
	guildPlates.Store(characterID, p)
	return p
}

// plateOf is characterID's line in g (nil g: none).
func plateOf(g *guild.Guild, characterID int64) guildPlate {
	if g == nil {
		return guildPlate{}
	}
	p := guildPlate{ID: uint32(g.ID), Name: g.Name}
	for _, m := range g.Members {
		if m.CharacterID == characterID {
			p.Nickname = m.Nickname
		}
	}
	return p
}

// refreshGuildPlate files characterID's new line and, when it changed, tells
// everyone who sees the character -- itself included -- with an
// OpEntityGuildUpdate (OURS: the original sends it on a create or a join;
// OpenSRO on every change, a leave and a grant name too, so a viewer's line
// is never stale), its spawn record re-read (bumpPlayerState via
// sendAboutOwner).
func refreshGuildPlate(hub *world.Hub, characterID int64, g *guild.Guild) {
	p := plateOf(g, characterID)
	if v, ok := guildPlates.Load(characterID); ok && v.(guildPlate) == p {
		return
	}
	guildPlates.Store(characterID, p)
	msg := &EntityGuildUpdate{UID: uint32(characterID), GuildID: p.ID, GuildName: p.Name, Nickname: p.Nickname}
	sendAboutOwner(equipObservers(hub, characterID), characterID, OpEntityGuildUpdate, msg.Encode())
}

// guildNicknameToMembers sends g's online members an OpGuildNicknameUpdate
// for one member's grant name (the guild window's row and, for a member in
// view, the line).
func guildNicknameToMembers(hub *world.Hub, g *guild.Guild, name, nickname string) {
	if hub == nil || g == nil {
		return
	}
	msg := &GuildNicknameUpdate{GuildID: uint32(g.ID), CharacterName: name, Nickname: nickname}
	f, err := gateway.NewFrame(&proto.Packet{Opcode: OpGuildNicknameUpdate, Data: msg.Encode()})
	if err != nil {
		return
	}
	for _, m := range g.Members {
		if e, ok := hub.EntityByCharacterID(m.CharacterID); ok && e.Session != nil {
			_ = e.Session.SendFrames(f)
		}
	}
}

// handleGuildGrantName answers 0x7256: the sender's own grant name (OURS: the
// target must be the sender; guild.CheckNickname has the ladder).
func handleGuildGrantName(ctx context.Context, sess *gateway.Session, p *proto.Packet, guilds guild.Store, hub *world.Hub) error {
	if hub == nil {
		return nil
	}
	e, ok := hub.EntityBySession(sess.ID())
	if !ok {
		return nil
	}
	req, err := DecodeGuildGrantNameRequest(p.Data)
	if err != nil {
		return nil
	}
	refuse := func(code int) error {
		return sess.Send(&proto.Packet{Opcode: OpGuildGrantNameResult, Data: (&GuildGrantNameResult{Code: uint16(code)}).Encode()})
	}
	g, err := guilds.SetNickname(ctx, e.CharacterID, int64(req.TargetID), req.Nickname, func(s string) bool { return NameFilter().NameOK(s) })
	if err != nil {
		code := guild.NicknameCode(err)
		if code == 0 {
			slog.Warn("guild grant name failed", "character_id", e.CharacterID, "err", err)
			code = 0x4c0d // OURS: a store failure answers as "not in a guild"
		}
		return refuse(code)
	}
	res := &GuildGrantNameResult{OK: true, GuildID: uint32(g.ID), TargetID: req.TargetID, Nickname: req.Nickname}
	if err := sess.Send(&proto.Packet{Opcode: OpGuildGrantNameResult, Data: res.Encode()}); err != nil {
		return err
	}
	guildNicknameToMembers(hub, g, e.Name, req.Nickname)
	refreshGuildPlate(hub, e.CharacterID, g)
	// Round 821: the member rows' grant names.
	broadcastGuildBlock(ctx, g)
	return nil
}

// sendOwnGuildLine tells a character entering the world its own guild line
// (nothing without a guild).
func sendOwnGuildLine(ctx context.Context, sess *gateway.Session, characterID int64) {
	if sess == nil {
		return
	}
	if pkt := ownGuildLine(ctx, characterID); pkt != nil {
		_ = sess.Send(pkt)
	}
}

// ownGuildLine is characterID's own OpEntityGuildUpdate, nil without a guild.
func ownGuildLine(ctx context.Context, characterID int64) *proto.Packet {
	p := guildPlateOf(ctx, characterID)
	if p.Name == "" {
		return nil
	}
	msg := &EntityGuildUpdate{UID: uint32(characterID), GuildID: p.ID, GuildName: p.Name, Nickname: p.Nickname}
	return &proto.Packet{Opcode: OpEntityGuildUpdate, Data: msg.Encode()}
}
