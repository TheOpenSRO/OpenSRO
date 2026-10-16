// Package retexture copies a .bsr or .bmt with some of its path strings
// renamed and every other byte kept (round 789, lane X). It is how a new
// item reuses a retail mesh with a new texture, the way retail's own
// variants do it (MEASURED: avatar_m_knight_3.bsr is avatar_m_knight.bsr
// with the material path `prim\mtrl\item\etc\avatar_m_knight.bmt` renamed to
// `..._knight_3.bmt` and nothing else changed but the section table; its
// .bmt is the knight .bmt with the texture path renamed):
//
//	new item row -> new .bsr (material path renamed) -> new .bmt (texture
//	path renamed) -> new .ddj; the .bms meshes are the retail ones.
//
// Strings in both formats are a uint32 length then the bytes, no NUL.
//
// A .bsr's header holds byte offsets to its sections (0x0C..0x28, eight
// words; BSR_FORMAT.md). A string that changes length moves everything after
// it, so every table word past the string moves by the same amount; that is
// exactly what the knight/knight_3 pair shows (the six words after the
// material path differ by 2, the material and bounds words before it are
// equal). Nothing else in an item .bsr is known to hold an absolute offset
// (INFERRED from the same pair: every other byte after the path is equal);
// keeping a name's length avoids the question entirely.
//
// A .bmt layer's texture path is followed by seven bytes, the third non-zero
// when the path is a full archive path and zero when it is a name beside the
// .bmt (READ, CPrimMtrl FUN_00bf91b0; BMT_FORMAT.md). The two other bytes
// also differ between the knight pair (20 08 against 00 00, meaning OPEN),
// so a rename that turns a bare name into a full path or back is refused
// rather than guessed: keep the base's form.
package retexture

import (
	"bytes"
	"compress/zlib"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"strings"
)

// Replacement renames one string. Old matches case-insensitively with `/` and
// `\` alike, the way the archive matches paths; New is written as given.
type Replacement struct {
	Old, New string
}

// Change is one rewritten string.
type Change struct {
	Offset   int // of the length word, in the input (decompressed for a zlib .bmt)
	Old, New string
}

const (
	bsrMagic   = "JMXVRES 0109"
	bmtMagic   = "JMXVBMT 0102"
	bsrTableLo = 0x0C
	bsrTableHi = 0x28 // last table word (the bounds block); 0x2C is the flag word
)

// Kind names what Patch saw: "bsr", "bmt" or "bmt-zlib".
func Kind(data []byte) (string, error) {
	switch {
	case bytes.HasPrefix(data, []byte(bsrMagic)):
		return "bsr", nil
	case bytes.HasPrefix(data, []byte(bmtMagic)):
		return "bmt", nil
	case len(data) > 6 && data[4] == 0x78:
		return "bmt-zlib", nil
	}
	return "", errors.New("retexture: not a JMXVRES 0109 .bsr or a JMXVBMT 0102 .bmt")
}

func norm(s string) string {
	return strings.ToLower(strings.ReplaceAll(s, "/", "\\"))
}

func inflate(data []byte) ([]byte, error) {
	want := binary.LittleEndian.Uint32(data)
	r, err := zlib.NewReader(bytes.NewReader(data[4:]))
	if err != nil {
		return nil, fmt.Errorf("retexture: zlib .bmt: %w", err)
	}
	dec, err := io.ReadAll(r)
	if err != nil {
		return nil, fmt.Errorf("retexture: zlib .bmt: %w", err)
	}
	if uint32(len(dec)) != want || !bytes.HasPrefix(dec, []byte(bmtMagic)) {
		return nil, fmt.Errorf("retexture: zlib .bmt decompressed to %d bytes (header says %d) without the magic", len(dec), want)
	}
	return dec, nil
}

// Patch returns data with every length-prefixed string matching a
// replacement's Old rewritten to its New. Every replacement must match at
// least once. A zlib-wrapped .bmt comes back wrapped again (its size word
// and a new zlib stream; the stream's bytes differ from the input's, the
// decompressed content is what is kept).
func Patch(data []byte, repl []Replacement) ([]byte, []Change, error) {
	kind, err := Kind(data)
	if err != nil {
		return nil, nil, err
	}
	if kind != "bmt-zlib" {
		return patchRaw(data, repl, kind)
	}
	dec, err := inflate(data)
	if err != nil {
		return nil, nil, err
	}
	out, changes, err := patchRaw(dec, repl, "bmt")
	if err != nil {
		return nil, nil, err
	}
	var buf bytes.Buffer
	var n [4]byte
	binary.LittleEndian.PutUint32(n[:], uint32(len(out)))
	buf.Write(n[:])
	w := zlib.NewWriter(&buf)
	w.Write(out)
	w.Close()
	return buf.Bytes(), changes, nil
}

