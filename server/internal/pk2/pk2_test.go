package pk2

import (
	"encoding/binary"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"golang.org/x/crypto/blowfish"
)

// buildSyntheticArchive writes a minimal, unencrypted pk2-shaped file to a
// temp path so tests don't depend on a real (copyrighted) game archive.
func buildSyntheticArchive(t *testing.T) string {
	t.Helper()

	header := make([]byte, headerSize)
	copy(header, []byte("JoyMax File Manager!\x00"))
	// header[0x22] left 0 => not encrypted

	block := make([]byte, blockSize)
	writeEntry := func(i int, entryType byte, name string, offset, size uint32) {
		e := block[i*entrySize : (i+1)*entrySize]
		e[0] = entryType
		copy(e[entryOffName:entryOffName+entryNameLen], name)
		binary.LittleEndian.PutUint32(e[entryOffPosition:], offset)
		binary.LittleEndian.PutUint32(e[entryOffSize:], size)
	}

	fileData := []byte("hello silkroad")
	fileOffset := uint32(headerSize + blockSize)

	writeEntry(0, entryTypeFolder, ".", headerSize, 0)
	writeEntry(1, entryTypeFile, "hello.txt", fileOffset, uint32(len(fileData)))

	path := filepath.Join(t.TempDir(), "test.pk2")
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()

	if _, err := f.Write(header); err != nil {
		t.Fatal(err)
	}
	if _, err := f.Write(block); err != nil {
		t.Fatal(err)
	}
	if _, err := f.Write(fileData); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestOpenAndReadDir(t *testing.T) {
	path := buildSyntheticArchive(t)

	a, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer a.Close()

	entries, err := a.ReadDir()
	if err != nil {
		t.Fatalf("ReadDir: %v", err)
	}
	if len(entries) != 1 {
		t.Fatalf("expected 1 entry, got %d: %+v", len(entries), entries)
	}
	if entries[0].Name != "hello.txt" || entries[0].IsDir {
		t.Fatalf("unexpected entry: %+v", entries[0])
	}
}

func TestReadFile(t *testing.T) {
	path := buildSyntheticArchive(t)

	a, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer a.Close()

	entries, err := a.ReadDir()
	if err != nil {
		t.Fatalf("ReadDir: %v", err)
	}

	data, err := a.ReadFile(entries[0])
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	if string(data) != "hello silkroad" {
		t.Fatalf("unexpected contents: %q", data)
	}
}

// buildFullBlockArchive writes an archive whose root directory fills every
// slot in a single block, to check the reader doesn't overrun the block or
// miscount when there's no empty (type 0) slot to stop at.
func buildFullBlockArchive(t *testing.T) string {
	t.Helper()

	header := make([]byte, headerSize)
	copy(header, []byte("JoyMax File Manager!\x00"))

	writeEntry := func(block []byte, i int, entryType byte, name string, offset, size uint32) {
		e := block[i*entrySize : (i+1)*entrySize]
		e[0] = entryType
		copy(e[entryOffName:entryOffName+entryNameLen], name)
		binary.LittleEndian.PutUint32(e[entryOffPosition:], offset)
		binary.LittleEndian.PutUint32(e[entryOffSize:], size)
	}

	fileOffset := uint32(headerSize + blockSize)

	block := make([]byte, blockSize)
	writeEntry(block, 0, entryTypeFolder, ".", headerSize, 0)
	for i := 1; i < entriesPerBlock; i++ {
		writeEntry(block, i, entryTypeFile, fmt.Sprintf("file%02d.txt", i), fileOffset, 4)
	}

	path := filepath.Join(t.TempDir(), "fullblock.pk2")
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()

	for _, chunk := range [][]byte{header, block, []byte("data")} {
		if _, err := f.Write(chunk); err != nil {
			t.Fatal(err)
		}
	}
	return path
}

func TestReadDirHandlesFullBlock(t *testing.T) {
	path := buildFullBlockArchive(t)

	a, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer a.Close()

	entries, err := a.ReadDir()
	if err != nil {
		t.Fatalf("ReadDir: %v", err)
	}

	// entriesPerBlock-1 files (slot 0 is "." and skipped).
	if len(entries) != entriesPerBlock-1 {
		t.Fatalf("expected %d entries, got %d: %+v", entriesPerBlock-1, len(entries), entries)
	}
}

func TestEffectiveKeyAndDecryptMatchRealArchive(t *testing.T) {
	// Known-answer check derived from a real archive's header checksum
	// blob: Blowfish-ECB-encrypting "Joymax Pak File\x00" (as two 8-byte,
	// word-swapped blocks) with the archive's effective key must reproduce
	// the checksum bytes stored in a real pk2 header. See
	// docs/protocol/PK2_FORMAT.md.
	eff := effectiveKey(defaultKey)
	wantEff := []byte{0x32, 0xce, 0xdd, 0x7c, 0xbc, 0xa8}
	if string(eff) != string(wantEff) {
		t.Fatalf("effectiveKey(%q) = % x, want % x", defaultKey, eff, wantEff)
	}

	c, err := blowfish.NewCipher(eff)
	if err != nil {
		t.Fatal(err)
	}
	plain := []byte("Joymax Pak File\x00")

	enc := make([]byte, len(plain))
	copy(enc, plain)
	encryptECBForTest(c, enc)
	if string(enc) == string(plain) {
		t.Fatal("encryption should have changed the plaintext")
	}
	dec := make([]byte, len(enc))
	copy(dec, enc)
	decryptECB(c, dec)
	if string(dec) != string(plain) {
		t.Fatalf("decrypt(encrypt(plain)) = %q, want %q", dec, plain)
	}

	wantFirst3 := []byte{0xd8, 0xda, 0x30}
	if string(enc[:3]) != string(wantFirst3) {
		t.Fatalf("encrypted checksum bytes = % x, want % x (mismatched against a real archive's header)", enc[:3], wantFirst3)
	}
}

// encryptECBForTest mirrors decryptECB's word-swap convention for the
// encrypt direction, needed only to build the known-answer test above (the
// reader itself is decrypt-only).
func encryptECBForTest(c *blowfish.Cipher, data []byte) {
	var block [8]byte
	for off := 0; off+8 <= len(data); off += 8 {
		block[0], block[1], block[2], block[3] = data[off+3], data[off+2], data[off+1], data[off+0]
		block[4], block[5], block[6], block[7] = data[off+7], data[off+6], data[off+5], data[off+4]
		c.Encrypt(block[:], block[:])
		data[off+0], data[off+1], data[off+2], data[off+3] = block[3], block[2], block[1], block[0]
		data[off+4], data[off+5], data[off+6], data[off+7] = block[7], block[6], block[5], block[4]
	}
}

func TestOpenRejectsBadMagic(t *testing.T) {
	path := filepath.Join(t.TempDir(), "bad.pk2")
	if err := os.WriteFile(path, make([]byte, headerSize), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := Open(path); err == nil {
		t.Fatal("expected error opening file with bad magic, got nil")
	}
}
