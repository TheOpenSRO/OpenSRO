package guildstorage

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"sync"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/testdb"
	"github.com/TheOpenSRO/OpenSRO/server/internal/txn"
)

func testDSN() string {
	if v := os.Getenv("OPENSRO_TEST_POSTGRES_DSN"); v != "" {
		return v
	}
	return "postgres://postgres:postgres@localhost:5432/opensro_test?sslmode=disable"
}

func TestMain(m *testing.M) {
	release := testdb.Lock(testDSN())
	code := m.Run()
	release()
	os.Exit(code)
}

// The items: 100 a potion (stacks to 50, fee 7), 200 a sword (one, fee 10),
// 300 a quest item (3/3/9), 400 an untradeable one.
type items struct{}

func (items) GetItem(_ context.Context, id int64) (*refdata.Item, error) {
	switch id {
	case 100:
		return &refdata.Item{ID: id, MaxStack: 50, KeepingFee: 7, CanTrade: true, TypeID1: 3, TypeID2: 3, TypeID3: 1}, nil
	case 200:
		return &refdata.Item{ID: id, MaxStack: 1, KeepingFee: 10, CanTrade: true, TypeID1: 3, TypeID2: 1}, nil
	case 300:
		return &refdata.Item{ID: id, MaxStack: 1, KeepingFee: 1, CanTrade: true, TypeID1: 3, TypeID2: 3, TypeID3: 9}, nil
	case 400:
		return &refdata.Item{ID: id, MaxStack: 1, KeepingFee: 1, CanTrade: false, TypeID1: 3, TypeID2: 1}, nil
	}
	return nil, errors.New("no such item")
}

func (items) GetMaxStack(ctx context.Context, id int64) (int, error) {
	it, err := items{}.GetItem(ctx, id)
	if err != nil {
		return 0, nil
	}
	return it.MaxStack, nil
}

type fixture struct {
	svc        *Service
	bag, chest inventory.Store
	chars      character.Store
	vault      GoldStore
	charID     int64
	guildID    int64
	db         *sql.DB
}

const testGuild = 7

func newMem(t *testing.T) *fixture {
	t.Helper()
	bag := inventory.NewMemStore(items{})
	chest := inventory.NewMemStore(items{})
	chest.SetCapacity(MaxSlots)
	chest.SetCapacityFunc(func(context.Context, int64) int { return Capacity(2) })
	chars := character.NewMemStore()
	c, err := chars.Create(context.Background(), 1, "Aria")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	vault := NewMemGold()
	return &fixture{svc: &Service{Bag: bag, Chest: chest, Purse: chars, Vault: vault, Items: items{}},
		bag: bag, chest: chest, chars: chars, vault: vault, charID: c.ID, guildID: testGuild}
}

func newSQL(t *testing.T) *fixture {
	t.Helper()
	ctx := context.Background()
	db, err := txn.OpenPool(testDSN(), 8)
	if err != nil {
		t.Fatalf("OpenPool: %v (is postgres running?)", err)
	}
	t.Cleanup(func() { db.Close() })
	accounts, err := account.NewSQLStore(db)
	if err != nil {
		t.Fatalf("account store: %v", err)
	}
	chars, err := character.NewSQLStore(db)
	if err != nil {
		t.Fatalf("character store: %v", err)
	}
	bag, err := inventory.NewSQLStoreOwned(db, items{}, inventory.DefaultTable, inventory.DefaultOwnerColumn)
	if err != nil {
		t.Fatalf("bag store: %v", err)
	}
	chest, err := inventory.NewSQLStoreOwned(db, items{}, ChestTable, ChestOwner)
	if err != nil {
		t.Fatalf("chest store: %v", err)
	}
	chest.SetCapacity(MaxSlots)
	chest.SetCapacityFunc(func(context.Context, int64) int { return Capacity(2) })
	vault, err := NewSQLGold(db)
	if err != nil {
		t.Fatalf("gold store: %v", err)
	}
	if _, err := db.Exec(`TRUNCATE accounts RESTART IDENTITY CASCADE; TRUNCATE characters RESTART IDENTITY CASCADE;
		TRUNCATE inventory_slots; TRUNCATE ` + ChestTable + `; TRUNCATE guild_storage_gold; TRUNCATE economy_ops`); err != nil {
		t.Fatalf("truncating: %v", err)
	}
	acc, err := accounts.Register(ctx, "player", "pw")
	if err != nil {
		t.Fatalf("Register: %v", err)
	}
	c, err := chars.Create(ctx, acc.ID, "Aria")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	return &fixture{svc: &Service{Bag: bag, Chest: chest, Purse: chars, Vault: vault, Items: items{}},
		bag: bag, chest: chest, chars: chars, vault: vault, charID: c.ID, guildID: testGuild, db: db}
}

