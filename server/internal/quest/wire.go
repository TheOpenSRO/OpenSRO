package quest

import (
	"encoding/binary"
	"errors"
)

// The quest messages (round 785). Layouts READ from sro_client.exe's handlers
// and senders (docs/protocol/quests.md, "Messages"); every string is a u16
// length and its bytes (FUN_004f7a70).
const (
	// OpUpdate 0x30D5: add (1), change (2) or remove (3, 4) one quest
	// (FUN_008812b0; the body FUN_008b94d0).
	OpUpdate uint16 = 0x30D5
	// OpTalkPage 0x30D4: an NPC talk page (FUN_00889d90 -> FUN_006fc1c0).
	OpTalkPage uint16 = 0x30D4
	// OpTalkAnswer 0x70D4: the chosen line's response id. The client builds
	// it with 0x30D4 (0x7026be..0x702732) and the server's handler is index
	// 0x0d4 (GObjPC_HandleTalkMenuSelectMsg_0d4, npc_gui.md section 8); the
	// server dispatches on the low 12 bits, so both are accepted here.
	OpTalkAnswer    uint16 = 0x70D4
	OpTalkAnswerAlt uint16 = 0x30D4
	// OpMark 0x30D6 puts a mark over an object (FUN_008811e0); OpUnmark 0x30D7
	// removes it.
	OpMark   uint16 = 0x30D6
	OpUnmark uint16 = 0x30D7
	// OpRewardWindow 0x3514 opens CNIFQuestReward (FUN_00884ca0).
	OpRewardWindow uint16 = 0x3514
	// OpTakeReward 0x7515 / 0xB515: take the reward (FUN_008252d0 /
	// FUN_00881570).
	OpTakeReward       uint16 = 0x7515
	OpTakeRewardResult uint16 = 0xB515
	// OpAbandon 0x70D9 / 0xB0D9: give a quest up (0x6e4af1 / FUN_008814b0).
	OpAbandon       uint16 = 0x70D9
	OpAbandonResult uint16 = 0xB0D9
	// OpClaim 0x70D8 / 0xB0D8: the quest window's reward button on a quest
	// whose missions are done (FUN_006e4ec0 / FUN_00881450).
	OpClaim       uint16 = 0x70D8
	OpClaimResult uint16 = 0xB0D8
	// OpEventMessage 0x30EC: a quest notice, {string key} (CGObjPC::
	// SendQuestEventMessage, CGObjPC vslot 0x1cc, s:0x4ed4a0; the client's
	// 0x884a30 shows the key's text through 0x77b5b0 -- the quest info
	// notice -- and plays snd_quest_end for SN_TALK_COMMON_END). READ.
	OpEventMessage uint16 = 0x30EC
	// OpLog (OURS, 0x00B1): the character's quest section at entering the
	// world, in the layout retail carries inside its character data
	// (ICPlayer::FUN_009d9830): OpenSRO's character data is its own, so the
	// section travels on its own. 0x00B1 was OpenSRO's own quest-list reply
	// before round 785 and is reused.
	OpLog uint16 = 0x00B1
)

// Update kinds (FUN_008812b0's switch).
const (
	UpdateAdd     = 1
	UpdateChange  = 2
	UpdateRemove  = 3 // given up, or a status 4/5/6 (GObjPC 0x5709c0)
	UpdateDropped = 4 // removed as completed (OURS: the paid quest)
)

// Talk page types (FUN_006fc1c0).
const (
	PageConfirm = 1 // one line, UIIT_STT_CONFIRM, response 1
	PageYesNo   = 3 // UIIT_STT_YES response 2, UIIT_STT_NO response 3
	PageList    = 4 // n lines, response 5+i (define.sct TALK_RESPONSE_LIST_BASE 5)
)

// Response ids.
const (
	RespConfirm  = 1
	RespYes      = 2
	RespNo       = 3
	RespListBase = 5
	// RespAccept and RespDeny are the accept page's two lines (round 819).
	RespAccept = RespListBase
	RespDeny   = RespListBase + 1
)

