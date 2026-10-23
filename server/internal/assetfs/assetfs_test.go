package assetfs

import (
	"archive/zip"
	"bytes"
	"compress/flate"
	"encoding/binary"
	"errors"
	"fmt"
	"hash/crc32"
	"io"
	"io/fs"
	"math/rand"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/pk2/pk2test"
)

// All archives here are synthetic, built at test time: no game data.

type zent struct {
	name   string
	data   string
	method uint16
}

func writeZip(t *testing.T, path string, ents ...zent) {
	t.Helper()
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	for _, e := range ents {
		w, err := zw.CreateHeader(&zip.FileHeader{Name: e.name, Method: e.method})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := io.WriteString(w, e.data); err != nil {
			t.Fatal(err)
		}
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, buf.Bytes(), 0o644); err != nil {
		t.Fatal(err)
	}
}

func writePK2(t *testing.T, path string, nodes ...pk2test.Node) {
	t.Helper()
	if err := pk2test.Write(path, nodes...); err != nil {
		t.Fatal(err)
	}
}

func read(t *testing.T, v *View, p string) string {
	t.Helper()
	b, err := v.ReadFile(p)
	if err != nil {
		t.Fatalf("ReadFile(%q): %v", p, err)
	}
	return string(b)
}

// cascadeDir: the TODO's example stack and the five bases.
func cascadeDir(t *testing.T) string {
	dir := t.TempDir()
	writePK2(t, filepath.Join(dir, "Data.pk2"),
		pk2test.File("shared.txt", "Data"),
		pk2test.File("object.ifo", "data's object.ifo"),
		pk2test.Folder("Prim", pk2test.Folder("Mtrl", pk2test.File("Foo.ddj", "retail texture"))))
	writePK2(t, filepath.Join(dir, "Map.pk2"), pk2test.File("object.ifo", "map's object.ifo"))
	writePK2(t, filepath.Join(dir, "Media.pk2"),
		pk2test.Folder("server_dep", pk2test.Folder("silkroad", pk2test.Folder("textdata",
			pk2test.File("itemdata.txt", "itemdata_5000.txt\r\nitemdata_10000.txt\r\n"),
			pk2test.File("itemdata_5000.txt", "retail rows")))))
	writePK2(t, filepath.Join(dir, "Music.pk2"), pk2test.File("a.ogg", "music"))
	writePK2(t, filepath.Join(dir, "Particles.pk2"), pk2test.File("p.efp", "particles"))
	writeZip(t, filepath.Join(dir, "assets.pk3"),
		zent{"shared.txt", "assets.pk3", zip.Deflate},
		zent{"prim/mtrl/foo.ddj", "pack texture", zip.Store})
	writePK2(t, filepath.Join(dir, "z_assets.pk2"), pk2test.File("shared.txt", "z_assets.pk2"))
	writeZip(t, filepath.Join(dir, "Z_Assets.pk3"),
		zent{"SHARED.TXT", "z_assets.pk3", zip.Deflate},
		zent{"only.txt", "only in z", zip.Deflate})
	writeZip(t, filepath.Join(dir, "aaa.zip"), zent{"Shared.txt", "aaa.zip", zip.Deflate})
	os.WriteFile(filepath.Join(dir, "readme.txt"), []byte("not an archive"), 0o644)
	return dir
}

func layerNames(ls []*Layer) string {
	var s []string
	for _, l := range ls {
		s = append(s, l.Name)
	}
	return strings.Join(s, " ")
}

