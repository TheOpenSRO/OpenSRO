package session

import (
	"context"
	"log/slog"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// The auto potion settings (round 786; docs/protocol/auto_potion.md).
//
// READ: retail's client keeps the Auto potion window's settings on the
// server. CAutoPotion::Send (sro_client.exe 0x82d2e0), called by the
// window's Confirm (0x741590) when anything changed, sends 0x7158 with
// {u8 2, u16 HP, u16 MP, u16 abnormal, u8 delay}; the game server's 0x7158
// handler (GObjPC::FUN_00518c20, SR_GameServer.exe) reads the type byte --
// 0 and 1 are the quick slots, 2 these settings, anything else logs
// "Unhandled Client Config Data Msg Type" -- and type 2's FUN_00407ee0 stores
// the words into the character's _ClientConfig record without checking them,
// and sends no reply. The client reads them back from its character data at
// entry (0x8ab0e0 -> 0x8a7bd0: three u16 and a u8).
//
// OpenSRO takes 0x7158 type 2 as retail sends it and stores the seven bytes
// (character.AutoPotionStore). The quick-slot types 0 and 1 are not stored:
// OpenSRO's bar lives on the client (round 639, HotbarStore, OURS at the
// user's request). The character data is not retail's here, so the client
// asks for the settings once it is in the world (OpAutoPotionLoad, OURS) and
// they come back on OpAutoPotionConfig (OURS), the same seven bytes the
// character data carries. A request rather than a push after the entry, so
// nothing new lands between OpEnterWorldResult and what the client and the
// tools already expect after it.
const (
	// OpAutoPotionSave is retail's 0x7158 (client -> server).
	OpAutoPotionSave uint16 = 0x7158
	// OpAutoPotionConfig is OURS (server -> client): the seven bytes the
	// character data carries in retail, the answer to OpAutoPotionLoad.
	OpAutoPotionConfig uint16 = 0x0116
	// OpAutoPotionLoad is OURS (client -> server, empty): asks for them.
	OpAutoPotionLoad uint16 = 0x0117

	// clientConfigAutoPotion is 0x7158's type byte for these settings
	// (FUN_00518c20's `local_1 == '\x02'`).
	clientConfigAutoPotion = 2
)

// AutoPotionHandler stores 0x7158 type 2 for the session's character in
// store (nil: dropped) and answers OpAutoPotionLoad with what is stored. A
// malformed 0x7158 and the quick-slot types are ignored; a save is not
// answered, as retail answers nothing.
func AutoPotionHandler(store character.AutoPotionStore, hub *world.Hub, logger *slog.Logger) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		if p.Opcode == OpAutoPotionLoad {
			return autoPotionLoad(ctx, sess, store, hub)
		}
		if p.Opcode != OpAutoPotionSave {
			return nil
		}
		if store == nil || hub == nil || len(p.Data) < 1+character.AutoPotionSize || p.Data[0] != clientConfigAutoPotion {
			return nil
		}
		e, ok := hub.EntityBySession(sess.ID())
		if !ok {
			return nil
		}
		settings := append([]byte(nil), p.Data[1:1+character.AutoPotionSize]...)
		if err := store.SetAutoPotion(ctx, e.CharacterID, settings); err != nil && logger != nil {
			logger.Warn("auto potion: saving the settings failed", "character", e.CharacterID, "err", err)
		}
		return nil
	}
}

// autoPotionLoad answers the session's character's saved settings -- seven
// zero bytes when none were saved, which the client turns into retail's
// defaults as 0x8a7c0d..0x8a7c44 does for a zero delay byte. A session not
// in the world is not answered.
func autoPotionLoad(ctx context.Context, sess *gateway.Session, store character.AutoPotionStore, hub *world.Hub) error {
	if hub == nil {
		return nil
	}
	e, ok := hub.EntityBySession(sess.ID())
	if !ok {
		return nil
	}
	var settings []byte
	if store != nil {
		settings, _ = store.AutoPotion(ctx, e.CharacterID)
	}
	if len(settings) != character.AutoPotionSize {
		settings = make([]byte, character.AutoPotionSize)
	}
	return sess.Send(&proto.Packet{Opcode: OpAutoPotionConfig, Data: settings})
}