func (f *fixture) count(t *testing.T, st inventory.Store, owner, itemID int64) int {
	t.Helper()
	list, err := st.List(context.Background(), owner)
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	n := 0
	for _, s := range list {
		if s.ItemID == itemID {
			n += s.Quantity
		}
	}
	return n
}

func (f *fixture) slot(t *testing.T, st inventory.Store, owner int64, index int) *inventory.Slot {
	t.Helper()
	list, err := st.List(context.Background(), owner)
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	return slotAt(list, index)
}

func (f *fixture) purse(t *testing.T) int64 {
	t.Helper()
	c, err := f.chars.GetByID(context.Background(), f.charID)
	if err != nil {
		t.Fatalf("GetByID: %v", err)
	}
	return c.Gold
}

func (f *fixture) gold(t *testing.T) int64 {
	t.Helper()
	g, err := f.vault.Gold(context.Background(), f.guildID)
	if err != nil {
		t.Fatalf("Gold: %v", err)
	}
	return g
}

func both(t *testing.T, run func(t *testing.T, f *fixture)) {
	t.Run("mem", func(t *testing.T) { run(t, newMem(t)) })
	t.Run("sql", func(t *testing.T) { run(t, newSQL(t)) })
}

// The READ size table and the fee.
func TestCapacityAndFee(t *testing.T) {
	for level, want := range map[int]int{0: 0, 1: 0, 2: 30, 3: 60, 4: 90, 5: 120} {
		if got := Capacity(level); got != want {
			t.Errorf("Capacity(%d) = %d, want %d", level, got, want)
		}
	}
	for _, c := range []struct {
		fee   int64
		count int
		want  int64
	}{{0, 5, 1}, {1, 1, 1}, {7, 3, 10}, {10, 1, 5}, {2_000_000, 50, FeeCap}, {3, 7, 10}} {
		if got := Fee(c.fee, c.count); got != c.want {
			t.Errorf("Fee(%d, %d) = %d, want %d", c.fee, c.count, got, c.want)
		}
	}
}

// A deposit moves the whole stack to the named slot and takes half the fee.
func TestDepositWholeStackAndFee(t *testing.T) {
	both(t, func(t *testing.T, f *fixture) {
		ctx := context.Background()
		if err := f.bag.AddItem(ctx, f.charID, 100, 20); err != nil {
			t.Fatal(err)
		}
		dst, fee, err := f.svc.Deposit(ctx, f.charID, f.guildID, Capacity(2), 0, 5)
		if err != nil || dst != 5 || fee != 70 {
			t.Fatalf("Deposit = %d, %d, %v; want 5, 70, nil", dst, fee, err)
		}
		if f.count(t, f.bag, f.charID, 100) != 0 || f.slot(t, f.chest, f.guildID, 5).Quantity != 20 || f.purse(t) != character.StartingGold-70 {
			t.Fatalf("after the deposit: bag %d, slot 5 %+v, purse %d", f.count(t, f.bag, f.charID, 100),
				f.slot(t, f.chest, f.guildID, 5), f.purse(t))
		}
		// An occupied slot sends the next stack to the first empty one, no merge.
		if err := f.bag.AddItem(ctx, f.charID, 100, 3); err != nil {
			t.Fatal(err)
		}
		dst, _, err = f.svc.Deposit(ctx, f.charID, f.guildID, Capacity(2), 0, 5)
		if err != nil || dst != 0 || f.slot(t, f.chest, f.guildID, 5).Quantity != 20 || f.slot(t, f.chest, f.guildID, 0).Quantity != 3 {
			t.Fatalf("the second deposit went to %d (%v), slot 5 %+v", dst, err, f.slot(t, f.chest, f.guildID, 5))
		}
	})
}

