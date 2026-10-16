package assetfs

import (
	"fmt"
	"io"
	"os"
	"sort"
	"time"
)

// PackResult is what WritePack did.
type PackResult struct {
	Stats      PackStats
	Verify     VerifyResult
	PackBytes  int64
	WriteTime  time.Duration
	VerifyTime time.Duration
}

// WritePack writes a `.pk3` at out: fill adds the entries, then the pack is
// closed, read back through the reader (VerifyPack: every file by name,
// size and SHA-256) and only then renamed into place, so a failed or
// interrupted run never leaves a pack that looks finished. verify=false
// skips the read-back (the pack is still renamed into place).
func WritePack(out string, policy PackPolicy, workers int, verify bool, fill func(pw *PackWriter) error) (PackResult, error) {
	var res PackResult
	tmp := out + ".partial"
	f, err := os.Create(tmp)
	if err != nil {
		return res, err
	}
	fail := func(err error) (PackResult, error) {
		f.Close()
		os.Remove(tmp)
		return res, err
	}
	start := time.Now()
	pw := NewPackWriter(f, policy, workers, 0)
	ferr := fill(pw)
	st, sums, cerr := pw.Close()
	res.Stats = st
	if ferr != nil {
		return fail(ferr)
	}
	if cerr != nil {
		return fail(cerr)
	}
	if err := f.Sync(); err != nil {
		return fail(err)
	}
	if err := f.Close(); err != nil {
		return fail(err)
	}
	res.WriteTime = time.Since(start)
	if fi, err := os.Stat(tmp); err == nil {
		res.PackBytes = fi.Size()
	}
	if verify {
		start = time.Now()
		v, err := VerifyPack(tmp, sums, st.Dirs, workers)
		res.Verify = v
		res.VerifyTime = time.Since(start)
		if err != nil {
			os.Remove(tmp)
			return res, fmt.Errorf("verifying %s: %w", out, err)
		}
	}
	if err := os.Rename(tmp, out); err != nil {
		os.Remove(tmp)
		return res, err
	}
	return res, nil
}

// Report prints a pack's summary and its per-extension table.
func (r PackResult) Report(w io.Writer) {
	s := r.Stats
	fmt.Fprintf(w, "  files %d, folders %d\n", s.Files, s.Dirs)
	fmt.Fprintf(w, "  stored %d (%d of them because deflate did not shrink them), deflated %d\n", s.Stored, s.StoredFallback, s.Deflated)
	pct := 0.0
	if s.In > 0 {
		pct = 100 * float64(r.PackBytes) / float64(s.In)
	}
	fmt.Fprintf(w, "  file bytes %d, pack %d bytes (%.1f%%), largest deflate ratio %.1f:1 (%s)\n", s.In, r.PackBytes, pct, s.MaxRatio, s.MaxRatioPath)
	fmt.Fprintf(w, "  written in %.1f s\n", r.WriteTime.Seconds())
	if r.Verify.Files > 0 {
		z := "no"
		if r.Verify.Zip64 {
			z = "yes"
		}
		fmt.Fprintf(w, "  verified: %d files, %d bytes byte-identical through the pack reader (SHA-256), %d folders, zip64 end record: %s, in %.1f s\n",
			r.Verify.Files, r.Verify.Bytes, r.Verify.Dirs, z, r.VerifyTime.Seconds())
	}
	var exts []string
	for e := range s.ByExt {
		exts = append(exts, e)
	}
	sort.Slice(exts, func(i, j int) bool { return s.ByExt[exts[i]].In > s.ByExt[exts[j]].In })
	fmt.Fprintf(w, "  %-8s %8s %8s %14s %14s %7s\n", "ext", "files", "stored", "bytes", "packed", "packed%")
	for _, e := range exts {
		x := s.ByExt[e]
		p := 0.0
		if x.In > 0 {
			p = 100 * float64(x.Out) / float64(x.In)
		}
		name := e
		if name == "" {
			name = "(none)"
		}
		fmt.Fprintf(w, "  %-8s %8d %8d %14d %14d %6.1f%%\n", name, x.Files, x.Stored, x.In, x.Out, p)
	}
}