// The quest pages' lines (round 819, READ). Every quest page is a type-4
// list (CBasicQuest's conversation s:0x920110 shows each through ShowMenu,
// CGObjPC vslot 0x150, with type 4) whose lines come from the quest's table
// at +0x500 (its constructor, s:0x91e35d..): an offer is [Accept, Refuse],
// every other page [OK]. ShowMenu (s:0x4ec930) swaps the accept line for
// LineMaxQuest when the player holds MaxQuests or more quests
// (GetRecvQuestCount, s:0x5714b0); nothing else enforces it -- the line
// still answers 5 and the quest still starts (no other caller of the count).
const (
	LineOK       = "SN_TALK_COMMON_OK"
	LineAccept   = "SN_TALK_COMMON_ACCEPT"
	LineDeny     = "SN_TALK_COMMON_DENY"
	LineMaxQuest = "SN_TALK_COMMON_MAXQUEST"
	// NoticeEnd is the notice after a paid reward (s:0x920110, when the
	// quest's +0x48c is set, which its constructor does and nothing clears).
	NoticeEnd = "SN_TALK_COMMON_END"
	// MaxQuests: the accept line reads LineMaxQuest at this many quests
	// (`bVar2 < 0x21` keeps it).
	MaxQuests = 33
)

// EncodeEventMessage writes 0x30EC: the key, a u16-length string (FUN_00426040).
func EncodeEventMessage(key string) []byte { return putString(nil, key) }

// Mark types (GlobalDataManager::FUN_009c75e0): the effect drawn over the
// object.
const (
	MarkStart = 1 // SYSTEM_EXCLAMATION_START: a quest to take
	MarkGoing = 2 // SYSTEM_EXCLAMATION_GOING: a quest under way
	MarkEnd   = 3 // SYSTEM_EXCLAMATION_END: a quest to hand in
)

// MissionView is one mission line of an update body.
type MissionView struct {
	Index byte
	// Open is the mission flag: 1 while the mission is under way
	// (UIIT_STT_QUEST_ING), 0 when done (UIIT_STT_QUEST_END; UI_QUEST::
	// FUN_006e8360). A change of an open mission's text is the client's
	// progress notice.
	Open   bool
	Text   string
	Values []uint32
}

// View is the 0x30D5 body (FUN_008b94d0).
type View struct {
	// Counter is the byte at +8: the quest window draws its two nibbles,
	// low then high, as "%s (%d/%d)" (quest_window.gd, from 0x6e5bf0).
	// OURS: achieved count in the low nibble, the achievement limit in the
	// high one (what the pair means is not READ).
	Counter byte
	// State is the byte at +9, which picks the row's colour bar (1 green,
	// 2 red, 3 light green; 0x6e5c5d..0x6e5cf4): the quest's divide type
	// (s:0x871bd0, READ round 819), so a quest of type 0 or 5 has none.
	State    byte
	Status   byte
	Missions []MissionView
	NPCs     []uint32
}

func putString(b []byte, s string) []byte {
	b = binary.LittleEndian.AppendUint16(b, uint16(len(s)))
	return append(b, s...)
}

// EncodeBody writes a View: flags 8 (status), 0x10 (missions) and 0x40 (the
// NPC list) are always set; 4 (a time limit) never (OURS: no timed quest is
// modelled).
func (v View) EncodeBody(b []byte) []byte {
	b = append(b, v.Counter, v.State, 0x08|0x10|0x40)
	b = append(b, v.Status)
	b = append(b, byte(len(v.Missions)))
	for _, m := range v.Missions {
		flag := byte(0)
		if m.Open {
			flag = 1
		}
		b = append(b, m.Index, flag)
		b = putString(b, m.Text)
		b = append(b, byte(len(m.Values)))
		for _, x := range m.Values {
			b = binary.LittleEndian.AppendUint32(b, x)
		}
	}
	b = append(b, byte(len(v.NPCs)))
	for _, n := range v.NPCs {
		b = binary.LittleEndian.AppendUint32(b, n)
	}
	return b
}

// EncodeUpdate writes 0x30D5.
func EncodeUpdate(kind byte, questID uint32, v *View) []byte {
	b := []byte{kind}
	b = binary.LittleEndian.AppendUint32(b, questID)
	if (kind == UpdateAdd || kind == UpdateChange) && v != nil {
		b = v.EncodeBody(b)
	}
	return b
}

