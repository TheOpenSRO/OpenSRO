//go:build windows

package testdb

import "os"

// Windows developers run the SQL-backed tests one process at a time; the
// lock is a no-op there rather than pulling in a dependency for it.
func flock(f *os.File) error   { return nil }
func funlock(f *os.File) error { return nil }
