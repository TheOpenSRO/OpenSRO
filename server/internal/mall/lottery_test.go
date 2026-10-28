package mall

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/txn"
)

// Round 838: the Silk Lottery's registrations, in memory and in PostgreSQL
// alike: open entries in order, a close that marks the winner, and a
// registration undone with its purchase.
func TestLotteryStores(t *testing.T) {
	ctx := context.Background()
	now := time.Now().Truncate(time.Second)
	for name, s := range map[string]interface {
		Store
		LotteryStore
	}{"memory": NewMemStore(), "postgres": openTestSQLStore(t)} {
		t.Run(name, func(t *testing.T) {
			for i, code := range []string{"ITEM_LOTTERY_BRONZE", "ITEM_LOTTERY_GOLD"} {
				if err := s.RegisterLottery(ctx, LotteryEntry{AccountID: 1, CharacterID: int64(10 + i), Ticket: code,
					Silk: int64(50 + 100*i), At: now}); err != nil {
					t.Fatal(err)
				}
			}
			_ = txn.For(s).Run(ctx, func(ctx context.Context) error {
				if err := s.RegisterLottery(ctx, LotteryEntry{AccountID: 2, CharacterID: 12, Ticket: "ITEM_LOTTERY_SILVER", Silk: 100, At: now}); err != nil {
					t.Fatal(err)
				}
				return errors.New("the purchase failed")
			})
			es, err := s.OpenLottery(ctx)
			if err != nil || len(es) != 2 || es[0].Ticket != "ITEM_LOTTERY_BRONZE" || es[1].Silk != 150 || es[1].CharacterID != 11 {
				t.Fatalf("open %+v %v", es, err)
			}
			if n, err := s.CloseLottery(ctx, es[1].ID, 200, now); n != 2 || err != nil {
				t.Fatalf("close %d %v", n, err)
			}
			if es, _ := s.OpenLottery(ctx); len(es) != 0 {
				t.Fatalf("still open %+v", es)
			}
		})
	}
	if !IsLotteryTicket("item_lottery_gold") || IsLotteryTicket("ITEM_SILK_LOTTERY") {
		t.Error("IsLotteryTicket")
	}
}
