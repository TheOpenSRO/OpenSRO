package guild

import "encoding/binary"

// Round 844 (lane G): the notice, permission, hand-over, donation and
// level-up requests and the updates they cause (READ unless marked;
// docs/protocol/guild_census.md, sections 1-5).
const (
	// OpNotice is 0x70F9 {str title, str body} (c:0x824360, s:0x516ea0).
	OpNotice       uint16 = 0x70F9
	OpNoticeResult uint16 = 0xB0F9 // {1} | {2, u16}
	// OpLevelUp is 0x70FA {u32 npc} (CIFGuildLevelUp c:0x81fdc0,
	// s:0x516da0).
	OpLevelUp       uint16 = 0x70FA
	OpLevelUpResult uint16 = 0xB0FA // {1} | {2, u16}
	// OpHandOver is 0x7103 {u32 npc, u32 new master id} (c:0x81fe80,
	// s:0x517300).
	OpHandOver       uint16 = 0x7103
	OpHandOverResult uint16 = 0xB103 // {1} | {2, u16}
	// OpPermission is 0x7104 {u8 n, n x {u32 id, u32 mask}} (c:0x5ace60,
	// s:0x5173e0).
	OpPermission       uint16 = 0x7104
	OpPermissionResult uint16 = 0xB104 // {1} | {2, u16}
	// OpDonate is 0x7258 {u32 SP} (CIFGuildPointUp c:0x70bcd0, s:0x517cc0).
	OpDonate       uint16 = 0x7258
	OpDonateResult uint16 = 0xB258 // {1, u32 SP} | {2, u16}
)

// The 0x38F5 types these add (c:0x887330's table, READ).
const (
	UpdatePermissions  = 0x14 // u8 n, n x {u32 id, u32 mask}: silent
	UpdateMembersField = 0x16 // u8 n, u8 mask, n x {u32 id, the mask's fields}
)

// The refusal codes (the client's names; category 0x10 unless marked).
const (
	CodeNoticeTitle    uint16 = 0x4c22 // GUILDERR_INVALID_MASTER_COMMENT_TITLE
	CodeNoticeBody     uint16 = 0x4c23 // GUILDERR_INVALID_MASTER_COMMENT
	CodeIMDead         uint16 = 0x4c07 // GUILDERR_IM_DEAD
	CodeGPDeficit      uint16 = 0x4c32 // ERROR_GUILD_LEVEL_UP_GP_DEFICIT (also the donation's SP short)
	CodeUnionChatFull  uint16 = 0x4c4b // GUILD_UNION_CHAT_FULL
	CodeStorageUseIng  uint16 = 0x4c4c // GUILD_WAREHOUSE_USE_ING
	CodeFortressPeriod uint16 = 0x4c5d // FORT_POSITION_GRANT_FAIL_01
	CodeSoldierMaster  uint16 = 0x4c55 // GUILD_SOLDIER_LEAVE_MASTER_ERROR
	CodeFailed         uint16 = 2      // the job could not be sent; no text
)

// NoticeTitleMaxBytes and NoticeBodyMaxBytes are the server's limits on the
// notice (READ s:0x5c64f4 `cmp eax,0x80; ja`, s:0x5c6502 `cmp eax,0x800;
// ja`): bytes of the string as sent, 1..128 and 1..2048. The engine's are
// ANSI bytes; OpenSRO's strings are UTF-8 (a non-ASCII notice can be refused
// here that the engine would take).
const (
	NoticeTitleMaxBytes = 0x80
	NoticeBodyMaxBytes  = 0x800
)

// UnionChatMax is the most members holding PermUnionChat (READ s:0x5c4b42
// `cmp [esp+0x30],0xc; jbe`).
const UnionChatMax = 12

// NoticeQuoteRefused is the GameServer's filter on the notice (s:0x7312f0 on
// the title, then the body, READ): a ' or " drops the request with no reply.
// Its configured substring list is not read (OPEN).
func NoticeQuoteRefused(s string) bool {
	for _, r := range s {
		if r == '\'' || r == '"' {
			return true
		}
	}
	return false
}

// EncodePermissions is 0x38F5 type 0x14: every listed member's mask.
func EncodePermissions(changes []PermissionChange) []byte {
	b := []byte{UpdatePermissions, byte(len(changes))}
	for _, c := range changes {
		b = binary.LittleEndian.AppendUint32(b, uint32(c.CharacterID))
		b = binary.LittleEndian.AppendUint32(b, uint32(c.Permission))
	}
	return b
}

// EncodeMembersFields is 0x38F5 type 0x16: the mask's fields of several
// members (each as type 6 writes them, after the id).
func EncodeMembersFields(mask byte, members []Member, live func(characterID int64) MemberLive) []byte {
	b := []byte{UpdateMembersField, byte(len(members)), mask}
	for _, m := range members {
		var l MemberLive
		if live != nil {
			l = live(m.CharacterID)
		}
		one := EncodeMemberFields(mask, m, l)
		// EncodeMemberFields writes {type, u32 id, mask, fields}: keep the id
		// and the fields.
		b = append(b, one[1:5]...)
		b = append(b, one[6:]...)
	}
	return b
}

// EncodeDonateOK is 0xB258's success: {1, u32 the SP given}.
func EncodeDonateOK(sp uint32) []byte {
	return binary.LittleEndian.AppendUint32([]byte{1}, sp)
}
