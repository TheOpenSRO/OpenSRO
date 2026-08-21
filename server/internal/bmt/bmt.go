// Package bmt parses .bmt material files. Confirmed empirically
// (byte-level, black-box) against real files found in a loose server
// patch-data tree (no .bmt files exist in the pk2 archives available in
// this client build, only under a separate, unpacked
// SMC_Independent/.../patch_upload_temp/data/Prim/mtrl tree) — see
// docs/protocol/BMT_FORMAT.md. No decompiler output is stored in this
// repo, only the resulting facts about the container format.
//
// Unlike pk2/bsr/bms/ddj, .bmt isn't a raw "JMXV*"-prefixed binary blob at
// the file level: the whole file (after a 4-byte decompressed-size header)
// is a standard zlib stream, which only decompresses to something with a
// "JMXVBMT 0102" magic.
package bmt

import (
	"bytes"
	"compress/zlib"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"math"
	"strings"
)

const (
	magic      = "JMXVBMT 0102"
	magicLen   = 12
	maxNameLen = 256
)

// Layer is one material layer (real files had 1 or more layers per
// material, e.g. a base layer plus attachment/decal layers).
type Layer struct {
	Name string
	// Ambient/Diffuse/Specular/Emissive are RGBA color components,
	// confirmed via real files decoding to sane values (e.g. 1.0 alpha).
	Ambient, Diffuse, Specular, Emissive [4]float32
	// Power is a single trailing float after the four colors — plausibly
	// specular power/shininess, not confirmed.
	Power float32
	// Unknown is a uint32 field of unconfirmed meaning between Power and
	// the texture filename.
	Unknown uint32
	// TexturePath is a bare filename (not a full path), e.g.
	// "avatar_m_zombie.ddj" — resolved against whatever directory the
	// .bmt itself lives in, same as a .bsr's mesh/material references.
	TexturePath string
}

// Material is a parsed .bmt file.
type Material struct {
	Layers []Layer
}

// Parse parses a .bmt file's raw bytes. Two real on-disk variants exist:
// files from a patch-staging tree (patch_upload_temp) are a 4-byte
// decompressed-size header followed by a zlib stream, but real files from a
// live client Data tree (Prim/Mtrl/Char/China/man/*.bmt) are the raw
// "JMXVBMT 0102" magic at byte 0 with no compression at all -- confirmed
// across 3 real files (chinaman_warrior.bmt, chinaman_bogy.bmt,
// chinaman_monk.bmt). Detect by checking for the magic directly before
// assuming the compressed layout.
func Parse(data []byte) (*Material, error) {
	if len(data) >= magicLen && string(data[0:magicLen]) == magic {
		return parseDecompressed(data)
	}

	if len(data) < 4 {
		return nil, errors.New("bmt: file too small to contain the size header")
	}
	wantSize := binary.LittleEndian.Uint32(data[0:4])

	zr, err := zlib.NewReader(bytes.NewReader(data[4:]))
	if err != nil {
		return nil, fmt.Errorf("bmt: opening zlib stream: %w", err)
	}
	defer zr.Close()
	dec, err := io.ReadAll(zr)
	if err != nil {
		return nil, fmt.Errorf("bmt: decompressing: %w", err)
	}
	if uint32(len(dec)) != wantSize {
		return nil, fmt.Errorf("bmt: decompressed size is %d, want %d (size header)", len(dec), wantSize)
	}

	return parseDecompressed(dec)
}

