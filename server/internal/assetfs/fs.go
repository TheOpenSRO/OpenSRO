package assetfs

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Mode is the source mode setting (docs/TODO.md "Asset packs"; the user's
// decision 2026-10-01): which archive types a folder is read from.
type Mode int

const (
	// ModeMixed, the default, reads every archive type: packs layer over the
	// base archives, whether `.pk2` or converted `.pk3`.
	ModeMixed Mode = iota
	// ModePK2 reads `.pk2` archives only (base and pack), today's behaviour.
	ModePK2
	// ModePK3 reads `.pk3` and `.zip` only: the retail content converted
	// once (cmd/pk2topk3), then no `.pk2` needed.
	ModePK3
)

func (m Mode) String() string {
	switch m {
	case ModePK2:
		return "pk2"
	case ModePK3:
		return "pk3"
	}
	return "mixed"
}

// ParseMode reads "pk2", "pk3" or "mixed" (or "", which is mixed).
func ParseMode(s string) (Mode, error) {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "", "mixed":
		return ModeMixed, nil
	case "pk2":
		return ModePK2, nil
	case "pk3":
		return ModePK3, nil
	}
	return ModeMixed, fmt.Errorf("assetfs: source mode %q: want pk2, pk3 or mixed", s)
}

// BaseNames are the five retail base archives (the user, 2026-10-16: FIVE,
// not the four docs/TODO.md listed). Whatever their extension they are the
// bottom of every lookup.
var BaseNames = []string{"Data", "Map", "Media", "Music", "Particles"}

// Kind is a layer's place in the stack.
type Kind int

const (
	KindCustom Kind = iota // the loose custom/ folder, top
	KindPack               // .pk3, .zip, non-base .pk2
	KindBase               // Data, Map, Media, Music, Particles
)

func (k Kind) String() string {
	switch k {
	case KindCustom:
		return "custom"
	case KindPack:
		return "pack"
	}
	return "base"
}

// Layer is one archive (or the custom/ folder) in the stack.
type Layer struct {
	Name   string // the file name ("z_assets.pk3", "Data.pk2"), or "custom/"
	Path   string
	Kind   Kind
	Volume string // KindBase: which of BaseNames ("Data"); "" otherwise
	// Rejected lists the entries refused at load (unsafe names, zip-bomb
	// limits, duplicates), each with its reason.
	Rejected []string
	src      source
}

func (l *Layer) String() string { return l.Name }

// Options configure Open.
type Options struct {
	Mode Mode
	// CustomDir is the loose overlay folder. "" means <dir>/custom when it
	// exists; NoCustom turns the overlay off.
	CustomDir string
	NoCustom  bool
	// Limits for pack entries; the zero value means DefaultLimits.
	Limits *Limits
	// Logf receives one line per refused entry, skipped archive and override
	// (nil: silent).
	Logf func(format string, args ...any)
	// Strict makes Open fail instead of skipping an archive it cannot open
	// or refusing an entry: for exporters, where a dropped pack would
	// silently drop rows.
	Strict bool
}

// Override is a pack (or custom/) file that hides the same path in a lower
// layer.
type Override struct {
	Path  string // as the overriding layer spells it, `\`-joined
	Layer *Layer
	Over  *Layer
}

// FS is a folder of archives opened per the rules. Its embedded View is the
// unscoped one: every layer, the base archives cascaded by name like packs.
type FS struct {
	*View
	all       []*Layer // highest first
	overrides []Override
	added     map[*Layer]int
}

// View is a stack of layers, highest first; the first layer that has a path
// serves it.
type View struct {
	layers []*Layer
}

func extRank(ext string) int {
	switch strings.ToLower(ext) {
	case ".pk2":
		return 0
	case ".zip":
		return 1
	case ".pk3":
		return 2
	}
	return -1
}

func baseVolume(stem string) string {
	for _, b := range BaseNames {
		if strings.EqualFold(b, stem) {
			return b
		}
	}
	return ""
}

// sortCascade orders archives LOWEST first: by lower-cased stem, then
// `.pk2` < `.zip` < `.pk3` of the same stem, then the exact file name (so
// "Assets.pk3" and "assets.pk3" on a case-sensitive disk still order the
// same way every time). The last one wins a lookup.
func sortCascade(names []string) {
	sort.SliceStable(names, func(i, j int) bool {
		ei, ej := filepath.Ext(names[i]), filepath.Ext(names[j])
		si, sj := FoldName(strings.TrimSuffix(names[i], ei)), FoldName(strings.TrimSuffix(names[j], ej))
		if si != sj {
			return si < sj
		}
		if ri, rj := extRank(ei), extRank(ej); ri != rj {
			return ri < rj
		}
		return names[i] < names[j]
	})
}

