package main

import (
	"archive/zip"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/OpenSRO/OpenSRO/server/internal/assetfs"
	"github.com/OpenSRO/OpenSRO/server/internal/pk2"
	"github.com/OpenSRO/OpenSRO/server/internal/pk2/pk2test"
)

// A synthetic pk2 (never game data) converts to a pack that serves every
// path the pk2 serves with the same bytes, and leaves the shadowed
// duplicate out.
func TestConvert(t *testing.T) {
	dir := t.TempDir()
	in := filepath.Join(dir, "Media.pk2")
	var many []pk2test.Node
	for i := 0; i < 30; i++ {
		many = append(many, pk2test.File(fmt.Sprintf("t%02d.txt", i), strings.Repeat(fmt.Sprintf("row %d\t", i), 40)))
	}
	err := pk2test.Write(in,
		pk2test.Folder("server_dep", pk2test.Folder("silkroad", pk2test.Folder("textdata", many...))),
		pk2test.Folder("Music", pk2test.File("Song.OGG", "OggS not really")),
		pk2test.Folder("Empty"),
		pk2test.File("\xc0\xda.ddj", "a cp949 name"),
		pk2test.File("readme.txt", "first"),
		pk2test.File("README.TXT", "shadowed"),
	)
	if err != nil {
		t.Fatal(err)
	}
	bin := filepath.Join(t.TempDir(), "pk2topk3")
	if out, err := exec.Command("go", "build", "-o", bin, ".").CombinedOutput(); err != nil {
		t.Fatalf("build: %v\n%s", err, out)
	}
	pk3 := filepath.Join(dir, "out", "Media.pk3")
	os.MkdirAll(filepath.Dir(pk3), 0o755)
	out, err := exec.Command(bin, "-in", in, "-o", pk3, "-workers", "2").CombinedOutput()
	if err != nil {
		t.Fatalf("pk2topk3: %v\n%s", err, out)
	}
	for _, want := range []string{"1 shadowed duplicate(s) left out", "files 33, folders 5", "byte-identical"} {
		if !strings.Contains(string(out), want) {
			t.Fatalf("report lacks %q:\n%s", want, out)
		}
	}
	if _, err := os.Stat(pk3 + ".partial"); err == nil {
		t.Fatal("the .partial file must be gone")
	}

	a, _ := pk2.Open(in)
	defer a.Close()
	f, err := assetfs.OpenArchive(pk3, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	n := 0
	a.Walk(func(p string, e pk2.Entry) error {
		got, err := f.Stat(assetfs.Latin1ToUTF8(p))
		if err != nil || got.IsDir != e.IsDir {
			t.Errorf("%q: %+v, %v", p, got, err)
			return nil
		}
		if !e.IsDir {
			want, _ := a.ReadFile(e)
			b, _ := f.ReadFile(p) // the raw Latin-1 spelling resolves too
			if string(b) != string(want) {
				t.Errorf("%q differs", p)
			}
			n++
		}
		return nil
	})
	if n != 33 {
		t.Fatalf("compared %d files", n)
	}
	if b, _ := f.ReadFile("readme.txt"); string(b) != "first" {
		t.Fatalf("readme.txt = %q, want the first entry's", b)
	}
	z, _ := zip.OpenReader(pk3)
	defer z.Close()
	for _, zf := range z.File {
		switch zf.Name {
		case "Music/Song.OGG":
			if zf.Method != zip.Store {
				t.Error(".ogg must be stored")
			}
		case "server_dep/silkroad/textdata/t00.txt":
			if zf.Method != zip.Deflate {
				t.Error(".txt must be deflated")
			}
		case "Empty/":
		case "ÀÚ.ddj":
			if zf.Flags&0x800 == 0 {
				t.Error("the UTF-8 flag must be set on a non-ASCII name")
			}
		}
	}

	// -measure writes nothing and prints a row per extension.
	out, err = exec.Command(bin, "-measure", "-in", in).CombinedOutput()
	if err != nil || !strings.Contains(string(out), ".txt") || !strings.Contains(string(out), ".ogg") {
		t.Fatalf("-measure: %v\n%s", err, out)
	}
}