func TestCascadeOrder(t *testing.T) {
	dir := cascadeDir(t)
	// custom/ sits beside the archive folder by default, as the client has it.
	custom := filepath.Join(filepath.Dir(dir), "custom")
	os.MkdirAll(custom, 0o755)
	os.WriteFile(filepath.Join(custom, "Shared.TXT"), []byte("custom"), 0o644)
	var logs []string
	f, err := Open(dir, Options{Logf: func(format string, a ...any) { logs = append(logs, fmt.Sprintf(format, a...)) }})
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	want := "custom/ Z_Assets.pk3 z_assets.pk2 assets.pk3 aaa.zip Particles.pk2 Music.pk2 Media.pk2 Map.pk2 Data.pk2"
	if got := layerNames(f.Layers()); got != want {
		t.Fatalf("stack = %q\nwant    %q", got, want)
	}
	if got := read(t, f.View, "shared.txt"); got != "custom" {
		t.Fatalf("shared.txt from %q, want custom", got)
	}
	l, _ := f.Which(`SHARED.txt`)
	if l.Kind != KindCustom {
		t.Fatalf("Which = %s", l.Name)
	}
	all, _ := f.WhichAll("shared.txt")
	var got []string
	for _, i := range all {
		got = append(got, i.Layer.Name)
	}
	if strings.Join(got, " ") != "custom/ Z_Assets.pk3 z_assets.pk2 assets.pk3 aaa.zip Data.pk2" {
		t.Fatalf("WhichAll = %v", got)
	}
	// Every override is logged at load.
	if len(f.Overrides()) != 6 { // shared.txt x5 (custom, Z, z, assets, aaa) + foo.ddj
		t.Fatalf("overrides = %+v", f.Overrides())
	}
	n := 0
	for _, s := range logs {
		if strings.Contains(s, "overrides") {
			n++
		}
	}
	if n != 6 {
		t.Fatalf("%d override lines logged: %q", n, logs)
	}

	g, err := Open(dir, Options{NoCustom: true})
	if err != nil {
		t.Fatal(err)
	}
	defer g.Close()
	if got := read(t, g.View, "shared.txt"); got != "z_assets.pk3" {
		t.Fatalf("without custom/: %q, want z_assets.pk3 (.pk3 beats .pk2 of the same name)", got)
	}
	if got := read(t, g.View, "only.txt"); got != "only in z" {
		t.Fatal(got)
	}
	// A pack named "aaa" still beats the base archives.
	os.Remove(filepath.Join(dir, "Z_Assets.pk3"))
	os.Remove(filepath.Join(dir, "z_assets.pk2"))
	os.Remove(filepath.Join(dir, "assets.pk3"))
	h, err := Open(dir, Options{NoCustom: true})
	if err != nil {
		t.Fatal(err)
	}
	defer h.Close()
	if got := read(t, h.View, "shared.txt"); got != "aaa.zip" {
		t.Fatalf("%q, want aaa.zip over Data.pk2", got)
	}
}

func TestCaseAndSlashes(t *testing.T) {
	f, err := Open(cascadeDir(t), Options{})
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	for _, p := range []string{`Prim\Mtrl\Foo.ddj`, "prim/mtrl/FOO.DDJ", `/PRIM\\mtrl/foo.ddj`} {
		if got := read(t, f.View, p); got != "pack texture" {
			t.Fatalf("%q = %q, want the pack's", p, got)
		}
	}
	i, err := f.Stat(`prim\mtrl\foo.ddj`)
	if err != nil || i.Layer.Name != "assets.pk3" || i.Size != int64(len("pack texture")) || i.Path != `prim\mtrl\foo.ddj` {
		t.Fatalf("Stat = %+v, %v", i, err)
	}
	if _, err := f.Stat("nope.txt"); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("missing: %v", err)
	}
	if _, err := f.Stat(`prim\..\shared.txt`); !errors.Is(err, ErrUnsafe) {
		t.Fatalf("a .. lookup: %v, want ErrUnsafe", err)
	}
}

func TestVolumes(t *testing.T) {
	f, err := Open(cascadeDir(t), Options{})
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	// Unscoped, the bases cascade by name too: Map over Data.
	if got := read(t, f.View, "object.ifo"); got != "map's object.ifo" {
		t.Fatal(got)
	}
	data, err := f.In("data")
	if err != nil {
		t.Fatal(err)
	}
	if got := read(t, data, "object.ifo"); got != "data's object.ifo" {
		t.Fatalf("In(Data): %q", got)
	}
	if _, err := data.Stat("p.efp"); !errors.Is(err, fs.ErrNotExist) {
		t.Fatal("In(Data) must not see Particles")
	}
	if got := read(t, data, "only.txt"); got != "only in z" {
		t.Fatal("packs overlay every volume")
	}
	if _, err := f.In("Textures"); err == nil {
		t.Fatal("In(non-base) must fail")
	}
}

