package clientpacks

import (
	"crypto/sha256"
	"fmt"
	"io"
	"io/fs"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/assetfs"
)

// Options say where the packs are and where clients fetch them from.
type Options struct {
	// Dir is the folder of required packs (-client-packs). Only the folder
	// itself is read, as the readers read a pack folder (rule 1).
	Dir string
	// BaseURL, when set, is where every pack is fetched from: BaseURL + "/"
	// + its name (-client-packs-url; a CDN, a GitHub release's download
	// path).
	BaseURL string
	// HTTPPort is this server's own listener's port (0: none).
	HTTPPort uint16
	// LocalExtras lets clients keep their own packs and custom/ too.
	LocalExtras bool
	// Limits for the entry checks (nil: assetfs.DefaultLimits).
	Limits *assetfs.Limits
	// Logf gets one line per pack checked (nil: silent).
	Logf func(format string, args ...any)
}

// File is a required pack as this server holds it.
type File struct {
	Pack
	Path    string    // the file, symbolic links resolved
	ModTime time.Time // when it was hashed: the listener refuses a file that changed since
	Entries int       // files inside it
}

// Built is what Build found: the manifest and the files behind it.
type Built struct {
	Manifest Manifest
	Files    []File // in the manifest's order
}

// ByName is the file serving `name` (exactly as the manifest spells it).
func (b *Built) ByName(name string) (File, bool) {
	for _, f := range b.Files {
		if f.Name == name {
			return f, true
		}
	}
	return File{}, false
}

// Build checks every pack in opt.Dir and returns the manifest naming them.
// It fails -- the server should not start -- on anything a client would
// refuse or that would let a client end up with other content than the
// server's: a file in the folder that is not a .pk3/.zip pack, a name that
// is unsafe or a base archive's, a pack the readers would not open whole
// (any entry refused by rule 6, a bad CRC, a lying header), more than
// MaxPacks packs or bytes over the caps, a pack that changed while it was
// being hashed. Folders, and files whose names start with a dot, are
// skipped (logged).
func Build(opt Options) (*Built, error) {
	logf := opt.Logf
	if logf == nil {
		logf = func(string, ...any) {}
	}
	base := strings.TrimRight(opt.BaseURL, "/")
	if base != "" {
		if why := ValidURL(base + "/x.pk3"); why != "" {
			return nil, fmt.Errorf("clientpacks: -client-packs-url %q: %s", opt.BaseURL, why)
		}
		if u, _ := url.Parse(base); u != nil && u.RawQuery != "" {
			return nil, fmt.Errorf("clientpacks: -client-packs-url %q: a base URL has no query (the pack's name is appended to it)", opt.BaseURL)
		}
	}
	if base == "" && opt.HTTPPort == 0 {
		return nil, fmt.Errorf("clientpacks: no -client-packs-url and no listener: clients would have nowhere to fetch the packs from")
	}
	ents, err := os.ReadDir(opt.Dir)
	if err != nil {
		return nil, fmt.Errorf("clientpacks: %w", err)
	}
	var names []string
	for _, e := range ents {
		n := e.Name()
		if strings.HasPrefix(n, ".") {
			logf("clientpacks: %s: a hidden file -- skipped", n)
			continue
		}
		p := filepath.Join(opt.Dir, n)
		st, err := os.Stat(p) // follows a symbolic link: an archive file may be one (rule 1)
		if err != nil {
			return nil, fmt.Errorf("clientpacks: %s: %w", n, err)
		}
		if st.IsDir() {
			logf("clientpacks: %s: a folder -- skipped (only the folder itself is read)", n)
			continue
		}
		if !st.Mode().IsRegular() {
			return nil, fmt.Errorf("clientpacks: %s: not a regular file", n)
		}
		if strings.EqualFold(filepath.Ext(n), ".pk2") {
			return nil, fmt.Errorf("clientpacks: %s: a server pack is a .pk3 or .zip (convert it: pk2topk3 -in %s -o <name>.pk3)", n, n)
		}
		if why := ValidName(n); why != "" {
			return nil, fmt.Errorf("clientpacks: %s: %s", n, why)
		}
		names = append(names, n)
	}
	if len(names) > MaxPacks {
		return nil, fmt.Errorf("clientpacks: %d packs in %s, at most %d", len(names), opt.Dir, MaxPacks)
	}
	seen := map[string]string{}
	for _, n := range names {
		if other, dup := seen[strings.ToLower(n)]; dup {
			return nil, fmt.Errorf("clientpacks: %s and %s differ only in case (a client's disk may not tell them apart)", other, n)
		}
		seen[strings.ToLower(n)] = n
	}
	// Rule 2's order, lowest first: the client layers them in this order,
	// so the server's folder and a client agree on which pack wins.
	assetfs.SortCascade(names)
	b := &Built{Manifest: Manifest{Required: true, LocalExtras: opt.LocalExtras, HTTPPort: opt.HTTPPort}}
	var total int64
	for _, n := range names {
		f, err := checkPack(filepath.Join(opt.Dir, n), opt.Limits)
		if err != nil {
			return nil, fmt.Errorf("clientpacks: %s: %w", n, err)
		}
		if base != "" {
			f.URL = base + "/" + n
		}
		total += f.Size
		if total > MaxTotal {
			return nil, fmt.Errorf("clientpacks: the packs total more than %d bytes", MaxTotal)
		}
		logf("clientpacks: %s: %d bytes, %d files, sha256 %s", n, f.Size, f.Entries, f.SHA256Hex())
		b.Files = append(b.Files, f)
		b.Manifest.Packs = append(b.Manifest.Packs, f.Pack)
	}
	if err := b.Manifest.Check(); err != nil {
		return nil, err
	}
	return b, nil
}

