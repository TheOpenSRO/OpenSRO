package account

import (
	"context"
	"errors"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/txn"
)

// Round 837: the silk balances, the same rules on both stores.

type silkTestStore interface {
	SilkStore
	Registerer
	SetStartingSilk(int64)
}

func TestMemStoreSilk(t *testing.T) { runSilkTests(t, func() silkTestStore { return NewMemStore() }) }

func TestSQLStoreSilk(t *testing.T) {
	runSilkTests(t, func() silkTestStore { return openTestSQLStore(t) })
}

func runSilkTests(t *testing.T, open func() silkTestStore) {
	ctx := context.Background()
	s := open()
	a, err := s.Register(ctx, "silky", "pw")
	if err != nil {
		t.Fatal(err)
	}
	if b, err := s.Silk(ctx, a.ID); err != nil || b != (Silk{}) {
		t.Fatalf("a new account: %+v %v", b, err)
	}
	if b, _ := s.AddSilk(ctx, a.ID, SilkOwn, 100); b != (Silk{Own: 100}) {
		t.Fatalf("add own %+v", b)
	}
	s.AddSilk(ctx, a.ID, SilkGift, 50)
	s.AddSilk(ctx, a.ID, SilkPoint, 7)
	if b, _ := s.AddSilk(ctx, a.ID, SilkGift, -80); b != (Silk{Own: 100, Gift: 0, Point: 7}) {
		t.Fatalf("a subtraction floors at 0: %+v", b)
	}
	if b, err := s.SpendSilk(ctx, a.ID, 30, 0, 7); err != nil || b != (Silk{Own: 70}) {
		t.Fatalf("spend %+v %v", b, err)
	}
	if _, err := s.SpendSilk(ctx, a.ID, 71, 0, 0); !errors.Is(err, ErrInsufficientSilk) {
		t.Fatalf("overspend: %v", err)
	}
	if _, err := s.SpendSilk(ctx, a.ID, 1, 1, 0); !errors.Is(err, ErrInsufficientSilk) {
		t.Fatal("a spend with one short balance took the other")
	}
	if b, _ := s.Silk(ctx, a.ID); b != (Silk{Own: 70}) {
		t.Fatalf("after the refused spends %+v", b)
	}
	if _, err := s.SpendSilk(ctx, 999999, 0, 0, 0); !errors.Is(err, ErrNoSuchAccount) {
		t.Fatalf("no such account: %v", err)
	}
	// A spend inside a failed action is undone.
	boom := errors.New("boom")
	err = txn.For(s).Run(ctx, func(ctx context.Context) error {
		if _, err := s.SpendSilk(ctx, a.ID, 70, 0, 0); err != nil {
			return err
		}
		return boom
	})
	if !errors.Is(err, boom) {
		t.Fatal(err)
	}
	if b, _ := s.Silk(ctx, a.ID); b != (Silk{Own: 70}) {
		t.Fatalf("after the rolled-back spend %+v", b)
	}
	// The starting grant: once per account, and only while it is set.
	s.SetStartingSilk(500)
	if b, _ := s.Silk(ctx, a.ID); b.Own != 570 {
		t.Fatalf("starting silk %+v", b)
	}
	if b, _ := s.Silk(ctx, a.ID); b.Own != 570 {
		t.Fatalf("starting silk given twice: %+v", b)
	}
	c, _ := s.Register(ctx, "late", "pw")
	if b, _ := s.Silk(ctx, c.ID); b.Own != 500 {
		t.Fatalf("a later account's grant %+v", b)
	}
}
