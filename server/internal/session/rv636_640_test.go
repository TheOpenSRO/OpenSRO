package session

// The rounds 636-640 integration review's fixes.

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
)

// A death ends the wall -- and so its root -- on the default respawn path too
// (-player-dead-state off), as markDead ends the book on the dead-state path
// (round 616's rule). Before the fix a player killed through Crystal Wall
// (physical only) by magical blows respawned still walled: rooted, in state
// 0x11, the MP drain running.
func TestRound640ADeathOnTheRespawnPathEndsTheWall(t *testing.T) {
	if playerDeadState.Load() {
		t.Fatal("the rig runs with -player-dead-state on; this is the default (off) path")
	}
	w := startWallWorld(t)
	SetMonsterSkillRefs(w.ref)
	t.Cleanup(func() { SetMonsterSkillRefs(nil) })
	if e := w.cast(t, 99); e != "" { // Crystal Wall: 'pw' 7, the physical half
		t.Fatalf("Crystal Wall: %q", e)
	}
	start, err := DecodeBuffStart(w.expect(t, OpBuffStart).Data)
	if err != nil {
		t.Fatal(err)
	}
	if !wallRoots(w.aria) {
		t.Fatal("not rooted with the wall up")
	}
	// The Tomb Stone Ghost slave's magical blow ('att' 10) passes the wall.
	died := false
	for i := 0; i < 5000 && !died; i++ {
		out := w.strike(t, 171)
		if out.wall.Absorbed {
			t.Fatalf("blow %d: a magical blow absorbed by Crystal Wall: %+v", i, out.wall)
		}
		died = out.died
	}
	if !died {
		t.Fatal("the magical blows never killed Aria")
	}
	if w.hp(t) <= 0 {
		t.Fatalf("HP %d after the death: the respawn path did not run", w.hp(t))
	}
	end, err := DecodeBuffEnd(w.expect(t, OpBuffEnd).Data)
	if err != nil || len(end.Tokens) != 1 || end.Tokens[0] != start.Token {
		t.Fatalf("OpBuffEnd %+v %v, want the wall's token %d", end, err, start.Token)
	}
	if n := len(buffBooks.Active(w.aria)); n != 0 {
		t.Errorf("%d records after the death, want none", n)
	}
	if wallRoots(w.aria) {
		t.Error("still rooted after the death")
	}
	if s := motions.state(w.aria, time.Now()); s != MotionStand {
		t.Errorf("motion state %#x after the death, want STAND", s)
	}
	w.move(t, 40, 0, 40)
	if p := w.pos(t); p.X != 40 || p.Z != 40 {
		t.Errorf("a move after the death left Aria at %+v, want 40,40", p)
	}
}

// READ: the wall's 0x3009 refusal tests 'tel2' and 'tel3' as it tests 'tele'
// (Skill_CheckUseConditions 0x58e033..0x58e061). A row carrying 'tel2' alone
// (Ghost Walk's row with its 'tele' taken off and 'tel2' set: test data) is
// refused while the wall stands; before the fix only 'tele' was tested.
func TestRound640ATel2RowIsRefusedWhileWalled(t *testing.T) {
	w := startWallWorld(t)
	rows, err := refdata.LoadSkillsCSV(strings.NewReader(ghostWalk640CSV))
	if err != nil || len(rows) != 1 {
		t.Fatalf("the row: %v", err)
	}
	row := rows[0]
	row.ID, row.Tele0, row.Tele1, row.Tel2, row.ConsumeMP = 9901, 0, 0, true, 0
	if row.HasTele() || !row.HasTeleport() {
		t.Fatalf("test premise: HasTele %v HasTeleport %v", row.HasTele(), row.HasTeleport())
	}
	w.ref[9901] = &row
	if err := w.skills.Learn(context.Background(), w.aria, 9901); err != nil {
		t.Fatal(err)
	}
	if e := w.cast(t, 136); e != "" {
		t.Fatalf("Fire Wall: %q", e)
	}
	w.write(t, OpUseSkill, (&UseSkillRequest{CharacterName: "Aria", SkillID: 9901, TargetType: TargetGround, HasTargetType: true, X: 50, Z: 0}).Encode())
	ar, err := DecodeAttackResult(w.expect(t, OpAttackResult).Data)
	if err != nil || ar.Error != wallTeleRefusal {
		t.Fatalf("a 'tel2' row with a wall up: %+v %v, want %q", ar, err, wallTeleRefusal)
	}
}
