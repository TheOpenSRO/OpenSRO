package pk2

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"path/filepath"
	"strings"
	"testing"

	"github.com/OpenSRO/OpenSRO/server/internal/pk2/pk2test"
)

func buildTree(t *testing.T) *Archive {
	t.Helper()
	var many []pk2test.Node
	for i := 0; i < 45; i++ { // three chained blocks
		many = append(many, pk2test.File(fmt.Sprintf("f%02d.txt", i), fmt.Sprintf("many %d", i)))
	}
	many = append(many, pk2test.File("F03.TXT", "shadowed duplicate"))
	path := filepath.Join(t.TempDir(), "tree.pk2")
	err := pk2test.Write(path,
		pk2test.File("readme.txt", "root file"),
		pk2test.Folder("Prim",
			pk2test.Folder("Mtrl", pk2test.File("Foo.DDJ", "texture bytes")),
			pk2test.Folder("Many", many...),
		),
		pk2test.Folder("prim", pk2test.File("hidden.txt", "under a shadowed folder")),
		pk2test.File("\xC0BC.txt", "latin-1 name"),
	)
	if err != nil {
		t.Fatal(err)
	}
	a, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { a.Close() })
	return a
}

func TestFindCaseAndSlashes(t *testing.T) {
	a := buildTree(t)
	for _, p := range []string{`Prim\Mtrl\Foo.DDJ`, `prim/mtrl/foo.ddj`, `PRIM\mtrl/FOO.ddj`, `\prim\\mtrl\foo.ddj\`} {
		got, err := a.ReadPath(p)
		if err != nil || string(got) != "texture bytes" {
			t.Fatalf("ReadPath(%q) = %q, %v", p, got, err)
		}
	}
	e, err := a.Find("prim/mtrl")
	if err != nil || !e.IsDir || e.Name != "Mtrl" {
		t.Fatalf("Find(folder) = %+v, %v", e, err)
	}
	if e, err := a.Find(""); err != nil || !e.IsDir {
		t.Fatalf("Find(\"\") = %+v, %v; want the root folder", e, err)
	}
}

func TestFindLatin1Fold(t *testing.T) {
	a := buildTree(t)
	got, err := a.ReadPath("\xE0bc.TXT") // à folds with À
	if err != nil || string(got) != "latin-1 name" {
		t.Fatalf("Latin-1 fold: %q, %v", got, err)
	}
	if _, err := a.Find("\xD7bc.txt"); err == nil { // × has no case partner
		t.Fatal("0xD7 must not fold")
	}
}

func TestFindChainedAndFirstWins(t *testing.T) {
	a := buildTree(t)
	got, err := a.ReadPath(`prim\many\f44.txt`)
	if err != nil || string(got) != "many 44" {
		t.Fatalf("third-block entry: %q, %v", got, err)
	}
	got, err = a.ReadPath(`prim\many\f03.txt`)
	if err != nil || string(got) != "many 3" {
		t.Fatalf("first entry of a folded name must win: %q, %v", got, err)
	}
	// The second "prim" folder is shadowed by "Prim": its file is unreachable.
	if _, err := a.Find(`prim\hidden.txt`); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("shadowed folder's child: err = %v, want fs.ErrNotExist", err)
	}
}

func TestFindErrors(t *testing.T) {
	a := buildTree(t)
	for _, p := range []string{"nope.txt", `readme.txt\x`, `prim\nope\foo.ddj`} {
		if _, err := a.Find(p); !errors.Is(err, fs.ErrNotExist) {
			t.Errorf("Find(%q) err = %v, want fs.ErrNotExist", p, err)
		}
	}
	if _, err := a.ReadPath("prim"); err == nil {
		t.Error("ReadPath on a folder must fail")
	}
}

func TestWalkAndWalkAll(t *testing.T) {
	a := buildTree(t)
	var all, shadowed, reach []string
	if err := a.WalkAll(func(p string, e Entry, sh bool) error {
		all = append(all, p)
		if sh {
			shadowed = append(shadowed, p)
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if err := a.Walk(func(p string, e Entry) error {
		reach = append(reach, p)
		if !e.IsDir {
			if _, err := a.Find(p); err != nil {
				t.Errorf("Walk gave %q but Find cannot reach it: %v", p, err)
			}
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	wantShadowed := []string{`Prim\Many\F03.TXT`, `prim`, `prim\hidden.txt`}
	if strings.Join(shadowed, "|") != strings.Join(wantShadowed, "|") {
		t.Fatalf("shadowed = %q, want %q", shadowed, wantShadowed)
	}
	if len(all)-len(reach) != len(wantShadowed) {
		t.Fatalf("WalkAll %d entries, Walk %d: want %d fewer", len(all), len(reach), len(wantShadowed))
	}
	// 1 readme + Prim + Mtrl + Foo + Many + 45 + prim + hidden + F03 + latin = 54
	if len(all) != 54 {
		t.Fatalf("WalkAll visited %d entries, want 54", len(all))
	}
}

func TestOpenEntryStreams(t *testing.T) {
	a := buildTree(t)
	e, err := a.Find(`prim\mtrl\foo.ddj`)
	if err != nil {
		t.Fatal(err)
	}
	r, err := a.OpenEntry(e)
	if err != nil {
		t.Fatal(err)
	}
	b, _ := io.ReadAll(r)
	if string(b) != "texture bytes" {
		t.Fatalf("OpenEntry = %q", b)
	}
	dir, _ := a.Find(`PRIM`)
	if lst, err := a.Children(dir); err != nil || len(lst) != 2 {
		t.Fatalf("Children(PRIM) = %v, %v", lst, err)
	}
}
