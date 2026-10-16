package clientpacks

import (
	"archive/zip"
	"bytes"
	"crypto/sha256"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// writeZip makes a pack holding files (name -> content), stored.
func writeZip(t *testing.T, path string, files map[string]string) []byte {
	t.Helper()
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	for n, c := range files {
		w, err := zw.CreateHeader(&zip.FileHeader{Name: n, Method: zip.Store})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := w.Write([]byte(c)); err != nil {
			t.Fatal(err)
		}
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, buf.Bytes(), 0o644); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func TestBuildNamesThePacksInCascadeOrder(t *testing.T) {
	dir := t.TempDir()
	zb := writeZip(t, filepath.Join(dir, "z_b.pk3"), map[string]string{"prim/mtrl/x.ddj": "one"})
	writeZip(t, filepath.Join(dir, "A.zip"), map[string]string{"a.txt": "a"})
	writeZip(t, filepath.Join(dir, "a.pk3"), map[string]string{"a.txt": "b"})
	if err := os.Mkdir(filepath.Join(dir, "sub"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, ".DS_Store"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	var lines []string
	b, err := Build(Options{Dir: dir, HTTPPort: 15780, Logf: func(f string, a ...any) { lines = append(lines, f) }})
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, p := range b.Manifest.Packs {
		names = append(names, p.Name)
	}
	// Rule 2: by stem, case ignored; of one stem .zip below .pk3.
	if got := strings.Join(names, ","); got != "A.zip,a.pk3,z_b.pk3" {
		t.Fatalf("order %s", got)
	}
	last := b.Manifest.Packs[2]
	if last.Size != int64(len(zb)) || last.SHA256 != sha256.Sum256(zb) || last.URL != "" {
		t.Fatalf("z_b.pk3: %+v", last)
	}
	if !b.Manifest.Required || b.Manifest.HTTPPort != 15780 || b.Manifest.LocalExtras {
		t.Fatalf("manifest %+v", b.Manifest)
	}
	if f, ok := b.ByName("z_b.pk3"); !ok || f.Entries != 1 {
		t.Fatalf("ByName %+v %v", f, ok)
	}
	if _, ok := b.ByName("Z_B.PK3"); ok {
		t.Fatal("ByName ignores case")
	}
	if len(lines) < 5 {
		t.Fatalf("log lines %v", lines)
	}
	if _, err := b.Manifest.Encode(); err != nil {
		t.Fatal(err)
	}
}

func TestBuildURLs(t *testing.T) {
	dir := t.TempDir()
	writeZip(t, filepath.Join(dir, "z.pk3"), map[string]string{"a": "b"})
	b, err := Build(Options{Dir: dir, BaseURL: "https://github.com/o/r/releases/download/v1/", LocalExtras: true})
	if err != nil {
		t.Fatal(err)
	}
	if u := b.Manifest.Packs[0].URL; u != "https://github.com/o/r/releases/download/v1/z.pk3" {
		t.Fatalf("url %s", u)
	}
	for _, bad := range []string{"ftp://x/p", "https://u:p@x/p", "https://x/p?a=1", "https://x/p q"} {
		if _, err := Build(Options{Dir: dir, BaseURL: bad}); err == nil {
			t.Errorf("base URL %q accepted", bad)
		}
	}
	if _, err := Build(Options{Dir: dir}); err == nil {
		t.Error("no URL and no listener accepted")
	}
}

func TestBuildRefuses(t *testing.T) {
	cases := map[string]func(t *testing.T, dir string){
		"a .pk2": func(t *testing.T, dir string) {
			os.WriteFile(filepath.Join(dir, "extra.pk2"), []byte("x"), 0o644)
		},
		"a base archive's name": func(t *testing.T, dir string) {
			writeZip(t, filepath.Join(dir, "Media.pk3"), map[string]string{"a": "b"})
		},
		"a stray file": func(t *testing.T, dir string) {
			os.WriteFile(filepath.Join(dir, "readme.txt"), []byte("x"), 0o644)
		},
		"an unsafe name": func(t *testing.T, dir string) {
			writeZip(t, filepath.Join(dir, "my pack.pk3"), map[string]string{"a": "b"})
		},
		"names differing in case": func(t *testing.T, dir string) {
			writeZip(t, filepath.Join(dir, "a.pk3"), map[string]string{"a": "b"})
			writeZip(t, filepath.Join(dir, "A.pk3"), map[string]string{"a": "b"})
		},
		"an entry escaping the archive": func(t *testing.T, dir string) {
			writeZip(t, filepath.Join(dir, "z.pk3"), map[string]string{"../evil.txt": "x", "ok.txt": "y"})
		},
		"an absolute entry": func(t *testing.T, dir string) {
			writeZip(t, filepath.Join(dir, "z.pk3"), map[string]string{"/etc/passwd": "x"})
		},
		"a corrupt entry (bad CRC)": func(t *testing.T, dir string) {
			p := filepath.Join(dir, "z.pk3")
			b := writeZip(t, p, map[string]string{"a.txt": "hello world"})
			i := bytes.Index(b, []byte("hello world"))
			b[i] = 'J'
			os.WriteFile(p, b, 0o644)
		},
		"not a zip": func(t *testing.T, dir string) {
			os.WriteFile(filepath.Join(dir, "z.pk3"), []byte("not a zip at all"), 0o644)
		},
		"an empty file": func(t *testing.T, dir string) {
			os.WriteFile(filepath.Join(dir, "z.pk3"), nil, 0o644)
		},
		"too many packs": func(t *testing.T, dir string) {
			for i := 0; i <= MaxPacks; i++ {
				writeZip(t, filepath.Join(dir, "p"+string(rune('a'+i%26))+string(rune('a'+i/26))+".pk3"), map[string]string{"a": "b"})
			}
		},
	}
	for name, setup := range cases {
		t.Run(name, func(t *testing.T) {
			dir := t.TempDir()
			setup(t, dir)
			if b, err := Build(Options{Dir: dir, HTTPPort: 1}); err == nil {
				t.Fatalf("built %+v", b.Manifest)
			} else {
				t.Log(err)
			}
		})
	}
	if _, err := Build(Options{Dir: filepath.Join(t.TempDir(), "missing"), HTTPPort: 1}); err == nil {
		t.Error("a missing folder accepted")
	}
}

func TestBuildFollowsALinkedPack(t *testing.T) {
	dir, elsewhere := t.TempDir(), t.TempDir()
	real := filepath.Join(elsewhere, "store.pk3")
	writeZip(t, real, map[string]string{"a": "b"})
	if err := os.Symlink(real, filepath.Join(dir, "z_link.pk3")); err != nil {
		t.Skip(err)
	}
	b, err := Build(Options{Dir: dir, HTTPPort: 1})
	if err != nil {
		t.Fatal(err)
	}
	if b.Files[0].Name != "z_link.pk3" || b.Files[0].Path != real {
		t.Fatalf("%+v", b.Files[0])
	}
}

func TestEmptyFolderIsRequiredWithNoPacks(t *testing.T) {
	b, err := Build(Options{Dir: t.TempDir(), HTTPPort: 1})
	if err != nil {
		t.Fatal(err)
	}
	enc, err := b.Manifest.Encode()
	if err != nil || len(b.Manifest.Packs) != 0 || !b.Manifest.Required {
		t.Fatalf("%+v %v", b.Manifest, err)
	}
	if got := len(enc); got != 5 {
		t.Fatalf("%d bytes", got)
	}
}
