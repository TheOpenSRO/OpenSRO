package assetfs

import (
	"archive/zip"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"unicode/utf8"

	"github.com/OpenSRO/OpenSRO/server/internal/pk2"
)

// Limits are the zip-bomb guards a pack is checked against when it is
// opened (OURS; the measurement behind the defaults is in
// docs/protocol/asset_packs.md, "Safety"). An entry over a limit is refused
// (logged, listed in Layer.Rejected) and the rest of the pack loads; a pack
// over the whole-pack ratio is not opened at all.
type Limits struct {
	// MaxEntrySize caps one entry's unpacked size.
	MaxEntrySize int64
	// MaxRatio caps unpacked/packed, for one entry and for the whole pack
	// (every entry's unpacked size against the pack file's size).
	MaxRatio int64
}

// DefaultLimits: 256 MiB an entry, twelve times the largest retail entry
// (21,352,219 bytes, Data.pk2's navmesh\ainavdata_32773.dat; MEASURED round
// 789), and 1100:1. Deflate cannot pack better than about 1032:1, so no
// honest entry or pack passes 1100:1, while retail itself reaches 974.6:1
// (Media.pk2's script\image\qno_script_background_white.ddj, MEASURED): a
// lower cap would refuse real files. What a ratio past deflate's limit
// catches is a lying header (an entry claiming more than its stream holds)
// and entries that overlap one compressed stream to multiply it (the
// "better zip bomb"), which the whole-pack ratio sees. A single honest
// entry can still unpack 1032 times its size, which is what MaxEntrySize
// bounds; and the reader stops at the size an entry records (archive/zip).
var DefaultLimits = Limits{MaxEntrySize: 256 << 20, MaxRatio: 1100}

// node is one file or folder as a source knows it.
type node struct {
	name  string // the stored spelling, as UTF-8 code points
	isDir bool
	size  int64
	ref   any // pk2.Entry, *treeNode
}

// source is one archive (or loose folder) of a layer.
type source interface {
	// lookup resolves a path's folded segments.
	lookup(key []string) (node, bool, error)
	// list returns a folder's children in stored order.
	list(dir node) ([]node, error)
	open(file node) (io.ReadCloser, error)
	// walk visits every reachable entry, a folder before its contents.
	walk(fn func(parts []string, n node) error) error
	close() error
}

// ---- pk2 ----

type pk2Source struct{ a *pk2.Archive }

func openPK2(path string) (*pk2Source, error) {
	a, err := pk2.Open(path)
	if err != nil {
		return nil, err
	}
	return &pk2Source{a: a}, nil
}

func pk2Node(e pk2.Entry) node {
	return node{name: Latin1ToUTF8(e.Name), isDir: e.IsDir, size: int64(e.Size), ref: e}
}

