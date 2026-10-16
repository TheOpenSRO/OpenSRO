package assetfs

import (
	"bufio"
	"errors"
	"flag"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"unicode/utf16"
)

// TextDataDir is where the client keeps its text tables, in Media.pk2.
const TextDataDir = `server_dep\silkroad\textdata`

// Inputs resolves an exporter's input arguments (round 789: export-refdata
// and export-leveldata read their tables straight through the layered file
// system with -archives, so a pack's added rows reach the server's CSVs).
//
// With a View, an argument is looked up there first -- a bare file name
// under Dir (the text-data folder), a path with separators as a pk2 path --
// then in Fallback (the whole stack, for a file of another base archive,
// such as Data.pk2's navmesh\objectstring.ifo), then on disk, so the
// server-side files an exporter also takes (Quest.sct, SR_GameServer.exe)
// keep working. Without a View every argument is a disk path, as before.
type Inputs struct {
	View     *View
	Fallback *View
	Dir      string
}

func (in *Inputs) vfsPath(name string) (string, bool) {
	if in.View == nil || filepath.IsAbs(name) {
		return "", false
	}
	if !strings.ContainsAny(name, `/\`) && in.Dir != "" {
		return in.Dir + `\` + name, true
	}
	return name, true
}

func (in *Inputs) views() []*View {
	if in.Fallback != nil {
		return []*View{in.View, in.Fallback}
	}
	return []*View{in.View}
}

// ReadFile reads one input.
func (in *Inputs) ReadFile(name string) ([]byte, error) {
	if p, ok := in.vfsPath(name); ok {
		for _, v := range in.views() {
			b, err := v.ReadFile(p)
			if err == nil {
				return b, nil
			}
			if !errors.Is(err, fs.ErrNotExist) && !errors.Is(err, ErrUnsafe) {
				return nil, err
			}
		}
	}
	return os.ReadFile(name)
}

func (in *Inputs) exists(name string) bool {
	if p, ok := in.vfsPath(name); ok {
		for _, v := range in.views() {
			if i, err := v.Stat(p); err == nil && !i.IsDir {
				return true
			}
		}
	}
	st, err := os.Stat(name)
	return err == nil && st.Mode().IsRegular()
}

// Expand replaces each "@<index>" argument (itemdata.txt, skilldataenc.txt,
// characterdata.txt: the client's lists of the table parts it loads) with
// the parts it names that exist, in its order and lower-cased, the way
// deploy/README.md's `order` shell function does. A bare index name
// resolves like any input; the parts resolve beside it (in the same folder
// of the view, or on disk). With a View, `\` in a relative argument becomes
// `/`, so an exporter's filepath.Base sees the file name on every OS.
func (in *Inputs) Expand(args []string) ([]string, error) {
	var out []string
	norm := func(a string) string {
		if in.View != nil && !filepath.IsAbs(a) {
			return strings.ReplaceAll(a, `\`, "/")
		}
		return a
	}
	for _, a := range args {
		if !strings.HasPrefix(a, "@") {
			out = append(out, norm(a))
			continue
		}
		idx := a[1:]
		raw, err := in.ReadFile(idx)
		if err != nil {
			return nil, fmt.Errorf("reading index %s: %w", idx, err)
		}
		dir := ""
		if i := strings.LastIndexAny(idx, `/\`); i >= 0 {
			dir = idx[:i+1]
		}
		for _, name := range IndexNames(raw) {
			p := dir + name
			if in.exists(p) {
				out = append(out, norm(p))
			}
		}
	}
	return out, nil
}

// IndexNames reads a client index file (UTF-16LE with a BOM, or UTF-8):
// one table part a line; blank lines and `//` comments are skipped; names
// are lower-cased.
func IndexNames(raw []byte) []string {
	var text string
	if len(raw) >= 2 && raw[0] == 0xFF && raw[1] == 0xFE {
		u := make([]uint16, 0, len(raw)/2)
		for i := 2; i+1 < len(raw); i += 2 {
			u = append(u, uint16(raw[i])|uint16(raw[i+1])<<8)
		}
		text = string(utf16.Decode(u))
	} else {
		text = strings.TrimPrefix(string(raw), "\xef\xbb\xbf")
	}
	var out []string
	sc := bufio.NewScanner(strings.NewReader(text))
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "//") {
			continue
		}
		out = append(out, strings.ToLower(line))
	}
	return out
}

// InputFlags are the exporters' archive flags.
type InputFlags struct {
	Archives, Source, Custom, Volume, TextData string
	NoCustom                                   bool
}

// Register adds -archives, -source, -custom, -no-custom, -volume and
// -textdata to fs.
func (f *InputFlags) Register(fs *flag.FlagSet) {
	fs.StringVar(&f.Archives, "archives", "", "read the input tables through this folder of archives (custom/, packs, base archives; docs/protocol/asset_packs.md) instead of loose files: a bare name is a file of -textdata, @<index> expands to the parts the index lists")
	fs.StringVar(&f.Source, "source", "mixed", "with -archives: the source mode, pk2, pk3 or mixed")
	fs.StringVar(&f.Custom, "custom", "", "with -archives: the loose overlay folder (default <archives>/custom when it exists)")
	fs.BoolVar(&f.NoCustom, "no-custom", false, "with -archives: no loose overlay folder")
	fs.StringVar(&f.Volume, "volume", "Media", "with -archives: the base archive the inputs are looked up in first (then every layer)")
	fs.StringVar(&f.TextData, "textdata", TextDataDir, "with -archives: the folder a bare input name is in")
}

// Open builds the Inputs the flags describe (plain disk inputs without
// -archives). It opens the folder strictly: a pack that cannot be read, or
// an entry the reader refuses, is an error, not a silently missing row. The
// returned FS (nil without -archives) is the caller's to close.
func (f *InputFlags) Open(logf func(string, ...any)) (*Inputs, *FS, error) {
	if f.Archives == "" {
		return &Inputs{}, nil, nil
	}
	mode, err := ParseMode(f.Source)
	if err != nil {
		return nil, nil, err
	}
	fsys, err := Open(f.Archives, Options{Mode: mode, CustomDir: f.Custom, NoCustom: f.NoCustom, Strict: true, Logf: logf})
	if err != nil {
		return nil, nil, err
	}
	v, err := fsys.In(f.Volume)
	if err != nil {
		fsys.Close()
		return nil, nil, err
	}
	return &Inputs{View: v, Fallback: fsys.View, Dir: f.TextData}, fsys, nil
}
