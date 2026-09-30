package nest

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

// Round 666: a nest DB file the server may not read -- a CSV copied at mode
// 0600 into a container that runs as nonroot -- fails the boot with an error
// that says what to do, not a bare "permission denied". The tests run as
// root, which the kernel never refuses, so the refusal is injected where
// os.Open would return it (EACCES, as a nonroot open of a 0600 file does).
func TestUnreadableNestFileSaysChmod(t *testing.T) {
	dir := t.TempDir()
	was := openFile
	t.Cleanup(func() { openFile = was })
	openFile = func(name string) (*os.File, error) {
		return nil, &fs.PathError{Op: "open", Path: name, Err: syscall.EACCES}
	}
	for _, name := range []string{TacticsFile, AISkillFile} {
		var err error
		if name == TacticsFile {
			_, err = LoadDir(dir)
		} else {
			err = loadOptional(&DB{}, dir)
		}
		if err == nil {
			t.Fatalf("%s: an unreadable file loaded", name)
		}
		if !strings.Contains(err.Error(), "permission denied: chmod 644") || !strings.Contains(err.Error(), filepath.Join(dir, name)) {
			t.Fatalf("%s: the boot error %q does not say \"permission denied: chmod 644\" and name the file", name, err)
		}
		if !errors.Is(err, fs.ErrPermission) {
			t.Fatalf("%s: the error no longer wraps the refusal: %v", name, err)
		}
	}
	// A missing file is still a plain not-exist error (fatal for the three,
	// skipped for the two optional ones), not a chmod hint.
	openFile = os.Open
	if _, err := LoadDir(dir); err == nil || !errors.Is(err, fs.ErrNotExist) || strings.Contains(err.Error(), "chmod") {
		t.Fatalf("a missing file: %v", err)
	}
}