func TestModes(t *testing.T) {
	dir := cascadeDir(t)
	writeZip(t, filepath.Join(dir, "Data.pk3"), zent{"shared.txt", "Data.pk3", zip.Deflate})
	f, err := Open(dir, Options{Mode: ModePK2})
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if got := layerNames(f.Layers()); got != "z_assets.pk2 Particles.pk2 Music.pk2 Media.pk2 Map.pk2 Data.pk2" {
		t.Fatalf("pk2 mode: %q", got)
	}
	g, err := Open(dir, Options{Mode: ModePK3})
	if err != nil {
		t.Fatal(err)
	}
	defer g.Close()
	if got := layerNames(g.Layers()); got != "Z_Assets.pk3 assets.pk3 aaa.zip Data.pk3" {
		t.Fatalf("pk3 mode: %q", got)
	}
	m, err := Open(dir, Options{})
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	data, _ := m.In("Data")
	if got := layerNames(data.Layers()); got != "Z_Assets.pk3 z_assets.pk2 assets.pk3 aaa.zip Data.pk3 Data.pk2" {
		t.Fatalf("mixed In(Data): %q", got)
	}
	for _, s := range []string{"", "mixed", "PK2", "pk3"} {
		if _, err := ParseMode(s); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := ParseMode("zip"); err == nil {
		t.Fatal("ParseMode(zip) must fail")
	}
}

func TestUnsafeNames(t *testing.T) {
	dir := t.TempDir()
	writeZip(t, filepath.Join(dir, "evil.pk3"),
		zent{"../escape.txt", "x", zip.Store},
		zent{"/abs.txt", "x", zip.Store},
		zent{`\abs2.txt`, "x", zip.Store},
		zent{"C:/drive.txt", "x", zip.Store},
		zent{"c:drive2.txt", "x", zip.Store},
		zent{`a\..\..\b.txt`, "x", zip.Store},
		zent{"a/./b.txt", "x", zip.Store},
		zent{"a//b.txt", "x", zip.Store},
		zent{"nul\x00.txt", "x", zip.Store},
		zent{"stream.txt:ads", "x", zip.Store},
		zent{"ok/fine.txt", "fine", zip.Store},
		zent{"OK/FINE.TXT", "duplicate", zip.Store},
		zent{"ok", "a file where a folder is", zip.Store},
	)
	f, err := Open(dir, Options{})
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	l := f.Layers()[0]
	if len(l.Rejected) != 12 {
		t.Fatalf("rejected %d: %q", len(l.Rejected), l.Rejected)
	}
	if got := read(t, f.View, "ok/fine.txt"); got != "fine" {
		t.Fatal(got)
	}
	n := 0
	f.Walk(func(i Info) error { n++; return nil })
	if n != 2 {
		t.Fatalf("walk saw %d entries, want ok and ok/fine.txt", n)
	}
	if _, err := Open(dir, Options{Strict: true}); err == nil {
		t.Fatal("Strict must refuse a pack with refused entries")
	}
}

func TestZipBomb(t *testing.T) {
	dir := t.TempDir()
	// An honest extreme: 64 MiB of zeros deflates at about 1030:1, past
	// retail's largest (974.6:1) and under the cap. It is served.
	zeros := strings.Repeat("\x00", 64<<20)
	writeZip(t, filepath.Join(dir, "zeros.pk3"), zent{"zeros.bin", zeros, zip.Deflate})
	f, err := Open(dir, Options{Strict: true})
	if err != nil {
		t.Fatal(err)
	}
	if got := read(t, f.View, "zeros.bin"); len(got) != 64<<20 {
		t.Fatalf("read %d bytes", len(got))
	}
	f.Close()

	// A header claiming 100 MiB from a 10-byte stream: the entry is refused,
	// the rest of the pack (a stored, incompressible filler) loads.
	dir = t.TempDir()
	filler := make([]byte, 200<<10)
	rand.New(rand.NewSource(789)).Read(filler)
	var comp bytes.Buffer
	fw, _ := flate.NewWriter(&comp, flate.BestCompression)
	fw.Write([]byte("xxxxxxxxxx"))
	fw.Close()
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	w, _ := zw.CreateHeader(&zip.FileHeader{Name: "filler.ogg", Method: zip.Store})
	w.Write(filler)
	w, _ = zw.CreateRaw(&zip.FileHeader{Name: "liar.bin", Method: zip.Deflate, CRC32: 1,
		CompressedSize64: uint64(comp.Len()), UncompressedSize64: 100 << 20})
	w.Write(comp.Bytes())
	zw.Close()
	os.WriteFile(filepath.Join(dir, "liar.pk3"), buf.Bytes(), 0o644)
	g, err := Open(dir, Options{})
	if err != nil {
		t.Fatal(err)
	}
	l := g.Layers()[0]
	if len(l.Rejected) != 1 || !strings.Contains(l.Rejected[0], "zip bomb") {
		t.Fatalf("rejected = %q", l.Rejected)
	}
	if _, err := g.Stat("liar.bin"); err == nil {
		t.Fatal("the lying entry must not be served")
	}
	read(t, g.View, "filler.ogg")
	g.Close()

	// 50 directory records over one 64 MiB stream (overlapping entries):
	// the whole pack is refused, and a strict open fails.
	dir = t.TempDir()
	overlapBomb(t, filepath.Join(dir, "overlap.pk3"), zeros, 50)
	var logs []string
	h, err := Open(dir, Options{Logf: func(format string, a ...any) { logs = append(logs, fmt.Sprintf(format, a...)) }})
	if err != nil {
		t.Fatal(err)
	}
	if len(h.Layers()) != 0 || len(logs) != 1 || !strings.Contains(logs[0], "zip bomb") {
		t.Fatalf("layers %v, logs %q", layerNames(h.Layers()), logs)
	}
	h.Close()
	if _, err := Open(dir, Options{Strict: true}); err == nil {
		t.Fatal("a strict open must fail on the bomb")
	}

	// The size cap.
	dir = t.TempDir()
	writeZip(t, filepath.Join(dir, "big.pk3"), zent{"a.txt", strings.Repeat("a", 1000), zip.Deflate}, zent{"b.txt", "small", zip.Deflate})
	k, err := Open(dir, Options{Limits: &Limits{MaxEntrySize: 500, MaxRatio: 1100}})
	if err != nil {
		t.Fatal(err)
	}
	defer k.Close()
	if len(k.Layers()[0].Rejected) != 1 {
		t.Fatalf("cap 500: rejected %q", k.Layers()[0].Rejected)
	}
}

// overlapBomb writes one deflated entry and n central-directory records
// that all point at it.
func overlapBomb(t *testing.T, path, data string, n int) {
	t.Helper()
	var comp bytes.Buffer
	fw, _ := flate.NewWriter(&comp, flate.BestCompression)
	fw.Write([]byte(data))
	fw.Close()
	crc := crc32.ChecksumIEEE([]byte(data))
	var b bytes.Buffer
	le := func(v any) { binary.Write(&b, binary.LittleEndian, v) }
	le(uint32(0x04034b50))
	le(uint16(20))
	le(uint16(0))
	le(uint16(8))
	le(uint16(0))
	le(uint16(0x21))
	le(crc)
	le(uint32(comp.Len()))
	le(uint32(len(data)))
	le(uint16(7))
	le(uint16(0))
	b.WriteString("b00.bin")
	b.Write(comp.Bytes())
	cd := b.Len()
	for i := 0; i < n; i++ {
		le(uint32(0x02014b50))
		le(uint16(20))
		le(uint16(20))
		le(uint16(0))
		le(uint16(8))
		le(uint16(0))
		le(uint16(0x21))
		le(crc)
		le(uint32(comp.Len()))
		le(uint32(len(data)))
		le(uint16(7))
		le(uint16(0))
		le(uint16(0))
		le(uint16(0))
		le(uint16(0))
		le(uint32(0))
		le(uint32(0))
		fmt.Fprintf(&b, "b%02d.bin", i)
	}
	cdSize := b.Len() - cd
	le(uint32(0x06054b50))
	le(uint16(0))
	le(uint16(0))
	le(uint16(n))
	le(uint16(n))
	le(uint32(cdSize))
	le(uint32(cd))
	le(uint16(0))
	if err := os.WriteFile(path, b.Bytes(), 0o644); err != nil {
		t.Fatal(err)
	}
}

// A header that claims fewer bytes than its deflate stream holds is caught
// on read: the reader stops at the recorded size.
func TestLyingSize(t *testing.T) {
	var comp bytes.Buffer
	fw, _ := flate.NewWriter(&comp, flate.BestCompression)
	payload := bytes.Repeat([]byte("abcd"), 1000)
	fw.Write(payload)
	fw.Close()
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	w, _ := zw.CreateRaw(&zip.FileHeader{Name: "liar.bin", Method: zip.Deflate,
		CRC32: crc32.ChecksumIEEE(payload[:100]), CompressedSize64: uint64(comp.Len()), UncompressedSize64: 100})
	w.Write(comp.Bytes())
	zw.Close()
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "liar.pk3"), buf.Bytes(), 0o644)
	f, err := Open(dir, Options{})
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if b, err := f.ReadFile("liar.bin"); err == nil {
		t.Fatalf("read %d bytes from a lying entry without an error", len(b))
	}
}