func (o *Options) limits() Limits {
	if o.Limits != nil {
		return *o.Limits
	}
	return DefaultLimits
}

func (o *Options) logf(format string, args ...any) {
	if o.Logf != nil {
		o.Logf(format, args...)
	}
}

func openSource(path string, lim Limits) (source, []string, error) {
	if strings.EqualFold(filepath.Ext(path), ".pk2") {
		s, err := openPK2(path)
		return s, nil, err
	}
	return openZip(path, lim)
}

// Open opens the archives in dir per docs/protocol/asset_packs.md.
func Open(dir string, opt Options) (*FS, error) {
	ents, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	var names []string
	for _, e := range ents {
		if !e.Type().IsRegular() {
			// An archive may be a symbolic link to one kept elsewhere (the
			// operator's own folder); a pack's ENTRIES never follow links.
			st, err := os.Stat(filepath.Join(dir, e.Name()))
			if e.Type()&fs.ModeSymlink == 0 || err != nil || !st.Mode().IsRegular() {
				continue
			}
		}
		r := extRank(filepath.Ext(e.Name()))
		if r < 0 || (opt.Mode == ModePK2 && r != 0) || (opt.Mode == ModePK3 && r == 0) {
			continue
		}
		names = append(names, e.Name())
	}
	sortCascade(names)
	lim := opt.limits()
	f := &FS{added: map[*Layer]int{}}
	var packs, bases []*Layer
	fail := func(l *Layer) error {
		for _, l := range append(packs, bases...) {
			l.src.close()
		}
		if l != nil && l.src != nil {
			l.src.close()
		}
		return fmt.Errorf("assetfs: %s refuses %d entr(ies), first %s (strict)", l.Name, len(l.Rejected), l.Rejected[0])
	}
	// Highest first: walk the cascade from its end.
	for i := len(names) - 1; i >= 0; i-- {
		n := names[i]
		p := filepath.Join(dir, n)
		src, rejected, err := openSource(p, lim)
		if err != nil {
			if opt.Strict {
				for _, l := range append(packs, bases...) {
					l.src.close()
				}
				return nil, fmt.Errorf("assetfs: opening %s: %w", n, err)
			}
			opt.logf("assetfs: skipping %s: %v", n, err)
			continue
		}
		l := &Layer{Name: n, Path: p, Kind: KindPack, Rejected: rejected, src: src}
		if v := baseVolume(strings.TrimSuffix(n, filepath.Ext(n))); v != "" {
			l.Kind, l.Volume = KindBase, v
		}
		for _, r := range rejected {
			opt.logf("assetfs: %s: refused entry %s", n, r)
		}
		if opt.Strict && len(rejected) > 0 {
			return nil, fail(l)
		}
		if l.Kind == KindBase {
			bases = append(bases, l)
		} else {
			packs = append(packs, l)
		}
	}
	var stack []*Layer
	if !opt.NoCustom {
		cdir := opt.CustomDir
		explicit := cdir != ""
		if !explicit {
			cdir = filepath.Join(dir, "custom")
		}
		if st, err := os.Stat(cdir); err == nil && st.IsDir() {
			src, rejected, err := openLoose(cdir, lim)
			if err != nil {
				return nil, fmt.Errorf("assetfs: custom folder %s: %w", cdir, err)
			}
			l := &Layer{Name: "custom/", Path: cdir, Kind: KindCustom, Rejected: rejected, src: src}
			for _, r := range rejected {
				opt.logf("assetfs: custom/: refused entry %s", r)
			}
			if opt.Strict && len(rejected) > 0 {
				return nil, fail(l)
			}
			stack = append(stack, l)
		} else if explicit {
			return nil, fmt.Errorf("assetfs: custom folder %s: not found", cdir)
		}
	}
	stack = append(stack, packs...)
	stack = append(stack, bases...)
	f.all = stack
	f.View = &View{layers: stack}
	if err := f.findOverrides(opt); err != nil {
		f.Close()
		return nil, err
	}
	return f, nil
}

// OpenArchive opens one archive (`.pk2`, `.pk3` or `.zip`) as a one-layer
// FS, with the pack entry checks.
func OpenArchive(path string, lim *Limits) (*FS, error) {
	if extRank(filepath.Ext(path)) < 0 {
		return nil, fmt.Errorf("assetfs: %s: not a .pk2, .pk3 or .zip", path)
	}
	return openOne(path, lim, strings.EqualFold(filepath.Ext(path), ".pk2"))
}

