package session

// Round 844 lane G (part 2): the GP usage history, the guild manager's line
// 0x43 (READ): 0x7501 {u32 NPC} (c:0x8206c0); the GameServer (s:0x517e90)
// answers B501 {2, 3} without the talk or a guild manager, {2, 0x4c0d} without
// a guild, else B501 {1, u8 n, n x {u32 time_t, str name, u32 GP, u8 kind}}
// (s:0x5d1560 / 0x5d6090), newest first. No rank is checked.

import (
	"context"
	"encoding/binary"
	"log/slog"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/guild"
)

const (
	OpGPHistory       uint16 = 0x7501
	OpGPHistoryResult uint16 = 0xB501
)

// EncodeGPHistory is B501's success.
func EncodeGPHistory(list []guild.GPHistoryEntry) []byte {
	n := len(list)
	if n > 255 {
		n = 255
	}
	b := []byte{1, byte(n)}
	for _, e := range list[:n] {
		b = binary.LittleEndian.AppendUint32(b, uint32(e.At.Unix()))
		b = binary.LittleEndian.AppendUint16(b, uint16(len(e.Name)))
		b = append(b, e.Name...)
		b = binary.LittleEndian.AppendUint32(b, uint32(e.GP))
		b = append(b, e.Kind)
	}
	return b
}

func (d guildOpsDeps) handleGPHistory(ctx context.Context, sess *gateway.Session, data []byte) error {
	if len(data) < 4 || d.hub == nil {
		return nil
	}
	e, ok := d.hub.EntityBySession(sess.ID())
	if !ok {
		return nil
	}
	if !guildNPCInReach(e, binary.LittleEndian.Uint32(data)) {
		sendGuild(sess, OpGPHistoryResult, guild.EncodeFail(guild.CodeNotInRange))
		return nil
	}
	gid, err := d.guilds.GuildIDOf(ctx, e.CharacterID)
	if err != nil {
		sendGuild(sess, OpGPHistoryResult, guild.EncodeFail(guild.CodeNotInGuild))
		return nil
	}
	var list []guild.GPHistoryEntry
	if hs, ok := d.guilds.(guild.GPHistoryStore); ok {
		list, err = hs.GPHistory(ctx, gid, time.Now())
		if err != nil {
			slog.Warn("guild GP history not read", "guild_id", gid, "err", err)
		}
	}
	sendGuild(sess, OpGPHistoryResult, EncodeGPHistory(list))
	return nil
}

// logGPUse records GP spent (the ShardManager's _AddGPHistory: the level-up
// as kind 5, a guild store purchase as kind 6).
func logGPUse(ctx context.Context, guilds guild.Store, guildID int64, name string, gp int64, kind uint8) {
	hs, ok := guilds.(guild.GPHistoryStore)
	if !ok || gp <= 0 {
		return
	}
	if err := hs.AddGPHistory(ctx, guildID, guild.GPHistoryEntry{At: time.Now(), Name: name, GP: gp, Kind: kind}); err != nil {
		slog.Warn("guild GP history not saved", "guild_id", guildID, "err", err)
	}
}
