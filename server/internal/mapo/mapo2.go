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
// each holding 3 separate uint16-counted lists of fixed 30-byte records.
// Each record decodes as a type ID (uint32) + world position (3x float32)
// + a partially-understood 14-byte trailer (a 0xffff sentinel, a real
// confirmed 1-based sequential index at relative offset 22, and a constant
// 0x6464 tail — see docs/protocol/MAPO2_FORMAT.md for the parts still not
// understood, including what actually distinguishes the 3 per-sector
// lists and a real 552-byte trailing gap after the last sector this parser
// doesn't yet consume).
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
	magic2         = "JMXVMAPO"
	headerLen2     = magicLen + versionLen // 12
	sectorsPerSide = 6
	listsPerSector = 3
	entryLen       = 30
)

// Entry2 is one real .o2 record: a catalog type ID, a world position, and
// a real, confirmed 1-based sequential index (scope — per-list? per-sector?
// per-file? — not yet confirmed). Raw holds the full 30 bytes, including
// the fields already decoded above, since the trailer isn't fully
// understood yet.
type Entry2 struct {
	TypeID   uint32
	Position [3]float32
	Index    uint16
	Raw      [entryLen]byte
}

// Sector2 holds the 3 real per-sector lists, in real file order. Which
// list is which is not confirmed — type IDs are shared across all 3 lists
// in every real file checked, ruling out a simple per-list category split
// (see docs/protocol/MAPO2_FORMAT.md).
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
			for listIdx := 0; listIdx < listsPerSector; listIdx++ {
				if off+2 > len(data) {
					return nil, fmt.Errorf("mapo2: truncated before sector (%d,%d) list %d count", bandRow, bandCol, listIdx)
				}
				count := int(binary.LittleEndian.Uint16(data[off:]))
				off += 2
				entries := make([]Entry2, 0, count)
				for e := 0; e < count; e++ {
					if off+entryLen > len(data) {
						return nil, fmt.Errorf("mapo2: truncated mid-entry in sector (%d,%d) list %d", bandRow, bandCol, listIdx)
					}
					var entry Entry2
					entry.TypeID = binary.LittleEndian.Uint32(data[off:])
					entry.Position = [3]float32{
						readFloat32(data, off+4),
						readFloat32(data, off+8),
						readFloat32(data, off+12),
					}
					entry.Index = binary.LittleEndian.Uint16(data[off+22:])
					copy(entry.Raw[:], data[off:off+entryLen])
					off += entryLen
					entries = append(entries, entry)
				}
				sector.Lists[listIdx] = entries
			}
			r.Sectors = append(r.Sectors, sector)
		}
	}

	return r, nil
}
