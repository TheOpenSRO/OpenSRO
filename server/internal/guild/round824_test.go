package guild

import (
	"bytes"
	"context"
	"testing"
)

// Round 824: the crest -- 256 palette indices under a revision one past the
// guild's last, 0 once deleted (SetCrest / ClearCrest / Crest), on both
// stores.
func TestRound824CrestMem(t *testing.T) { testRound824(t, NewMemStore()) }

func TestRound824CrestSQL(t *testing.T) { testRound824(t, openTestSQLStore(t)) }

func testRound824(t *testing.T, store Store) {
	t.Helper()
	ctx := context.Background()
	g, err := store.Create(ctx, "Crested", 1, "Ann")
	if err != nil {
		t.Fatal(err)
	}
	if rev, px, err := store.Crest(ctx, g.ID); err != nil || rev != 0 || px != nil {
		t.Fatalf("a new guild's crest: %d %v %v", rev, px, err)
	}
	if _, err := store.SetCrest(ctx, g.ID, make([]byte, 10)); err == nil {
		t.Fatal("a 10-byte crest was taken")
	}
	a := bytes.Repeat([]byte{7}, CrestBytes)
	rev, err := store.SetCrest(ctx, g.ID, a)
	if err != nil || rev != 1 {
		t.Fatalf("first crest: rev %d, %v", rev, err)
	}
	if r, px, _ := store.Crest(ctx, g.ID); r != 1 || !bytes.Equal(px, a) {
		t.Fatalf("read back: rev %d, %d bytes", r, len(px))
	}
	if got, _ := store.Get(ctx, g.ID); got.CrestRev != 1 {
		t.Fatalf("the guild's CrestRev %d", got.CrestRev)
	}
	if err := store.ClearCrest(ctx, g.ID); err != nil {
		t.Fatal(err)
	}
	if r, px, _ := store.Crest(ctx, g.ID); r != 0 || px != nil {
		t.Fatalf("after the delete: rev %d, %d bytes", r, len(px))
	}
	// A new crest takes a revision the old one never had.
	b := bytes.Repeat([]byte{9}, CrestBytes)
	if rev, _ := store.SetCrest(ctx, g.ID, b); rev != 2 {
		t.Fatalf("second crest's rev %d, want 2", rev)
	}
	if _, err := store.SetCrest(ctx, 999999, b); err != ErrGuildNotFound {
		t.Fatalf("no such guild: %v", err)
	}
}
