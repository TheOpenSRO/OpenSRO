package account

import (
	"os"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/testdb"
)

// TestMain holds the shared test-database lock for the whole package run, so
// two `go test` processes on one host take turns instead of clobbering each
// other's rows (see internal/testdb).
func TestMain(m *testing.M) {
	release := testdb.Lock(testDSN())
	code := m.Run()
	release()
	os.Exit(code)
}
