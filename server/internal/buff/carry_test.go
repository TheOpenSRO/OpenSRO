package buff

import (
	"encoding/json"
	"testing"
	"time"
)

// A book carried to another process's Books comes back whole: the records
// with their tokens and starts, the state bits, the speed holder (so the run
// speed), the GM /speed factor -- through JSON, as the hand-off carries it.
func TestBookSnapshotRestore(t *testing.T) {
	src := NewBooks(50)
	src.SeedTokens(3 << 24)
	now := time.Now()
	rec, _, refused, _ := src.Start(7, Spec{SkillID: 11, GroupID: 11, Level: 2, CasterID: 7, DuraMs: 60000,
		HasHste: true, Hste: 40, ActionOverlap: 0x0105}, now)
	if refused != NotRefused || rec.Token < 3<<24 {
		t.Fatalf("start %+v %v", rec, refused)
	}
	src.SetGMSpeedFactor(7, 2)
	want := src.RunSpeed(7)
	b, err := json.Marshal(src.Snapshot(7))
	if err != nil {
		t.Fatal(err)
	}
	var s BookState
	if err := json.Unmarshal(b, &s); err != nil {
		t.Fatal(err)
	}
	dst := NewBooks(50)
	sp := dst.Restore(7, s)
	if sp.RunSpeed != want || dst.RunSpeed(7) != want {
		t.Fatalf("run speed %d, want %d", dst.RunSpeed(7), want)
	}
	got := dst.Active(7)
	if len(got) != 1 || got[0].Token != rec.Token || !got[0].Start.Equal(rec.Start) || got[0].Dura != time.Minute {
		t.Fatalf("records %+v", got)
	}
	// The recast rule sees the carried bits: the same row is refused or
	// replaces as on the source.
	_, _, r1, _ := src.Start(7, Spec{SkillID: 12, CasterID: 7, ActionOverlap: 0x01}, now)
	_, _, r2, _ := dst.Start(7, Spec{SkillID: 12, CasterID: 7, ActionOverlap: 0x01}, now)
	if r1 != r2 {
		t.Fatalf("the recast rule differs after the move: %v vs %v", r1, r2)
	}
	// An empty state clears the book.
	dst.Restore(7, BookState{})
	if len(dst.Active(7)) != 0 {
		t.Fatal("not cleared")
	}
}
