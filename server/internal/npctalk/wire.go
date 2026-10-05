// Package npctalk holds the retail NPC select / open / end messages (round
// 727): 0x7045 -> 0xB045, 0x7046 -> 0xB046 and 0x704B -> 0xB04B. Every field
// below was read from both binaries (docs/protocol/npc_gui.md, "The retail
// NPC protocol (round 727)").
package npctalk

import (
	"encoding/binary"
	"errors"
)

// The opcodes.
const (
	OpSelect       uint16 = 0x7045 // C->S {u32 entity}
	OpSelectResult uint16 = 0xB045
	OpOpen         uint16 = 0x7046 // C->S {u32 entity, u8 interaction id}
	OpOpenResult   uint16 = 0xB046
	OpEnd          uint16 = 0x704B // C->S {u32 entity}
	OpEndResult    uint16 = 0xB04B
)

// The interaction ids the select reply's tail depends on.
const (
	// IDStructureUpdate (0x1f): the server appends a u16 when the set holds
	// it (GObjPC::FUN_004c95c0 tests 0x1f, 0x4c95de; appended at 0x4a97ed)
	// and the client reads one into +0x13a when the set holds 0x1f
	// (FUN_0088b200 0x88b659..0x88b691).
	IDStructureUpdate byte = 0x1f
	// IDArenaManager (0x21, '!'): the server appends a u16 for
	// NPC_BATTLE_ARENA_MANAGER (0x4a9840..), which the client reads when its
	// set held 0x21 (0x88b6c3..0x88b6dc).
	IDArenaManager byte = 0x21
	// IDTalk (2), IDWithdrawSkill (10) and IDSpecial (0xc): 0x046's switch
	// echoes 10 as 2 (0x5104a8 `cmp al,0xa` ... `mov [esp+0xe],2`) and
	// appends one more byte for 0xc (0x5104f4).
	IDTalk          byte = 2
	IDWithdrawSkill byte = 10
	IDSpecial       byte = 0x0c
)

// Result bytes. A refusal is Msg_SendTwoFieldReply's {u8 2, u16 code}
// (0x4e7250, docs/protocol/PACKET_FORMAT.md "The failure-reply shape").
const (
	ResultOK   byte = 1
	ResultFail byte = 2
)

// Refusal codes.
const (
	// CodeBusy 0x1C0B, UIIT_MSG_INTERACTION_FAIL_IM_BUSY: 0x046 refuses an
	// open while INTERACTMODE is not 0 (0x51041c).
	CodeBusy uint16 = 0x1c0b
	// CodeNotOffered 5: 0x046 refuses an id the NPC does not offer
	// (HasAvailableInteraction 0x50cd80; round 449).
	CodeNotOffered uint16 = 5
	// CodeNoInteraction 0x1C0D: 0x04b refuses an end with no interaction open
	// (character_state.md round 449; GObjPC::EndInteraction 0x5107c0).
	CodeNoInteraction uint16 = 0x1c0d
	// CodeNoTarget 3: the select handler's refusal for an entity it cannot
	// resolve or a requester it will not serve (0x50fd41 ->
	// Msg_SendTwoFieldReply(3)).
	CodeNoTarget uint16 = 3
	// CodeTooFar 4: IsWithinInteractionRange's out-of-range return (0x4a902f),
	// which the select handler sends as the code (0x50fd11).
	CodeTooFar uint16 = 4
)

// ErrShort is a request shorter than its layout.
var ErrShort = errors.New("npctalk: short message")

// DecodeEntity reads 0x7045's and 0x704B's {u32 entity}
// (client FUN_0078f5f0: one 4-byte write at 0x78f6a3; 0x78fc20 writes the
// selected id at +0x62c the same way).
func DecodeEntity(b []byte) (uint32, error) {
	if len(b) < 4 {
		return 0, ErrShort
	}
	return binary.LittleEndian.Uint32(b), nil
}

// EncodeEntity writes {u32 entity}.
func EncodeEntity(entity uint32) []byte {
	return binary.LittleEndian.AppendUint32(nil, entity)
}

// DecodeOpen reads 0x7046's {u32 entity, u8 id} (GObjPC_HandleShopMsg_046
// 0x510250 reads the u32, then the u8 at 0x510320).
func DecodeOpen(b []byte) (entity uint32, id byte, err error) {
	if len(b) < 5 {
		return 0, 0, ErrShort
	}
	return binary.LittleEndian.Uint32(b), b[4], nil
}

// EncodeOpen writes {u32 entity, u8 id}.
func EncodeOpen(entity uint32, id byte) []byte {
	return append(binary.LittleEndian.AppendUint32(nil, entity), id)
}

