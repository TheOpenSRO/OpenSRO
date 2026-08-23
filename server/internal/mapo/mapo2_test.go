package mapo

import (
	"encoding/binary"
	"math"
	"testing"
)

func appendU16(buf []byte, v uint16) []byte {
	b := make([]byte, 2)
	binary.LittleEndian.PutUint16(b, v)
	return append(buf, b...)
}

func appendU32b(buf []byte, v uint32) []byte {
	b := make([]byte, 4)
	binary.LittleEndian.PutUint32(b, v)
	return append(buf, b...)
}

func appendFloat32b(buf []byte, v float32) []byte {
	b := make([]byte, 4)
	binary.LittleEndian.PutUint32(b, math.Float32bits(v))
	return append(buf, b...)
}

// makeEntry2 builds one real-shaped 30-byte entry: type_id + position +
// the real, confirmed trailer shape (0xffff sentinel, 2 zero u16s, the
// real 1-based index at relative offset 22, a zero u32, and the constant
// 0x6464 tail) — see docs/protocol/MAPO2_FORMAT.md.
func makeEntry2(buf []byte, typeID uint32, pos [3]float32, index uint16) []byte {
	buf = appendU32b(buf, typeID)
	buf = appendFloat32b(buf, pos[0])
	buf = appendFloat32b(buf, pos[1])
	buf = appendFloat32b(buf, pos[2])
	buf = appendU16(buf, 0xffff)
	buf = appendU16(buf, 0)
	buf = appendU16(buf, 0)
	buf = appendU16(buf, index)
	buf = appendU32b(buf, 0)
	buf = appendU16(buf, 0x6464)
	return buf
}

func emptySector2(buf []byte) []byte {
	for i := 0; i < listsPerSector; i++ {
		buf = appendU16(buf, 0)
	}
	return buf
}

// buildRegion2 builds a full, real-shaped 6x6 region matching this
// project's own real empirical find against 100/100.o2 exactly: every
// sector empty except sector (0,0)'s list 3, which gets 3 real-shaped
// entries (same type ID, positions, and sequential indices).
func buildRegion2() []byte {
	buf := []byte(magic2)
	buf = append(buf, []byte("1001")...)

	for bandRow := 0; bandRow < sectorsPerSide; bandRow++ {
		for bandCol := 0; bandCol < sectorsPerSide; bandCol++ {
			if bandRow == 0 && bandCol == 0 {
				buf = appendU16(buf, 0) // list 1: empty
				buf = appendU16(buf, 0) // list 2: empty
				buf = appendU16(buf, 3) // list 3: 3 entries
				buf = makeEntry2(buf, 1489, [3]float32{56.81, 167.02, 22.98}, 1)
				buf = makeEntry2(buf, 1489, [3]float32{128.47, 167.25, 179.25}, 2)
				buf = makeEntry2(buf, 1489, [3]float32{210.54, 167.25, 119.00}, 3)
			} else {
				buf = emptySector2(buf)
			}
		}
	}
	return buf
}

func TestParse2(t *testing.T) {
	data := buildRegion2()

	r, err := Parse2(data)
	if err != nil {
		t.Fatalf("Parse2: %v", err)
	}
	if r.Version != "1001" {
		t.Errorf("version = %q, want 1001", r.Version)
	}
	if len(r.Sectors) != sectorsPerSide*sectorsPerSide {
		t.Fatalf("got %d sectors, want %d", len(r.Sectors), sectorsPerSide*sectorsPerSide)
	}

	sector00 := r.Sectors[0]
	if len(sector00.Lists[0]) != 0 || len(sector00.Lists[1]) != 0 {
		t.Errorf("sector (0,0) lists 1/2 should be empty, got %d/%d", len(sector00.Lists[0]), len(sector00.Lists[1]))
	}
	if len(sector00.Lists[2]) != 3 {
		t.Fatalf("sector (0,0) list 3 has %d entries, want 3", len(sector00.Lists[2]))
	}
	e0 := sector00.Lists[2][0]
	if e0.TypeID != 1489 {
		t.Errorf("entry 0 type ID = %d, want 1489", e0.TypeID)
	}
	wantPos := [3]float32{56.81, 167.02, 22.98}
	if e0.Position != wantPos {
		t.Errorf("entry 0 position = %v, want %v", e0.Position, wantPos)
	}
	if e0.Index != 1 {
		t.Errorf("entry 0 index = %d, want 1", e0.Index)
	}
	if sector00.Lists[2][2].Index != 3 {
		t.Errorf("entry 2 index = %d, want 3", sector00.Lists[2][2].Index)
	}

	sector11 := r.Sectors[1*sectorsPerSide+1]
	for i, l := range sector11.Lists {
		if len(l) != 0 {
			t.Errorf("unrelated sector (1,1) list %d should be empty, got %d entries", i, len(l))
		}
	}
}

func TestParse2TruncatedMidEntry(t *testing.T) {
	data := buildRegion2()
	truncated := data[:headerLen2+6+entryLen+5]
	if _, err := Parse2(truncated); err == nil {
		t.Error("Parse2 on a file truncated mid-entry should return an error")
	}
}

func TestParse2BadMagic(t *testing.T) {
	data := make([]byte, headerLen2+10)
	if _, err := Parse2(data); err == nil {
		t.Error("Parse2 with bad magic should return an error")
	}
}

func TestParse2TooSmall(t *testing.T) {
	data := make([]byte, headerLen2-1)
	if _, err := Parse2(data); err == nil {
		t.Error("Parse2 on a too-small buffer should return an error")
	}
}
