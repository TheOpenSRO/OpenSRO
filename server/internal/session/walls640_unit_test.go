package session

// Round 640, the parts the negative file cannot reach on the base: the
// magical blow through the skill table, the break, the drain, the motion
// state and the wire suffix. Same rows and rig as walls640_test.go.

import (
	"context"
	"testing"
	"time"
)

// Fire Wall - Tower lv1 takes the Tomb Stone Ghost slave's magical blows
// ('att' 10, read through the skill table) off its 1159 HP while Aria's HP
// stays put; the blow that empties it breaks it, the wall's record ends on
// the next pass with an OpBuffEnd, Aria stands again, and the next magical
// blow lands on her.
func TestRound640FireWallAbsorbsMagicUntilItBreaks(t *testing.T) {
	w := startWallWorld(t)
	SetMonsterSkillRefs(w.ref)
	t.Cleanup(func() { SetMonsterSkillRefs(nil) })
	if e := w.cast(t, 136); e != "" {
		t.Fatalf("Fire Wall: %q", e)
	}
	start, err := DecodeBuffStart(w.expect(t, OpBuffStart).Data)
	if err != nil {
		t.Fatal(err)
	}
	if s := motions.state(w.aria, time.Now()); s != MotionProtectionWall {
		t.Fatalf("motion state %#x after the wall, want 0x11 SKILL_PROTECTIONWALL", s)
	}
	before := w.hp(t)
	wallHP := 1159
	broke := false
	for i := 0; i < 200 && !broke; i++ {
		out := w.strike(t, 171)
		if !out.wall.Absorbed {
			t.Fatalf("blow %d: not absorbed while the wall had %d HP: %+v", i, wallHP, out)
		}
		if out.damage != 0 || w.hp(t) != before {
			t.Fatalf("blow %d: the caster took %d (HP %d -> %d)", i, out.damage, before, w.hp(t))
		}
		want := wallHP - int(out.wall.Damage)
		if want < 0 {
			want = 0
		}
		if out.wall.Damage < 1 || int(out.wall.HP) != want || out.wall.Max != 1159 {
			t.Fatalf("blow %d: wall %+v, want %d - damage = %d of 1159", i, out.wall, wallHP, want)
		}
		wallHP = int(out.wall.HP)
		broke = out.wall.Broke
		if broke != (wallHP == 0) {
			t.Fatalf("blow %d: broke %v at %d HP", i, broke, wallHP)
		}
		// The push repeats it: the strike's OpMonsterAttacked carries the
		// suffix.
		msg, err := DecodeMonsterAttacked(out.message(9001, w.aria).Encode())
		if err != nil || msg.Wall != out.wall {
			t.Fatalf("blow %d: OpMonsterAttacked wall %+v %v, want %+v", i, msg.Wall, err, out.wall)
		}
	}
	if !broke {
		t.Fatal("the wall never broke")
	}
	// The break's end comes after the blow's messages (the strike's caller,
	// or the toggle ticker's next pass -- driven here).
	if n := len(buffBooks.Active(w.aria)); n != 1 {
		t.Fatalf("%d records right after the breaking blow, want the wall still listed until the end runs", n)
	}
	togglePass(context.Background(), w.hub, w.chars, RegenDeps{Mana: w.mp}, time.Now())
	end, err := DecodeBuffEnd(w.expect(t, OpBuffEnd).Data)
	if err != nil || len(end.Tokens) != 1 || end.Tokens[0] != start.Token {
		t.Fatalf("OpBuffEnd %+v %v, want the wall's token", end, err)
	}
	if n := len(buffBooks.Active(w.aria)); n != 0 {
		t.Fatalf("%d records after the break", n)
	}
	if s := motions.state(w.aria, time.Now()); s != MotionStand {
		t.Fatalf("motion state %#x after the break, want STAND", s)
	}
	out := w.strike(t, 171)
	if out.wall.Absorbed || out.damage <= 0 || w.hp(t) != before-out.damage {
		t.Fatalf("after the break: %+v, HP %d -> %d; want the blow on the caster", out, before, w.hp(t))
	}
}