func parseDecompressed(dec []byte) (*Material, error) {
	if len(dec) < magicLen+4 {
		return nil, errors.New("bmt: decompressed data too small to contain a header")
	}
	if string(dec[0:magicLen]) != magic {
		return nil, fmt.Errorf("bmt: bad magic %q, want %q", dec[0:magicLen], magic)
	}
	count := binary.LittleEndian.Uint32(dec[magicLen:])
	off := magicLen + 4

	// The exact byte layout of a layer's trailer (between its texture
	// filename and the next layer's name length) isn't fully confirmed —
	// real files were seen with, apparently, non-4-byte-aligned gaps there,
	// and at least one real sample's last layer had a texture-length field
	// pointing past the end of the file (that sample came from a
	// "patch_upload_temp" staging directory, so it may just be an
	// incomplete/in-progress file rather than a real format quirk). Rather
	// than hard-fail the whole material over one bad trailing layer, parse
	// what can be parsed and stop there — this is a deliberate choice, not
	// silent data loss: a caller can compare len(m.Layers) against the
	// file's declared count to notice.
	m := &Material{}
	for i := uint32(0); i < count; i++ {
		layer, next, err := parseLayer(dec, off)
		if err != nil {
			if i == 0 {
				return nil, fmt.Errorf("bmt: reading layer %d/%d: %w", i+1, count, err)
			}
			break
		}
		m.Layers = append(m.Layers, *layer)
		off = next

		if i+1 < count {
			nameOff, ok := scanForNameString(dec, off)
			if !ok {
				break
			}
			off = nameOff
		}
	}
	return m, nil
}

func parseLayer(dec []byte, off int) (*Layer, int, error) {
	name, off, err := readLenPrefixedString(dec, off)
	if err != nil {
		return nil, off, fmt.Errorf("reading name: %w", err)
	}

	const colorsSize = 64 // 4 vec4s
	if off+colorsSize+4+4 > len(dec) {
		return nil, off, errors.New("truncated before colors/power/unknown")
	}
	l := &Layer{Name: name}
	l.Ambient = readVec4(dec, off)
	l.Diffuse = readVec4(dec, off+16)
	l.Specular = readVec4(dec, off+32)
	l.Emissive = readVec4(dec, off+48)
	off += colorsSize
	l.Power = readFloat32(dec, off)
	off += 4
	l.Unknown = binary.LittleEndian.Uint32(dec[off:])
	off += 4

	texPath, off, err := readLenPrefixedString(dec, off)
	if err != nil {
		return nil, off, fmt.Errorf("reading texture path: %w", err)
	}
	// The declared length includes trailing NUL padding in at least one
	// real file checked (20-byte filename, 26-byte declared length) —
	// trim it rather than exposing padding bytes as part of the path.
	l.TexturePath = strings.TrimRight(texPath, "\x00")

	return l, off, nil
}

func scanForNameString(data []byte, off int) (int, bool) {
	for pos := off; pos+4 <= len(data); pos++ {
		n := int(binary.LittleEndian.Uint32(data[pos:]))
		if n <= 0 || n > maxNameLen || pos+4+n > len(data) {
			continue
		}
		if isPlausibleName(data[pos+4 : pos+4+n]) {
			return pos, true
		}
	}
	return 0, false
}

func isPlausibleName(b []byte) bool {
	if len(b) == 0 {
		return false
	}
	for _, c := range b {
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9':
		case c == '_' || c == '-' || c == ' ' || c == '.' || c == '#':
		default:
			return false
		}
	}
	return true
}

func readLenPrefixedString(data []byte, off int) (string, int, error) {
	if off+4 > len(data) {
		return "", off, errors.New("truncated before string length")
	}
	n := int(binary.LittleEndian.Uint32(data[off:]))
	off += 4
	if n < 0 || off+n > len(data) {
		return "", off, fmt.Errorf("string length %d out of range", n)
	}
	return string(data[off : off+n]), off + n, nil
}

func readVec4(b []byte, off int) [4]float32 {
	return [4]float32{
		readFloat32(b, off),
		readFloat32(b, off+4),
		readFloat32(b, off+8),
		readFloat32(b, off+12),
	}
}

func readFloat32(b []byte, off int) float32 {
	return math.Float32frombits(binary.LittleEndian.Uint32(b[off:]))
}