func openOne(path string, lim *Limits, isPK2 bool) (*FS, error) {
	l := DefaultLimits
	if lim != nil {
		l = *lim
	}
	var src source
	var rejected []string
	var err error
	if isPK2 {
		src, err = openPK2(path)
	} else {
		src, rejected, err = openZip(path, l)
	}
	if err != nil {
		return nil, err
	}
	n := filepath.Base(path)
	layer := &Layer{Name: n, Path: path, Kind: KindPack, Rejected: rejected, src: src}
	if v := baseVolume(strings.TrimSuffix(n, filepath.Ext(n))); v != "" {
		layer.Kind, layer.Volume = KindBase, v
	}
	stack := []*Layer{layer}
	return &FS{View: &View{layers: stack}, all: stack, added: map[*Layer]int{}}, nil
}

// findOverrides records, for every custom/ and pack file, the highest lower
// layer that also has its path ("log every override at load", docs/TODO.md).
func (f *FS) findOverrides(opt Options) error {
	for i, l := range f.all {
		if l.Kind == KindBase {
			break
		}
		lower := f.all[i+1:]
		err := l.src.walk(func(parts []string, n node) error {
			if n.isDir {
				return nil
			}
			key := foldParts(parts)
			for _, m := range lower {
				if _, ok, err := m.src.lookup(key); err != nil {
					return err
				} else if ok {
					o := Override{Path: DisplayPath(parts), Layer: l, Over: m}
					f.overrides = append(f.overrides, o)
					opt.logf("assetfs: %s overrides %s in %s", l.Name, o.Path, m.Name)
					return nil
				}
			}
			f.added[l]++
			return nil
		})
		if err != nil {
			return err
		}
	}
	return nil
}

// Overrides lists every custom/ or pack file that hides a lower layer's.
func (f *FS) Overrides() []Override { return f.overrides }

// Added counts a layer's files that no lower layer has.
func (f *FS) Added(l *Layer) int { return f.added[l] }

// Close closes every archive.
func (f *FS) Close() error {
	var first error
	for _, l := range f.all {
		if err := l.src.close(); err != nil && first == nil {
			first = err
		}
	}
	return first
}

// In is the view a lookup that names its base archive sees: custom/, every
// pack, then only that volume's base layers (Data.pk3 over Data.pk2 when
// both are there). The client asks this way (each find_file names its
// archive), and it must: 40 paths exist in two retail base archives and 5
// of them differ (MEASURED, docs/protocol/asset_packs.md "Volumes").
func (f *FS) In(volume string) (*View, error) {
	v := baseVolume(volume)
	if v == "" {
		return nil, fmt.Errorf("assetfs: %q is not a base archive (want one of %s)", volume, strings.Join(BaseNames, ", "))
	}
	var stack []*Layer
	have := false
	for _, l := range f.all {
		if l.Kind != KindBase {
			stack = append(stack, l)
		} else if l.Volume == v {
			stack = append(stack, l)
			have = true
		}
	}
	if !have {
		return nil, fmt.Errorf("assetfs: no %s archive among the layers: %w", v, fs.ErrNotExist)
	}
	return &View{layers: stack}, nil
}

// Layers returns the stack, highest first.
func (v *View) Layers() []*Layer { return v.layers }

// Info describes a resolved file or folder.
type Info struct {
	Path  string // `\`-joined; the last segment as the serving layer stores it
	Name  string
	IsDir bool
	Size  int64
	Layer *Layer
}

func foldParts(parts []string) []string {
	out := make([]string, len(parts))
	for i, p := range parts {
		out[i] = FoldName(p)
	}
	return out
}

type hit struct {
	layer *Layer
	n     node
	parts []string
}

func (v *View) resolve(path string) (hit, error) {
	parts, err := Segments(path)
	if err != nil {
		return hit{}, err
	}
	key := foldParts(parts)
	for _, l := range v.layers {
		n, ok, err := l.src.lookup(key)
		if err != nil {
			return hit{}, fmt.Errorf("assetfs: %s: %s: %w", l.Name, path, err)
		}
		if ok {
			if len(parts) > 0 {
				parts[len(parts)-1] = n.name
			}
			return hit{layer: l, n: n, parts: parts}, nil
		}
	}
	return hit{}, fmt.Errorf("assetfs: %s: %w", path, fs.ErrNotExist)
}

