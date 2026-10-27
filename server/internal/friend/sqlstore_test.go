package friend

import (
	"context"
	"os"
	"testing"
)

func testDSN() string {
	if v := os.Getenv("OPENSRO_TEST_POSTGRES_DSN"); v != "" {
		return v
	}
	return "postgres://postgres:postgres@localhost:5432/opensro_test?sslmode=disable"
}

func openTestSQLStore(t *testing.T) *SQLStore {
	t.Helper()
	s, err := OpenSQLStore(testDSN())
	if err != nil {
		t.Fatalf("OpenSQLStore: %v (is postgres running?)", err)
	}
	if err := s.TruncateForTest(context.Background()); err != nil {
		t.Fatalf("truncating friend tables: %v", err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

// TestSQLStoreContract runs the store contract (friend_test.go) on Postgres.
func TestSQLStoreContract(t *testing.T) {
	storeContract(t, openTestSQLStore(t))
}

func TestSQLStoreFillsToTheCap(t *testing.T) {
	capContract(t, openTestSQLStore(t))
}
