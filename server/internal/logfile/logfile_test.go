package logfile

import (
	"compress/gzip"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func readGz(t *testing.T, path string) string {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	zr, err := gzip.NewReader(f)
	if err != nil {
		t.Fatal(err)
	}
	b, err := io.ReadAll(zr)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// Past MaxBytes the file is renamed .1 (gzipped), older ones shift up, the
// oldest past Keep is deleted, and writing goes on in a fresh file.
func TestRotatesBySizeAndKeepsN(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "server.log")
	l, err := Open(path, 100, 2, true)
	if err != nil {
		t.Fatal(err)
	}
	line := strings.Repeat("x", 59) + "\n" // 60 bytes: two lines pass 100
	for i := 0; i < 7; i++ {
		if _, err := l.Write([]byte(string(rune('a'+i)) + line[1:])); err != nil {
			t.Fatal(err)
		}
	}
	if err := l.Close(); err != nil {
		t.Fatal(err)
	}
	// 7 lines of 60 bytes, one per file: g live, f in .1, e in .2, the rest gone.
	live, _ := os.ReadFile(path)
	if !strings.HasPrefix(string(live), "g") || len(live) != 60 {
		t.Fatalf("live file %q", live)
	}
	if got := readGz(t, path+".1.gz"); !strings.HasPrefix(got, "f") {
		t.Fatalf(".1.gz holds %q", got)
	}
	if got := readGz(t, path+".2.gz"); !strings.HasPrefix(got, "e") {
		t.Fatalf(".2.gz holds %q", got)
	}
	for _, gone := range []string{path + ".3.gz", path + ".1", path + ".2"} {
		if _, err := os.Stat(gone); err == nil {
			t.Fatalf("%s should not exist", gone)
		}
	}
}

// A file already past the limit when the server starts (prod's 847 MB) is
// rotated at once.
func TestOpenRotatesAnOversizedFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "server.log")
	if err := os.WriteFile(path, []byte(strings.Repeat("y", 500)), 0o644); err != nil {
		t.Fatal(err)
	}
	l, err := Open(path, 100, 3, false)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := l.Write([]byte("fresh\n")); err != nil {
		t.Fatal(err)
	}
	l.Close()
	if b, _ := os.ReadFile(path); string(b) != "fresh\n" {
		t.Fatalf("live file %q", b)
	}
	if b, _ := os.ReadFile(path + ".1"); len(b) != 500 {
		t.Fatalf(".1 holds %d bytes, want 500 (uncompressed)", len(b))
	}
}
