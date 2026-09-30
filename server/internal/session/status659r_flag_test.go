package session

import (
	"encoding/binary"
	"testing"
)

// The status-tick flag round-trips and leaves the other bits alone.
func TestStrikeStatusTickFlag(t *testing.T) {
	m := &MonsterAttacked{MonsterID: 7, TargetCharacterID: 42, Damage: 16, TargetDied: true, StatusTick: true}
	data := m.Encode()
	if data[20] != StrikeTargetDied|StrikeStatusTick || StrikeStatusTick != 0x08 {
		t.Fatalf("flags %#02x", data[20])
	}
	back, err := DecodeMonsterAttacked(data)
	if err != nil || !back.StatusTick || back.Critical || back.Blocked {
		t.Fatalf("round trip %+v %v", back, err)
	}
	if binary.LittleEndian.Uint64(data[8:16]) != 42 {
		t.Fatal("target")
	}
}
