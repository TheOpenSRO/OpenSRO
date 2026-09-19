// Package testdb serialises test PROCESSES that share the local PostgreSQL
// test database.
//
// Eleven packages' tests talk to the same `srrevamp_test` database (the
// SRREVAMP_TEST_POSTGRES_DSN default). Inside one `go test -p 1 ./...` run they
// are already serialised; two runs on the same host are not, and 2026-09-19
// showed what that looks like: five worktrees running the suite at once made
// TestInventoryFullFlow read a stranger's item and TestTradeFullFlow's
// execution find mismatched state and system-cancel. Neither was a race in
// the code -- the rows were being clobbered from another process.
//
// Lock takes an advisory file lock keyed by the DSN and holds it for the
// package's whole run, so a second process waits its turn instead of sharing
// the tables. Call it from TestMain.
package testdb

import (
	"crypto/sha1"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
)

// Lock blocks until this process holds the lock for dsn's database and
// returns the function that releases it. A lock that cannot be taken is
// reported on stderr and the tests run unserialised, which is the old
// behaviour, not a failure.
func Lock(dsn string) (release func()) {
	sum := sha1.Sum([]byte(dsn))
	path := filepath.Join(os.TempDir(), "srrevamp-testdb-"+hex.EncodeToString(sum[:6])+".lock")
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o666)
	if err != nil {
		fmt.Fprintf(os.Stderr, "testdb: cannot open %s: %v -- running unserialised\n", path, err)
		return func() {}
	}
	if err := flock(f); err != nil {
		fmt.Fprintf(os.Stderr, "testdb: cannot lock %s: %v -- running unserialised\n", path, err)
		f.Close()
		return func() {}
	}
	return func() {
		funlock(f)
		f.Close()
	}
}
