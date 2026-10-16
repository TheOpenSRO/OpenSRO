// Command pk2topk3 converts a pk2 archive into a `.pk3` (a zip) holding
// every file under the same path, so the output drops in for the original
// (docs/protocol/asset_packs.md; OURS -- retail has only `.pk2`). It runs on
// the operator's own archives and its output is game data: never commit it
// (docs/LEGAL.md).
//
//	pk2topk3 -in /path/to/Data.pk2 -o /path/to/pk3/Data.pk3
//	pk2topk3 -measure -in /path/to/Media.pk2      # deflate ratio by extension, nothing written
//
// What goes in: exactly the entries the pk2 lookup can reach (the first of
// a case-folded name in a folder wins, as in the client; a shadowed
// duplicate is counted and left out), every folder as a folder entry, names
// as UTF-8 (a pk2 name's bytes are Latin-1 code points). Stored or deflated
// per assetfs.DefaultPolicy (-store / -deflate change it). Entries are read
// and compressed on -workers goroutines and written in order with a bounded
// in-flight budget, so memory does not grow with the archive; the zip64
// records appear when the entry count or a size needs them.
//
// What is checked: the pack is read back through the same reader the
// layered file system uses, every file by its name, size and SHA-256
// against the bytes read from the pk2, and nothing else may be in it. Only
// then is it renamed from <out>.partial to <out>.
package main

import (
	"bytes"
	"compress/flate"
	"flag"
	"fmt"
	"io"
	"os"
	"path"
	"sort"
	"strings"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/assetfs"
	"github.com/OpenSRO/OpenSRO/server/internal/pk2"
)

func main() {
	in := flag.String("in", "", "the pk2 archive to convert (required)")
	out := flag.String("o", "", "the .pk3 to write (required unless -measure)")
	workers := flag.Int("workers", 0, "compressing goroutines (0: GOMAXPROCS, at most 8)")
	store := flag.String("store", "", "extra extensions to store uncompressed, comma-separated (e.g. .wav)")
	deflate := flag.String("deflate", "", "extensions to deflate although the policy stores them, comma-separated")
	level := flag.Int("level", flate.DefaultCompression, "deflate level, 1-9")
	noVerify := flag.Bool("no-verify", false, "skip the byte-identical read-back (not recommended)")
	measure := flag.Bool("measure", false, "print the deflate ratio of a sample of each extension and exit")
	sample := flag.Int("sample", 300, "with -measure: files sampled per extension (at most 64 MiB of each)")
	flag.Parse()
	if *in == "" || (*out == "" && !*measure) {
		fmt.Fprintln(os.Stderr, "usage: pk2topk3 -in <archive.pk2> -o <archive.pk3> [-workers n] [-store exts] [-deflate exts] [-level n] [-no-verify]")
		fmt.Fprintln(os.Stderr, "       pk2topk3 -measure -in <archive.pk2> [-sample n]")
		os.Exit(2)
	}
	a, err := pk2.Open(*in)
	if err != nil {
		fmt.Fprintln(os.Stderr, "pk2topk3:", err)
		os.Exit(1)
	}
	defer a.Close()
	if *measure {
		if err := measureRatios(a, *sample, *level); err != nil {
			fmt.Fprintln(os.Stderr, "pk2topk3:", err)
			os.Exit(1)
		}
		return
	}

	shadowed := 0
	if err := a.WalkAll(func(p string, e pk2.Entry, sh bool) error {
		if sh {
			shadowed++
			fmt.Fprintf(os.Stderr, "pk2topk3: %s is shadowed by an earlier entry of the same name; the lookup never reaches it, so it is left out\n", p)
			if e.IsDir {
				return pk2.SkipDir
			}
		}
		return nil
	}); err != nil {
		fmt.Fprintln(os.Stderr, "pk2topk3:", err)
		os.Exit(1)
	}

	policy := assetfs.DefaultPolicy().WithOverrides(*store, *deflate)
	policy.Level = *level
	start := time.Now()
	res, err := assetfs.WritePack(*out, policy, *workers, !*noVerify, func(pw *assetfs.PackWriter) error {
		return a.Walk(func(p string, e pk2.Entry) error {
			name := assetfs.Latin1ToUTF8(strings.ReplaceAll(p, `\`, "/"))
			if e.IsDir {
				return pw.AddDir(name)
			}
			return pw.AddFile(name, int64(e.Size), func() (io.ReadCloser, error) {
				r, err := a.OpenEntry(e)
				if err != nil {
					return nil, err
				}
				return io.NopCloser(r), nil
			})
		})
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, "pk2topk3:", err)
		os.Exit(1)
	}
	fi, _ := os.Stat(*in)
	fmt.Printf("%s -> %s\n", *in, *out)
	fmt.Printf("  pk2 %d bytes; %d shadowed duplicate(s) left out\n", fi.Size(), shadowed)
	res.Report(os.Stdout)
	fmt.Printf("  total %.1f s\n", time.Since(start).Seconds())
}

// measureRatios deflates up to n files (and 64 MiB) of each extension and
// prints packed/unpacked: the measurement assetfs.StoredExtensions is
// chosen from.
func measureRatios(a *pk2.Archive, n, level int) error {
	type st struct {
		files, sampled int
		bytes, in, out int64
	}
	by := map[string]*st{}
	err := a.Walk(func(p string, e pk2.Entry) error {
		if e.IsDir {
			return nil
		}
		ext := strings.ToLower(path.Ext(strings.ReplaceAll(p, `\`, "/")))
		s := by[ext]
		if s == nil {
			s = &st{}
			by[ext] = s
		}
		s.files++
		s.bytes += int64(e.Size)
		if s.sampled >= n || s.in >= 64<<20 || e.Size == 0 {
			return nil
		}
		r, err := a.OpenEntry(e)
		if err != nil {
			return err
		}
		var buf bytes.Buffer
		w, _ := flate.NewWriter(&buf, level)
		k, err := io.Copy(w, r)
		if err != nil {
			return err
		}
		w.Close()
		s.sampled++
		s.in += k
		s.out += int64(buf.Len())
		return nil
	})
	if err != nil {
		return err
	}
	var exts []string
	for e := range by {
		exts = append(exts, e)
	}
	sort.Slice(exts, func(i, j int) bool { return by[exts[i]].bytes > by[exts[j]].bytes })
	fmt.Printf("%-8s %8s %14s %8s %12s %9s\n", "ext", "files", "bytes", "sampled", "sample in", "deflated")
	for _, e := range exts {
		s := by[e]
		r := 0.0
		if s.in > 0 {
			r = 100 * float64(s.out) / float64(s.in)
		}
		name := e
		if name == "" {
			name = "(none)"
		}
		fmt.Printf("%-8s %8d %14d %8d %12d %8.1f%%\n", name, s.files, s.bytes, s.sampled, s.in, r)
	}
	return nil
}
