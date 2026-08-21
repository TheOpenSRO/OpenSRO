package main

import (
	"encoding/binary"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// buildSyntheticArchive writes a minimal, unencrypted pk2-shaped file
// (never real game data) using the on-disk layout documented in
// docs/protocol/PK2_FORMAT.md -- duplicated here rather than imported
// since server/internal/pk2's own field-offset constants are unexported.
func buildSyntheticArchive(t *testing.T) string {
	t.Helper()

	const (
		headerSize       = 256
		entrySize        = 128
		blockSize        = entrySize * 20
		entryTypeFolder  = 1
		entryTypeFile    = 2
		entryOffName     = 0x01
		entryOffPosition = 0x6A
		entryOffSize     = 0x72
	)

	header := make([]byte, headerSize)
	copy(header, []byte("JoyMax File Manager!\x00"))

	block := make([]byte, blockSize)
	writeEntry := func(i int, entryType byte, name string, offset, size uint32) {
		e := block[i*entrySize : (i+1)*entrySize]
		e[0] = entryType
		copy(e[entryOffName:], name)
		binary.LittleEndian.PutUint32(e[entryOffPosition:], offset)
		binary.LittleEndian.PutUint32(e[entryOffSize:], size)
	}

	fileData := []byte("hello silkroad")
	fileOffset := uint32(headerSize + blockSize)

	writeEntry(0, entryTypeFolder, ".", headerSize, 0)
	writeEntry(1, entryTypeFile, "grass01.ddj", fileOffset, uint32(len(fileData)))

	path := filepath.Join(t.TempDir(), "test.pk2")
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	f.Write(header)
	f.Write(block)
	f.Write(fileData)
	return path
}

func TestListsMatchingFiles(t *testing.T) {
	archivePath := buildSyntheticArchive(t)

	bin := filepath.Join(t.TempDir(), "pk2list")
	build := exec.Command("go", "build", "-o", bin, ".")
	if out, err := build.CombinedOutput(); err != nil {
		t.Fatalf("building pk2list: %v\n%s", err, out)
	}

	out, err := exec.Command(bin, "-pk2", archivePath, "-filter", "grass").CombinedOutput()
	if err != nil {
		t.Fatalf("running pk2list: %v\n%s", err, out)
	}
	if !strings.Contains(string(out), "grass01.ddj") {
		t.Fatalf("expected output to list grass01.ddj, got:\n%s", out)
	}

	outUnfiltered, err := exec.Command(bin, "-pk2", archivePath).CombinedOutput()
	if err != nil {
		t.Fatalf("running pk2list unfiltered: %v\n%s", err, outUnfiltered)
	}
	if !strings.Contains(string(outUnfiltered), "grass01.ddj") {
		t.Fatalf("expected unfiltered output to list grass01.ddj, got:\n%s", outUnfiltered)
	}

	outFiltered, err := exec.Command(bin, "-pk2", archivePath, "-filter", "nomatch").CombinedOutput()
	if err != nil {
		t.Fatalf("running pk2list with no matches: %v\n%s", err, outFiltered)
	}
	if strings.Contains(string(outFiltered), "grass01.ddj") {
		t.Fatalf("expected no match for 'nomatch' filter, got:\n%s", outFiltered)
	}
}
