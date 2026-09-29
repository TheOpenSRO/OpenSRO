package session

// Round 640's root (OURS -- the user's choice "Root while walled"; nothing in
// retail's binaries roots a walled caster, docs/protocol/skill_buffs.md). Its
// negative runs against 946da3a, the round before the root, where the move
// goes through.

import (
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/world"
)

func (w *wallWorld) pos(t *testing.T) world.Position {
	t.Helper()
	e, ok := w.hub.EntityByCharacterID(w.aria)
	if !ok {
		t.Fatal("Aria is not in the world")
	}
	return e.Pos
}

// move sends one OpMove and waits long enough for the handler to have run
// (a dropped move answers nothing, so there is nothing to wait for).
func (w *wallWorld) move(t *testing.T, x, y, z float32) {
	t.Helper()
	w.write(t, OpMove, (&MoveRequest{X: x, Y: y, Z: z}).Encode())
	time.Sleep(150 * time.Millisecond)
}

// A wall up: a move is dropped and the caster stays where she stood; the
// wall's cancel ends the root and the same move goes through.
func TestRound640TheWallRootsItsCaster(t *testing.T) {
	w := startWallWorld(t)
	w.move(t, 10, 0, 10)
	if p := w.pos(t); p.X != 10 || p.Z != 10 {
		t.Fatalf("an ordinary move left Aria at %+v", p)
	}
	if e := w.cast(t, 136); e != "" {
		t.Fatalf("Fire Wall: %q", e)
	}
	start, err := DecodeBuffStart(w.expect(t, OpBuffStart).Data)
	if err != nil {
		t.Fatal(err)
	}
	w.move(t, 40, 0, 40)
	if p := w.pos(t); p.X != 10 || p.Z != 10 {
		t.Errorf("a move with the wall up took Aria to %+v, want her rooted at 10,10", p)
	}
	w.write(t, OpBuffCancel, (&BuffCancelRequest{CharacterName: "Aria", SkillID: 136, Token: start.Token}).Encode())
	if _, err := DecodeBuffEnd(w.expect(t, OpBuffEnd).Data); err != nil {
		t.Fatal(err)
	}
	w.move(t, 40, 0, 40)
	if p := w.pos(t); p.X != 40 || p.Z != 40 {
		t.Errorf("a move after the cancel left Aria at %+v, want 40,40", p)
	}
}

// The recast (the toggle-off) and the MP drain's end each end the root (the
// wall's break: TestRound640FireWallAbsorbsMagicUntilItBreaks). Told by the
// moves alone, so the file runs on the round before the root too.
func TestRound640EveryEndEndsTheRoot(t *testing.T) {
	w := startWallWorld(t)
	if e := w.cast(t, 136); e != "" {
		t.Fatalf("Fire Wall: %q", e)
	}
	w.move(t, 20, 0, 20)
	if p := w.pos(t); p.X == 20 {
		t.Errorf("a move with Fire Wall up went through to %+v", p)
	}
	if e := w.cast(t, 136); e != "" {
		t.Fatalf("the recast: %q", e)
	}
	w.move(t, 20, 0, 20)
	if p := w.pos(t); p.X != 20 {
		t.Errorf("a move after the recast switched the wall off left Aria at %+v", p)
	}
	if e := w.cast(t, 99); e != "" {
		t.Fatalf("Crystal Wall: %q", e)
	}
	w.move(t, 30, 0, 30)
	if p := w.pos(t); p.X == 30 {
		t.Errorf("a move with Crystal Wall up went through to %+v", p)
	}
	recs := buffBooks.Active(w.aria)
	if len(recs) != 1 {
		t.Fatalf("%d records", len(recs))
	}
	c, _ := w.chars.GetByID(t.Context(), w.aria)
	w.mp.Spend(w.aria, c.MaxMP(), w.mp.Current(w.aria, c.MaxMP())-1)
	togglePass(t.Context(), w.hub, w.chars, RegenDeps{Mana: w.mp}, recs[0].LastDrain.Add(5001*time.Millisecond))
	w.move(t, 30, 0, 30)
	if p := w.pos(t); p.X != 30 {
		t.Errorf("a move after the drain ended the wall left Aria at %+v", p)
	}
}
