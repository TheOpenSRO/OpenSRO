package main

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/OpenSRO/OpenSRO/server/internal/assetfs"
)

func write(t *testing.T, root, rel, data string) {
	t.Helper()
	p := filepath.Join(root, filepath.FromSlash(rel))
	os.MkdirAll(filepath.Dir(p), 0o755)
	if err := os.WriteFile(p, []byte(data), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestPackFolder(t *testing.T) {
	src := t.TempDir()
	write(t, src, "prim/mtrl/foo.ddj", strings.Repeat("texture ", 100))
	write(t, src, "sound/x.ogg", "ogg")
	os.MkdirAll(filepath.Join(src, "empty"), 0o755)
	out := filepath.Join(src, "z_mine.pk3") // inside the folder: must not pack itself
	if err := run(src, out, 2, "", "", 6); err != nil {
		t.Fatal(err)
	}
	f, err := assetfs.OpenArchive(out, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if b, _ := f.ReadFile(`Prim\Mtrl\FOO.DDJ`); string(b) != strings.Repeat("texture ", 100) {
		t.Fatalf("foo.ddj = %q", b)
	}
	if i, err := f.Stat("empty"); err != nil || !i.IsDir {
		t.Fatal("an empty folder is kept")
	}
	n := 0
	f.Walk(func(i assetfs.Info) error {
		if !i.IsDir {
			n++
		}
		return nil
	})
	if n != 2 {
		t.Fatalf("%d files in the pack, want 2", n)
	}
}

func TestPackRefuses(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("case-distinct names and symlinks")
	}
	src := t.TempDir()
	write(t, src, "a/Foo.txt", "1")
	write(t, src, "a/foo.TXT", "2")
	out := filepath.Join(t.TempDir(), "x.pk3")
	if err := run(src, out, 1, "", "", 6); err == nil || !strings.Contains(err.Error(), "case") {
		t.Fatalf("case-folded duplicates: %v", err)
	}
	if _, err := os.Stat(out); err == nil {
		t.Fatal("a failed build must not leave a pack")
	}
	src = t.TempDir()
	write(t, src, "ok.txt", "1")
	os.Symlink("/etc/passwd", filepath.Join(src, "link.txt"))
	if err := run(src, out, 1, "", "", 6); err == nil || !strings.Contains(err.Error(), "symbolic link") {
		t.Fatalf("symlink: %v", err)
	}
	src = t.TempDir()
	write(t, src, "c:evil.txt", "1")
	if err := run(src, out, 1, "", "", 6); err == nil {
		t.Fatal("a name a reader refuses must fail the build")
	}
}