// Crystal Wall does not cover magic ('pw' 7): the Tomb Stone Ghost's blow
// lands on the caster and the wall keeps its HP.
func TestRound640CrystalWallLetsMagicThrough(t *testing.T) {
	w := startWallWorld(t)
	SetMonsterSkillRefs(w.ref)
	t.Cleanup(func() { SetMonsterSkillRefs(nil) })
	if e := w.cast(t, 99); e != "" {
		t.Fatalf("Crystal Wall: %q", e)
	}
	before := w.hp(t)
	out := w.strike(t, 171)
	if out.wall.Absorbed || out.damage <= 0 || w.hp(t) != before-out.damage {
		t.Fatalf("%+v, HP %d -> %d", out, before, w.hp(t))
	}
	if recs := buffBooks.Active(w.aria); len(recs) != 1 || !recs[0].HasWall || recs[0].WallHP != 824 {
		t.Fatalf("the wall: %+v, want 824 HP untouched", recs)
	}
}

// While a wall stands the caster is in SKILL_PROTECTIONWALL: the other wall
// ('pw', SitGate 1) is refused there by the gate's motion test (0x58e0cb),
// before the recast rule; a cancel ends the wall and stands the caster.
func TestRound640TheWallStateRefusesTheOtherWall(t *testing.T) {
	w := startWallWorld(t)
	if e := w.cast(t, 136); e != "" {
		t.Fatalf("Fire Wall: %q", e)
	}
	start, _ := DecodeBuffStart(w.expect(t, OpBuffStart).Data)
	if e := w.cast(t, 99); e != wallStateRefusal {
		t.Fatalf("Crystal Wall over Fire Wall: %q, want %q", e, wallStateRefusal)
	}
	if _, ok := motions.regenRate(w.aria, time.Now()); ok {
		t.Fatal("regeneration runs in SKILL_PROTECTIONWALL; CGObjPC::vslot_362 restores only in STAND and SIT")
	}
	w.write(t, OpBuffCancel, (&BuffCancelRequest{CharacterName: "Aria", SkillID: 136, Token: start.Token}).Encode())
	if _, err := DecodeBuffEnd(w.expect(t, OpBuffEnd).Data); err != nil {
		t.Fatal(err)
	}
	if s := motions.state(w.aria, time.Now()); s != MotionStand {
		t.Fatalf("motion state %#x after the cancel, want STAND", s)
	}
}

// The toggle-off answers with the ToggledOff marker and no cost.
func TestRound640ToggleOffReplyIsMarked(t *testing.T) {
	w := startWallWorld(t)
	if e := w.cast(t, 136); e != "" {
		t.Fatalf("Fire Wall: %q", e)
	}
	w.write(t, OpUseSkill, (&UseSkillRequest{CharacterName: "Aria", SkillID: 136, TargetType: TargetNone, HasTargetType: true}).Encode())
	ar, err := DecodeAttackResult(w.expect(t, OpAttackResult).Data)
	if err != nil || ar.Error != "" || !ar.Wall.ToggledOff || ar.PlayerHP != int32(w.hp(t)) {
		t.Fatalf("the toggle-off reply: %+v %v", ar, err)
	}
}

