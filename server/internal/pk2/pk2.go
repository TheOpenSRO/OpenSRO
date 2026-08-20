// Package pk2 is a read-only reader for the pk2 (JMXVFS) archive container
// format. See docs/protocol/PK2_FORMAT.md for the on-disk layout this
// implements against — the layout and obfuscation scheme were verified
// empirically (byte-level, black-box) against a real archive after the
// previously-documented community layout turned out not to match; no
// decompiler output is stored in this repo, only the resulting facts about
// the container format.
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

	// Field offsets within a 128-byte directory entry. See
	// docs/protocol/PK2_FORMAT.md for how these were derived.
	entryOffName     = 0x01
	entryNameLen     = 89
	entryOffPosition = 0x6A
	entryOffSize     = 0x72
)

// defaultKey is the long-published default Blowfish key used by the pk2
// container format for its directory-table obfuscation. It is a fixed
// constant needed purely to parse the container's own directory layout, not
// a secret protecting any first-party asset bytes (those are stored plain).
// See docs/protocol/PK2_FORMAT.md.
var defaultKey = []byte("169841")

// keyXorTable is a fixed, format-constant byte table the reference client
// XORs against the raw key string before running it through the standard
// Blowfish key schedule. Only the bytes up to the key's length are ever
// used; the table is zero beyond what's shown here (verified against a real
// archive), so a longer key would just pick up no-op XOR bytes past this
// point. See docs/protocol/PK2_FORMAT.md.
var keyXorTable = []byte{0x03, 0xf8, 0xe4, 0x44, 0x88, 0x99, 0x3f, 0x64, 0xfe, 0x35}

func effectiveKey(key []byte) []byte {
	eff := make([]byte, len(key))
	for i := range key {
		var x byte
		if i < len(keyXorTable) {
			x = keyXorTable[i]
		}
		eff[i] = key[i] ^ x
	}
	return eff
}

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
		c, err := blowfish.NewCipher(effectiveKey(defaultKey))
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

// readBlockChain reads one directory block (entriesPerBlock entries). No
// "next block" chain-continuation mechanism was found empirically for
// folders with more than entriesPerBlock entries — see
// docs/protocol/PK2_FORMAT.md — so this reads exactly one block per
// directory. If a real archive turns out to need more, this is the place to
// add it, with a cycle/bound guard so a wrong guess can't hang again like
// the previous (incorrect) implementation did.
func (a *Archive) readBlockChain(offset uint32) ([]Entry, error) {
	var out []Entry

	block := make([]byte, blockSize)
	if _, err := a.f.ReadAt(block, int64(offset)); err != nil && !errors.Is(err, io.EOF) {
		return nil, fmt.Errorf("pk2: reading block at %d: %w", offset, err)
	}

	if a.encrypted {
		decryptECB(a.cipher, block)
	}

	for i := 0; i < entriesPerBlock; i++ {
		raw := block[i*entrySize : (i+1)*entrySize]
		entryType := raw[0]

		switch entryType {
		case entryTypeFolder, entryTypeFile:
			name := nullTerminated(raw[entryOffName : entryOffName+entryNameLen])
			if name != "." && name != ".." {
				pos := binary.LittleEndian.Uint32(raw[entryOffPosition:])
				size := binary.LittleEndian.Uint32(raw[entryOffSize:])
				out = append(out, Entry{
					Name:   name,
					IsDir:  entryType == entryTypeFolder,
					Size:   size,
					offset: pos,
				})
			}
		}
	}

	return out, nil
}

// decryptECB decrypts data in place, 8 bytes at a time. The reference
// client's Blowfish usage here isn't quite textbook ECB: each 4-byte half of
// the 8-byte block is byte-order-reversed before being handed to a standard
// (big-endian) Blowfish block decrypt, and reversed back on the way out —
// equivalent to the client treating each half as a little-endian, rather
// than big-endian, 32-bit word. Verified against a real archive's directory
// table. See docs/protocol/PK2_FORMAT.md.
// nullTerminated returns the bytes up to (not including) the first NUL, as
// a string. Reused directory-entry slots can carry stale bytes after a
// still-valid NUL terminator (leftover from whatever longer name previously
// occupied that slot), so trimming only trailing NULs isn't enough.
func nullTerminated(b []byte) string {
	if i := bytes.IndexByte(b, 0); i >= 0 {
		b = b[:i]
	}
	return string(b)
}

func decryptECB(c *blowfish.Cipher, data []byte) {
	var block [8]byte
	for off := 0; off+8 <= len(data); off += 8 {
		block[0], block[1], block[2], block[3] = data[off+3], data[off+2], data[off+1], data[off+0]
		block[4], block[5], block[6], block[7] = data[off+7], data[off+6], data[off+5], data[off+4]
		c.Decrypt(block[:], block[:])
		data[off+0], data[off+1], data[off+2], data[off+3] = block[3], block[2], block[1], block[0]
		data[off+4], data[off+5], data[off+6], data[off+7] = block[7], block[6], block[5], block[4]
	}
}
