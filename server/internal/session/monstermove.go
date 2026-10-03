package session

import (
	"encoding/binary"
	"errors"
	"fmt"
	"math"
)

// OpenSRO's own monster-movement messages, the server half of round 533's
// client (docs/protocol/monster_ai.md, "OpenSRO's own monster protocol
// (placeholders)"; client/scripts/net/combat.gd decodes both). Additive
// placeholders like every opcode here (docs/protocol/PROTOCOL_DECISION.md):
// retail moves a monster with 0x7021/0xB021, which carry no speed. Only the
// monster AI sends them (monsterai.go, round 537, behind -monster-ai, off by
// default): the tick pushes OpMonsterMoved, and handleMonsterList follows its
// unchanged OpMonsterListResult with one OpMonsterMotionList.
const (
	OpMonsterMoved      uint16 = 0x007c // server -> every session in the zone: one monster's new leg
	OpMonsterMotionList uint16 = 0x007f // server -> the requester, right after an OpMonsterListResult
)

// MonsterMovedSize is an OpMonsterMoved payload's length: s64 id, five f32
// and the u8 mode.
const MonsterMovedSize = 29

// MonsterMotionSize is one OpMonsterMotionList entry's length: s64 id, three
// f32 and the u8 mode.
const MonsterMotionSize = 21

// MonsterMoved is the OpMonsterMoved payload: monster MonsterID walks from
// (X, Z) -- where the server had it when it issued the move -- to
// (DestX, DestZ) at Speed world units per second. Mode picks the clip (0 walk,
// 1 run; ai.MotionMode). A destination equal to (X, Z) is a stop there.
type MonsterMoved struct {
	MonsterID                 int64
	X, Z, DestX, DestZ, Speed float32
	Mode                      uint8
}

func (m *MonsterMoved) Encode() []byte {
	out := make([]byte, MonsterMovedSize)
	binary.LittleEndian.PutUint64(out[0:8], uint64(m.MonsterID))
	for i, f := range []float32{m.X, m.Z, m.DestX, m.DestZ, m.Speed} {
		binary.LittleEndian.PutUint32(out[8+4*i:12+4*i], math.Float32bits(f))
	}
	out[28] = m.Mode
	return out
}

// DecodeMonsterMoved refuses a payload shorter than 29 bytes, as the client
// does (CombatNet.decode_monster_moved).
func DecodeMonsterMoved(data []byte) (*MonsterMoved, error) {
	if len(data) < MonsterMovedSize {
		return nil, fmt.Errorf("session: decoding MonsterMoved: %d bytes, want %d", len(data), MonsterMovedSize)
	}
	f := func(off int) float32 { return math.Float32frombits(binary.LittleEndian.Uint32(data[off : off+4])) }
	return &MonsterMoved{
		MonsterID: int64(binary.LittleEndian.Uint64(data[0:8])),
		X:         f(8), Z: f(12), DestX: f(16), DestZ: f(20), Speed: f(24),
		Mode: data[28],
	}, nil
}

// MonsterMotion is one OpMonsterMotionList entry: a listed monster's current
// leg, without a position -- the list result sent just before carries that.
type MonsterMotion struct {
	ID                  int64
	DestX, DestZ, Speed float32
	Mode                uint8
}

// MonsterMotionList is the OpMonsterMotionList payload: u16 n, then n
// 21-byte entries.
type MonsterMotionList struct {
	Entries []MonsterMotion
}

func (l *MonsterMotionList) Encode() []byte {
	out := make([]byte, 2, 2+MonsterMotionSize*len(l.Entries))
	binary.LittleEndian.PutUint16(out, uint16(len(l.Entries)))
	for _, e := range l.Entries {
		var b [MonsterMotionSize]byte
		binary.LittleEndian.PutUint64(b[0:8], uint64(e.ID))
		binary.LittleEndian.PutUint32(b[8:12], math.Float32bits(e.DestX))
		binary.LittleEndian.PutUint32(b[12:16], math.Float32bits(e.DestZ))
		binary.LittleEndian.PutUint32(b[16:20], math.Float32bits(e.Speed))
		b[20] = e.Mode
		out = append(out, b[:]...)
	}
	return out
}

// DecodeMonsterMotionList decodes an OpMonsterMotionList payload. A payload
// cut short keeps every whole entry before the cut, as the client's
// CombatNet.decode_monster_motion_list does, and the cut is reported as an
// error alongside them; a payload without its count gives no entries and an
// error. Round 539 (round 536's review): this half used to refuse the whole
// list at a cut the client reads past, so the two halves of the codec
// disagreed. Only tests call it -- the message goes server to client.
func DecodeMonsterMotionList(data []byte) (*MonsterMotionList, error) {
	l := &MonsterMotionList{Entries: []MonsterMotion{}}
	if len(data) < 2 {
		return l, errors.New("session: decoding MonsterMotionList: truncated count")
	}
	n := int(binary.LittleEndian.Uint16(data))
	rest := data[2:]
	whole := len(rest) / MonsterMotionSize
	if whole > n {
		whole = n
	}
	for i := 0; i < whole; i++ {
		b := rest[i*MonsterMotionSize:]
		l.Entries = append(l.Entries, MonsterMotion{
			ID:    int64(binary.LittleEndian.Uint64(b[0:8])),
			DestX: math.Float32frombits(binary.LittleEndian.Uint32(b[8:12])),
			DestZ: math.Float32frombits(binary.LittleEndian.Uint32(b[12:16])),
			Speed: math.Float32frombits(binary.LittleEndian.Uint32(b[16:20])),
			Mode:  b[20],
		})
	}
	if whole < n {
		return l, fmt.Errorf("session: decoding MonsterMotionList: %d entries need %d bytes, have %d; kept the %d whole one(s)",
			n, n*MonsterMotionSize, len(rest), whole)
	}
	return l, nil
}
