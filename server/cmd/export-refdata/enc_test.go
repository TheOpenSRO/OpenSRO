package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// encrypt is encDecrypt's inverse over synthetic keys (no real key table is
// in the repo: they are the player's executable's).
func encrypt(plain []byte, k *encKeys) []byte {
	out := append([]byte(nil), plain...)
	for p := range out {
		key := encSeed + p
		out[p] -= k.t2[key%encKeyT2Len] - k.t1[key%encKeyT1Len]
	}
	return append(out, encTrailer...)
}

// TestENCTableDecrypts: an ENC file (the UTF-16 "\r\n//encrypt" trailer) is
// decrypted with 0x4f5140's rule before it is read; without keys it is
// refused with the flag's name, never read as garbage.
func TestENCTableDecrypts(t *testing.T) {
	k := &encKeys{t1: make([]byte, encKeyT1Len), t2: make([]byte, encKeyT2Len)}
	for i := range k.t1 {
		k.t1[i] = byte(i*7 + 3)
	}
	for i := range k.t2 {
		k.t2[i] = byte(i*13 + 1)
	}
	plain := utf16le("1\t42\t172\tSKILL_TEST_01\n")
	path := filepath.Join(t.TempDir(), "skilldata_1000enc.txt")
	if err := os.WriteFile(path, encrypt(plain, k), 0o600); err != nil {
		t.Fatal(err)
	}
	loadedEncKeys = nil
	if _, err := readTable(path); err == nil || !strings.Contains(err.Error(), "-enc-exe") {
		t.Fatalf("no keys: %v", err)
	}
	loadedEncKeys = k
	defer func() { loadedEncKeys = nil }()
	rows, err := readTable(path)
	if err != nil || len(rows) != 1 || rows[0][3] != "SKILL_TEST_01" {
		t.Fatalf("rows %q, %v", rows, err)
	}
}

// TestRawParamsColumn: column 91 carries the 50 raw words from Param1, as
// int32, trailing zeros dropped.
func TestRawParamsColumn(t *testing.T) {
	cols := make([]string, 118)
	for i := range cols {
		cols[i] = "0"
	}
	cols[skActionKind] = "3"
	cols[skActionKind+1] = "1685418593" // 'dura'
	cols[skActionKind+2] = "4294967295" // an unsigned spelling of -1
	if got := rawParams(cols); got != "3 1685418593 -1" {
		t.Fatalf("rawParams = %q", got)
	}
}

// Round 838: a table re-saved as UTF-8 keeps its first row (the BOM went
// into the Service column, and a one-row gachanpcmap.txt lost its NPC).
func TestDecodeDropsUTF8BOM(t *testing.T) {
	if got := decode([]byte("\xef\xbb\xbf1\t9251\t1\t2")); got != "1\t9251\t1\t2" {
		t.Fatalf("decode %q", got)
	}
	if got := decode([]byte("1\tA")); got != "1\tA" {
		t.Fatalf("plain %q", got)
	}
}