func printable(b []byte) bool {
	for _, c := range b {
		if c < 0x20 || c > 0x7e {
			return false
		}
	}
	return true
}

func isFullPath(s string) bool {
	return strings.ContainsAny(s, "\\/")
}

// match is the replacement whose Old sits, length-prefixed, at data[i:], or
// -1. Only exact lengths and bytes match, so no heuristic decides what is a
// string.
func match(data []byte, i int, repl []Replacement) int {
	if i+4 > len(data) {
		return -1
	}
	n := int(binary.LittleEndian.Uint32(data[i:]))
	for j, r := range repl {
		if n == len(r.Old) && i+4+n <= len(data) && norm(string(data[i+4:i+4+n])) == norm(r.Old) {
			return j
		}
	}
	return -1
}

type shift struct{ at, delta int }

func patchRaw(data []byte, repl []Replacement, kind string) ([]byte, []Change, error) {
	for _, r := range repl {
		if r.Old == "" {
			return nil, nil, errors.New("retexture: empty old string")
		}
		if r.New == "" || len(r.New) > 511 || !printable([]byte(r.New)) {
			return nil, nil, fmt.Errorf("retexture: new string %q: want 1..511 printable ASCII bytes", r.New)
		}
	}
	hits := make([]int, len(repl))
	var changes []Change
	var shifts []shift
	var out bytes.Buffer
	prev := 0
	for i := 0; i+4 <= len(data); {
		k := match(data, i, repl)
		if k < 0 {
			i++
			continue
		}
		r := repl[k]
		old := string(data[i+4 : i+4+len(r.Old)])
		if kind == "bsr" && i < bsrTableHi+4 {
			return nil, nil, errors.New("retexture: a renamed string sits inside the .bsr header table")
		}
		if kind == "bmt" && strings.HasSuffix(strings.ToLower(old), ".ddj") && isFullPath(old) != isFullPath(r.New) {
			return nil, nil, fmt.Errorf("retexture: %q -> %q changes a texture path between a bare name and a full path; "+
				"the trailer byte that says which (and two bytes of OPEN meaning) would be stale -- keep the base's form", old, r.New)
		}
		hits[k]++
		out.Write(data[prev:i])
		var n [4]byte
		binary.LittleEndian.PutUint32(n[:], uint32(len(r.New)))
		out.Write(n[:])
		out.WriteString(r.New)
		changes = append(changes, Change{Offset: i, Old: old, New: r.New})
		if d := len(r.New) - len(old); d != 0 {
			shifts = append(shifts, shift{i, d})
		}
		i += 4 + len(old)
		prev = i
	}
	out.Write(data[prev:])
	for j, n := range hits {
		if n == 0 {
			return nil, nil, fmt.Errorf("retexture: %q is not a string in the file", repl[j].Old)
		}
	}
	res := out.Bytes()
	if kind == "bsr" {
		for w := bsrTableLo; w <= bsrTableHi; w += 4 {
			v := int(binary.LittleEndian.Uint32(res[w:]))
			nv := v
			for _, s := range shifts {
				if v > s.at {
					nv += s.delta
				}
			}
			binary.LittleEndian.PutUint32(res[w:], uint32(nv))
		}
	}
	return res, changes, nil
}

// Strings lists a file's plausible length-prefixed strings (a length 3..511
// and that many printable bytes; decompressing a zlib .bmt first), for a tool
// to show what can be renamed. A listing, not a parse: Patch matches exact
// strings and does not use it.
func Strings(data []byte) ([]Change, error) {
	kind, err := Kind(data)
	if err != nil {
		return nil, err
	}
	if kind == "bmt-zlib" {
		if data, err = inflate(data); err != nil {
			return nil, err
		}
	}
	var out []Change
	for i := 0; i+4 <= len(data); i++ {
		n := int(binary.LittleEndian.Uint32(data[i:]))
		if n < 3 || n > 511 || i+4+n > len(data) || !printable(data[i+4:i+4+n]) {
			continue
		}
		out = append(out, Change{Offset: i, Old: string(data[i+4 : i+4+n])})
		i += 3 + n
	}
	return out, nil
}