// ActiveQuest is one open quest in the log section.
type ActiveQuest struct {
	ID   uint32
	View View
}

// EncodeLog writes the log section: u16 n + n x u32 completed ids, u8 n + n x
// (u32 id, body), u8 0 marks (marks go as 0x30D6).
func EncodeLog(completed []uint32, active []ActiveQuest) []byte {
	b := binary.LittleEndian.AppendUint16(nil, uint16(len(completed)))
	for _, id := range completed {
		b = binary.LittleEndian.AppendUint32(b, id)
	}
	b = append(b, byte(len(active)))
	for _, a := range active {
		b = binary.LittleEndian.AppendUint32(b, a.ID)
		b = a.View.EncodeBody(b)
	}
	return append(b, 0)
}

// EncodeTalkPage writes 0x30D4: u8 type, string text, and for a list u8 n +
// n strings.
func EncodeTalkPage(kind byte, text string, lines []string) []byte {
	b := putString([]byte{kind}, text)
	if kind == PageList || kind == 5 {
		b = append(b, byte(len(lines)))
		for _, l := range lines {
			b = putString(b, l)
		}
	}
	return b
}

// EncodeMark writes 0x30D6: u32 object, u8 flags 0, u8 type, u16 region,
// three f32 position.
func EncodeMark(object uint32, markType byte, region uint16, x, y, z float32) []byte {
	b := binary.LittleEndian.AppendUint32(nil, object)
	b = append(b, 0, markType)
	b = binary.LittleEndian.AppendUint16(b, region)
	for _, f := range []float32{x, y, z} {
		b = binary.LittleEndian.AppendUint32(b, mathFloat32bits(f))
	}
	return b
}

// EncodeRewardWindow writes 0x3514: u32 quest, u8 0, string text.
func EncodeRewardWindow(questID uint32, text string) []byte {
	b := binary.LittleEndian.AppendUint32(nil, questID)
	return putString(append(b, 0), text)
}

// ErrShort is a request shorter than its layout.
var ErrShort = errors.New("quest: short message")

// DecodeQuestID reads 0x70D8 / 0x70D9's u32.
func DecodeQuestID(b []byte) (uint32, error) {
	if len(b) < 4 {
		return 0, ErrShort
	}
	return binary.LittleEndian.Uint32(b), nil
}

// DecodeTakeReward reads 0x7515: u32 quest, u8 n, n x u32 chosen.
func DecodeTakeReward(b []byte) (uint32, []uint32, error) {
	if len(b) < 5 {
		return 0, nil, ErrShort
	}
	id := binary.LittleEndian.Uint32(b)
	n := int(b[4])
	b = b[5:]
	if len(b) < 4*n {
		return 0, nil, ErrShort
	}
	out := make([]uint32, n)
	for i := range out {
		out[i] = binary.LittleEndian.Uint32(b[4*i:])
	}
	return id, out, nil
}

// EncodeOKID writes {u8 1, u32 id} (0xB0D8 / 0xB0D9 success).
func EncodeOKID(id uint32) []byte { return binary.LittleEndian.AppendUint32([]byte{1}, id) }

// EncodeFailByte writes {u8 2, u8 code} (0xB0D9, 0xB515 refusals).
func EncodeFailByte(code byte) []byte { return []byte{2, code} }

// EncodeFailWord writes {u8 2, u16 code} (0xB0D8's refusal).
func EncodeFailWord(code uint16) []byte { return binary.LittleEndian.AppendUint16([]byte{2}, code) }

// Refusal codes the client names (READ, FUN_008814b0 / FUN_00881570).
const (
	// AbandonWrongStatus is the refusal for a quest not under way (status
	// other than 1, 7 or 8): {2, 2}, which the client shows nothing for
	// (s:0x571d45, READ round 819).
	AbandonWrongStatus = 2
	AbandonNotAllowed  = 4 // UIIT_MSG_SR_ABORT_QUEST_ERROR_NOT_ALLOWED
	// AbandonGiveUp is the refusal while an NPC talk is open (the PC's
	// +0x1ca0, which EndInteraction clears for a talk; s:0x571d66).
	AbandonGiveUp = 5 // UIIT_STT_QUEST_GIVEUP_1
	RewardError   = 2 // UIIT_STT_QUESTREWARD_ERROR
)
