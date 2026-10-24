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

// The guild requests and replies (round 822, READ; the client's senders and
// handlers in docs/protocol/guild.md, "Membership (round 822)").
const (
	OpCreate           uint16 = 0x70F0 // {u32 npc, str name}
	OpCreateResult     uint16 = 0xB0F0 // {1, block} | {2, u16} | {2, 0x4c3c, u32 seconds}
	OpDisband          uint16 = 0x70F1 // {u32 npc}
	OpDisbandResult    uint16 = 0xB0F1
	OpLeave            uint16 = 0x70F2 // {u32 npc}
	OpLeaveResult      uint16 = 0xB0F2
	OpInvite           uint16 = 0x70F3 // {u32 target uid}
	OpInviteResult     uint16 = 0xB0F3 // to the inviter
	OpExpel            uint16 = 0x70F4 // {str member name}
	OpExpelResult      uint16 = 0xB0F4
	OpJoinResult       uint16 = 0xB0F8 // to the invitee
	OpUpdate           uint16 = 0x38F5 // the guild update, by type
	OpObjectLeft       uint16 = 0x3100 // {u32 uid}: drop that player's guild line
	OpRequest          uint16 = 0x3080 // the request prompt; kind 5 a guild invitation
	RequestGuildInvite byte   = 5
)

// The refusal codes these replies carry (READ, s:0x514f10, 0x514c40,
// 0x515070, 0x5151d0, 0x515340, 0x5c60b0, 0x5c6870; the client's names).
const (
	CodeNotInRange       uint16 = 3      // out of reach, not a player, dead
	CodeTargetBusy       uint16 = 0x4c06 // GUILDERR_TARGET_BUSY
	CodeNotInGuild       uint16 = 0x4c0d
	CodeInviteTimeout    uint16 = 0x4c10 // the invitation's 30 s ran out (trs_wait_response::OnTimeout 0x46ce51)
	CodeExistingMember   uint16 = 0x4c12 // GUILDERR_EXISTING_MEMBER
	CodeGuildFull        uint16 = 0x4c13 // GUILDERR_MEMBER_FULL
	CodeJoinRefused      uint16 = 0x4c16 // GUILDERR_JOIN_GUILD_REFUSED (the invitee's "no")
	CodeOtherGuild       uint16 = 0x4c17 // GUILDERR_MEMBER_OF_ANOTHER_GUILD
	CodeCantFindMember   uint16 = 0x4c1d
	CodePermissionDenied uint16 = 0x4c1e // GUILDERR_PERMISSION_DENIED
	CodeMasterCannot     uint16 = 0x4c1f // GUILD_EXPULSION_NOTEXP
	CodeExpelSelf        uint16 = 0x4c36 // GUILD_EXPULSION_NOTEXP
	CodeCreatePenalty    uint16 = 0x4c3c // GUILDWARERR_GUILD_CREATE_PENALTY (+ u32 seconds)
	CodeJoinPenalty      uint16 = 0x4c3d // GUILD_PENALTY
	CodeAtWar            uint16 = 0x4c46 // GUILD_ERROR_BREAK_WAR
	CodeStorageInUse     uint16 = 0x4c48 // GUILD_WAREHOUSE_INTERRUPT
	CodeJoinJob          uint16 = 0x4c56 // CTL_GUILD_JOIN_JOB_ERROR
)

// 0x38F5's types (READ, the client's FUN_00887330).
const (
	UpdateDisbanded = 1 // no body
	UpdateMemberAdd = 2 // the member record
	UpdateMemberOut = 3 // u32 id, u8 reason
	UpdateGuild     = 5 // u8 mask, fields
	UpdateMember    = 6 // u32 id, u8 mask, fields
)

// A removed member's reason (0x38F5 type 3).
const (
	RemovedLeft     = 1
	RemovedExpelled = 2
)

// 0x38F5 type 5's mask bits (READ guildWnd FUN_005b7b80), fields in bit
// order; 0x01, 0x20 and 0x80 are not read.
const (
	GuildFieldName    = 0x02 // u16 count + UTF-16LE
	GuildFieldLevel   = 0x04 // u8
	GuildFieldGP      = 0x08 // u32
	GuildFieldNotice  = 0x10 // str title, str body
	GuildFieldSoldier = 0x40 // u8
)

// 0x38F5 type 6's mask bits (READ guildWnd FUN_005bb1b0), fields in bit
// order; 0x80 is not read.
const (
	MemberFieldLevel   = 0x01 // u8
	MemberFieldOffline = 0x02 // u8: 0 online ("logged on" / "joined"), 1 offline
	MemberFieldClass   = 0x04 // u8
	MemberFieldGP      = 0x08 // u32
	MemberFieldPerm    = 0x10 // u32
	MemberFieldName    = 0x20 // str (a rename; NOT the grant name)
	MemberFieldSiege   = 0x40 // u8
)

