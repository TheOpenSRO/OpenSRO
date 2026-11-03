package session

import "github.com/TheOpenSRO/OpenSRO/server/internal/world"

// OpLevelUpEffect is retail's 0x3054 for a character (round 859): u32 the
// object that levelled. The retail GameServer's GObjPC_SetLevel (s:0x4e4d90,
// called at s:0x4e555e) sends it before the HP update and the 0x3056 (round
// 716, killshare.go); a COS's level-up sends the same opcode with the COS's
// id (cos.OpCOSLevelUp, cosexp.go). The client's handler (c:0x8a7020) plays
// SYSTEM_LEVELUP on that body for everyone who sees it, SYSTEM_PET_LEVEL_UP
// for a COS, and snd_levup only for the owner. Until this round OpenSRO told
// a level-up only to the character itself (OpLevelUp, its own 0x0067), so
// nobody else saw it.
//
// OURS: the audience is sendAboutOwner's (the character's own client and every
// client that holds its body), the interest area this server uses for every
// broadcast about a character; the engine's region broadcast was not traced
// to its receivers.
const OpLevelUpEffect uint16 = 0x3054

// LevelUpEffect is the 0x3054 payload.
func LevelUpEffect(characterID int64) []byte {
	return uint32LE(uint32(characterID))
}

// announceLevelUp sends 0x3054 for characterID to everyone in view of it,
// the character included. Called once for each OpLevelUp the character is
// sent, just before it.
func announceLevelUp(hub *world.Hub, characterID int64) {
	if hub == nil {
		return
	}
	sendAboutOwner(zoneOf(hub, characterID), characterID, OpLevelUpEffect, LevelUpEffect(characterID))
}
