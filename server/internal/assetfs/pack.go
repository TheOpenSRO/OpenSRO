package assetfs

import (
	"archive/zip"
	"bytes"
	"compress/flate"
	"crypto/sha256"
	"errors"
	"fmt"
	"hash/crc32"
	"io"
	"os"
	"path"
	"runtime"
	"strings"
	"sync"
	"unicode/utf8"
)

// The pack writer behind cmd/pk2topk3 and cmd/pk3pack (OURS). Entries are
// read and compressed on several goroutines and written in the order they
// were added, so memory is bounded by the in-flight budget, not by the
// archive.

// StoredExtensions are written without compression. The three retail ones
// are MEASURED (round 789, deflate level 6 over up to 300 files of each
// extension in the five retail archives; docs/protocol/asset_packs.md,
// "Store or deflate"): .ogg deflates to 99.4%, .rar to 98.6%, .png to
// 90.3%. The rest are formats that are compressed by construction (INFERRED
// from the formats; none is in the retail archives). .ddj is stored too,
// as the plan decided (docs/TODO.md, the user 2026-10-01), although it
// deflates to 26-79% (MEASURED): a game reads textures far more often than
// it installs them. MEASURED at the round's merge (pack_bench, 20,000 Data
// reads, native): 2,636 ms with .ddj deflated, 2,076 ms stored, 241 ms from
// Data.pk2 -- storing .ddj saves ~21% of the read time for 0.63 GB more on
// Data.pk3; the rest of the gap to .pk2 (which is not compressed at all) is
// the inflate of the other deflated types. `-deflate .ddj` trades the other
// way. .wav (75%) is deflated.
var StoredExtensions = []string{".ddj", ".ogg", ".rar", ".png", ".jpg", ".jpeg", ".mp3", ".zip", ".pk3", ".7z", ".gz", ".webp"}

// PackPolicy decides store or deflate per entry.
type PackPolicy struct {
	Store map[string]bool // lower-cased extensions, with the dot
	Level int             // compress/flate level
}

// DefaultPolicy stores StoredExtensions and deflates the rest at the
// default level.
func DefaultPolicy() PackPolicy {
	p := PackPolicy{Store: map[string]bool{}, Level: flate.DefaultCompression}
	for _, e := range StoredExtensions {
		p.Store[e] = true
	}
	return p
}

// WithOverrides returns a copy of p that also stores the extensions in
// store and deflates those in deflate (comma-separated, with or without
// the dot), for an operator's -store / -deflate flags.
func (p PackPolicy) WithOverrides(store, deflate string) PackPolicy {
	q := PackPolicy{Store: map[string]bool{}, Level: p.Level}
	for e, v := range p.Store {
		q.Store[e] = v
	}
	norm := func(e string) string {
		e = strings.ToLower(strings.TrimSpace(e))
		if e != "" && !strings.HasPrefix(e, ".") {
			e = "." + e
		}
		return e
	}
	for _, e := range strings.Split(store, ",") {
		if e = norm(e); e != "" {
			q.Store[e] = true
		}
	}
	for _, e := range strings.Split(deflate, ",") {
		if e = norm(e); e != "" {
			delete(q.Store, e)
		}
	}
	return q
}

