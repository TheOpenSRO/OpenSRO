// Package pk2 is a read-only reader for the pk2 (JMXVFS) archive container
// format. See docs/protocol/PK2_FORMAT.md for the on-disk layout this
// implements against — a publicly documented community file-container
// format, not anything derived from decompiling a client binary.
//
// This package never writes or re-encrypts pk2 archives; it only opens
// files a caller already has on disk.
package pk2

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"

	"golang.org/x/crypto/blowfish"
)

const (
	headerSize      = 256
	entrySize       = 128
	entriesPerBlock = 20
	blockSize       = entrySize * entriesPerBlock

	entryTypeEmpty  = 0
	entryTypeFolder = 1
	entryTypeFile   = 2
)

// defaultKey is the long-published default Blowfish key used by the pk2
// container format for its directory-table obfuscation. It is a fixed
// constant needed purely to parse the container's own directory layout, not
// a secret protecting any first-party asset bytes (those are stored plain).
// See docs/protocol/PK2_FORMAT.md.
var defaultKey = []byte("169841")

// Entry describes one file or folder within a pk2 archive.
type Entry struct {
	Name   string
	IsDir  bool
	Size   uint32
	offset uint32 // file data offset, or child block offset for folders
}

// Archive is an opened, read-only pk2 file.
type Archive struct {
	f          *os.File
	cipher     *blowfish.Cipher
	encrypted  bool
	rootOffset uint32
}

// Open opens a pk2 archive for reading. The returned Archive must be closed
// by the caller.
func Open(path string) (*Archive, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}

	header := make([]byte, headerSize)
	if _, err := io.ReadFull(f, header); err != nil {
		f.Close()
		return nil, fmt.Errorf("pk2: reading header: %w", err)
	}

	// Magic is a null-padded ASCII string near the start of the header.
	magic := string(bytes.TrimRight(header[0:30], "\x00"))
	if !strings.HasPrefix(magic, "JoyMax File Manager") {
		f.Close()
		return nil, errors.New("pk2: not a pk2 archive (bad magic)")
	}

	encrypted := header[0x22] != 0

	a := &Archive{f: f, encrypted: encrypted, rootOffset: headerSize}
	if encrypted {
		c, err := blowfish.NewCipher(defaultKey)
		if err != nil {
			f.Close()
			return nil, fmt.Errorf("pk2: init cipher: %w", err)
		}
		a.cipher = c
	}
	return a, nil
}

// Close releases the underlying file handle.
func (a *Archive) Close() error {
	return a.f.Close()
}

// ReadDir returns the entries of the root directory. Use ReadDirAt with a
// folder Entry's offset to descend further.
func (a *Archive) ReadDir() ([]Entry, error) {
	return a.readBlockChain(a.rootOffset)
}

// ReadDirAt returns the entries of the folder Entry previously returned by
// ReadDir/ReadDirAt. Calling it on a file Entry is an error.
func (a *Archive) ReadDirAt(dir Entry) ([]Entry, error) {
	if !dir.IsDir {
		return nil, fmt.Errorf("pk2: %q is not a folder", dir.Name)
	}
	return a.readBlockChain(dir.offset)
}

// ReadFile returns the raw contents of a file Entry.
func (a *Archive) ReadFile(file Entry) ([]byte, error) {
	if file.IsDir {
		return nil, fmt.Errorf("pk2: %q is a folder, not a file", file.Name)
	}
	buf := make([]byte, file.Size)
	if _, err := a.f.ReadAt(buf, int64(file.offset)); err != nil && !errors.Is(err, io.EOF) {
		return nil, fmt.Errorf("pk2: reading %q: %w", file.Name, err)
	}
	return buf, nil
}

func (a *Archive) readBlockChain(startOffset uint32) ([]Entry, error) {
	var out []Entry
	offset := startOffset

	for offset != 0 {
		block := make([]byte, blockSize)
		if _, err := a.f.ReadAt(block, int64(offset)); err != nil && !errors.Is(err, io.EOF) {
			return nil, fmt.Errorf("pk2: reading block at %d: %w", offset, err)
		}

		if a.encrypted {
			decryptECB(a.cipher, block)
		}

		next := uint32(0)
		for i := 0; i < entriesPerBlock; i++ {
			raw := block[i*entrySize : (i+1)*entrySize]
			entryType := raw[0]

			switch entryType {
			case entryTypeEmpty:
				continue
			case entryTypeFolder, entryTypeFile:
				name := string(bytes.TrimRight(raw[0x01:0x01+81], "\x00"))
				if name == "." || name == ".." {
					continue
				}
				pos := binary.LittleEndian.Uint32(raw[0x5A:])
				size := binary.LittleEndian.Uint32(raw[0x5E:])
				out = append(out, Entry{
					Name:   name,
					IsDir:  entryType == entryTypeFolder,
					Size:   size,
					offset: pos,
				})
			default:
				// Unknown/terminator entry type; nothing more useful in this slot.
			}
		}
		// Next-block pointer lives in the last entry slot's "next" field in
		// many observed layouts; conservatively treat 0 as end-of-chain.
		_ = next
		break // single-block directories are the common case; chained
		// blocks (>20 entries in one folder) are left as a follow-up once
		// we have real archives to test the multi-block path against.
	}

	return out, nil
}

func decryptECB(c *blowfish.Cipher, data []byte) {
	for off := 0; off+8 <= len(data); off += 8 {
		c.Decrypt(data[off:off+8], data[off:off+8])
	}
}