// The drain: 58 MP every 5000 ms (strictly after), a pool of exactly 58 pays
// it down to 0, and a pool short of 58 ends the wall -- with its OpBuffEnd,
// and the caster on her feet.
func TestRound640TheDrainTakesMPAndEndsTheWall(t *testing.T) {
	w := startWallWorld(t)
	if e := w.cast(t, 136); e != "" {
		t.Fatalf("Fire Wall: %q", e)
	}
	start, _ := DecodeBuffStart(w.expect(t, OpBuffStart).Data)
	recs := buffBooks.Active(w.aria)
	if len(recs) != 1 || !recs[0].HasOnff || recs[0].OnffMs != 5000 || recs[0].OnffMP != 58 {
		t.Fatalf("the record: %+v", recs)
	}
	t0 := recs[0].LastDrain
	ctx := context.Background()
	c, _ := w.chars.GetByID(ctx, w.aria)
	max := c.MaxMP()
	if max < 116 {
		t.Fatalf("MaxMP %d too small for the test", max)
	}
	w.mp.Spend(w.aria, max, max-116)
	deps := RegenDeps{Mana: w.mp}
	togglePass(ctx, w.hub, w.chars, deps, t0.Add(5000*time.Millisecond))
	if got := w.mp.Current(w.aria, max); got != 116 {
		t.Fatalf("MP %d at exactly 5000 ms, want 116 (not yet due)", got)
	}
	togglePass(ctx, w.hub, w.chars, deps, t0.Add(5001*time.Millisecond))
	if got := w.mp.Current(w.aria, max); got != 58 {
		t.Fatalf("MP %d after the first drain, want 58", got)
	}
	togglePass(ctx, w.hub, w.chars, deps, t0.Add(10002*time.Millisecond))
	if got := w.mp.Current(w.aria, max); got != 0 || len(buffBooks.Active(w.aria)) != 1 {
		t.Fatalf("MP %d / %d records after a drain of exactly the pool, want 0 and the wall still up", got, len(buffBooks.Active(w.aria)))
	}
	togglePass(ctx, w.hub, w.chars, deps, t0.Add(15003*time.Millisecond))
	if n := len(buffBooks.Active(w.aria)); n != 0 {
		t.Fatalf("%d records with MP short of the drain, want the wall ended", n)
	}
	end, err := DecodeBuffEnd(w.expect(t, OpBuffEnd).Data)
	if err != nil || len(end.Tokens) != 1 || end.Tokens[0] != start.Token {
		t.Fatalf("OpBuffEnd %+v %v", end, err)
	}
	if s := motions.state(w.aria, time.Now()); s != MotionStand {
		t.Fatalf("motion state %#x, want STAND", s)
	}
}

// The suffixes: a result or a push without them decodes as no wall; with
// them, every field comes back.
func TestRound640WallSuffixRoundTrips(t *testing.T) {
	wi := WallInfo{Absorbed: true, Broke: true, Critical: true, Damage: 321, HP: 0, Max: 1159}
	r := &AttackResult{PlayerHP: 90, MonsterID: 4, Wall: wi}
	got, err := DecodeAttackResult(r.Encode())
	if err != nil || got.Wall != wi || got.PlayerHP != 90 || got.MonsterID != 4 {
		t.Fatalf("AttackResult: %+v %v", got, err)
	}
	full := r.Encode()
	old, err := DecodeAttackResult(full[:len(full)-wallInfoSize])
	if err != nil || old.Wall != (WallInfo{}) {
		t.Fatalf("a result without the suffix: %+v %v", old, err)
	}
	m := &MonsterAttacked{MonsterID: 1, TargetCharacterID: 2, TargetHP: 50, Wall: WallInfo{Absorbed: true, Damage: 7, HP: 800, Max: 824}}
	enc := m.Encode()
	if len(enc) != MonsterAttackedSize+wallInfoSize || len((&MonsterAttacked{MonsterID: 1}).Encode()) != MonsterAttackedSize {
		t.Fatalf("OpMonsterAttacked is %d bytes, want %d", len(enc), MonsterAttackedSize+wallInfoSize)
	}
	back, err := DecodeMonsterAttacked(enc)
	if err != nil || back.Wall != m.Wall {
		t.Fatalf("MonsterAttacked: %+v %v", back, err)
	}
	short, err := DecodeMonsterAttacked(enc[:MonsterAttackedSize])
	if err != nil || short.Wall != (WallInfo{}) {
		t.Fatalf("a 33-byte push: %+v %v", short, err)
	}
}