func (h hit) info() Info {
	return Info{Path: DisplayPath(h.parts), Name: h.n.name, IsDir: h.n.isDir, Size: h.n.size, Layer: h.layer}
}

// Stat resolves a path. A missing path's error wraps fs.ErrNotExist; an
// unsafe one's wraps ErrUnsafe.
func (v *View) Stat(path string) (Info, error) {
	h, err := v.resolve(path)
	if err != nil {
		return Info{}, err
	}
	return h.info(), nil
}

// Which names the layer that serves path.
func (v *View) Which(path string) (*Layer, error) {
	h, err := v.resolve(path)
	if err != nil {
		return nil, err
	}
	return h.layer, nil
}

// WhichAll lists every layer that has path, highest (the serving one)
// first.
func (v *View) WhichAll(path string) ([]Info, error) {
	parts, err := Segments(path)
	if err != nil {
		return nil, err
	}
	if len(parts) == 0 {
		return nil, fmt.Errorf("assetfs: WhichAll needs a path")
	}
	key := foldParts(parts)
	var out []Info
	for _, l := range v.layers {
		n, ok, err := l.src.lookup(key)
		if err != nil {
			return nil, err
		}
		if ok {
			p := append([]string(nil), parts...)
			p[len(p)-1] = n.name
			out = append(out, Info{Path: DisplayPath(p), Name: n.name, IsDir: n.isDir, Size: n.size, Layer: l})
		}
	}
	return out, nil
}

// Open streams a file. Closing the reader is the caller's job.
func (v *View) Open(path string) (io.ReadCloser, Info, error) {
	h, err := v.resolve(path)
	if err != nil {
		return nil, Info{}, err
	}
	if h.n.isDir {
		return nil, Info{}, fmt.Errorf("assetfs: %s is a folder", path)
	}
	rc, err := h.layer.src.open(h.n)
	if err != nil {
		return nil, Info{}, fmt.Errorf("assetfs: %s: %s: %w", h.layer.Name, path, err)
	}
	return rc, h.info(), nil
}

// ReadFile reads a whole file.
func (v *View) ReadFile(path string) ([]byte, error) {
	h, err := v.resolve(path)
	if err != nil {
		return nil, err
	}
	if h.n.isDir {
		return nil, fmt.Errorf("assetfs: %s is a folder", path)
	}
	b, err := readAll(h.layer.src, h.n)
	if err != nil {
		return nil, fmt.Errorf("assetfs: %s: %s: %w", h.layer.Name, path, err)
	}
	return b, nil
}

// ReadDir lists a folder merged across every layer that has it as a folder:
// each child once, as the highest layer holding that child has it.
func (v *View) ReadDir(path string) ([]Info, error) {
	parts, err := Segments(path)
	if err != nil {
		return nil, err
	}
	key := foldParts(parts)
	var out []Info
	seen := map[string]bool{}
	found := false
	for _, l := range v.layers {
		n, ok, err := l.src.lookup(key)
		if err != nil {
			return nil, err
		}
		if !ok || !n.isDir {
			continue
		}
		found = true
		kids, err := l.src.list(n)
		if err != nil {
			return nil, err
		}
		for _, c := range kids {
			k := FoldName(c.name)
			if seen[k] {
				continue
			}
			seen[k] = true
			p := append(append([]string(nil), parts...), c.name)
			out = append(out, Info{Path: DisplayPath(p), Name: c.name, IsDir: c.isDir, Size: c.size, Layer: l})
		}
	}
	if !found {
		return nil, fmt.Errorf("assetfs: %s: no such folder: %w", path, fs.ErrNotExist)
	}
	return out, nil
}

// SkipDir, returned by a Walk callback on a folder, skips its contents in
// that layer.
var SkipDir = errSkipDir

// Walk visits every path the view serves exactly once, as the layer that
// serves it has it: the layers highest first, each in its stored order, a
// folder before its contents.
func (v *View) Walk(fn func(Info) error) error {
	seen := map[string]bool{}
	for _, l := range v.layers {
		err := l.src.walk(func(parts []string, n node) error {
			k := strings.Join(foldParts(parts), "/")
			if seen[k] {
				return nil
			}
			seen[k] = true
			return fn(Info{Path: DisplayPath(parts), Name: n.name, IsDir: n.isDir, Size: n.size, Layer: l})
		})
		if err != nil && !errors.Is(err, errSkipDir) {
			return err
		}
	}
	return nil
}
