// Command pk3pack builds an asset pack (`.pk3`, a zip) from a folder whose
// files sit at their pk2 paths, for operators and modders
// (docs/protocol/asset_packs.md; OURS):
//
//	pk3pack -dir mypack/ -o z_mypack.pk3
//
// mypack/prim/mtrl/foo.ddj becomes the entry prim/mtrl/foo.ddj, which
// overrides (or adds) Prim\Mtrl\foo.ddj for every reader once the pack sits
// beside the archives. The store/deflate policy is pk2topk3's. The same
// rules a reader applies are checked while building, so the pack a builder
// makes is one no reader refuses an entry of: no symbolic links, no name a
// reader calls unsafe, no two paths that differ only in case, no file over
// the reader's size cap. The pack is read back and compared byte for byte
// (SHA-256) before it is renamed into place.
package main

import (
	"compress/flate"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"time"
	"unicode/utf8"

	"github.com/OpenSRO/OpenSRO/server/internal/assetfs"
)

func main() {
	dir := flag.String("dir", "", "the folder to pack; its files are at their pk2 paths (required)")
	out := flag.String("o", "", "the .pk3 to write (required)")
	workers := flag.Int("workers", 0, "compressing goroutines (0: GOMAXPROCS, at most 8)")
	store := flag.String("store", "", "extra extensions to store uncompressed, comma-separated")
	deflate := flag.String("deflate", "", "extensions to deflate although the policy stores them")
	level := flag.Int("level", flate.DefaultCompression, "deflate level, 1-9")
	flag.Parse()
	if *dir == "" || *out == "" {
		fmt.Fprintln(os.Stderr, "usage: pk3pack -dir <folder> -o <pack.pk3> [-workers n] [-store exts] [-deflate exts] [-level n]")
		os.Exit(2)
	}
	if err := run(*dir, *out, *workers, *store, *deflate, *level); err != nil {
		fmt.Fprintln(os.Stderr, "pk3pack:", err)
		os.Exit(1)
	}
}

func run(dir, out string, workers int, store, deflate string, level int) error {
	st, err := os.Stat(dir)
	if err != nil {
		return err
	}
	if !st.IsDir() {
		return fmt.Errorf("%s is not a folder", dir)
	}
	absOut, _ := filepath.Abs(out)
	policy := assetfs.DefaultPolicy().WithOverrides(store, deflate)
	policy.Level = level
	start := time.Now()
	res, err := assetfs.WritePack(out, policy, workers, true, func(pw *assetfs.PackWriter) error {
		return filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if p == dir {
				return nil
			}
			if abs, _ := filepath.Abs(p); abs == absOut || abs == absOut+".partial" {
				return nil // the pack being written inside the folder
			}
			rel, _ := filepath.Rel(dir, p)
			name := filepath.ToSlash(rel)
			if !utf8.ValidString(name) {
				return fmt.Errorf("%s: the name is not UTF-8", p)
			}
			if d.Type()&fs.ModeSymlink != 0 {
				return fmt.Errorf("%s is a symbolic link; a pack holds files only", p)
			}
			if d.IsDir() {
				return pw.AddDir(name)
			}
			if !d.Type().IsRegular() {
				return fmt.Errorf("%s is not a regular file", p)
			}
			info, err := d.Info()
			if err != nil {
				return err
			}
			return pw.AddFile(name, info.Size(), func() (io.ReadCloser, error) { return os.Open(p) })
		})
	})
	if err != nil {
		return err
	}
	fmt.Printf("%s -> %s\n", dir, out)
	res.Report(os.Stdout)
	fmt.Printf("  total %.1f s\n", time.Since(start).Seconds())
	return nil
}