// The deposit's refusals, each moving nothing.
func TestDepositRefusals(t *testing.T) {
	both(t, func(t *testing.T, f *fixture) {
		ctx := context.Background()
		for _, id := range []int64{300, 400, 200} {
			if err := f.bag.AddItem(ctx, f.charID, id, 1); err != nil {
				t.Fatal(err)
			}
		}
		check := func(name string, err error, want uint16) {
			t.Helper()
			if CodeOf(err) != want {
				t.Errorf("%s: %v (0x%x), want 0x%x", name, err, CodeOf(err), want)
			}
		}
		_, _, err := f.svc.Deposit(ctx, f.charID, f.guildID, 30, 0, 0)
		check("a quest item", err, CodeCannotStore)
		_, _, err = f.svc.Deposit(ctx, f.charID, f.guildID, 30, 1, 0)
		check("an untradeable item", err, CodeCannotStore)
		_, _, err = f.svc.Deposit(ctx, f.charID, f.guildID, 30, 9, 0)
		check("an empty slot", err, CodeEmpty)
		_, _, err = f.svc.Deposit(ctx, f.charID, f.guildID, 30, 2, 30)
		check("past the storage", err, CodeNoTarget)
		if err := f.chars.DeductGold(ctx, f.charID, f.purse(t)-4); err != nil {
			t.Fatal(err)
		}
		_, _, err = f.svc.Deposit(ctx, f.charID, f.guildID, 30, 2, 0)
		check("the fee", err, CodeNotEnoughGold)
		if f.count(t, f.bag, f.charID, 200) != 1 || f.count(t, f.chest, f.guildID, 200) != 0 || f.purse(t) != 4 {
			t.Fatal("a refused deposit moved something")
		}
		// A full storage: 0x1807.
		f.chars.AddGold(ctx, f.charID, 1000)
		for i := 0; i < 30; i++ {
			if err := f.chest.AddItem(ctx, f.guildID, 200, 1); err != nil {
				t.Fatal(err)
			}
		}
		_, _, err = f.svc.Deposit(ctx, f.charID, f.guildID, 30, 2, 3)
		check("a full storage", err, CodeFull)
		if f.count(t, f.bag, f.charID, 200) != 1 {
			t.Fatal("a deposit into a full storage lost the sword")
		}
	})
}

// A withdraw is free, the whole stack, to the named bag slot or the first
// empty one.
func TestWithdraw(t *testing.T) {
	both(t, func(t *testing.T, f *fixture) {
		ctx := context.Background()
		if err := f.chest.AddItem(ctx, f.guildID, 100, 12); err != nil {
			t.Fatal(err)
		}
		if err := f.bag.AddItem(ctx, f.charID, 200, 1); err != nil {
			t.Fatal(err)
		}
		dst, err := f.svc.Withdraw(ctx, f.charID, f.guildID, 30, 0, 50, 0)
		if err != nil || dst != 1 || f.slot(t, f.bag, f.charID, 1).Quantity != 12 || f.count(t, f.chest, f.guildID, 100) != 0 || f.purse(t) != character.StartingGold {
			t.Fatalf("Withdraw = %d, %v; bag 1 %+v", dst, err, f.slot(t, f.bag, f.charID, 1))
		}
		if _, err := f.svc.Withdraw(ctx, f.charID, f.guildID, 30, 0, 50, 0); CodeOf(err) != CodeEmpty {
			t.Fatalf("withdrawing an empty slot: %v", err)
		}
	})
}

