package account

import (
	"context"
	"errors"
	"testing"
	"time"
)

// punishTestStore is what the shared punishment tests drive: both stores.
type punishTestStore interface {
	Store
	Registerer
	PunishmentStore
	AccountLookup
}

// Both stores keep punishments and look accounts up.
var (
	_ PunishmentStore = (*MemStore)(nil)
	_ PunishmentStore = (*SQLStore)(nil)
	_ AccountLookup   = (*MemStore)(nil)
	_ AccountLookup   = (*SQLStore)(nil)
)

// The clock the tests run on: a fixed instant, whole seconds (Postgres keeps
// microseconds, so a round trip compares equal).
var punishT0 = time.Date(2026, 10, 15, 12, 0, 0, 0, time.UTC)

func TestMemStorePunishments(t *testing.T) {
	m := NewMemStore()
	now := punishT0
	m.Now = func() time.Time { return now }
	runPunishmentTests(t, m, func(t time.Time) { now = t })
}

func TestSQLStorePunishments(t *testing.T) {
	s := openTestSQLStore(t)
	now := punishT0
	s.Now = func() time.Time { return now }
	runPunishmentTests(t, s, func(t time.Time) { now = t })
}

func runPunishmentTests(t *testing.T, s punishTestStore, setNow func(time.Time)) {
	ctx := context.Background()
	alice, err := s.Register(ctx, "alice", "pw")
	if err != nil {
		t.Fatal(err)
	}
	bob, err := s.Register(ctx, "bob", "pw")
	if err != nil {
		t.Fatal(err)
	}

	// Lookups.
	if a, err := s.AccountByName(ctx, "alice"); err != nil || a.ID != alice.ID {
		t.Fatalf("AccountByName = %+v, %v", a, err)
	}
	if a, err := s.AccountByID(ctx, bob.ID); err != nil || a.Username != "bob" {
		t.Fatalf("AccountByID = %+v, %v", a, err)
	}
	if _, err := s.AccountByName(ctx, "nobody"); !errors.Is(err, ErrNoSuchAccount) {
		t.Fatalf("AccountByName of nobody = %v, want ErrNoSuchAccount", err)
	}
	if _, err := s.AccountByID(ctx, bob.ID+100); !errors.Is(err, ErrNoSuchAccount) {
		t.Fatalf("AccountByID of nobody = %v, want ErrNoSuchAccount", err)
	}

	// Refusals: a bad type, an end before the begin, no account.
	for _, bad := range []Punishment{
		{AccountID: alice.ID, Type: 0, BeginAt: punishT0},
		{AccountID: alice.ID, Type: 5, BeginAt: punishT0},
		{AccountID: alice.ID, Type: PunishLogin, BeginAt: punishT0, EndAt: punishT0},
		{AccountID: alice.ID, Type: PunishLogin},
	} {
		if _, err := s.AddPunishment(ctx, bad); err == nil {
			t.Errorf("AddPunishment(%+v) succeeded", bad)
		}
	}
	if _, err := s.AddPunishment(ctx, Punishment{AccountID: bob.ID + 100, Type: PunishLogin, BeginAt: punishT0}); !errors.Is(err, ErrNoSuchAccount) {
		t.Errorf("AddPunishment for no account = %v, want ErrNoSuchAccount", err)
	}

	// All four types are stored; only 1 and 2 block a login.
	chat, err := s.AddPunishment(ctx, Punishment{AccountID: alice.ID, Type: PunishChat, Executor: "gm1",
		Guide: "spam", Description: "note", BeginAt: punishT0, EndAt: punishT0.Add(time.Hour)})
	if err != nil {
		t.Fatal(err)
	}
	if chat.Serial == 0 || !chat.RaisedAt.Equal(punishT0) {
		t.Fatalf("AddPunishment = %+v: want a serial and RaisedAt = now", chat)
	}
	if _, err := s.AddPunishment(ctx, Punishment{AccountID: alice.ID, Type: PunishTrade, BeginAt: punishT0}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Authenticate(ctx, "alice", "pw"); err != nil {
		t.Fatalf("chat and trade blocks keep a login out: %v", err)
	}

	// A 10-minute login block: Authenticate reports it with its guide and end.
	login, err := s.AddPunishment(ctx, Punishment{AccountID: alice.ID, Type: PunishLogin, Executor: AutomatedPunisher,
		Guide: "wrong passwords", Description: "auto", BeginAt: punishT0, EndAt: punishT0.Add(10 * time.Minute)})
	if err != nil {
		t.Fatal(err)
	}
	_, err = s.Authenticate(ctx, "alice", "pw")
	var be *BlockedError
	if !errors.Is(err, ErrBlocked) || !errors.As(err, &be) {
		t.Fatalf("Authenticate of a blocked account = %v, want a *BlockedError", err)
	}
	if be.Punishment.Serial != login.Serial || be.Punishment.Guide != "wrong passwords" ||
		!be.Punishment.EndAt.Equal(punishT0.Add(10*time.Minute)) || be.Punishment.Executor != AutomatedPunisher {
		t.Fatalf("blocked by %+v, want %+v", be.Punishment, login)
	}
	// The password is checked first: a wrong one is a wrong one.
	if _, err := s.Authenticate(ctx, "alice", "nope"); !errors.Is(err, ErrInvalidCredentials) {
		t.Fatalf("a wrong password on a blocked account = %v, want ErrInvalidCredentials", err)
	}
	// Bob is not touched.
	if _, err := s.Authenticate(ctx, "bob", "pw"); err != nil {
		t.Fatalf("bob: %v", err)
	}

	// An infinite type-2 block outranks it (ends last).
	insp, err := s.AddPunishment(ctx, Punishment{AccountID: alice.ID, Type: PunishLoginInspection, Guide: "inspection", BeginAt: punishT0})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Authenticate(ctx, "alice", "pw"); !errors.As(err, &be) || be.Punishment.Serial != insp.Serial || !be.Punishment.Infinite() {
		t.Fatalf("with an infinite block too: %v", err)
	}
	active, err := s.ActivePunishments(ctx, alice.ID, punishT0)
	if err != nil || len(active) != 4 || active[0].Serial != insp.Serial {
		t.Fatalf("ActivePunishments = %+v, %v; want 4, the infinite first", active, err)
	}

	// Ending the login blocks leaves chat and trade; Authenticate passes.
	setNow(punishT0.Add(time.Minute))
	n, err := s.EndPunishments(ctx, alice.ID, punishT0.Add(time.Minute), LoginBlockTypes...)
	if err != nil || n != 2 {
		t.Fatalf("EndPunishments = %d, %v; want 2", n, err)
	}
	if _, err := s.Authenticate(ctx, "alice", "pw"); err != nil {
		t.Fatalf("after the unblock: %v", err)
	}
	if n, _ := s.EndPunishments(ctx, alice.ID, punishT0.Add(time.Minute), LoginBlockTypes...); n != 0 {
		t.Fatalf("a second unblock ended %d", n)
	}

	// The history keeps all four, newest first, the ended ones with their end.
	all, err := s.Punishments(ctx, alice.ID)
	if err != nil || len(all) != 4 {
		t.Fatalf("Punishments = %+v, %v; want 4", all, err)
	}
	if all[0].Serial != insp.Serial || !all[0].EndAt.Equal(punishT0.Add(time.Minute)) || all[3].Serial != chat.Serial {
		t.Fatalf("Punishments order/ends: %+v", all)
	}
	if all[3].Guide != "spam" || all[3].Description != "note" || all[3].Executor != "gm1" || all[3].Type != PunishChat {
		t.Fatalf("fields lost: %+v", all[3])
	}

	// A block expires by itself.
	if _, err := s.AddPunishment(ctx, Punishment{AccountID: bob.ID, Type: PunishLogin, BeginAt: punishT0.Add(time.Minute),
		EndAt: punishT0.Add(11 * time.Minute)}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Authenticate(ctx, "bob", "pw"); !errors.Is(err, ErrBlocked) {
		t.Fatalf("bob blocked: %v", err)
	}
	setNow(punishT0.Add(11 * time.Minute))
	if _, err := s.Authenticate(ctx, "bob", "pw"); err != nil {
		t.Fatalf("bob at the end of his block: %v", err)
	}
	// A future block is not active yet.
	if _, err := s.AddPunishment(ctx, Punishment{AccountID: bob.ID, Type: PunishLogin, BeginAt: punishT0.Add(time.Hour)}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Authenticate(ctx, "bob", "pw"); err != nil {
		t.Fatalf("a block not begun yet: %v", err)
	}
}

// SetBlocked (the old API) writes and ends punishments now.
func TestMemStoreSetBlockedIsAPunishment(t *testing.T) {
	ctx := context.Background()
	m := NewMemStore()
	acc, _ := m.Add("alice", "pw")
	if err := m.SetBlocked("alice", true, "cheating"); err != nil {
		t.Fatal(err)
	}
	if err := m.SetBlocked("alice", true, "again"); err != nil {
		t.Fatal(err)
	}
	ps, _ := m.Punishments(ctx, acc.ID)
	if len(ps) != 1 || !ps[0].Infinite() || ps[0].Type != PunishLogin || ps[0].Guide != "cheating" {
		t.Fatalf("SetBlocked twice made %+v, want one infinite login block", ps)
	}
	var be *BlockedError
	if _, err := m.Authenticate(ctx, "alice", "pw"); !errors.As(err, &be) || be.Punishment.Guide != "cheating" {
		t.Fatalf("Authenticate = %v", err)
	}
	if err := m.SetBlocked("alice", false, ""); err != nil {
		t.Fatal(err)
	}
	if _, err := m.Authenticate(ctx, "alice", "pw"); err != nil {
		t.Fatalf("after SetBlocked false: %v", err)
	}
}

// The round-788 migration: an account blocked by the old column becomes an
// infinite login block with its reason, once; running the schema again moves
// nothing more.
func TestSQLStoreMigratesBlockedColumn(t *testing.T) {
	s := openTestSQLStore(t)
	ctx := context.Background()
	acc, err := s.Register(ctx, "old", "pw")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Register(ctx, "fine", "pw"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.db.Exec(`UPDATE accounts SET blocked = TRUE, block_reason = 'gold seller' WHERE username = 'old'`); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		s2, err := NewSQLStore(s.db)
		if err != nil {
			t.Fatalf("NewSQLStore (run %d): %v", i+1, err)
		}
		ps, err := s2.Punishments(ctx, acc.ID)
		if err != nil || len(ps) != 1 {
			t.Fatalf("run %d: punishments %+v, %v; want exactly 1", i+1, ps, err)
		}
		p := ps[0]
		if p.Type != PunishLogin || !p.Infinite() || p.Guide != "gold seller" || p.Executor != migratedExecutor {
			t.Fatalf("run %d: migrated %+v", i+1, p)
		}
		var be *BlockedError
		if _, err := s2.Authenticate(ctx, "old", "pw"); !errors.As(err, &be) || be.Punishment.Guide != "gold seller" {
			t.Fatalf("run %d: Authenticate = %v", i+1, err)
		}
		if _, err := s2.Authenticate(ctx, "fine", "pw"); err != nil {
			t.Fatalf("run %d: an unblocked account: %v", i+1, err)
		}
	}
	var blocked bool
	if err := s.db.QueryRow(`SELECT blocked FROM accounts WHERE username = 'old'`).Scan(&blocked); err != nil || blocked {
		t.Fatalf("the old column after the migration: %v, %v; want false", blocked, err)
	}
}