// checkPack opens one pack as the readers do, reads every entry back (each
// checked against its CRC-32 and declared size by the reader), and hashes
// the file. The file must not change while this runs.
func checkPack(path string, lim *assetfs.Limits) (File, error) {
	real, err := filepath.EvalSymlinks(path)
	if err != nil {
		return File{}, err
	}
	before, err := os.Stat(real)
	if err != nil {
		return File{}, err
	}
	if before.Size() < 1 || before.Size() > MaxPackSize {
		return File{}, fmt.Errorf("%d bytes, want 1-%d", before.Size(), MaxPackSize)
	}
	a, err := assetfs.OpenArchive(real, lim)
	if err != nil {
		return File{}, fmt.Errorf("the readers do not open it: %w", err)
	}
	defer a.Close()
	l := a.Layers()[0]
	if len(l.Rejected) > 0 {
		return File{}, fmt.Errorf("the readers refuse %d entr(ies), first %s: a client would load less than the server names", len(l.Rejected), l.Rejected[0])
	}
	entries := 0
	err = a.Walk(func(i assetfs.Info) error {
		if i.IsDir {
			return nil
		}
		rc, _, err := a.Open(i.Path)
		if err != nil {
			return fmt.Errorf("entry %s: %w", i.Path, err)
		}
		defer rc.Close()
		n, err := io.Copy(io.Discard, rc)
		if err != nil {
			return fmt.Errorf("entry %s: %w", i.Path, err)
		}
		if n != i.Size {
			return fmt.Errorf("entry %s: %d bytes read, %d declared", i.Path, n, i.Size)
		}
		entries++
		return nil
	})
	if err != nil {
		return File{}, err
	}
	fh, err := os.Open(real)
	if err != nil {
		return File{}, err
	}
	defer fh.Close()
	h := sha256.New()
	n, err := io.Copy(h, fh)
	if err != nil {
		return File{}, err
	}
	after, err := os.Stat(real)
	if err != nil {
		return File{}, err
	}
	if n != before.Size() || !sameFile(before, after) {
		return File{}, fmt.Errorf("the file changed while it was checked -- try again")
	}
	f := File{Path: real, ModTime: after.ModTime(), Entries: entries}
	f.Name = filepath.Base(path)
	f.Size = n
	copy(f.SHA256[:], h.Sum(nil))
	return f, nil
}

func sameFile(a, b fs.FileInfo) bool {
	return a.Size() == b.Size() && a.ModTime().Equal(b.ModTime())
}
