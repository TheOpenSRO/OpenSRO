package guild

import (
	"context"
	"errors"
	"testing"
	"time"
)

var (
	_ PresenceStore  = (*MemStore)(nil)
	_ PresenceStore  = (*SQLStore)(nil)
	_ GPHistoryStore = (*MemStore)(nil)
	_ GPHistoryStore = (*SQLStore)(nil)
	_ GPSpendStore   = (*MemStore)(nil)
	_ GPSpendStore   = (*SQLStore)(nil)
)

type part2Store interface {
	Store
	PresenceStore
	GPHistoryStore
	GPSpendStore
}

// Round 844 lane G part 2: the last logouts, the GP history and the GP spend
// on both stores.
func TestRound844Part2Mem(t *testing.T) { testRound844Part2(t, NewMemStore()) }

func TestRound844Part2SQL(t *testing.T) { testRound844Part2(t, openTestSQLStore(t)) }

func testRound844Part2(t *testing.T, s part2Store) {
	t.Helper()
	ctx := context.Background()
	g, err := s.Create(ctx, "Part2", 84401, "Boss")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Join(ctx, g.ID, 84402, "Ann"); err != nil {
		t.Fatal(err)
	}
	at := time.Now().Add(-50 * 24 * time.Hour).Truncate(time.Second)
	if err := s.SetLastLogout(ctx, 84401, at); err != nil {
		t.Fatal(err)
	}
	lo, err := s.LastLogouts(ctx, g.ID)
	if err != nil || !lo[84401].Equal(at) || len(lo) != 1 {
		t.Fatalf("last logouts %v %v", lo, err)
	}
	// The spend: a member refused, too little refused, then the master.
	if _, err := s.SpendPoints(ctx, 84402, 10, nil); !errors.Is(err, ErrGuildStoreNotMaster) {
		t.Fatalf("member %v", err)
	}
	if _, err := s.SpendPoints(ctx, 99999, 10, nil); !errors.Is(err, ErrGuildStoreNotMaster) {
		t.Fatalf("no guild %v", err)
	}
	if err := s.AddPoints(ctx, g.ID, 84402, 100); err != nil {
		t.Fatal(err)
	}
	if _, err := s.SpendPoints(ctx, 84401, 101, nil); !errors.Is(err, ErrGuildStoreLackGP) {
		t.Fatalf("short %v", err)
	}
	payErr := errors.New("no room")
	if _, err := s.SpendPoints(ctx, 84401, 40, func() error { return payErr }); !errors.Is(err, payErr) {
		t.Fatalf("pay %v", err)
	}
	after, err := s.SpendPoints(ctx, 84401, 40, func() error { return nil })
	if err != nil || after.GatheredSP != 60 {
		t.Fatalf("spend %+v %v", after, err)
	}
	// The history: newest first.
	now := time.Now()
	_ = s.AddGPHistory(ctx, g.ID, GPHistoryEntry{At: now.Add(-time.Minute), Name: "Boss", GP: 5400, Kind: GPUseGuildGrowth})
	_ = s.AddGPHistory(ctx, g.ID, GPHistoryEntry{At: now, Name: "Boss", GP: 40, Kind: GPUseGuildItem})
	list, err := s.GPHistory(ctx, g.ID, now.Add(time.Second))
	if err != nil || len(list) < 2 || list[0].Kind != GPUseGuildItem || list[1].GP != 5400 {
		t.Fatalf("history %+v %v", list, err)
	}
	_, _ = s.Disband(ctx, g.ID)
}
