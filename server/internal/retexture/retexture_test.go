package retexture

import (
	"bytes"
	"compress/zlib"
	"encoding/binary"
	"math"
	"strings"
	"testing"

	"github.com/OpenSRO/OpenSRO/server/internal/bmt"
	"github.com/OpenSRO/OpenSRO/server/internal/bsr"
)

// Synthetic fixtures only (never game data): an item .bsr laid out the way
// BSR_FORMAT.md documents a type-5 file, and a one-layer .bmt.

type wbuf struct{ bytes.Buffer }

func (w *wbuf) u32(v uint32) { binary.Write(&w.Buffer, binary.LittleEndian, v) }
func (w *wbuf) str(s string) { w.u32(uint32(len(s))); w.WriteString(s) }
func (w *wbuf) f32(v float32) {
	w.u32(math.Float32bits(v))
}

const (
	testMaterial = `prim\mtrl\item\etc\test_item.bmt`
	testMesh1    = `prim\mesh\item\etc\test_item_part1.bms`
	testMesh2    = `prim\mesh\item\etc\test_item_part2.bms`
)

func syntheticBSR() []byte {
	var w wbuf
	w.WriteString(bsrMagic)
	for i := 0; i < 8; i++ {
		w.u32(0) // the table, filled below
	}
	w.u32(0) // 0x2C flags
	w.u32(0) // 0x30
	for w.Len() < 0x40 {
		w.WriteByte(0)
	}
	binary.Write(&w.Buffer, binary.LittleEndian, uint16(5)) // item
	binary.Write(&w.Buffer, binary.LittleEndian, uint16(2))
	w.str("test_item")
	nameEnd := w.Len()
	for w.Len() < nameEnd+48 {
		w.WriteByte(0)
	}
	table := map[int]int{0x28: w.Len()}
	w.u32(0) // no navigation mesh
	for i := 0; i < 6; i++ {
		w.f32(float32(i))
	}
	table[0x0C] = w.Len()
	w.u32(1)
	w.u32(0)
	w.str(testMaterial)
	table[0x10] = w.Len()
	w.u32(2)
	w.str(testMesh1)
	w.str(testMesh2)
	table[0x18] = w.Len()
	w.u32(4096)
	w.u32(0)
	w.u32(0)
	table[0x14] = w.Len()
	w.u32(0)
	table[0x1C] = w.Len()
	w.u32(1)
	w.str("default")
	w.u32(2)
	w.u32(0)
	w.u32(1)
	table[0x20] = w.Len()
	w.u32(0)
	table[0x24] = w.Len()
	w.u32(1)
	w.str("ambient")
	w.u32(0)
	w.u32(0)
	w.u32(1)
	w.u32(1)
	w.u32(2)
	w.u32(0)
	b := w.Bytes()
	for off, v := range table {
		binary.LittleEndian.PutUint32(b[off:], uint32(v))
	}
	return b
}

func syntheticBMT(texture string, trailer [3]byte) []byte {
	var w wbuf
	w.WriteString(bmtMagic)
	w.u32(1)
	w.str("test_item")
	for i := 0; i < 16; i++ {
		w.f32(0.5)
	}
	w.f32(0)
	w.u32(0x41)
	w.str(texture)
	w.f32(1)
	w.Write(trailer[:])
	return w.Bytes()
}

func TestPatchBSRRenamesTheMaterialAndShiftsTheTable(t *testing.T) {
	base := syntheticBSR()
	if obj, err := bsr.Parse(base); err != nil || obj.MaterialPath != testMaterial {
		t.Fatalf("fixture does not parse: %v %+v", err, obj)
	}
	const newMat = `prim\mtrl\item\etc\opensro_akatsuki_m.bmt` // 6 bytes longer
	out, changes, err := Patch(base, []Replacement{{Old: strings.ToUpper(testMaterial), New: newMat}})
	if err != nil {
		t.Fatal(err)
	}
	if len(changes) != 1 || changes[0].Old != testMaterial {
		t.Fatalf("changes %+v", changes)
	}
	obj, err := bsr.Parse(out)
	if err != nil {
		t.Fatal(err)
	}
	if obj.MaterialPath != newMat {
		t.Errorf("material %q, want %q", obj.MaterialPath, newMat)
	}
	if got := obj.AllMeshPaths(); len(got) != 2 || got[0] != testMesh1 || got[1] != testMesh2 {
		t.Errorf("meshes %v", got)
	}
	d := len(newMat) - len(testMaterial)
	at := changes[0].Offset
	le := binary.LittleEndian
	for w := bsrTableLo; w <= bsrTableHi; w += 4 {
		before, after := int(le.Uint32(base[w:])), int(le.Uint32(out[w:]))
		want := before
		if before > at {
			want += d
		}
		if after != want {
			t.Errorf("table word %#x: %d -> %d, want %d", w, before, after, want)
		}
	}
	// Every byte but the table, the string and its length is kept.
	strEnd := at + 4 + len(testMaterial)
	if !bytes.Equal(base[bsrTableHi+4:at], out[bsrTableHi+4:at]) || !bytes.Equal(base[strEnd:], out[strEnd+d:]) {
		t.Error("bytes outside the renamed string changed")
	}
	// Renaming back is the original, byte for byte.
	back, _, err := Patch(out, []Replacement{{Old: newMat, New: testMaterial}})
	if err != nil || !bytes.Equal(back, base) {
		t.Errorf("round trip differs (err %v)", err)
	}
}

