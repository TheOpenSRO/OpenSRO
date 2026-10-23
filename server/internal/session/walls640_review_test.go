package session

// Round 640's review follow-up: Ghost Walk refused while walled (READ,
// 0x58e033..0x58e061, 0x3009) and the root's answer to a dropped move (OURS).

import (
	"context"
	"strings"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
)

// Ghost Walk - Phantom lv1 (114): 'tele' 500,100, MEASURED on the RE box's
// export, typed here as test data.
const ghostWalk640CSV = `114,261,SKILL_CH_LIGHTNING_GYEONGGONG_B_01,0,1,0,0,0,0,0,5000,0,0,0,0,0,0,0,225,172,0,SN_SKILL_CH_LIGHTNING_GYEONGGONG_B,274,32,0,0,0,0,0,255,255,0,,0,1,1,0,260,1,0,0,0,0,0,0,59,0,0,1,1,0,0,0,0,0,0,0,0,500,100,,0,0,0,0,0,0,0,0,0,0,0,0,0,SKILL_CH_LIGHTNING_GYEONGGONG_B,2,0,0,0,0,0,0,0,0,0,0,0
`

func addGhostWalk(t *testing.T, w *wallWorld) {
	t.Helper()
	rows, err := refdata.LoadSkillsCSV(strings.NewReader(ghostWalk640CSV))
	if err != nil || len(rows) != 1 || !rows[0].HasTele() {
		t.Fatalf("the Ghost Walk row: %v %+v", err, rows)
	}
	rows[0].ConsumeMP = 0
	w.ref[114] = &rows[0]
	if err := w.skills.Learn(context.Background(), w.aria, 114); err != nil {
		t.Fatal(err)
	}
}

// READ: with a wall on the book, a 'tele' row is refused 0x3009 before
// anything else; with none, the same cast moves the caster.
func TestRound640GhostWalkIsRefusedWhileWalled(t *testing.T) {
	w := startWallWorld(t)
	addGhostWalk(t, w)
	if e := w.cast(t, 136); e != "" {
		t.Fatalf("Fire Wall: %q", e)
	}
	w.write(t, OpUseSkill, (&UseSkillRequest{CharacterName: "Aria", SkillID: 114, TargetType: TargetGround, HasTargetType: true, X: 50, Z: 0}).Encode())
	ar, err := DecodeAttackResult(w.expect(t, OpAttackResult).Data)
	if err != nil || ar.Error != wallTeleRefusal {
		t.Fatalf("Ghost Walk with a wall up: %+v %v, want %q", ar, err, wallTeleRefusal)
	}
	if e := w.cast(t, 136); e != "" { // the recast switches the wall off
		t.Fatalf("the recast: %q", e)
	}
	w.write(t, OpUseSkill, (&UseSkillRequest{CharacterName: "Aria", SkillID: 114, TargetType: TargetGround, HasTargetType: true, X: 50, Z: 0}).Encode())
	ar, err = DecodeAttackResult(w.expect(t, OpAttackResult).Data)
	if err != nil || ar.Error != "" {
		t.Fatalf("Ghost Walk with no wall: %+v %v", ar, err)
	}
	if p := w.pos(t); p.X != 50 {
		t.Fatalf("Ghost Walk left Aria at %+v", p)
	}
}

// OURS: a move the root drops is answered with the position the server holds,
// as an OpSkillMove carrying the wall's skill, to the mover alone.
func TestRound640ARootedMoveIsAnsweredWithTheHeldPosition(t *testing.T) {
	w := startWallWorld(t)
	w.move(t, 10, 0, 10)
	if e := w.cast(t, 136); e != "" {
		t.Fatalf("Fire Wall: %q", e)
	}
	w.move(t, 40, 0, 40)
	m, err := DecodeSkillMove(w.expect(t, OpSkillMove).Data)
	if err != nil || m.CharacterID != w.aria || m.SkillID != 136 || m.X != 10 || m.Z != 10 {
		t.Fatalf("the answer to a rooted move: %+v %v, want Aria held at 10,10 by skill 136", m, err)
	}
}
