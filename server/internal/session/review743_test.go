package session

import (
	"context"
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/grounditem"
	"github.com/TheOpenSRO/OpenSRO/server/internal/txn"
)

// Round 743's review, F1: four party members picking up gold piles at once.
// Each pick credits every member's share in one transaction, the picker's
// share first in the message order. Credited in that order, two members'
// picks locked each other's rows in opposite orders and deadlocked: the
// review measured 59 of 200 picks failed and a worst pick of 15 s. Credited
// in character-id order (sharesByCharacter), none may fail or stall.
func TestPartyGoldPickupsDoNotDeadlock(t *testing.T) {
	ctx := context.Background()
	db, err := txn.OpenPool(inventoryTestDSN(), 32)
	if err != nil {
		t.Fatalf("OpenPool: %v", err)
	}
	defer db.Close()
	chars, err := character.NewSQLStore(db)
	if err != nil {
		t.Fatalf("character store: %v", err)
	}
	if _, err := db.Exec(`TRUNCATE characters RESTART IDENTITY CASCADE; TRUNCATE economy_ops`); err != nil {
		t.Fatalf("truncating: %v", err)
	}
	var party []int64
	for i := 0; i < 4; i++ {
		c, err := chars.Create(ctx, int64(i+1), fmt.Sprintf("Member%d", i))
		if err != nil {
			t.Fatalf("creating a member: %v", err)
		}
		party = append(party, c.ID)
	}
	runner := txn.For(chars)
	const picksEach = 50
	var wg sync.WaitGroup
	var mu sync.Mutex
	var failed int
	var worst time.Duration
	for p, picker := range party {
		wg.Add(1)
		go func(p int, picker int64) {
			defer wg.Done()
			// The picker first, then the party in its own order, as splitGold
			// builds the shares.
			shares := []goldShare{{picker, 10}}
			for _, m := range party {
				if m != picker {
					shares = append(shares, goldShare{m, 10})
				}
			}
			for i := 0; i < picksEach; i++ {
				it := grounditem.Item{ItemID: grounditem.GoldItemID, Quantity: 40, Gold: true, Serial: -int64(1_000_000 + p*picksEach + i)}
				start := time.Now()
				err := applyPickup(ctx, runner, chars, nil, it, pickupLedgerKey(it), picker, shares)
				d := time.Since(start)
				mu.Lock()
				if err != nil {
					failed++
				}
				if d > worst {
					worst = d
				}
				mu.Unlock()
			}
		}(p, picker)
	}
	wg.Wait()
	t.Logf("%d picks: %d failed, worst %s", len(party)*picksEach, failed, worst)
	if failed != 0 || worst > 500*time.Millisecond {
		t.Fatalf("party gold pick-ups: %d failed, worst %s; want none failed and none past 0.5 s", failed, worst)
	}
	for _, id := range party {
		c, _ := chars.GetByID(ctx, id)
		if want := int64(character.StartingGold) + int64(len(party)*picksEach*10); c.Gold != want {
			t.Fatalf("member %d holds %d, want %d", id, c.Gold, want)
		}
	}
}