// Stores reports whether the policy stores name by its extension. An entry
// that deflate does not make smaller is stored as well (PackWriter does
// that per entry).
func (p PackPolicy) Stores(name string) bool {
	return p.Store[strings.ToLower(path.Ext(strings.ReplaceAll(name, `\`, "/")))]
}

// PackStats sums up a written pack.
type PackStats struct {
	Files, Dirs      int
	Stored, Deflated int
	// StoredFallback counts entries the policy would deflate but deflate did
	// not shrink, so they were stored.
	StoredFallback int
	In, Out        int64 // file bytes, and their packed bytes
	MaxRatio       float64
	MaxRatioPath   string
	// ByExt breaks the files down by lower-cased extension.
	ByExt map[string]*ExtStats
}

// ExtStats is one extension's share of a pack.
type ExtStats struct {
	Files, Stored int
	In, Out       int64
}

// EntrySum is a written file's size and SHA-256, for VerifyPack.
type EntrySum struct {
	Name string // the zip entry name
	Size int64
	Sum  [32]byte
}

type packJob struct {
	name   string
	isDir  bool
	size   int64
	open   func() (io.ReadCloser, error)
	done   chan struct{}
	err    error
	method uint16
	crc    uint32
	sum    [32]byte
	data   []byte
	charge int64
}

// PackWriter writes a `.pk3`.
type PackWriter struct {
	zw      *zip.Writer
	policy  PackPolicy
	maxSize int64
	jobs    chan *packJob
	order   chan *packJob
	wg      sync.WaitGroup
	wdone   chan struct{}
	budget  *budget
	stats   PackStats
	sums    []EntrySum
	err     error
	names   map[string]string
	flPool  sync.Pool
}

// NewPackWriter starts a writer over w with workers compressing goroutines
// (0: GOMAXPROCS, at most 8) and at most inFlight file bytes held at once
// (0: 128 MiB).
func NewPackWriter(w io.Writer, policy PackPolicy, workers int, inFlight int64) *PackWriter {
	if workers <= 0 {
		workers = min(runtime.GOMAXPROCS(0), 8)
	}
	if inFlight <= 0 {
		inFlight = 128 << 20
	}
	pw := &PackWriter{
		zw:      zip.NewWriter(w),
		policy:  policy,
		maxSize: DefaultLimits.MaxEntrySize,
		jobs:    make(chan *packJob, workers*4),
		order:   make(chan *packJob, 4096),
		wdone:   make(chan struct{}),
		budget:  newBudget(inFlight),
		names:   map[string]string{},
	}
	for i := 0; i < workers; i++ {
		pw.wg.Add(1)
		go pw.worker()
	}
	go pw.writer()
	return pw
}

// AddDir adds a folder entry (name without the trailing separator).
func (pw *PackWriter) AddDir(name string) error {
	name = strings.TrimSuffix(strings.ReplaceAll(name, `\`, "/"), "/") + "/"
	if err := pw.claim(name); err != nil {
		return err
	}
	j := &packJob{name: name, isDir: true, done: make(chan struct{})}
	close(j.done)
	pw.order <- j
	return nil
}

// AddFile queues a file of size bytes; open is called on a worker.
func (pw *PackWriter) AddFile(name string, size int64, open func() (io.ReadCloser, error)) error {
	name = strings.ReplaceAll(name, `\`, "/")
	if err := pw.claim(name); err != nil {
		return err
	}
	if size > pw.maxSize {
		return fmt.Errorf("assetfs: %s: %d bytes, over the %d-byte entry cap a reader enforces", name, size, pw.maxSize)
	}
	j := &packJob{name: name, size: size, open: open, done: make(chan struct{})}
	j.charge = pw.budget.acquire(size)
	pw.order <- j
	pw.jobs <- j
	return nil
}

// claim checks a name against the reader's rules and against the names
// already added (folded), so the pack a writer makes is one every reader
// opens without refusing an entry.
func (pw *PackWriter) claim(name string) error {
	if !utf8.ValidString(name) {
		return fmt.Errorf("assetfs: %q is not UTF-8", name)
	}
	parts, _, err := CheckEntryName(name)
	if err != nil {
		return err
	}
	k := strings.Join(foldParts(parts), "/")
	if prev, dup := pw.names[k]; dup {
		return fmt.Errorf("assetfs: %q and %q are the same path to a reader (case is ignored)", prev, name)
	}
	pw.names[k] = name
	return nil
}

func (pw *PackWriter) worker() {
	defer pw.wg.Done()
	for j := range pw.jobs {
		j.err = pw.compress(j)
		close(j.done)
	}
}

func (pw *PackWriter) compress(j *packJob) error {
	rc, err := j.open()
	if err != nil {
		return err
	}
	raw := make([]byte, j.size)
	_, err = io.ReadFull(rc, raw)
	rc.Close()
	if err != nil {
		return fmt.Errorf("reading %s: %w", j.name, err)
	}
	j.crc = crc32.ChecksumIEEE(raw)
	j.sum = sha256.Sum256(raw)
	j.method, j.data = zip.Store, raw
	if j.size == 0 || pw.policy.Stores(j.name) {
		return nil
	}
	var buf bytes.Buffer
	buf.Grow(len(raw) / 2)
	fw, _ := pw.flPool.Get().(*flate.Writer)
	if fw == nil {
		fw, err = flate.NewWriter(&buf, pw.policy.Level)
		if err != nil {
			return err
		}
	} else {
		fw.Reset(&buf)
	}
	fw.Write(raw)
	fw.Close()
	pw.flPool.Put(fw)
	if int64(buf.Len()) < j.size {
		j.method, j.data = zip.Deflate, buf.Bytes()
	} else {
		j.method = 0xFFFF // marks "stored: deflate did not shrink it"
	}
	return nil
}

func (pw *PackWriter) writer() {
	defer close(pw.wdone)
	for j := range pw.order {
		<-j.done
		if pw.err == nil {
			pw.err = pw.write(j)
		}
		j.data = nil
		pw.budget.release(j.charge)
	}
}

func (pw *PackWriter) write(j *packJob) error {
	if j.err != nil {
		return j.err
	}
	fh := &zip.FileHeader{Name: j.name, ModifiedDate: 0x21} // 1980-01-01: the output does not depend on when it was made
	for i := 0; i < len(j.name); i++ {
		if j.name[i] >= 0x80 {
			fh.Flags |= 0x800 // the name is UTF-8
			break
		}
	}
	if j.isDir {
		fh.Method = zip.Store
		_, err := pw.zw.CreateRaw(fh)
		pw.stats.Dirs++
		return err
	}
	fallback := j.method == 0xFFFF
	if fallback {
		j.method = zip.Store
		pw.stats.StoredFallback++
	}
	fh.Method = j.method
	fh.CRC32 = j.crc
	fh.UncompressedSize64 = uint64(j.size)
	fh.CompressedSize64 = uint64(len(j.data))
	w, err := pw.zw.CreateRaw(fh)
	if err != nil {
		return err
	}
	if _, err := w.Write(j.data); err != nil {
		return err
	}
	pw.stats.Files++
	if j.method == zip.Store {
		pw.stats.Stored++
	} else {
		pw.stats.Deflated++
	}
	pw.stats.In += j.size
	pw.stats.Out += int64(len(j.data))
	ext := strings.ToLower(path.Ext(j.name))
	if pw.stats.ByExt == nil {
		pw.stats.ByExt = map[string]*ExtStats{}
	}
	es := pw.stats.ByExt[ext]
	if es == nil {
		es = &ExtStats{}
		pw.stats.ByExt[ext] = es
	}
	es.Files++
	es.In += j.size
	es.Out += int64(len(j.data))
	if j.method == zip.Store {
		es.Stored++
	}
	if len(j.data) > 0 {
		if r := float64(j.size) / float64(len(j.data)); r > pw.stats.MaxRatio {
			pw.stats.MaxRatio, pw.stats.MaxRatioPath = r, j.name
		}
	}
	pw.sums = append(pw.sums, EntrySum{Name: j.name, Size: j.size, Sum: j.sum})
	return nil
}

// Close finishes the pack (the central directory, zip64 records when the
// pack needs them) and returns its statistics and every file's SHA-256.
func (pw *PackWriter) Close() (PackStats, []EntrySum, error) {
	close(pw.jobs)
	pw.wg.Wait()
	close(pw.order)
	<-pw.wdone
	if pw.err != nil {
		return pw.stats, nil, pw.err
	}
	if err := pw.zw.Close(); err != nil {
		return pw.stats, nil, err
	}
	return pw.stats, pw.sums, nil
}

// budget bounds the file bytes held by queued jobs.
type budget struct {
	mu   sync.Mutex
	cond *sync.Cond
	max  int64
	used int64
}

func newBudget(max int64) *budget {
	b := &budget{max: max}
	b.cond = sync.NewCond(&b.mu)
	return b
}

// acquire waits for n bytes (an entry larger than the whole budget waits for
// all of it) and returns what it charged.
func (b *budget) acquire(n int64) int64 {
	n = min(n, b.max)
	b.mu.Lock()
	for b.used+n > b.max {
		b.cond.Wait()
	}
	b.used += n
	b.mu.Unlock()
	return n
}

func (b *budget) release(n int64) {
	b.mu.Lock()
	b.used -= n
	b.mu.Unlock()
	b.cond.Broadcast()
}

// VerifyResult is what VerifyPack checked.
type VerifyResult struct {
	Files, Dirs int
	Bytes       int64
	Zip64       bool // the pack carries a zip64 end-of-central-directory record
}

// VerifyPack reopens a written pack through the same reader the layered
// file system uses and checks that every file in want resolves by its name,
// has its size and SHA-256, and that the pack holds nothing else and refuses
// no entry. workers reads run at once (0: GOMAXPROCS, at most 8).
func VerifyPack(packPath string, want []EntrySum, wantDirs int, workers int) (VerifyResult, error) {
	var res VerifyResult
	f, err := openOne(packPath, nil, false) // a zip whatever its name (<out>.partial)
	if err != nil {
		return res, err
	}
	defer f.Close()
	l := f.Layers()[0]
	if len(l.Rejected) > 0 {
		return res, fmt.Errorf("the reader refuses %d entries, first %s", len(l.Rejected), l.Rejected[0])
	}
	if z, err := hasZip64EOCD(packPath); err == nil {
		res.Zip64 = z
	}
	if err := f.Walk(func(i Info) error {
		if i.IsDir {
			res.Dirs++
		} else {
			res.Files++
		}
		return nil
	}); err != nil {
		return res, err
	}
	if res.Files != len(want) {
		return res, fmt.Errorf("the pack holds %d files, %d were written", res.Files, len(want))
	}
	if wantDirs >= 0 && res.Dirs < wantDirs {
		return res, fmt.Errorf("the pack holds %d folders, %d were written", res.Dirs, wantDirs)
	}
	if workers <= 0 {
		workers = min(runtime.GOMAXPROCS(0), 8)
	}
	ch := make(chan EntrySum)
	var mu sync.Mutex
	var firstErr error
	var wg sync.WaitGroup
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for e := range ch {
				err := verifyOne(f.View, e)
				mu.Lock()
				if err != nil && firstErr == nil {
					firstErr = err
				}
				if err == nil {
					res.Bytes += e.Size
				}
				mu.Unlock()
			}
		}()
	}
	for _, e := range want {
		ch <- e
	}
	close(ch)
	wg.Wait()
	return res, firstErr
}

func verifyOne(v *View, e EntrySum) error {
	rc, info, err := v.Open(e.Name)
	if err != nil {
		return err
	}
	defer rc.Close()
	if info.Path != DisplayPath(strings.FieldsFunc(e.Name, isSep)) {
		return fmt.Errorf("%s resolves to %s", e.Name, info.Path)
	}
	h := sha256.New()
	n, err := io.Copy(h, rc)
	if err != nil {
		return fmt.Errorf("%s: %w", e.Name, err)
	}
	if n != e.Size {
		return fmt.Errorf("%s: %d bytes back, %d written", e.Name, n, e.Size)
	}
	var got [32]byte
	copy(got[:], h.Sum(nil))
	if got != e.Sum {
		return fmt.Errorf("%s: the bytes differ (SHA-256)", e.Name)
	}
	return nil
}

var errNoEOCD = errors.New("no end-of-central-directory record")

// hasZip64EOCD reports whether a zip ends with a zip64 end-of-central-
// directory locator (the record that sits 20 bytes before the classic end
// record when the entry count or an offset overflows 16/32 bits).
func hasZip64EOCD(path string) (bool, error) {
	f, err := os.Open(path)
	if err != nil {
		return false, err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return false, err
	}
	n := min(st.Size(), 22+0xFFFF+20)
	tail := make([]byte, n)
	if _, err := f.ReadAt(tail, st.Size()-n); err != nil {
		return false, err
	}
	i := bytes.LastIndex(tail, []byte("PK\x05\x06"))
	if i < 0 {
		return false, errNoEOCD
	}
	return i >= 20 && bytes.Equal(tail[i-20:i-16], []byte("PK\x06\x07")), nil
}
