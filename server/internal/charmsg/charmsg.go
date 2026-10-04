// Package charmsg holds two of the original's character-update messages
// (round 716): 0x3056, the EXP/skill-EXP gain every kill receiver is told,
// and 0x304E kind 1, the gold total a party gold share is told with. Both
// layouts are READ in both binaries; see docs/protocol/party_protocol.md
// "Rewards: 0x3056 and 0x304E".
package charmsg

import (
	"encoding/binary"
	"fmt"
)

// OpExpGain is the EXP gain, S->C. The GameServer writes it at the end of
// GObjPC_GainExpAndLevel (slot 92, 0x4e5250, `push 0x3056` at 0x4e582d); the
// client reads it in Client_ApplyExpAndLevelUp (0x8a97c0).
const OpExpGain uint16 = 0x3056

// OpCharInfo is the character-info update, S->C, written by GObjPC::
// FUN_004e3fb0 (`push 0x304e`) and read by c:0x8a70d0. Only kind 1 is built
// here.
const OpCharInfo uint16 = 0x304e

// CharInfoGold is 0x304E's kind 1: the new gold total (chardata+0x78).
const CharInfoGold uint8 = 1

// ExpGain is one 0x3056.
//
// READ (GS 0x4e583c..0x4e58fa; client 0x8a97c0, the same widths in the same
// order): u32 source object id, u64 EXP, u64 skill EXP, u8 flags; then a u32
// when flags&0x0f == 1 and two u32s when flags&0xf0 == 0x10 (both
// training-camp states: GObjPC::FUN_004e43e0/43a0/4360 all start from
// pc[0x733], the camp membership); then a u16, the character's
// RemainStatPoint (chardata+0x84), only when the call raised the level
// (0x4e58df: new level > old). The client knows the u16 is there by doing the
// same level arithmetic on its own copy of the EXP.
//
// OpenSRO has no training camp, so Flags is always 0 and neither optional
// block is written (READ rule, applied to OURS state).
type ExpGain struct {
	// Source is the object the EXP came from: the kill path passes the
	// victim's unique id (vslot_420 0x4eabd2..0x4eabd5, [[ebp+8]+8]). The
	// client floats the gain from that object when it can find it.
	Source   uint32
	Exp      int64
	SkillExp int64
	Flags    uint8
	// LevelUp says the u16 follows; StatPoints is its value.
	LevelUp    bool
	StatPoints uint16
}

// Encode writes the message as the GameServer does.
func (g ExpGain) Encode() []byte {
	out := make([]byte, 0, 23)
	out = binary.LittleEndian.AppendUint32(out, g.Source)
	out = binary.LittleEndian.AppendUint64(out, uint64(g.Exp))
	out = binary.LittleEndian.AppendUint64(out, uint64(g.SkillExp))
	out = append(out, g.Flags)
	if g.LevelUp {
		out = binary.LittleEndian.AppendUint16(out, g.StatPoints)
	}
	return out
}

// DecodeExpGain reads a 0x3056 without the training-camp blocks. Where the
// client decides the stat-point u16 from its own level arithmetic, this
// reader takes it from the length (OURS: equal for every message Encode
// writes).
func DecodeExpGain(b []byte) (ExpGain, error) {
	if len(b) < 21 {
		return ExpGain{}, fmt.Errorf("charmsg: 0x3056 needs 21 bytes, got %d", len(b))
	}
	g := ExpGain{
		Source:   binary.LittleEndian.Uint32(b[0:]),
		Exp:      int64(binary.LittleEndian.Uint64(b[4:])),
		SkillExp: int64(binary.LittleEndian.Uint64(b[12:])),
		Flags:    b[20],
	}
	if g.Flags != 0 {
		return g, fmt.Errorf("charmsg: 0x3056 flags 0x%02x carry training-camp fields this reader does not take", g.Flags)
	}
	if len(b) >= 23 {
		g.LevelUp = true
		g.StatPoints = binary.LittleEndian.Uint16(b[21:])
	}
	return g, nil
}

// EncodeGold is 0x304E kind 1 (GS FUN_004e3fb0 case 1): u8 kind, u64 the new
// gold total, u8 show. The client (c:0x8a70d0) prints UIIT_MSG_STATE_GAIN_GOLD
// with the rise over its own total when show is non-zero and the total rose,
// then sets its gold. CGObjPC::OffsetGold (0x4e4b60) sends it when its fifth
// argument is 1, with the sixth as show; the party gold split (0x5bc7f0)
// calls it with (amount, 0, 0x17, 1, 1).
func EncodeGold(total int64, show bool) []byte {
	out := make([]byte, 0, 10)
	out = append(out, CharInfoGold)
	out = binary.LittleEndian.AppendUint64(out, uint64(total))
	if show {
		return append(out, 1)
	}
	return append(out, 0)
}

// DecodeGold reads EncodeGold's bytes back.
func DecodeGold(b []byte) (total int64, show bool, err error) {
	if len(b) < 10 || b[0] != CharInfoGold {
		return 0, false, fmt.Errorf("charmsg: not a 0x304E gold update (% x)", b)
	}
	return int64(binary.LittleEndian.Uint64(b[1:])), b[9] != 0, nil
}
