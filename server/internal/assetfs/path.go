// Package assetfs is the layered asset file system of docs/protocol/asset_packs.md:
// a loose `custom/` folder over asset packs (`.pk3`, `.zip` and non-base
// `.pk2`) over the five retail base archives, read through one lookup.
// Everything about packs is OURS: retail has only `.pk2`. The Go tools read
// through it (pk2list, export-refdata, export-leveldata, pk2topk3); the
// server itself reads no archive at runtime.
//
// Paths are the pk2's own: segments separated by `\` or `/`, matched
// case-insensitively. Inside this package a path is handled as its key, the
// lower-cased segments joined by `/` (Key); what a listing prints is the
// serving layer's own spelling joined by `\`.
package assetfs

import (
	"errors"
	"fmt"
	"strings"
	"unicode"
	"unicode/utf8"
)

// ErrUnsafe is wrapped by the errors for entry names (and lookups) that
// could escape an archive: `..` or `.` segments, absolute paths, drive
// letters, `:` or NUL.
var ErrUnsafe = errors.New("assetfs: unsafe path")

// FoldName lower-cases a name with the Unicode simple lower-case mapping,
// code point by code point (OURS, docs/protocol/asset_packs.md "Rules"). For
// the Latin-1 code points a pk2 name holds (one byte a character) it is
// exactly pk2.Fold: A-Z and U+00C0-U+00DE except U+00D7.
func FoldName(s string) string {
	ascii := true
	for i := 0; i < len(s); i++ {
		if s[i] >= 0x80 || (s[i] >= 'A' && s[i] <= 'Z') {
			ascii = false
			break
		}
	}
	if ascii {
		return s
	}
	return strings.Map(unicode.ToLower, s)
}

// Latin1ToUTF8 reads a pk2 name's bytes as Latin-1 code points (one byte a
// character, as the client's Pk2Reader and native pk2.rs decode them).
func Latin1ToUTF8(b string) string {
	for i := 0; i < len(b); i++ {
		if b[i] >= 0x80 {
			r := make([]rune, len(b))
			for j := 0; j < len(b); j++ {
				r[j] = rune(b[j])
			}
			return string(r)
		}
	}
	return b
}

// UTF8ToLatin1 is the inverse of Latin1ToUTF8; ok is false when a code
// point lies above U+00FF (no pk2 name can hold it) or s is not UTF-8.
func UTF8ToLatin1(s string) (string, bool) {
	ascii := true
	for i := 0; i < len(s); i++ {
		if s[i] >= 0x80 {
			ascii = false
			break
		}
	}
	if ascii {
		return s, true
	}
	if !utf8.ValidString(s) {
		return "", false
	}
	b := make([]byte, 0, len(s))
	for _, r := range s {
		if r > 0xFF {
			return "", false
		}
		b = append(b, byte(r))
	}
	return string(b), true
}

func isSep(r rune) bool { return r == '/' || r == '\\' }

// Segments splits a lookup path on `\` and `/`, dropping empty segments (a
// leading, trailing or doubled separator). A `.` or `..` segment, a `:` or a
// NUL makes the path unsafe: no layer serves it.
//
// A path that is not valid UTF-8 is read one byte a character (Latin-1): the
// raw bytes of a pk2 name, as pk2list printed them before round 789, still
// find their file.
func Segments(p string) ([]string, error) {
	if !utf8.ValidString(p) {
		p = Latin1ToUTF8(p)
	}
	parts := strings.FieldsFunc(p, isSep)
	for _, s := range parts {
		if s == "." || s == ".." || strings.ContainsAny(s, ":\x00") {
			return nil, fmt.Errorf("%w: %q", ErrUnsafe, p)
		}
	}
	return parts, nil
}

// Key is the folded, `/`-joined form of a lookup path: two paths name the
// same file exactly when their keys are equal.
func Key(p string) (string, error) {
	parts, err := Segments(p)
	if err != nil {
		return "", err
	}
	for i := range parts {
		parts[i] = FoldName(parts[i])
	}
	return strings.Join(parts, "/"), nil
}

// CheckEntryName applies the stricter rule for a name stored INSIDE a pack
// (a zip entry, or a file under custom/): on top of Segments' rule it must
// not be absolute (a leading separator), must not start with a drive letter,
// and must not hold an empty segment except one trailing separator (a
// folder entry). It returns the segments and whether the entry is a folder.
func CheckEntryName(name string) (parts []string, isDir bool, err error) {
	if name == "" {
		return nil, false, fmt.Errorf("%w: empty name", ErrUnsafe)
	}
	if isSep(rune(name[0])) {
		return nil, false, fmt.Errorf("%w: absolute path %q", ErrUnsafe, name)
	}
	if len(name) >= 2 && name[1] == ':' {
		return nil, false, fmt.Errorf("%w: drive letter in %q", ErrUnsafe, name)
	}
	trimmed := name
	if isSep(rune(name[len(name)-1])) {
		isDir = true
		trimmed = name[:len(name)-1]
	}
	raw := strings.FieldsFunc(trimmed, isSep)
	if strings.Count(strings.ReplaceAll(trimmed, `\`, "/"), "/") != len(raw)-1 {
		return nil, false, fmt.Errorf("%w: empty segment in %q", ErrUnsafe, name)
	}
	parts, err = Segments(trimmed)
	if err != nil {
		return nil, false, err
	}
	if len(parts) == 0 {
		return nil, false, fmt.Errorf("%w: empty name %q", ErrUnsafe, name)
	}
	return parts, isDir, nil
}

// DisplayPath joins segments the way the pk2 tools print a path.
func DisplayPath(parts []string) string { return strings.Join(parts, `\`) }
