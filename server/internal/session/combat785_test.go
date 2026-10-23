package session

import (
	"bytes"
	"encoding/binary"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
)

// Round 785: a monster's blow names the skill it swung, as retail's 0xB070
// does (u32 skillId). The id rides after the wall block, which is then
// always written; a blow with no skill is the 33 bytes it always was.
func TestMonsterAttackedCarriesTheSkill(t *testing.T) {
	plain := (&MonsterAttacked{MonsterID: 7, TargetCharacterID: 42, Damage: 200, TargetHP: 76}).Encode()
	if len(plain) != MonsterAttackedSize {
		t.Fatalf("a blow with no skill encodes %d bytes, want %d", len(plain), MonsterAttackedSize)
	}
	m := &MonsterAttacked{MonsterID: 7, TargetCharacterID: 42, Damage: 200, TargetHP: 76, SkillID: 161}
	got := m.Encode()
	if len(got) != MonsterAttackedSkillOffset+4 || MonsterAttackedSkillOffset != 46 {
		t.Fatalf("a blow with a skill encodes %d bytes (skill at %d), want 50 (at 46)", len(got), MonsterAttackedSkillOffset)
	}
	if !bytes.Equal(got[:MonsterAttackedSize], plain) {
		t.Errorf("the skill changed the 33 bytes before it: % x / % x", got[:MonsterAttackedSize], plain)
	}
	if !bytes.Equal(got[MonsterAttackedSize:MonsterAttackedSkillOffset], make([]byte, wallInfoSize)) {
		t.Errorf("the wall block before the skill is not zero for a blow that met no wall: % x", got[MonsterAttackedSize:MonsterAttackedSkillOffset])
	}
	if id := binary.LittleEndian.Uint32(got[MonsterAttackedSkillOffset:]); id != 161 {
		t.Errorf("skill u32 = %d, want 161", id)
	}
	back, err := DecodeMonsterAttacked(got)
	if err != nil || *back != *m {
		t.Fatalf("round trip: %+v, %v; want %+v", back, err, m)
	}
	// A wall and a skill together.
	w := &MonsterAttacked{MonsterID: 7, TargetCharacterID: 42, TargetHP: 76, SkillID: 160,
		Wall: WallInfo{Absorbed: true, Damage: 9, HP: 30, Max: 50}}
	if back, err := DecodeMonsterAttacked(w.Encode()); err != nil || *back != *w {
		t.Fatalf("wall + skill round trip: %+v, %v", back, err)
	}
}

// The skill a blow names: the swing's drawn skill, else the species' primary
// (Skills[0], characterdata col 83), else none.
func TestStrikeSkillID(t *testing.T) {
	m := combat.Monster{Skills: []combat.MonsterSkill{{ID: 160}, {ID: 161}}}
	if got := strikeSkillID(m, combat.MonsterSkill{ID: 161}); got != 161 {
		t.Errorf("drawn skill: %d, want 161", got)
	}
	if got := strikeSkillID(m, combat.MonsterSkill{}); got != 160 {
		t.Errorf("no drawn skill: %d, want the primary 160", got)
	}
	if got := strikeSkillID(combat.Monster{}, combat.MonsterSkill{}); got != 0 {
		t.Errorf("no list: %d, want 0", got)
	}
}

// The counter's push names the species' primary attack skill.
func TestCounterPushNamesThePrimarySkill(t *testing.T) {
	strikePushForTest(t, true)
	z := startStrikeZone(t)
	sp := strikeMangyang
	sp.Skills = []combat.MonsterSkill{{ID: 160, ReuseMs: 3000, Range: 10}, {ID: 161, ReuseMs: 3000, Range: 10}}
	m := z.monsters.SpawnSpecies("jangan", sp, z.aria.x, 0, z.aria.z, 1000, 0, 15, 0)
	res, after := z.aria.attack(t, m.ID)
	if res.PlayerDamageTaken <= 0 {
		t.Fatalf("precondition: the counter was ready; got %+v", res)
	}
	got := strikes(t, after)
	if len(got) != 1 || got[0].SkillID != 160 {
		t.Fatalf("Aria's push %+v, want one naming skill 160", got)
	}
}
