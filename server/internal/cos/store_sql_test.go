package cos

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"testing"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
)

// TestSQLStore runs the store against PostgreSQL (OPENSRO_TEST_POSTGRES_DSN,
// set in CI); without it the test is skipped.
func TestSQLStore(t *testing.T) {
	dsn := os.Getenv("OPENSRO_TEST_POSTGRES_DSN")
	if dsn == "" {
		t.Skip("OPENSRO_TEST_POSTGRES_DSN not set")
	}
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	s, err := NewSQLStore(db)
	if err != nil {
		t.Fatalf("NewSQLStore: %v", err)
	}
	if _, err := db.Exec(`TRUNCATE TABLE char_cos`); err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()

	rent := time.Now().Add(30 * 24 * time.Hour).Truncate(time.Second)
	pet, err := s.Create(ctx, Record{RefCharID: 7, HP: 100, State: StateAlive, Level: 1, HGP: HGPFull,
		PetOption: 0x80 | 1, RentEnd: rent, InvSize: AbilityPetSlots})
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	ride, err := s.Create(ctx, Record{OwnerCharID: 42, RefCharID: 9, HP: 500, State: StateAlive | StateSummoned, Level: 30})
	if err != nil {
		t.Fatal(err)
	}

	got, err := s.Get(ctx, pet)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if got.RefCharID != 7 || got.PetOption != 0x81 || got.InvSize != AbilityPetSlots || !got.RentEnd.Equal(rent) || got.Name != "" {
		t.Fatalf("Get = %+v", got)
	}
	r, _ := s.Get(ctx, ride)
	if !r.RentEnd.IsZero() {
		t.Fatalf("a ride's rent end = %v, want zero", r.RentEnd)
	}

	got.HP, got.Exp, got.Level, got.State = 80, 1234, 2, StateAlive|StateSummoned
	if err := s.Save(ctx, got); err != nil {
		t.Fatalf("Save: %v", err)
	}
	if got, _ = s.Get(ctx, pet); got.HP != 80 || got.Exp != 1234 || got.Level != 2 || !got.Summoned() {
		t.Fatalf("after Save = %+v", got)
	}
	if err := s.Save(ctx, Record{ID: 1 << 40}); !errors.Is(err, ErrNotFound) {
		t.Fatalf("Save of a missing id = %v", err)
	}

	if err := s.SetName(ctx, pet, "Rex"); err != nil {
		t.Fatalf("SetName: %v", err)
	}
	if err := s.SetName(ctx, ride, "rex"); !errors.Is(err, ErrNameTaken) {
		t.Fatalf("SetName of a taken name (other case) = %v, want ErrNameTaken", err)
	}

	rides, err := s.SummonedRides(ctx, 42)
	if err != nil || len(rides) != 1 || rides[0].ID != ride {
		t.Fatalf("SummonedRides = %+v, %v", rides, err)
	}

	if err := s.Delete(ctx, ride); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Get(ctx, ride); !errors.Is(err, ErrNotFound) {
		t.Fatalf("Get after Delete = %v", err)
	}
}
