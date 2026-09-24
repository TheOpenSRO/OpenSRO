package session

import (
	"bytes"
	"testing"
)

// The client's own fixtures (client/scripts/net/combat_test.gd, MOVED_FIXTURE
// and MOTION_LIST_FIXTURE; docs/protocol/monster_ai.md, "srrevamp's own
// monster protocol"): monster 7 from (100, -200) to (140, -200) at 8 u/s,
// walking. The server's encoders must produce them byte for byte.
var (
	movedFixture = []byte{0x07, 0, 0, 0, 0, 0, 0, 0, 0x00, 0x00, 0xc8, 0x42, 0x00, 0x00, 0x48, 0xc3,
		0x00, 0x00, 0x0c, 0x43, 0x00, 0x00, 0x48, 0xc3, 0x00, 0x00, 0x00, 0x41, 0x00}
	motionListFixture = []byte{0x01, 0x00, 0x07, 0, 0, 0, 0, 0, 0, 0, 0x00, 0x00, 0x0c, 0x43,
		0x00, 0x00, 0x48, 0xc3, 0x00, 0x00, 0x00, 0x41, 0x00}
)

func TestMonsterMovedMatchesTheClientFixture(t *testing.T) {
	m := &MonsterMoved{MonsterID: 7, X: 100, Z: -200, DestX: 140, DestZ: -200, Speed: 8, Mode: 0}
	got := m.Encode()
	if !bytes.Equal(got, movedFixture) {
		t.Fatalf("MonsterMoved.Encode:\n got % x\nwant % x", got, movedFixture)
	}
	back, err := DecodeMonsterMoved(got)
	if err != nil || *back != *m {
		t.Fatalf("round trip: %+v, %v", back, err)
	}
	if _, err := DecodeMonsterMoved(movedFixture[:28]); err == nil {
		t.Error("a 28-byte MonsterMoved must be refused")
	}
}

func TestMonsterMotionListMatchesTheClientFixture(t *testing.T) {
	l := &MonsterMotionList{Entries: []MonsterMotion{{ID: 7, DestX: 140, DestZ: -200, Speed: 8, Mode: 0}}}
	got := l.Encode()
	if !bytes.Equal(got, motionListFixture) {
		t.Fatalf("MonsterMotionList.Encode:\n got % x\nwant % x", got, motionListFixture)
	}
	back, err := DecodeMonsterMotionList(got)
	if err != nil || len(back.Entries) != 1 || back.Entries[0] != l.Entries[0] {
		t.Fatalf("round trip: %+v, %v", back, err)
	}
	if empty := (&MonsterMotionList{}).Encode(); !bytes.Equal(empty, []byte{0, 0}) {
		t.Errorf("an empty list encodes as % x; want 00 00", empty)
	}
	// n = 2 with the second entry cut short: the whole first one is kept, as
	// the client's decoder keeps it (combat_test.gd, "n=2 with a truncated
	// second entry gives 1 entry"), and the cut is reported (round 539).
	two := append([]byte{0x02, 0x00}, motionListFixture[2:]...)
	two = append(two, motionListFixture[2:12]...)
	cut, err := DecodeMonsterMotionList(two)
	if err == nil {
		t.Error("n = 2 with the second entry cut short must report the cut")
	}
	if cut == nil || len(cut.Entries) != 1 || cut.Entries[0] != l.Entries[0] {
		t.Errorf("n = 2 with the second entry cut short gave %+v; want the whole first entry kept, as the client does", cut)
	}
	none, err := DecodeMonsterMotionList([]byte{1})
	if err == nil {
		t.Error("a payload without its count must report it")
	}
	if none == nil || len(none.Entries) != 0 {
		t.Errorf("a payload without its count gave %+v; want no entries, as the client does", none)
	}
}

// The two new opcodes are the ones the client listens on (CombatNet
// OP_MONSTER_MOVED / OP_MONSTER_MOTION_LIST) and collide with no other
// session opcode in the 0x0060..0x007F block.
func TestMonsterMoveOpcodes(t *testing.T) {
	if OpMonsterMoved != 0x007C || OpMonsterMotionList != 0x007F {
		t.Fatalf("opcodes 0x%04X/0x%04X; the client decodes 0x007C/0x007F", OpMonsterMoved, OpMonsterMotionList)
	}
	for _, op := range []uint16{OpAttack, OpAttackResult, OpMonsterDamaged, OpMonsterDied, OpLootDropped,
		OpMonsterList, OpMonsterListResult, OpLevelUp, OpBerserk, OpBerserkResult,
		OpLearnSkill, OpLearnSkillResult, OpUseSkill, OpSkillList, OpSkillListResult,
		OpSkillState, OpSkillStateResult, OpRaiseMastery, OpRaiseMasteryResult,
		OpGroundItemList, OpGroundItemListResult, OpGroundItemSpawned, OpGroundItemRemoved,
		OpGroundItemOwnerReleased, OpPickUp, OpPickUpResult, OpRepair, OpRepairResult} {
		if op == OpMonsterMoved || op == OpMonsterMotionList {
			t.Errorf("0x%04X is already taken", op)
		}
	}
}