func (s *pk2Source) lookup(key []string) (node, bool, error) {
	parts := make([]string, len(key))
	for i, k := range key {
		b, ok := UTF8ToLatin1(k)
		if !ok {
			return node{}, false, nil
		}
		parts[i] = b
	}
	e, err := s.a.Find(strings.Join(parts, `\`))
	if errors.Is(err, fs.ErrNotExist) {
		return node{}, false, nil
	}
	if err != nil {
		return node{}, false, err
	}
	return pk2Node(e), true, nil
}

func (s *pk2Source) list(dir node) ([]node, error) {
	es, err := s.a.Children(dir.ref.(pk2.Entry))
	if err != nil {
		return nil, err
	}
	out := make([]node, 0, len(es))
	seen := make(map[string]bool, len(es))
	for _, e := range es {
		k := pk2.Fold(e.Name)
		if seen[k] { // shadowed: Find never returns it
			continue
		}
		seen[k] = true
		out = append(out, pk2Node(e))
	}
	return out, nil
}

func (s *pk2Source) open(file node) (io.ReadCloser, error) {
	r, err := s.a.OpenEntry(file.ref.(pk2.Entry))
	if err != nil {
		return nil, err
	}
	return io.NopCloser(r), nil
}

func (s *pk2Source) walk(fn func(parts []string, n node) error) error {
	return s.a.Walk(func(p string, e pk2.Entry) error {
		parts := pk2.SplitPath(Latin1ToUTF8(p))
		if _, err := Segments(p); err != nil {
			if e.IsDir {
				return pk2.SkipDir
			}
			return nil
		}
		err := fn(parts, pk2Node(e))
		if err == errSkipDir {
			return pk2.SkipDir
		}
		return err
	})
}

func (s *pk2Source) close() error { return s.a.Close() }

// errSkipDir, returned by a walk callback on a folder, skips its contents.
var errSkipDir = errors.New("assetfs: skip folder")

// ---- tree (zip and loose folder) ----

type treeNode struct {
	name     string
	isDir    bool
	size     int64
	file     *zip.File // zip entries
	disk     string    // loose files
	children map[string]*treeNode
	order    []*treeNode
}

func newTreeDir(name string) *treeNode {
	return &treeNode{name: name, isDir: true, children: map[string]*treeNode{}}
}

// insert adds a file (or an explicit folder) under root. A segment that
// collides with an existing file, or a file whose key is taken, is refused:
// the first entry of a key wins (OURS, as a pk2's first entry wins).
func (root *treeNode) insert(parts []string, leaf *treeNode) error {
	cur := root
	for i, p := range parts {
		k := FoldName(p)
		last := i == len(parts)-1
		child := cur.children[k]
		if last {
			if child != nil {
				if child.isDir && leaf.isDir {
					return nil // an explicit folder entry for an implied one
				}
				return fmt.Errorf("duplicate of %q", DisplayPath(parts))
			}
			leaf.name = p
			cur.children[k] = leaf
			cur.order = append(cur.order, leaf)
			return nil
		}
		if child == nil {
			child = newTreeDir(p)
			cur.children[k] = child
			cur.order = append(cur.order, child)
		} else if !child.isDir {
			return fmt.Errorf("%q is a file, not a folder", DisplayPath(parts[:i+1]))
		}
		cur = child
	}
	return nil
}

type treeSource struct {
	root   *treeNode
	closer io.Closer
}

func treeNodeOf(t *treeNode) node {
	return node{name: t.name, isDir: t.isDir, size: t.size, ref: t}
}

func (s *treeSource) lookup(key []string) (node, bool, error) {
	cur := s.root
	for _, k := range key {
		if !cur.isDir {
			return node{}, false, nil
		}
		cur = cur.children[k]
		if cur == nil {
			return node{}, false, nil
		}
	}
	return treeNodeOf(cur), true, nil
}

func (s *treeSource) list(dir node) ([]node, error) {
	t := dir.ref.(*treeNode)
	out := make([]node, len(t.order))
	for i, c := range t.order {
		out[i] = treeNodeOf(c)
	}
	return out, nil
}

func (s *treeSource) open(file node) (io.ReadCloser, error) {
	t := file.ref.(*treeNode)
	if t.file != nil {
		return t.file.Open() // checks the size and the CRC-32 as it reads
	}
	f, err := os.Open(t.disk)
	if err != nil {
		return nil, err
	}
	return f, nil
}

func (s *treeSource) walk(fn func(parts []string, n node) error) error {
	var rec func(t *treeNode, prefix []string) error
	rec = func(t *treeNode, prefix []string) error {
		for _, c := range t.order {
			parts := append(append([]string(nil), prefix...), c.name)
			err := fn(parts, treeNodeOf(c))
			if err == errSkipDir {
				continue
			}
			if err != nil {
				return err
			}
			if c.isDir {
				if err := rec(c, parts); err != nil {
					return err
				}
			}
		}
		return nil
	}
	return rec(s.root, nil)
}

func (s *treeSource) close() error {
	if s.closer != nil {
		return s.closer.Close()
	}
	return nil
}

// zipEntryName decodes a zip entry's name: UTF-8 when the entry says so
// (general-purpose flag bit 11, or a name that is plain ASCII), otherwise
// one byte a character (Latin-1, the way a pk2 name is read; not CP437).
func zipEntryName(f *zip.File) string {
	if f.NonUTF8 {
		return Latin1ToUTF8(f.Name)
	}
	return f.Name
}

// openZip indexes a zip (`.pk3`/`.zip`). Entries that break a rule are
// refused and described in rejected.
func openZip(path string, lim Limits) (src *treeSource, rejected []string, err error) {
	r, err := zip.OpenReader(path)
	if err != nil && !(errors.Is(err, zip.ErrInsecurePath) && r != nil) {
		return nil, nil, err // (an insecure name is refused below, entry by entry)
	}
	if st, serr := os.Stat(path); serr == nil && lim.MaxRatio > 0 {
		var total uint64
		for _, f := range r.File {
			total += f.UncompressedSize64
		}
		if total > uint64(lim.MaxRatio)*uint64(st.Size()) {
			r.Close()
			return nil, nil, fmt.Errorf("%w: its entries unpack to %d bytes from a %d-byte file (over %d:1): a zip bomb", ErrUnsafe, total, st.Size(), lim.MaxRatio)
		}
	}
	root := newTreeDir("")
	for _, f := range r.File {
		name := zipEntryName(f)
		if why := checkZipEntry(f, name, lim); why != "" {
			rejected = append(rejected, fmt.Sprintf("%q: %s", name, why))
			continue
		}
		parts, isDir, _ := CheckEntryName(name)
		leaf := &treeNode{isDir: isDir, size: int64(f.UncompressedSize64), file: f}
		if isDir {
			leaf = newTreeDir("")
		}
		if err := root.insert(parts, leaf); err != nil {
			rejected = append(rejected, fmt.Sprintf("%q: %v", name, err))
		}
	}
	return &treeSource{root: root, closer: r}, rejected, nil
}

func checkZipEntry(f *zip.File, name string, lim Limits) string {
	if _, _, err := CheckEntryName(name); err != nil {
		return err.Error()
	}
	if strings.HasSuffix(name, "/") || strings.HasSuffix(name, `\`) {
		return ""
	}
	if f.Flags&0x1 != 0 {
		return "encrypted"
	}
	if f.Method != zip.Store && f.Method != zip.Deflate {
		return fmt.Sprintf("compression method %d (only stored and deflated are read)", f.Method)
	}
	if lim.MaxEntrySize > 0 && f.UncompressedSize64 > uint64(lim.MaxEntrySize) {
		return fmt.Sprintf("unpacks to %d bytes, over the %d-byte cap", f.UncompressedSize64, lim.MaxEntrySize)
	}
	if f.Method == zip.Store && f.CompressedSize64 != f.UncompressedSize64 {
		return "a stored entry whose packed and unpacked sizes differ"
	}
	if lim.MaxRatio > 0 && f.UncompressedSize64 > 64 &&
		f.UncompressedSize64 > uint64(lim.MaxRatio)*f.CompressedSize64 {
		return fmt.Sprintf("unpacks %d bytes from %d (over %d:1): a zip bomb", f.UncompressedSize64, f.CompressedSize64, lim.MaxRatio)
	}
	return ""
}

// openLoose indexes a loose folder (custom/). Symbolic links are refused,
// so nothing outside the folder is reachable through it (OURS).
func openLoose(dir string, lim Limits) (src *treeSource, rejected []string, err error) {
	st, err := os.Stat(dir)
	if err != nil {
		return nil, nil, err
	}
	if !st.IsDir() {
		return nil, nil, fmt.Errorf("%s is not a folder", dir)
	}
	root := newTreeDir("")
	err = filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if p == dir {
			return nil
		}
		rel, _ := filepath.Rel(dir, p)
		name := filepath.ToSlash(rel)
		if !utf8.ValidString(name) {
			name = Latin1ToUTF8(name)
		}
		if d.Type()&fs.ModeSymlink != 0 {
			rejected = append(rejected, fmt.Sprintf("%q: a symbolic link", name))
			return nil
		}
		if d.IsDir() {
			name += "/"
		}
		parts, isDir, cerr := CheckEntryName(name)
		if cerr != nil {
			rejected = append(rejected, fmt.Sprintf("%q: %v", name, cerr))
			if d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		var leaf *treeNode
		if isDir {
			leaf = newTreeDir("")
		} else {
			if !d.Type().IsRegular() {
				rejected = append(rejected, fmt.Sprintf("%q: not a regular file", name))
				return nil
			}
			info, ierr := d.Info()
			if ierr != nil {
				return ierr
			}
			if lim.MaxEntrySize > 0 && info.Size() > lim.MaxEntrySize {
				rejected = append(rejected, fmt.Sprintf("%q: %d bytes, over the %d-byte cap", name, info.Size(), lim.MaxEntrySize))
				return nil
			}
			leaf = &treeNode{size: info.Size(), disk: p}
		}
		if ierr := root.insert(parts, leaf); ierr != nil {
			rejected = append(rejected, fmt.Sprintf("%q: %v", name, ierr))
			if d.IsDir() {
				return filepath.SkipDir
			}
		}
		return nil
	})
	if err != nil {
		return nil, nil, err
	}
	return &treeSource{root: root}, rejected, nil
}

// readAll reads exactly n.size bytes of a file node.
func readAll(s source, n node) ([]byte, error) {
	rc, err := s.open(n)
	if err != nil {
		return nil, err
	}
	defer rc.Close()
	buf := make([]byte, n.size)
	if _, err := io.ReadFull(rc, buf); err != nil {
		return nil, err
	}
	// Drain to EOF so a zip entry's CRC-32 is checked.
	var one [1]byte
	if k, err := rc.Read(one[:]); k != 0 || (err != nil && err != io.EOF) {
		if err == nil {
			err = errors.New("entry is longer than its recorded size")
		}
		return nil, err
	}
	return buf, nil
}