// The moves inside the storage: move, merge, swap; a split refused 5.
func TestMoveInside(t *testing.T) {
	both(t, func(t *testing.T, f *fixture) {
		ctx := context.Background()
		p := f.chest.(inventory.Placer)
		p.PlaceItemInstance(ctx, f.guildID, 0, 100, 30, inventory.Instance{})
		p.PlaceItemInstance(ctx, f.guildID, 1, 100, 40, inventory.Instance{})
		p.PlaceItemInstance(ctx, f.guildID, 2, 200, 1, inventory.Instance{})
		m, err := f.svc.Move(ctx, f.guildID, 30, 0, 5, 10)
		if CodeOf(err) != CodeWrongPlace {
			t.Fatalf("a split: %+v %v, want 5", m, err)
		}
		if _, err := f.svc.Move(ctx, f.guildID, 30, 0, 5, 31); CodeOf(err) != CodePastStack {
			t.Fatalf("past the stack: %v", err)
		}
		if _, err := f.svc.Move(ctx, f.guildID, 30, 0, 0, 30); CodeOf(err) != CodeSameSlot {
			t.Fatalf("onto itself: %v", err)
		}
		if _, err := f.svc.Move(ctx, f.guildID, 30, 9, 3, 1); CodeOf(err) != CodeEmpty {
			t.Fatalf("from an empty slot: %v", err)
		}
		if m, err = f.svc.Move(ctx, f.guildID, 30, 0, 5, 30); err != nil || m.Count != 30 || f.slot(t, f.chest, f.guildID, 5).Quantity != 30 {
			t.Fatalf("a move: %+v %v", m, err)
		}
		// 30 onto 40 of a 50 stack: 10 merge, 20 stay.
		if m, err = f.svc.Move(ctx, f.guildID, 30, 5, 1, 30); err != nil || m.Count != 10 ||
			f.slot(t, f.chest, f.guildID, 1).Quantity != 50 || f.slot(t, f.chest, f.guildID, 5).Quantity != 20 {
			t.Fatalf("a merge: %+v %v, slot 1 %+v slot 5 %+v", m, err, f.slot(t, f.chest, f.guildID, 1), f.slot(t, f.chest, f.guildID, 5))
		}
		// The sword onto the potions: a swap.
		if _, err = f.svc.Move(ctx, f.guildID, 30, 2, 5, 1); err != nil || f.slot(t, f.chest, f.guildID, 5).ItemID != 200 || f.slot(t, f.chest, f.guildID, 2).ItemID != 100 {
			t.Fatalf("a swap: %v", err)
		}
	})
}

// The gold, both ways, and its refusals.
func TestGold(t *testing.T) {
	both(t, func(t *testing.T, f *fixture) {
		ctx := context.Background()
		if err := f.svc.DepositGold(ctx, f.charID, f.guildID, 600); err != nil || f.gold(t) != 600 || f.purse(t) != character.StartingGold-600 {
			t.Fatalf("DepositGold: %v, gold %d, purse %d", err, f.gold(t), f.purse(t))
		}
		if err := f.svc.DepositGold(ctx, f.charID, f.guildID, 401); CodeOf(err) != CodeNotEnoughGold || f.gold(t) != 600 {
			t.Fatalf("depositing more than the purse: %v", err)
		}
		if err := f.svc.WithdrawGold(ctx, f.charID, f.guildID, 601); CodeOf(err) != CodeNotEnoughGold || f.purse(t) != 400 {
			t.Fatalf("withdrawing more than the storage: %v", err)
		}
		if err := f.svc.WithdrawGold(ctx, f.charID, f.guildID, 0); CodeOf(err) != CodeCount {
			t.Fatalf("withdrawing 0: %v", err)
		}
		if err := f.svc.WithdrawGold(ctx, f.charID, f.guildID, 250); err != nil || f.gold(t) != 350 || f.purse(t) != 650 {
			t.Fatalf("WithdrawGold: %v, gold %d, purse %d", err, f.gold(t), f.purse(t))
		}
	})
}

// A disbanded guild's storage is emptied.
func TestDrop(t *testing.T) {
	both(t, func(t *testing.T, f *fixture) {
		ctx := context.Background()
		f.chest.AddItem(ctx, f.guildID, 100, 9)
		f.chest.AddItem(ctx, f.guildID, 200, 1)
		f.svc.DepositGold(ctx, f.charID, f.guildID, 100)
		if err := f.svc.Drop(ctx, f.guildID); err != nil {
			t.Fatal(err)
		}
		if f.count(t, f.chest, f.guildID, 100)+f.count(t, f.chest, f.guildID, 200) != 0 || f.gold(t) != 0 {
			t.Fatal("the storage survived its guild")
		}
	})
}

