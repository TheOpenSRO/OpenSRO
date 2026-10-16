package pk2

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"strings"
	"sync"
)

// The path lookup every cmd/* tool used to carry its own copy of (round
// 789: ten hand-written walkers collapsed onto Find). The rules are the
// client's own, ObjectLoader.find_file and native/src/core/pk2.rs `find`,
// written down once in docs/protocol/asset_packs.md ("Rules"):
//
//   - `\` and `/` separate segments alike; empty segments (a leading,
//     trailing or doubled separator) are skipped (OURS: the client splits
//     without skipping, so it simply fails on such a path).
//   - a segment matches a name case-insensitively, folding each byte as a
//     Latin-1 code point (pk2 names are one byte a character: A-Z and
//     0xC0-0xDE except 0xD7 lower by 0x20, the Unicode simple lower-case
//     mapping Godot's to_lower and Rust's char::to_lowercase give for
//     those code points);
//   - the FIRST entry of a folded name in a directory wins (the client's
//     linear scan breaks on the first match; pk2.rs indexes the first);
//   - every segment but the last must be a folder.
//
// A directory is decrypted once and indexed by folded name; the index is
// kept for the archive's lifetime (a cache, never written back).

// ErrNotFound is returned (wrapped, with the path) when a path does not
// resolve. It is fs.ErrNotExist, so errors.Is(err, fs.ErrNotExist) holds.
var ErrNotFound = fs.ErrNotExist

// FoldByte lower-cases one pk2 name byte, read as a Latin-1 code point.
func FoldByte(b byte) byte {
	if (b >= 'A' && b <= 'Z') || (b >= 0xC0 && b <= 0xDE && b != 0xD7) {
		return b + 0x20
	}
	return b
}

// Fold lower-cases a pk2 name (or path) byte by byte with FoldByte.
func Fold(s string) string {
	for i := 0; i < len(s); i++ {
		if FoldByte(s[i]) != s[i] {
			b := []byte(s)
			for j := i; j < len(b); j++ {
				b[j] = FoldByte(b[j])
			}
			return string(b)
		}
	}
	return s
}

// SplitPath splits a pk2 path on `\` and `/`, dropping empty segments.
func SplitPath(p string) []string {
	return strings.FieldsFunc(p, func(r rune) bool { return r == '\\' || r == '/' })
}

type dirIndex struct {
	entries []Entry
	byName  map[string]int // folded name -> index of the FIRST entry of that name
}

type dirCache struct {
	mu   sync.Mutex
	dirs map[uint32]*dirIndex
}

// dirAt returns the indexed directory whose block chain starts at offset.
// The block chain is read outside the lock; two goroutines racing on the
// same directory both read it and the first stored wins.
func (a *Archive) dirAt(offset uint32) (*dirIndex, error) {
	a.cache.mu.Lock()
	d := a.cache.dirs[offset]
	a.cache.mu.Unlock()
	if d != nil {
		return d, nil
	}
	entries, err := a.readBlockChain(offset)
	if err != nil {
		return nil, err
	}
	d = &dirIndex{entries: entries, byName: make(map[string]int, len(entries))}
	for i, e := range entries {
		k := Fold(e.Name)
		if _, dup := d.byName[k]; !dup {
			d.byName[k] = i
		}
	}
	a.cache.mu.Lock()
	if a.cache.dirs == nil {
		a.cache.dirs = map[uint32]*dirIndex{}
	}
	if prev := a.cache.dirs[offset]; prev != nil {
		d = prev
	} else {
		a.cache.dirs[offset] = d
	}
	a.cache.mu.Unlock()
	return d, nil
}

// Root returns an Entry standing for the root folder (Name "", IsDir), so
// ReadDirAt(Root()) is ReadDir().
func (a *Archive) Root() Entry {
	return Entry{IsDir: true, offset: a.rootOffset}
}