// EncodeOK is a success reply's {1}.
func EncodeOK() []byte { return []byte{1} }

// EncodeFail is a refusal: {2, u16 code} (s:0x4e7250 Msg_SendTwoFieldReply).
func EncodeFail(code uint16) []byte { return binary.LittleEndian.AppendUint16([]byte{2}, code) }

// EncodeCreatePenalty is 0xB0F0's penalty refusal: {2, 0x4c3c, u32 seconds
// left} (the client prints UIIT_MSG_GUILD_SECESSION_PENALTY with days,
// hours and minutes, c:0x8852c0).
func EncodeCreatePenalty(seconds uint32) []byte {
	return binary.LittleEndian.AppendUint32(EncodeFail(CodeCreatePenalty), seconds)
}

// EncodeCreateOK is 0xB0F0's success: {1} and the guild block.
func EncodeCreateOK(block []byte) []byte { return append([]byte{1}, block...) }

// EncodeInvitation is 0x3080 kind 5: {5, u32 inviter uid} -- nothing else;
// the client names the guild from the inviter's own guild line (c:0x88aeb7).
func EncodeInvitation(inviterUID uint32) []byte {
	return binary.LittleEndian.AppendUint32([]byte{RequestGuildInvite}, inviterUID)
}

// EncodeObjectLeft is 0x3100: {u32 uid}.
func EncodeObjectLeft(uid uint32) []byte { return binary.LittleEndian.AppendUint32(nil, uid) }

// EncodeDisbanded is 0x38F5 type 1.
func EncodeDisbanded() []byte { return []byte{UpdateDisbanded} }

// EncodeMemberAdded is 0x38F5 type 2: the member record (the block's).
func EncodeMemberAdded(m Member, l MemberLive) []byte {
	return appendMember([]byte{UpdateMemberAdd}, m, l)
}

// EncodeMemberRemoved is 0x38F5 type 3: {u32 id, u8 reason}.
func EncodeMemberRemoved(characterID int64, reason byte) []byte {
	return append(binary.LittleEndian.AppendUint32([]byte{UpdateMemberOut}, uint32(characterID)), reason)
}

// EncodeGuildFields is 0x38F5 type 5 for the mask's fields of g.
func EncodeGuildFields(mask byte, g *Guild) []byte {
	b := []byte{UpdateGuild, mask}
	if mask&GuildFieldName != 0 {
		u := []rune(g.Name)
		b = binary.LittleEndian.AppendUint16(b, uint16(len(u)))
		for _, r := range u {
			b = binary.LittleEndian.AppendUint16(b, uint16(r))
		}
	}
	if mask&GuildFieldLevel != 0 {
		b = append(b, byte(g.Level))
	}
	if mask&GuildFieldGP != 0 {
		b = binary.LittleEndian.AppendUint32(b, uint32(clampU32(g.GatheredSP)))
	}
	if mask&GuildFieldNotice != 0 {
		b = appendString(b, g.NoticeTitle)
		b = appendString(b, g.NoticeBody)
	}
	if mask&GuildFieldSoldier != 0 {
		b = append(b, g.SoldierFlags)
	}
	return b
}

// EncodeMemberFields is 0x38F5 type 6 for the mask's fields of m.
func EncodeMemberFields(mask byte, m Member, l MemberLive) []byte {
	b := binary.LittleEndian.AppendUint32([]byte{UpdateMember}, uint32(m.CharacterID))
	b = append(b, mask)
	if mask&MemberFieldLevel != 0 {
		b = append(b, l.Level)
	}
	if mask&MemberFieldOffline != 0 {
		if l.Online {
			b = append(b, 0)
		} else {
			b = append(b, 1)
		}
	}
	if mask&MemberFieldClass != 0 {
		b = append(b, m.MemberClass())
	}
	if mask&MemberFieldGP != 0 {
		b = binary.LittleEndian.AppendUint32(b, uint32(clampU32(m.GPDonation)))
	}
	if mask&MemberFieldPerm != 0 {
		b = binary.LittleEndian.AppendUint32(b, uint32(m.Permission))
	}
	if mask&MemberFieldName != 0 {
		b = appendString(b, m.Name)
	}
	if mask&MemberFieldSiege != 0 {
		b = append(b, m.SiegeAuthority)
	}
	return b
}

// DecodeAnswer reads a 0x3080 answer: {1, 1} accept, {2, u16 code} refuse
// (the client's 0x797d90 for box 0x0F, READ). ok is false for a short one.
func DecodeAnswer(b []byte) (accept bool, ok bool) {
	if len(b) < 2 {
		return false, false
	}
	return b[0] == 1 && b[1] == 1, true
}
