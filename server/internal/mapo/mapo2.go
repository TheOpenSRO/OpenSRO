// Package mapo also parses .o2 files — the newer-generation per-region
// object/event index found inside Map.pk2 alongside .o, .m, and .t for
// "Shape B" regions only (see docs/protocol/MAPM_FORMAT.md's Shape A/B
// split; older "Shape A" regions have only .m + .o, no .o2 at all).
//
// Unlike .o (confirmed entirely empirically, see mapo.go), .o2's structure
// comes from a real decompiled loader function in sro_client.exe
// (FUN_00a361b0, real source path
// D:\vss-od\Silkroad\Client\Landscape\MapEngine\MapCallBack.cpp — the same
// function that also opens the region's .m file, see MAPM_FORMAT.md), and
// was then verified byte-for-byte against a real 100/100.o2 sample (3,780
// bytes): a fixed 12-byte header (magic + version, no other header
// fields), then a real, confirmed 6x6 grid of sectors in nested file order,
// each holding fieldsPerSector separate uint16-counted fields of fixed
// 30-byte records.
//
// fieldsPerSector is 4, not 3 — an initial reading of the decompiled
// function found only 3, and a first empirical check even seemed to
// confirm it (no parse errors), but left a real 552-byte gap before EOF
// that turned out to be more real, valid entries: a real 4th counted
// field, read right before what this project first labeled "list 1",
// whose value the real client reads but never stores anywhere. That 4th
// field's entries are parsed and discarded here (field index 0), matching
// the real client's own behavior — callers only see the 3 fields that are
// actually stored (Sector2.Lists[0..2], corresponding to file fields 1-3).
// See docs/protocol/MAPO2_FORMAT.md for the full account, including this
// correction and the parts still not understood (what actually
// distinguishes fields 1-3 — only one real sample has been checked, and it
// only ever populated field 3).
//
// Each record decodes as a type ID (uint32) + world position (3x float32)
// + a partially-understood 14-byte trailer (a 0xffff sentinel, a real
// confirmed 1-based sequential index at relative offset 22, and a constant
// 0x6464 tail).
//
// Because this layout is fully deterministic (unlike .m's still-partially-
// understood Shape A), a truncated file anywhere inside the 36-sector grid
// is treated as a real parse error, not a graceful partial result.
package mapo

import (
	"encoding/binary"
	"errors"
	"fmt"
)

const (
	magic2          = "JMXVMAPO"
	headerLen2      = magicLen + versionLen // 12
	sectorsPerSide  = 6
	fieldsPerSector = 4
	listsPerSector  = fieldsPerSector - 1 // field 0's entries are discarded, not stored
	entryLen        = 30
)

// Entry2 is one real .o2 record: a catalog type ID, a world position, and
// a real, confirmed 1-based sequential index (scope — per-list? per-sector?
// per-file? — not yet confirmed). Raw holds the full 30 bytes, including
// the fields already decoded above, since the trailer isn't fully
// understood yet.
type Entry2 struct {
	TypeID   uint32
	Position [3]float32
	// Rotation is the real Y-axis (yaw) rotation in radians -- Raw[18:22]
	// as a little-endian float32. Confirmed the same way .o's own
	// Object.Rotation was (see mapo.go): a real, densely-populated Jangan
	// region's .o2 file (98/168.o2, 506 real entries) has 100% of its
	// values at this offset landing in the real [0, 2*pi] range, several
	// rounding to whole real degrees. An earlier pass of this doc
	// (MAPO2_FORMAT.md) reported this same byte range as "reads zero" --
	// true for the one small sample checked at the time (most real
	// objects do have rotation 0, i.e. face the default direction), not a
	// real contradiction, just an incomplete sample corrected here.
	Rotation float32
	Index    uint16
	Raw      [entryLen]byte
}

// Sector2 holds the 3 real, stored per-sector lists (file fields 1-3), in
// real file order. Which is which is not confirmed — see
// docs/protocol/MAPO2_FORMAT.md (only one field held any real data in the
// one sample checked so far).
type Sector2 struct {
	Lists [listsPerSector][]Entry2
}

// Region2 is a parsed .o2 file. Sectors is always sectorsPerSide*
// sectorsPerSide long on success, row-major (index = bandRow*sectorsPerSide
// + bandCol), in the real nested file order the decompiled loader reads
// them in.
type Region2 struct {
	Version string
	Sectors []Sector2
}

// Parse2 parses a .o2 file's raw bytes.
func Parse2(data []byte) (*Region2, error) {
	if len(data) < headerLen2 {
		return nil, errors.New("mapo2: file too small to contain a header")
	}
	if string(data[0:magicLen]) != magic2 {
		return nil, fmt.Errorf("mapo2: bad magic %q, want %q", data[0:magicLen], magic2)
	}

	r := &Region2{Version: string(data[magicLen:headerLen2])}

	off := headerLen2
	for bandRow := 0; bandRow < sectorsPerSide; bandRow++ {
		for bandCol := 0; bandCol < sectorsPerSide; bandCol++ {
			var sector Sector2
			for fieldIdx := 0; fieldIdx < fieldsPerSector; fieldIdx++ {
				if off+2 > len(data) {
					return nil, fmt.Errorf("mapo2: truncated before sector (%d,%d) field %d count", bandRow, bandCol, fieldIdx)
				}
				count := int(binary.LittleEndian.Uint16(data[off:]))
				off += 2
				entries := make([]Entry2, 0, count)
				for e := 0; e < count; e++ {
					if off+entryLen > len(data) {
						return nil, fmt.Errorf("mapo2: truncated mid-entry in sector (%d,%d) field %d", bandRow, bandCol, fieldIdx)
					}
					var entry Entry2
					entry.TypeID = binary.LittleEndian.Uint32(data[off:])
					entry.Position = [3]float32{
						readFloat32(data, off+4),
						readFloat32(data, off+8),
						readFloat32(data, off+12),
					}
					entry.Rotation = readFloat32(data, off+18)
					entry.Index = binary.LittleEndian.Uint16(data[off+22:])
					copy(entry.Raw[:], data[off:off+entryLen])
					off += entryLen
					entries = append(entries, entry)
				}
				if fieldIdx > 0 {
					sector.Lists[fieldIdx-1] = entries
				}
			}
			r.Sectors = append(r.Sectors, sector)
		}
	}

	return r, nil
}