func TestPatchBSRSameLengthKeepsTheTable(t *testing.T) {
	base := syntheticBSR()
	same := `prim\mtrl\item\etc\test_xxxx.bmt`
	out, _, err := Patch(base, []Replacement{{Old: testMaterial, New: same}})
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(base[:0x44], out[:0x44]) || len(out) != len(base) {
		t.Error("a same-length rename moved the header or the size")
	}
}

func TestPatchBMT(t *testing.T) {
	base := syntheticBMT("test_item.ddj", [3]byte{0x20, 0x08, 0})
	out, _, err := Patch(base, []Replacement{{Old: "test_item.ddj", New: "opensro_akatsuki_w.ddj"}})
	if err != nil {
		t.Fatal(err)
	}
	m, err := bmt.Parse(out)
	if err != nil || len(m.Layers) != 1 {
		t.Fatalf("parse: %v", err)
	}
	l := m.Layers[0]
	if l.TexturePath != "opensro_akatsuki_w.ddj" || l.TextureBytes != [3]byte{0x20, 0x08, 0} || l.Name != "test_item" {
		t.Errorf("layer %+v", l)
	}
	// A bare name may not become a full path (the trailer byte would lie).
	if _, _, err := Patch(base, []Replacement{{Old: "test_item.ddj", New: `prim\mtrl\x.ddj`}}); err == nil {
		t.Error("bare -> full path accepted")
	}
	full := syntheticBMT(`prim\mtrl\item\etc\test_item.ddj`, [3]byte{0, 0, 1})
	if _, _, err := Patch(full, []Replacement{{Old: `prim/mtrl/item/etc/test_item.ddj`, New: `prim\mtrl\item\etc\opensro_akatsuki_m.ddj`}}); err != nil {
		t.Errorf("full -> full: %v", err)
	}
}

func TestPatchZlibBMT(t *testing.T) {
	raw := syntheticBMT("test_item.ddj", [3]byte{})
	var buf bytes.Buffer
	binary.Write(&buf, binary.LittleEndian, uint32(len(raw)))
	zw := zlib.NewWriter(&buf)
	zw.Write(raw)
	zw.Close()
	out, _, err := Patch(buf.Bytes(), []Replacement{{Old: "test_item.ddj", New: "renamed.ddj"}})
	if err != nil {
		t.Fatal(err)
	}
	if k, _ := Kind(out); k != "bmt-zlib" {
		t.Fatalf("kind %q", k)
	}
	m, err := bmt.Parse(out)
	if err != nil || m.Layers[0].TexturePath != "renamed.ddj" {
		t.Fatalf("parse %v %+v", err, m)
	}
}

func TestPatchRefuses(t *testing.T) {
	base := syntheticBSR()
	if _, _, err := Patch(base, []Replacement{{Old: "nope.bmt", New: "x.bmt"}}); err == nil {
		t.Error("a missing string was accepted")
	}
	if _, _, err := Patch(base, []Replacement{{Old: testMaterial, New: "bad\x00name"}}); err == nil {
		t.Error("a non-printable name was accepted")
	}
	if _, _, err := Patch([]byte("not a file at all"), nil); err == nil {
		t.Error("an unknown format was accepted")
	}
}

func TestStrings(t *testing.T) {
	got, err := Strings(syntheticBSR())
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, c := range got {
		names = append(names, c.Old)
	}
	want := []string{"test_item", testMaterial, testMesh1, testMesh2, "default", "ambient"}
	if strings.Join(names, ",") != strings.Join(want, ",") {
		t.Errorf("strings %v, want %v", names, want)
	}
}
