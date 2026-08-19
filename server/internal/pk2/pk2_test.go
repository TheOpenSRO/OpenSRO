package pk2

import (
	"encoding/binary"
	"fmt"
	"os"
	"path/filepath"
	"testing"
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
		copy(e[0x01:0x01+81], name)
		binary.LittleEndian.PutUint32(e[0x5A:], offset)
		binary.LittleEndian.PutUint32(e[0x5E:], size)
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

// buildMultiBlockArchive writes an archive whose root directory spans two
// chained blocks (entriesPerBlock-1 real file entries in block 1, forcing a
// second block for the last file), to exercise the next-block-pointer path.
func buildMultiBlockArchive(t *testing.T) string {
	t.Helper()

	header := make([]byte, headerSize)
	copy(header, []byte("JoyMax File Manager!\x00"))

	writeEntry := func(block []byte, i int, entryType byte, name string, offset, size uint32) {
		e := block[i*entrySize : (i+1)*entrySize]
		e[0] = entryType
		copy(e[0x01:0x01+81], name)
		binary.LittleEndian.PutUint32(e[0x5A:], offset)
		binary.LittleEndian.PutUint32(e[0x5E:], size)
	}
	writeNextPtr := func(block []byte, next uint64) {
		e := block[(entriesPerBlock-1)*entrySize : entriesPerBlock*entrySize]
		binary.LittleEndian.PutUint64(e[0x62:], next)
	}

	block1Offset := uint32(headerSize)
	block2Offset := block1Offset + blockSize
	fileOffset := block2Offset + blockSize

	block1 := make([]byte, blockSize)
	writeEntry(block1, 0, entryTypeFolder, ".", headerSize, 0)
	// Fill slots 1..18 with files so slot 19 is reserved for the chain
	// pointer (entriesPerBlock=20, so 18 file entries here).
	for i := 1; i < entriesPerBlock-1; i++ {
		writeEntry(block1, i, entryTypeFile, fmt.Sprintf("file%02d.txt", i), fileOffset, 4)
	}
	writeNextPtr(block1, uint64(block2Offset))

	block2 := make([]byte, blockSize)
	writeEntry(block2, 0, entryTypeFile, "last.txt", fileOffset, 4)
	// next pointer left 0 => end of chain

	path := filepath.Join(t.TempDir(), "multiblock.pk2")
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()

	for _, chunk := range [][]byte{header, block1, block2, []byte("data")} {
		if _, err := f.Write(chunk); err != nil {
			t.Fatal(err)
		}
	}
	return path
}

func TestReadDirFollowsBlockChain(t *testing.T) {
	path := buildMultiBlockArchive(t)

	a, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer a.Close()

	entries, err := a.ReadDir()
	if err != nil {
		t.Fatalf("ReadDir: %v", err)
	}

	// 18 files from block 1 + 1 file from block 2 = 19.
	if len(entries) != 19 {
		t.Fatalf("expected 19 entries across both blocks, got %d: %+v", len(entries), entries)
	}

	found := false
	for _, e := range entries {
		if e.Name == "last.txt" {
			found = true
		}
	}
	if !found {
		t.Fatal("expected to find last.txt from the second block in the chain")
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