// The one-member-at-a-time lock.
func TestLocks(t *testing.T) {
	l := NewLocks()
	if _, ok := l.Acquire(1, Holder{10, "Aria"}); !ok {
		t.Fatal("the first member was refused")
	}
	if h, ok := l.Acquire(1, Holder{11, "Bram"}); ok || h.Name != "Aria" {
		t.Fatalf("a second member got it: %+v %v", h, ok)
	}
	if _, ok := l.Acquire(1, Holder{10, "Aria"}); !ok {
		t.Fatal("the holder asking again was refused")
	}
	if l.Release(1, 11) {
		t.Fatal("a non-holder released it")
	}
	if g, ok := l.ReleaseCharacter(10); !ok || g != 1 {
		t.Fatal("the holder's logout did not release it")
	}
	if _, ok := l.Acquire(1, Holder{11, "Bram"}); !ok {
		t.Fatal("the storage stayed locked")
	}
}

// failingPurse refuses the fee's debit.
type failingPurse struct{ character.Store }

func (failingPurse) DeductGold(context.Context, int64, int64) error {
	return character.ErrInsufficientGold
}

// A deposit whose fee cannot be taken rolls the move back.
func TestDepositUnpaidFeeRollsBack(t *testing.T) {
	both(t, func(t *testing.T, f *fixture) {
		ctx := context.Background()
		f.bag.AddItem(ctx, f.charID, 200, 1)
		f.svc.Purse = failingPurse{f.chars}
		if _, _, err := f.svc.Deposit(ctx, f.charID, f.guildID, 30, 0, 0); CodeOf(err) != CodeNotEnoughGold {
			t.Fatalf("Deposit: %v", err)
		}
		if f.count(t, f.bag, f.charID, 200) != 1 || f.count(t, f.chest, f.guildID, 200) != 0 {
			t.Fatal("an unpaid deposit moved the sword")
		}
	})
}

// A move whose context dies mid-way (a dropped connection) changes nothing:
// the take and the place are one transaction.
type cancellingChest struct {
	inventory.Store
	cancel func()
}

func (c cancellingChest) PlaceItemInstance(ctx context.Context, owner int64, slot int, itemID int64, quantity int, inst inventory.Instance) error {
	c.cancel()
	return context.Canceled
}

func (c cancellingChest) PlacementCapacityFor(ctx context.Context, owner int64) int {
	return c.Store.(inventory.Placer).PlacementCapacityFor(ctx, owner)
}

func (c cancellingChest) TxDB() *sql.DB {
	if d, ok := c.Store.(txn.TxDBer); ok {
		return d.TxDB()
	}
	return nil
}

func TestDisconnectMidMoveLosesNothing(t *testing.T) {
	both(t, func(t *testing.T, f *fixture) {
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		f.bag.AddItem(context.Background(), f.charID, 200, 1)
		f.svc.Chest = cancellingChest{f.chest, cancel}
		if _, _, err := f.svc.Deposit(ctx, f.charID, f.guildID, 30, 0, 0); err == nil {
			t.Fatal("the cancelled deposit succeeded")
		}
		if f.count(t, f.bag, f.charID, 200) != 1 || f.count(t, f.chest, f.guildID, 200) != 0 || f.purse(t) != character.StartingGold {
			t.Fatalf("a cancelled deposit: bag %d, storage %d, purse %d", f.count(t, f.bag, f.charID, 200),
				f.count(t, f.chest, f.guildID, 200), f.purse(t))
		}
	})
}

