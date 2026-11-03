// Package logfile is the server's own rotating log file (round 858, OURS):
// -log-file names it, and once it passes MaxBytes it is renamed to
// <name>.1 (the older ones shifting up to <name>.<Keep>, the oldest
// deleted) and a fresh file is opened. Rotated files are gzipped in the
// background (<name>.1.gz ...) unless Compress is off.
//
// Why the server rotates its own file: the production host (macOS, launchd)
// redirects stdout to a file that launchd holds open, so the file can only be
// rotated by something that can make the writer reopen it -- newsyslog needs
// root to configure and a signal the server would have to handle -- and the
// file had grown to 847 MB. A file the server opens itself rotates with no
// root, no signal and no copy-truncate race, and a log shipper that follows
// the name (Grafana Alloy's loki.source.file) picks up the new file.
package logfile

import (
	"compress/gzip"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync"
)

// File is an io.Writer that rotates by size. Safe for concurrent use.
type File struct {
	Path     string
	MaxBytes int64
	Keep     int
	Compress bool

	mu   sync.Mutex
	f    *os.File
	size int64
	// gz serialises the background compression with the next shift, so a
	// shift never renames a file the compressor is still reading.
	gz sync.Mutex
}

// Open opens (appending to) path. A file already past maxBytes is rotated at
// once. keep is how many rotated files are kept (at least 1).
func Open(path string, maxBytes int64, keep int, compress bool) (*File, error) {
	if keep < 1 {
		keep = 1
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, err
	}
	l := &File{Path: path, MaxBytes: maxBytes, Keep: keep, Compress: compress}
	if err := l.open(); err != nil {
		return nil, err
	}
	if l.MaxBytes > 0 && l.size >= l.MaxBytes {
		l.mu.Lock()
		err := l.rotateLocked()
		l.mu.Unlock()
		if err != nil {
			return nil, err
		}
	}
	return l, nil
}

func (l *File) open() error {
	f, err := os.OpenFile(l.Path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return err
	}
	st, err := f.Stat()
	if err != nil {
		f.Close()
		return err
	}
	l.f, l.size = f, st.Size()
	return nil
}

// Write writes p, rotating first when p would take the file past MaxBytes.
func (l *File) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.f == nil {
		return 0, os.ErrClosed
	}
	if l.MaxBytes > 0 && l.size > 0 && l.size+int64(len(p)) > l.MaxBytes {
		if err := l.rotateLocked(); err != nil {
			// Keep writing to the old file rather than lose the line.
			fmt.Fprintf(os.Stderr, "logfile: rotating %s: %v\n", l.Path, err)
		}
	}
	n, err := l.f.Write(p)
	l.size += int64(n)
	return n, err
}

// Close closes the file and waits for a compression in flight.
func (l *File) Close() error {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.gz.Lock()
	l.gz.Unlock()
	if l.f == nil {
		return nil
	}
	err := l.f.Close()
	l.f = nil
	return err
}

func (l *File) name(i int, gz bool) string {
	n := fmt.Sprintf("%s.%d", l.Path, i)
	if gz {
		n += ".gz"
	}
	return n
}

// rotateLocked shifts <path>.N(.gz) up by one, moves the live file to
// <path>.1 and opens a new one. mu is held.
func (l *File) rotateLocked() error {
	// The last compression is done before anything moves. The lock passes
	// to the new compression, which releases it when it is done.
	l.gz.Lock()
	compressing := false
	defer func() {
		if !compressing {
			l.gz.Unlock()
		}
	}()
	if err := l.f.Close(); err != nil {
		return err
	}
	l.f = nil
	for _, gz := range []bool{true, false} {
		_ = os.Remove(l.name(l.Keep, gz))
	}
	for i := l.Keep - 1; i >= 1; i-- {
		for _, gz := range []bool{true, false} {
			if _, err := os.Stat(l.name(i, gz)); err == nil {
				_ = os.Rename(l.name(i, gz), l.name(i+1, gz))
			}
		}
	}
	rotated := l.name(1, false)
	renameErr := os.Rename(l.Path, rotated)
	if err := l.open(); err != nil {
		return err
	}
	if renameErr != nil {
		return renameErr
	}
	if l.Compress {
		compressing = true
		go func() {
			defer l.gz.Unlock()
			if err := gzipFile(rotated); err != nil {
				fmt.Fprintf(os.Stderr, "logfile: compressing %s: %v\n", rotated, err)
			}
		}()
	}
	return nil
}

func gzipFile(path string) error {
	in, err := os.Open(path)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(path+".gz", os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	zw := gzip.NewWriter(out)
	if _, err := io.Copy(zw, in); err != nil {
		zw.Close()
		out.Close()
		os.Remove(path + ".gz")
		return err
	}
	if err := zw.Close(); err != nil {
		out.Close()
		os.Remove(path + ".gz")
		return err
	}
	if err := out.Close(); err != nil {
		os.Remove(path + ".gz")
		return err
	}
	return os.Remove(path)
}