// zip64ByHand writes a zip whose sizes and offsets all sit in zip64 extra
// fields, with a zip64 end-of-central-directory record and locator: the
// shape a converted multi-GB archive takes, crafted small.
func zip64ByHand(t *testing.T, path string, files map[string]string, names []string) {
	t.Helper()
	var b bytes.Buffer
	le := func(v any) { binary.Write(&b, binary.LittleEndian, v) }
	type rec struct {
		name        string
		crc         uint32
		size, local uint64
	}
	var recs []rec
	for _, n := range names {
		data := files[n]
		r := rec{name: n, crc: crc32.ChecksumIEEE([]byte(data)), size: uint64(len(data)), local: uint64(b.Len())}
		recs = append(recs, r)
		le(uint32(0x04034b50))
		le(uint16(45))
		le(uint16(0))
		le(uint16(0)) // stored
		le(uint16(0))
		le(uint16(0x21))
		le(r.crc)
		le(uint32(0xFFFFFFFF))
		le(uint32(0xFFFFFFFF))
		le(uint16(len(n)))
		le(uint16(20))
		b.WriteString(n)
		le(uint16(0x0001))
		le(uint16(16))
		le(r.size)
		le(r.size)
		b.WriteString(data)
	}
	cdStart := uint64(b.Len())
	for _, r := range recs {
		le(uint32(0x02014b50))
		le(uint16(45))
		le(uint16(45))
		le(uint16(0))
		le(uint16(0))
		le(uint16(0))
		le(uint16(0x21))
		le(r.crc)
		le(uint32(0xFFFFFFFF))
		le(uint32(0xFFFFFFFF))
		le(uint16(len(r.name)))
		le(uint16(28))
		le(uint16(0))
		le(uint16(0))
		le(uint16(0))
		le(uint32(0))
		le(uint32(0xFFFFFFFF))
		b.WriteString(r.name)
		le(uint16(0x0001))
		le(uint16(24))
		le(r.size)
		le(r.size)
		le(r.local)
	}
	cdSize := uint64(b.Len()) - cdStart
	z64 := uint64(b.Len())
	le(uint32(0x06064b50))
	le(uint64(44))
	le(uint16(45))
	le(uint16(45))
	le(uint32(0))
	le(uint32(0))
	le(uint64(len(recs)))
	le(uint64(len(recs)))
	le(cdSize)
	le(cdStart)
	le(uint32(0x07064b50))
	le(uint32(0))
	le(z64)
	le(uint32(1))
	le(uint32(0x06054b50))
	le(uint16(0xFFFF))
	le(uint16(0xFFFF))
	le(uint16(0xFFFF))
	le(uint16(0xFFFF))
	le(uint32(0xFFFFFFFF))
	le(uint32(0xFFFFFFFF))
	le(uint16(0))
	if err := os.WriteFile(path, b.Bytes(), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestZip64DirectoryRecord(t *testing.T) {
	path := filepath.Join(t.TempDir(), "z64.pk3")
	files := map[string]string{"Prim/a.txt": "zip64 entry one", "b.bin": "two"}
	zip64ByHand(t, path, files, []string{"Prim/a.txt", "b.bin"})
	f, err := OpenArchive(path, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if got := read(t, f.View, `prim\A.TXT`); got != files["Prim/a.txt"] {
		t.Fatal(got)
	}
	if got := read(t, f.View, "b.bin"); got != "two" {
		t.Fatal(got)
	}
	if z, err := hasZip64EOCD(path); err != nil || !z {
		t.Fatalf("hasZip64EOCD = %v, %v", z, err)
	}
}

func TestPackWriterRoundTrip(t *testing.T) {
	dir := t.TempDir()
	out := filepath.Join(dir, "out.pk3")
	fh, _ := os.Create(out)
	pw := NewPackWriter(fh, DefaultPolicy(), 3, 1<<10) // a tiny budget exercises the back-pressure
	files := map[string]string{
		"Prim/Mtrl/a.ddj":   strings.Repeat("DDS texture ", 200),
		"Music/song.ogg":    strings.Repeat("ogg ", 100),
		"textdata/x.txt":    strings.Repeat("1\t2\t3\n", 50),
		"empty.txt":         "",
		"random.bin":        "\x8f\x12\xa0\x33\x01",
		"fonts/\u00c0b.ttf": strings.Repeat("latin-1 name", 20),
	}
	order := []string{"Prim/Mtrl/a.ddj", "Music/song.ogg", "textdata/x.txt", "empty.txt", "random.bin", "fonts/\u00c0b.ttf"}
	pw.AddDir("Prim")
	pw.AddDir(`Prim\Mtrl`)
	for _, n := range order {
		d := files[n]
		if err := pw.AddFile(n, int64(len(d)), func() (io.ReadCloser, error) { return io.NopCloser(strings.NewReader(d)), nil }); err != nil {
			t.Fatal(err)
		}
	}
	if err := pw.AddFile("PRIM/mtrl/A.DDJ", 1, nil); err == nil {
		t.Fatal("a case-folded duplicate must be refused")
	}
	if err := pw.AddFile("../x", 1, nil); err == nil {
		t.Fatal("an unsafe name must be refused")
	}
	st, sums, err := pw.Close()
	if err != nil {
		t.Fatal(err)
	}
	fh.Close()
	if st.Files != 6 || st.Dirs != 2 || st.Stored != 4 || st.Deflated != 2 || st.StoredFallback != 1 {
		t.Fatalf("stats %+v (want .txt and .ttf deflated; .ddj and .ogg stored by policy, the empty file and random.bin stored, the latter by the fallback)", st)
	}
	res, err := VerifyPack(out, sums, 2, 2)
	if err != nil {
		t.Fatal(err)
	}
	if res.Files != 6 || res.Bytes != st.In {
		t.Fatalf("verify %+v", res)
	}
	r, _ := zip.OpenReader(out)
	for _, zf := range r.File {
		if strings.HasPrefix(zf.Name, "fonts/") && zf.Flags&0x800 == 0 {
			t.Fatal("a non-ASCII name must carry the UTF-8 flag")
		}
		if zf.Name == "Music/song.ogg" && zf.Method != zip.Store {
			t.Fatal(".ogg must be stored")
		}
	}
	r.Close()
	f, _ := OpenArchive(out, nil)
	if got := read(t, f.View, "FONTS\\\u00e0B.TTF"); got != files["fonts/\u00c0b.ttf"] {
		t.Fatal(got)
	}
	f.Close()

	// A flipped byte in a stored entry fails the read-back (CRC-32).
	raw, _ := os.ReadFile(out)
	i := bytes.Index(raw, []byte("ogg ogg"))
	raw[i] ^= 0xFF
	os.WriteFile(out, raw, 0o644)
	if _, err := VerifyPack(out, sums, 2, 2); err == nil {
		t.Fatal("a corrupted pack must fail verification")
	}
}

// More than 65,535 entries: the writer must emit the zip64 end record and
// the reader must read every entry back.
func TestPackWriterZip64Count(t *testing.T) {
	if testing.Short() {
		t.Skip("writes 65,600 entries")
	}
	out := filepath.Join(t.TempDir(), "many.pk3")
	fh, _ := os.Create(out)
	pw := NewPackWriter(fh, DefaultPolicy(), 0, 0)
	const n = 65600
	for i := 0; i < n; i++ {
		d := fmt.Sprint(i)
		pw.AddFile(fmt.Sprintf("d%02d/f%05d.txt", i%50, i), int64(len(d)), func() (io.ReadCloser, error) { return io.NopCloser(strings.NewReader(d)), nil })
	}
	st, sums, err := pw.Close()
	fh.Close()
	if err != nil || st.Files != n {
		t.Fatalf("%+v %v", st, err)
	}
	res, err := VerifyPack(out, sums, -1, 0)
	if err != nil {
		t.Fatal(err)
	}
	if !res.Zip64 || res.Files != n {
		t.Fatalf("verify %+v: want a zip64 end record and %d files", res, n)
	}
}

func TestReadDirAndWalk(t *testing.T) {
	f, err := Open(cascadeDir(t), Options{})
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	kids, err := f.ReadDir(`prim\mtrl`)
	if err != nil || len(kids) != 1 || kids[0].Layer.Name != "assets.pk3" {
		t.Fatalf("ReadDir = %+v, %v", kids, err)
	}
	root, _ := f.ReadDir("")
	names := map[string]bool{}
	for _, k := range root {
		if names[FoldName(k.Name)] {
			t.Fatalf("ReadDir listed %s twice", k.Name)
		}
		names[FoldName(k.Name)] = true
	}
	if !names["only.txt"] || !names["object.ifo"] || !names["server_dep"] {
		t.Fatalf("root = %v", names)
	}
	seen := map[string]int{}
	f.Walk(func(i Info) error {
		k, _ := Key(i.Path)
		seen[k]++
		if k == "shared.txt" && i.Layer.Name != "Z_Assets.pk3" {
			t.Errorf("Walk serves shared.txt from %s", i.Layer.Name)
		}
		return nil
	})
	for k, n := range seen {
		if n != 1 {
			t.Fatalf("Walk visited %s %d times", k, n)
		}
	}
}

func TestInputs(t *testing.T) {
	dir := cascadeDir(t)
	// A pack that adds an itemdata part and lists it in the index.
	writeZip(t, filepath.Join(dir, "zz_items.pk3"),
		zent{"server_dep/silkroad/textdata/itemdata.txt", "itemdata_5000.txt\r\nitemdata_90000.txt\r\nitemdata_10000.txt\r\n", zip.Deflate},
		zent{"server_dep/silkroad/textdata/ItemData_90000.txt", "pack rows", zip.Deflate})
	f, err := Open(dir, Options{})
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	media, _ := f.In("Media")
	in := &Inputs{View: media, Dir: TextDataDir}
	got, err := in.Expand([]string{"@itemdata.txt", "other.txt"})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(got, " ") != "itemdata_5000.txt itemdata_90000.txt other.txt" {
		t.Fatalf("Expand = %q (itemdata_10000 does not exist)", got)
	}
	if b, _ := in.ReadFile("itemdata_90000.txt"); string(b) != "pack rows" {
		t.Fatalf("pack part: %q", b)
	}
	if b, _ := in.ReadFile(`server_dep/silkroad/textdata/itemdata_5000.txt`); string(b) != "retail rows" {
		t.Fatalf("full path: %q", b)
	}
	disk := filepath.Join(t.TempDir(), "define.sct")
	os.WriteFile(disk, []byte("from disk"), 0o644)
	if b, err := in.ReadFile(disk); err != nil || string(b) != "from disk" {
		t.Fatalf("disk fallback: %q, %v", b, err)
	}
	// Loose mode: an index on disk, parts beside it.
	ld := t.TempDir()
	os.WriteFile(filepath.Join(ld, "itemdata.txt"), []byte("\xef\xbb\xbfItemData_1.txt\n\nitemdata_2.txt\n"), 0o644)
	os.WriteFile(filepath.Join(ld, "itemdata_1.txt"), nil, 0o644)
	loose := &Inputs{}
	got, _ = loose.Expand([]string{"@" + filepath.Join(ld, "itemdata.txt")})
	if len(got) != 1 || filepath.Base(got[0]) != "itemdata_1.txt" {
		t.Fatalf("loose Expand = %q", got)
	}
	u16 := []byte{0xFF, 0xFE, 'a', 0, '\r', 0, '\n', 0, 'B', 0}
	if n := IndexNames(u16); strings.Join(n, ",") != "a,b" {
		t.Fatalf("IndexNames(UTF-16) = %q", n)
	}
}

// An archive in the folder may be a symbolic link (to the operator's own
// archives kept elsewhere); a link inside custom/ is refused.
func TestSymlinks(t *testing.T) {
	keep := t.TempDir()
	writePK2(t, filepath.Join(keep, "Media.pk2"), pk2test.File("a.txt", "linked"))
	dir := t.TempDir()
	if err := os.Symlink(filepath.Join(keep, "Media.pk2"), filepath.Join(dir, "Media.pk2")); err != nil {
		t.Skip("no symlinks here:", err)
	}
	custom := filepath.Join(filepath.Dir(dir), "custom")
	os.MkdirAll(custom, 0o755)
	os.WriteFile(filepath.Join(keep, "secret.txt"), []byte("outside"), 0o644)
	os.Symlink(filepath.Join(keep, "secret.txt"), filepath.Join(custom, "b.txt"))
	f, err := Open(dir, Options{})
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if got := read(t, f.View, "a.txt"); got != "linked" {
		t.Fatal(got)
	}
	if _, err := f.Stat("b.txt"); err == nil {
		t.Fatal("a symlink inside custom/ must not be served")
	}
	if l := f.Layers()[0]; l.Kind != KindCustom || len(l.Rejected) != 1 {
		t.Fatalf("custom/ rejected %q", l.Rejected)
	}
}

func TestFoldRules(t *testing.T) {
	if FoldName("ÀBÇ×Þ.TXT") != "àbç×þ.txt" {
		t.Fatal(FoldName("ÀBÇ×Þ.TXT"))
	}
	if Latin1ToUTF8("\xc0\xda.bms") != "ÀÚ.bms" {
		t.Fatal("latin-1")
	}
	if b, ok := UTF8ToLatin1("ÀÚ.bms"); !ok || b != "\xc0\xda.bms" {
		t.Fatal("inverse")
	}
	if _, ok := UTF8ToLatin1("\u4e00"); ok {
		t.Fatal("above U+00FF has no pk2 spelling")
	}
	k1, _ := Key(`\Prim\\Mtrl/Foo.DDJ/`)
	k2, _ := Key("prim/mtrl/foo.ddj")
	if k1 != k2 || k1 != "prim/mtrl/foo.ddj" {
		t.Fatalf("Key %q %q", k1, k2)
	}
}

// A symbolic-link entry inside a pack is refused, as the client refuses it
// (rule 6; round 789's merge aligned the two readers).
func TestSymlinkEntryRefused(t *testing.T) {
	dir := t.TempDir()
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	h := &zip.FileHeader{Name: "link.txt", Method: zip.Store}
	h.SetMode(os.ModeSymlink | 0o777)
	w, err := zw.CreateHeader(h)
	if err != nil {
		t.Fatal(err)
	}
	io.WriteString(w, "/etc/passwd")
	w, _ = zw.CreateHeader(&zip.FileHeader{Name: "plain.txt", Method: zip.Store})
	io.WriteString(w, "plain")
	zw.Close()
	os.WriteFile(filepath.Join(dir, "links.pk3"), buf.Bytes(), 0o644)
	f, err := Open(dir, Options{})
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if _, err := f.Stat("link.txt"); err == nil {
		t.Fatal("a symbolic-link entry must not be served")
	}
	if got := read(t, f.View, "plain.txt"); got != "plain" {
		t.Fatal(got)
	}
	l := f.Layers()[0]
	if len(l.Rejected) != 1 || !strings.Contains(l.Rejected[0], "symbolic link") {
		t.Fatalf("rejected = %q", l.Rejected)
	}
}
