package pk2

import (
	"encoding/binary"
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

func TestOpenRejectsBadMagic(t *testing.T) {
	path := filepath.Join(t.TempDir(), "bad.pk2")
	if err := os.WriteFile(path, make([]byte, headerSize), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := Open(path); err == nil {
		t.Fatal("expected error opening file with bad magic, got nil")
	}
}