// SelectNPC is the select reply for an NPC: CGObjChar::
// PublishAvailableInteractions (0x4a95a0) after FUN_0050faf0's status and id.
type SelectNPC struct {
	Entity uint32
	// Flag is the target's own byte, written before the count by its vtable
	// slot +0x4d8 (PublishAvailableInteractions 0x4a973a..0x4a9747, called
	// with (1, msg)). CGObjNPCNPC's is 0x4c79f0, which writes 0
	// (0x4c79ff `mov byte [esp+7],0`). The client reads it at 0x88b37c and,
	// when bit 0 is set, a u32 after it (0x88b385..0x88b393, FlagWord); bits
	// 1 and 2 are asserts there. An NPC sends 0 (READ).
	Flag     byte
	FlagWord uint32
	// IDs is the NPC's whole interaction set, in set (ascending) order.
	IDs []byte
	// StructureWord is the u16 sent when IDs holds 0x1f (FUN_004c95c0's
	// value; OURS 0 -- OpenSRO has no siege structures).
	StructureWord uint16
	// NPCByte is the u8 sent for an NPC (slot 0x24 true): FUN_00645790 with
	// the siege manager. Which value the client uses it for is not read; it
	// is the fortress side the user deferred, and OpenSRO sends 0 (OURS).
	NPCByte byte
	// ArenaWord is the u16 sent when IDs holds 0x21 (FUN_00669dd0's value;
	// OURS 0 -- OpenSRO has no arena).
	ArenaWord uint16
}

// EncodeSelectNPC writes 0xB045 for an NPC:
//
//	u8  1                    0x50fc3c
//	u32 entity               0x50fc4d
//	u8  flag (an NPC: 0)     0x4c79f0 via slot +0x4d8; c:0x88b37c
//	u32 if flag bit 0        c:0x88b385..0x88b393
//	u8  count                0x4a975f (+0x1c80, the set's size)
//	u8  x count  ids         0x4a97ae
//	u16 if 0x1f in the set   0x4a97ed
//	u8  (an NPC)             0x4a982e
//	u16 if 0x21 in the set   0x4a9852.. (NPC_BATTLE_ARENA_MANAGER)
//
// The client reads it in that order (FUN_0088b200 0x88b400..0x88b6dc).
func EncodeSelectNPC(s SelectNPC) []byte {
	out := []byte{ResultOK}
	out = binary.LittleEndian.AppendUint32(out, s.Entity)
	out = append(out, s.Flag)
	if s.Flag&1 != 0 {
		out = binary.LittleEndian.AppendUint32(out, s.FlagWord)
	}
	out = append(out, byte(len(s.IDs)))
	out = append(out, s.IDs...)
	if has(s.IDs, IDStructureUpdate) {
		out = binary.LittleEndian.AppendUint16(out, s.StructureWord)
	}
	out = append(out, s.NPCByte)
	if has(s.IDs, IDArenaManager) {
		out = binary.LittleEndian.AppendUint16(out, s.ArenaWord)
	}
	return out
}

// DecodeSelectNPC reads an EncodeSelectNPC payload (for tests and bots).
func DecodeSelectNPC(b []byte) (SelectNPC, error) {
	var s SelectNPC
	if len(b) < 7 || b[0] != ResultOK {
		return s, ErrShort
	}
	s.Entity = binary.LittleEndian.Uint32(b[1:])
	s.Flag = b[5]
	b = b[6:]
	if s.Flag&1 != 0 {
		if len(b) < 4 {
			return s, ErrShort
		}
		s.FlagWord = binary.LittleEndian.Uint32(b)
		b = b[4:]
	}
	if len(b) < 1 {
		return s, ErrShort
	}
	n := int(b[0])
	b = b[1:]
	if len(b) < n {
		return s, ErrShort
	}
	s.IDs = append([]byte(nil), b[:n]...)
	b = b[n:]
	if has(s.IDs, IDStructureUpdate) {
		if len(b) < 2 {
			return s, ErrShort
		}
		s.StructureWord = binary.LittleEndian.Uint16(b)
		b = b[2:]
	}
	if len(b) < 1 {
		return s, ErrShort
	}
	s.NPCByte = b[0]
	b = b[1:]
	if has(s.IDs, IDArenaManager) {
		if len(b) < 2 {
			return s, ErrShort
		}
		s.ArenaWord = binary.LittleEndian.Uint16(b)
	}
	return s, nil
}

// EncodeOpenOK writes 0xB046's success: {u8 1, u8 id}, the id echoed with
// 10 written as 2 (0x5104a8..0x5104b5), plus one u8 for id 0xc (the
// world-config byte at +0x42405, 0x5104fb; OURS 0 here).
func EncodeOpenOK(id byte) []byte {
	echo := id
	if id == IDWithdrawSkill {
		echo = IDTalk
	}
	out := []byte{ResultOK, echo}
	if id == IDSpecial {
		out = append(out, 0)
	}
	return out
}

// EncodeEndOK writes 0xB04B's success: {u8 1} (0x510763).
func EncodeEndOK() []byte { return []byte{ResultOK} }

// EncodeFail writes the refusal {u8 2, u16 code} any of the three replies
// uses.
func EncodeFail(code uint16) []byte {
	return binary.LittleEndian.AppendUint16([]byte{ResultFail}, code)
}

func has(ids []byte, id byte) bool {
	for _, b := range ids {
		if b == id {
			return true
		}
	}
	return false
}