// Find resolves a path to its Entry (a file or a folder). An empty path
// (or one of separators only) is the root folder. A missing segment, or a
// non-final segment that is a file, returns an error wrapping
// fs.ErrNotExist.
func (a *Archive) Find(path string) (Entry, error) {
	parts := SplitPath(path)
	cur := a.Root()
	for i, part := range parts {
		if !cur.IsDir {
			return Entry{}, fmt.Errorf("pk2: %s: %s is a file, not a folder: %w", path, strings.Join(parts[:i], `\`), ErrNotFound)
		}
		d, err := a.dirAt(cur.offset)
		if err != nil {
			return Entry{}, err
		}
		j, ok := d.byName[Fold(part)]
		if !ok {
			return Entry{}, fmt.Errorf("pk2: %s: %w", path, ErrNotFound)
		}
		cur = d.entries[j]
	}
	return cur, nil
}

// ReadPath returns the bytes of the file at path (Find + ReadFile).
func (a *Archive) ReadPath(path string) ([]byte, error) {
	e, err := a.Find(path)
	if err != nil {
		return nil, err
	}
	if e.IsDir {
		return nil, fmt.Errorf("pk2: %s is a folder, not a file", path)
	}
	return a.ReadFile(e)
}

// Children returns a folder Entry's entries from the directory cache
// (callers must not modify the slice).
func (a *Archive) Children(dir Entry) ([]Entry, error) {
	if !dir.IsDir {
		return nil, fmt.Errorf("pk2: %q is not a folder", dir.Name)
	}
	d, err := a.dirAt(dir.offset)
	if err != nil {
		return nil, err
	}
	return d.entries, nil
}

// OpenEntry returns a reader over a file Entry's bytes without loading
// them: a section of the archive file, safe to use from several goroutines
// at once (positional reads).
func (a *Archive) OpenEntry(file Entry) (*io.SectionReader, error) {
	if file.IsDir {
		return nil, fmt.Errorf("pk2: %q is a folder, not a file", file.Name)
	}
	return io.NewSectionReader(a.f, int64(file.offset), int64(file.Size)), nil
}

// SkipDir, returned by a WalkFunc on a folder, skips that folder's contents.
var SkipDir = errors.New("pk2: skip this folder")

// WalkFunc is called once per entry. path joins the names from the root
// with `\` (the archive's own spelling). shadowed is true when Find cannot
// reach the entry: an earlier entry of the same folded name sits in the
// same folder, or an ancestor folder is itself shadowed.
type WalkFunc func(path string, e Entry, shadowed bool) error

// WalkAll visits every file and folder entry in directory order, a folder
// before its contents, including the shadowed duplicates Find never
// returns. A folder whose block chain starts at an offset already on the
// current branch is reported as an error (a cycle), not followed.
func (a *Archive) WalkAll(fn WalkFunc) error {
	return a.walk(a.rootOffset, "", false, map[uint32]bool{a.rootOffset: true}, fn)
}

// Walk visits exactly the entries Find can reach, in directory order.
func (a *Archive) Walk(fn func(path string, e Entry) error) error {
	return a.WalkAll(func(path string, e Entry, shadowed bool) error {
		if shadowed {
			if e.IsDir {
				return SkipDir
			}
			return nil
		}
		return fn(path, e)
	})
}

func (a *Archive) walk(offset uint32, prefix string, shadowedParent bool, onBranch map[uint32]bool, fn WalkFunc) error {
	d, err := a.dirAt(offset)
	if err != nil {
		return fmt.Errorf("pk2: reading folder %q: %w", prefix, err)
	}
	for i, e := range d.entries {
		p := e.Name
		if prefix != "" {
			p = prefix + `\` + e.Name
		}
		shadowed := shadowedParent || d.byName[Fold(e.Name)] != i
		err := fn(p, e, shadowed)
		if err == SkipDir {
			continue
		}
		if err != nil {
			return err
		}
		if !e.IsDir {
			continue
		}
		if onBranch[e.offset] {
			return fmt.Errorf("pk2: folder %q loops back to an ancestor (block at %d)", p, e.offset)
		}
		onBranch[e.offset] = true
		err = a.walk(e.offset, p, shadowed, onBranch, fn)
		delete(onBranch, e.offset)
		if err != nil {
			return err
		}
	}
	return nil
}
