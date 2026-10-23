package main

import (
	"archive/zip"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/pk2/pk2test"
)

// The layered view (round 789): -layers, -which, -overrides, listing and
// -extract through a folder holding a synthetic base archive and a pack.
func TestLayeredView(t *testing.T) {
	dir := t.TempDir()
	if err := pk2test.Write(filepath.Join(dir, "Media.pk2"),
		pk2test.Folder("Prim", pk2test.File("Grass01.ddj", "retail grass"), pk2test.File("rock.ddj", "retail rock"))); err != nil {
		t.Fatal(err)
	}
	zf, _ := os.Create(filepath.Join(dir, "z_mod.pk3"))
	zw := zip.NewWriter(zf)
	w, _ := zw.Create("prim/grass01.ddj")
	w.Write([]byte("modded grass"))
	zw.Close()
	zf.Close()

	bin := filepath.Join(t.TempDir(), "pk2list")
	if out, err := exec.Command("go", "build", "-o", bin, ".").CombinedOutput(); err != nil {
		t.Fatalf("build: %v\n%s", err, out)
	}
	run := func(args ...string) string {
		t.Helper()
		out, err := exec.Command(bin, append([]string{"-archives", dir}, args...)...).CombinedOutput()
		if err != nil {
			t.Fatalf("pk2list %v: %v\n%s", args, err, out)
		}
		return string(out)
	}
	if out := run("-layers"); !strings.Contains(out, "1  pack    "+filepath.Join(dir, "z_mod.pk3")) || !strings.Contains(out, "(Media)") {
		t.Fatalf("-layers:\n%s", out)
	}
	out := run("-which", `PRIM\GRASS01.DDJ`)
	if !strings.Contains(out, "serves  z_mod.pk3") || !strings.Contains(out, "hidden  Media.pk2") {
		t.Fatalf("-which:\n%s", out)
	}
	if out := run("-overrides"); !strings.Contains(out, `z_mod.pk3  prim\grass01.ddj  over Media.pk2`) {
		t.Fatalf("-overrides:\n%s", out)
	}
	if out := run("-l", "-filter", "ddj"); !strings.Contains(out, `prim\grass01.ddj  z_mod.pk3`) || !strings.Contains(out, `Prim\rock.ddj  Media.pk2`) {
		t.Fatalf("listing:\n%s", out)
	}
	dst := filepath.Join(t.TempDir(), "g.ddj")
	run("-volume", "Media", "-extract", "prim/grass01.ddj", "-out", dst)
	if b, _ := os.ReadFile(dst); string(b) != "modded grass" {
		t.Fatalf("extracted %q", b)
	}
	run("-source", "pk2", "-extract", "prim/grass01.ddj", "-out", dst)
	if b, _ := os.ReadFile(dst); string(b) != "retail grass" {
		t.Fatalf("pk2 mode extracted %q", b)
	}
	// -pk2 takes a pack too.
	out2, err := exec.Command(bin, "-pk2", filepath.Join(dir, "z_mod.pk3")).CombinedOutput()
	if err != nil || !strings.Contains(string(out2), `prim\grass01.ddj`) {
		t.Fatalf("-pk2 on a .pk3: %v\n%s", err, out2)
	}
}