// raceTwice runs op twice at once while lockQuery's row is held, so both
// have read before either writes.
func raceTwice(t *testing.T, db *sql.DB, lockQuery string, args []any, op func() error) [2]error {
	t.Helper()
	ctx := context.Background()
	hold, err := testdb.HoldRow(ctx, db, lockQuery, args...)
	if err != nil {
		t.Fatalf("holding the row: %v", err)
	}
	var errs [2]error
	var wg sync.WaitGroup
	done := make(chan struct{})
	for i := range errs {
		wg.Add(1)
		go func(i int) { defer wg.Done(); errs[i] = op() }(i)
	}
	go func() { wg.Wait(); close(done) }()
	if _, err := testdb.WaitLockWaiters(ctx, db, 2, done, 3*time.Second); err != nil {
		t.Fatal(err)
	}
	hold.Commit()
	<-done
	return errs
}

// Two members withdrawing the one sword at once (the lock bypassed: two
// servers' worth of requests at the database): it leaves once.
func TestRacedWithdrawsOnce(t *testing.T) {
	ctx := context.Background()
	f := newSQL(t)
	other, err := f.chars.Create(ctx, 1, "Bram")
	if err != nil {
		t.Fatal(err)
	}
	if err := f.chest.AddItem(ctx, f.guildID, 200, 1); err != nil {
		t.Fatal(err)
	}
	who := []int64{f.charID, other.ID}
	var mu sync.Mutex
	n := 0
	errs := raceTwice(t, f.db, `SELECT 1 FROM `+ChestTable+` WHERE guild_id = $1 AND slot = 0 FOR UPDATE`, []any{f.guildID},
		func() error {
			mu.Lock()
			c := who[n]
			n++
			mu.Unlock()
			_, err := f.svc.Withdraw(ctx, c, f.guildID, 30, 0, 50, 0)
			return err
		})
	total := f.count(t, f.bag, f.charID, 200) + f.count(t, f.bag, other.ID, 200)
	if (errs[0] == nil) == (errs[1] == nil) || total != 1 || f.count(t, f.chest, f.guildID, 200) != 0 {
		t.Fatalf("two racing withdrawals: %v, bags %d, storage %d", errs, total, f.count(t, f.chest, f.guildID, 200))
	}
}

// Two gold withdrawals of the whole balance: paid once.
func TestRacedGoldWithdrawsOnce(t *testing.T) {
	ctx := context.Background()
	f := newSQL(t)
	if err := f.svc.DepositGold(ctx, f.charID, f.guildID, 500); err != nil {
		t.Fatal(err)
	}
	errs := raceTwice(t, f.db, `SELECT 1 FROM guild_storage_gold WHERE guild_id = $1 FOR UPDATE`, []any{f.guildID},
		func() error { return f.svc.WithdrawGold(ctx, f.charID, f.guildID, 500) })
	if (errs[0] == nil) == (errs[1] == nil) || f.gold(t) != 0 || f.purse(t) != character.StartingGold {
		t.Fatalf("two racing gold withdrawals: %v, gold %d, purse %d", errs, f.gold(t), f.purse(t))
	}
}

// The storage outlives the server: a second set of stores on a fresh pool
// reads what the first wrote.
func TestPersistsAcrossRestart(t *testing.T) {
	ctx := context.Background()
	f := newSQL(t)
	f.bag.AddItem(ctx, f.charID, 100, 17)
	if _, _, err := f.svc.Deposit(ctx, f.charID, f.guildID, 30, 0, 4); err != nil {
		t.Fatal(err)
	}
	if err := f.svc.DepositGold(ctx, f.charID, f.guildID, 123); err != nil {
		t.Fatal(err)
	}
	db2, err := txn.OpenPool(testDSN(), 4)
	if err != nil {
		t.Fatal(err)
	}
	defer db2.Close()
	chest2, err := inventory.NewSQLStoreOwned(db2, items{}, ChestTable, ChestOwner)
	if err != nil {
		t.Fatal(err)
	}
	gold2, err := NewSQLGold(db2)
	if err != nil {
		t.Fatal(err)
	}
	svc2 := &Service{Chest: chest2, Vault: gold2}
	slots, g, err := svc2.List(ctx, f.guildID)
	if err != nil || len(slots) != 1 || slots[0].Index != 4 || slots[0].Quantity != 17 || g != 123 {
		t.Fatalf("after the restart: %+v, gold %d, %v", slots, g, err)
	}
}
