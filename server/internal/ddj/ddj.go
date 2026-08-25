// Package ddj parses .ddj texture files. Confirmed empirically (byte-level,
// black-box) against real extracted files, the same way as the pk2 and bms
// fixes: it's a small proprietary 20-byte wrapper (12-byte magic + 4-byte
// size + 4-byte field of unconfirmed but constant-observed meaning) around
// an otherwise completely standard, unmodified Microsoft DDS file (magic
// "DDS ", standard 124-byte DDS_HEADER, standard 32-byte DDS_PIXELFORMAT).
// See docs/protocol/DDJ_FORMAT.md.
//
// The DDS layout itself is Microsoft's own long-published public format
// (docs.microsoft.com), not something reverse engineered from this game —
// only the 20-byte wrapper around it is proprietary and was confirmed
// against real files.
package ddj

import (
	"encoding/binary"
	"errors"
	"fmt"
)

const (
	magic         = "JMXVDDJ 1000"
	magicLen      = 12
	wrapperSize   = 20 // 12-byte magic + 4-byte size field + 4-byte field
	ddsMagicOff   = wrapperSize
	ddsHeaderSize = 124
)

// Texture is a parsed .ddj file: the fields pulled out of the embedded
// standard DDS header, plus the raw DDS bytes themselves (ready to hand to
// any standard DDS-capable image loader/decoder — nothing proprietary
// remains once the wrapper is stripped).
type Texture struct {
	Width       uint32
	Height      uint32
	MipMapCount uint32
	// FourCC is the compression format tag from the DDS pixel format, e.g.
	// "DXT1", "DXT5". Empty if the pixel format isn't FourCC-based.
	FourCC string
	// DDS is the embedded file's bytes starting at its own "DDS " magic —
	// a complete, standard DDS file on its own.
	DDS []byte
}

// Parse parses a .ddj file's raw bytes.
func Parse(data []byte) (*Texture, error) {
	if len(data) < wrapperSize+4 {
		return nil, errors.New("ddj: file too small to contain the wrapper header")
	}
	if string(data[0:magicLen]) != magic {
		return nil, fmt.Errorf("ddj: bad magic %q, want %q", data[0:magicLen], magic)
	}

	// The 0x0c field usually equals len(data)-magicLen, but a real sample
	// (Prim\Mtrl\Item\China\weapon\shield_90.ddj, 2026-08-24) has a value
	// 256 bytes larger than the actual file, even though its embedded DDS
	// header and pixel data are otherwise completely well formed and
	// byte-exact for its declared width/height/mip count. So it's not a
	// reliable file-size check across all real files and isn't used to
	// gate parsing.

	dds := data[ddsMagicOff:]
	if len(dds) < 4+ddsHeaderSize {
		return nil, errors.New("ddj: truncated before embedded DDS header")
	}
	if string(dds[0:4]) != "DDS " {
		return nil, fmt.Errorf("ddj: embedded payload has bad DDS magic %q", dds[0:4])
	}
	hdrSize := binary.LittleEndian.Uint32(dds[4:])
	if hdrSize != ddsHeaderSize {
		return nil, fmt.Errorf("ddj: embedded DDS_HEADER dwSize is %d, want %d", hdrSize, ddsHeaderSize)
	}

	t := &Texture{
		Height:      binary.LittleEndian.Uint32(dds[4+8:]),
		Width:       binary.LittleEndian.Uint32(dds[4+12:]),
		MipMapCount: binary.LittleEndian.Uint32(dds[4+24:]),
		DDS:         dds,
	}

	// DDS_PIXELFORMAT starts 4 (magic) + 72 bytes into the header.
	pf := dds[4+72:]
	if len(pf) >= 12 {
		pfFlags := binary.LittleEndian.Uint32(pf[4:])
		const ddpfFourCC = 0x4
		if pfFlags&ddpfFourCC != 0 {
			t.FourCC = string(pf[8:12])
		}
	}

	return t, nil
}
