package guild

import "encoding/binary"

// The retail guild block (round 821, READ from sro_client.exe): the server
// sends it as 0x34B3 (begin: the client's buffer reset, FUN_0087fcd0), one or
// more 0x3101 (its bytes appended, FUN_00883060 -> 0x833380, read in pieces of
// at most 0x1000), and 0x34B4 (end: the buffer parsed, FUN_00887300 ->
// 0x885550 -> CharacterDependentData::FUN_009965e0, then the guild window, the
// guild line and the plates refreshed).
const (
	OpBlockBegin uint16 = 0x34B3
	OpBlockChunk uint16 = 0x3101
	OpBlockEnd   uint16 = 0x34B4
	// BlockChunkSize is the most one 0x3101 carries (OURS: the client reads
	// any length; the original's server sends pieces of 0x1000, INFERRED from
	// the client's reader).
	BlockChunkSize = 0x1000
)

// MemberLive is what the block carries about a member that the guild record
// does not keep: the character's level and model (RefObjID) and whether it
// is in the world.
type MemberLive struct {
	Level    uint8
	RefObjID uint32
	Online   bool
}

func appendString(b []byte, s string) []byte {
	b = binary.LittleEndian.AppendUint16(b, uint16(len(s)))
	return append(b, s...)
}

// EncodeBlock writes the guild block (FUN_009965e0's order, READ):
//
//	u32 guild id, str name, u8 level, u32 GP, str notice title,
//	str notice body, u32 crest revision, u8 soldier flags,
//	u8 n x member {u32 character id, str name, u8 class, u8 level,
//	  u32 GP donation, u32 permission, u32 contribution, u32 war kills,
//	  u32 war deaths, str grant name, u32 RefObjID, u8 siege role,
//	  u8 offline (record +0x26: 0 draws gil_contact_on, 1 gil_contact_off,
//	  the row fill 0x5b6b40)},
//	u8 n x {u32, u8, u32} (FUN_0099d7e0; OpenSRO sends none).
//
// live answers a member's level, model and presence.
func EncodeBlock(g *Guild, live func(characterID int64) MemberLive) []byte {
	b := binary.LittleEndian.AppendUint32(nil, uint32(g.ID))
	b = appendString(b, g.Name)
	b = append(b, byte(g.Level))
	b = binary.LittleEndian.AppendUint32(b, uint32(clampU32(g.GatheredSP)))
	b = appendString(b, g.NoticeTitle)
	b = appendString(b, g.NoticeBody)
	b = binary.LittleEndian.AppendUint32(b, g.CrestRev)
	b = append(b, g.SoldierFlags)
	n := len(g.Members)
	if n > 255 {
		n = 255
	}
	b = append(b, byte(n))
	for _, m := range g.Members[:n] {
		l := live(m.CharacterID)
		b = appendMember(b, m, l)
	}
	return append(b, 0)
}

// appendMember writes one member record (the block's, and 0x38F5's member
// add).
func appendMember(b []byte, m Member, l MemberLive) []byte {
	b = binary.LittleEndian.AppendUint32(b, uint32(m.CharacterID))
	b = appendString(b, m.Name)
	b = append(b, m.MemberClass(), l.Level)
	b = binary.LittleEndian.AppendUint32(b, uint32(clampU32(m.GPDonation)))
	b = binary.LittleEndian.AppendUint32(b, uint32(m.Permission))
	b = binary.LittleEndian.AppendUint32(b, uint32(clampU32(m.Contribution)))
	b = binary.LittleEndian.AppendUint32(b, uint32(clampU32(m.WarKill)))
	b = binary.LittleEndian.AppendUint32(b, uint32(clampU32(m.WarKilled)))
	b = appendString(b, m.Nickname)
	b = binary.LittleEndian.AppendUint32(b, l.RefObjID)
	b = append(b, m.SiegeAuthority)
	if l.Online {
		return append(b, 0)
	}
	return append(b, 1)
}

func clampU32(v int64) int64 {
	if v < 0 {
		return 0
	}
	if v > 0xffffffff {
		return 0xffffffff
	}
	return v
}

// BlockChunks splits a block into 0x3101 bodies of at most BlockChunkSize.
func BlockChunks(block []byte) [][]byte {
	var out [][]byte
	for len(block) > 0 {
		n := min(len(block), BlockChunkSize)
		out = append(out, block[:n])
		block = block[n:]
	}
	return out
}
