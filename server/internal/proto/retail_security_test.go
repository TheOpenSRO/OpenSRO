package proto

import (
	"bytes"
	"encoding/hex"
	"hash/crc32"
	"math/big"
	"strings"
	"testing"
)

// The checksum family against the standard library's own reflected-CRC
// tables: index i's table is crc32.MakeTable(the CRC-32 table's entry i), and
// a frame's accumulator is the complement of crc32.Update from 0.
func TestCRCTableMatchesStdlib(t *testing.T) {
	known := 0
	frame := []byte{0x00, 0x80, 0x01, 0x61, 0x9a, 0x00, 1, 2, 3}
	for i := 1; i < 256; i++ {
		tab, ok := CRCTable(byte(i))
		if ok != CRCIndexKnown(byte(i)) {
			t.Fatalf("index %d: CRCTable ok=%v, CRCIndexKnown=%v", i, ok, !ok)
		}
		if !ok {
			continue
		}
		known++
		std := crc32.MakeTable(crc32.IEEETable[i])
		if *tab != [256]uint32(*std) {
			t.Fatalf("index %d: table differs from crc32.MakeTable", i)
		}
		acc := ^crc32.Update(0, std, frame)
		want := byte(acc) + byte(acc>>8) + byte(acc>>16) + byte(acc>>24)
		if got := CheckByte(tab, frame); got != want {
			t.Fatalf("index %d: check 0x%02x, want 0x%02x", i, got, want)
		}
	}
	if known != 218 {
		t.Fatalf("%d known indices, want 218 (MEASURED)", known)
	}
	if CRCIndexKnown(0) || CRCIndex(0x100) != 1 || CRCIndex(0x1207) != 7 {
		t.Fatal("index 0 is never used: a seed's low byte 0 selects 1")
	}
}

// Blowfish with little-endian halves, from the standard known answer (key
// and plaintext 0 -> 4ef997456198dd78 read as two big-endian words).
func TestRetailCipherHalves(t *testing.T) {
	c, err := NewRetailCipher(make([]byte, 8))
	if err != nil {
		t.Fatal(err)
	}
	b := make([]byte, 8)
	c.EncryptBlock(b)
	if want, _ := hex.DecodeString("4597f94e78dd9861"); !bytes.Equal(b, want) {
		t.Fatalf("% x, want % x", b, want)
	}
	c.DecryptBlock(b)
	if !bytes.Equal(b, make([]byte, 8)) {
		t.Fatal("decrypt does not invert encrypt")
	}
	if got := c.Encrypt([]byte{1, 2, 3}); len(got) != 8 {
		t.Fatalf("3 bytes encrypt to %d, want one zero-padded block", len(got))
	}
}

func TestModPowMatchesBig(t *testing.T) {
	for _, c := range [][3]uint32{{2147483629, 0x07654321, 2147483647}, {5, 0, 7}, {0xffffffff, 0xffffffff, 0xfffffffb}, {3, 1, 2}} {
		want := new(big.Int).Exp(big.NewInt(int64(c[0])), big.NewInt(int64(c[1])), big.NewInt(int64(c[2])))
		if c[1] == 0 {
			want = big.NewInt(1)
		}
		if got := ModPow(c[0], c[1], c[2]); uint64(got) != want.Uint64() {
			t.Fatalf("%v: %d, want %d", c, got, want)
		}
	}
}

func TestKeyTransformByHand(t *testing.T) {
	// byte 0: 0x01 ^ (0x01 + 0xef + 5) = 0x01 ^ 0xf5 = 0xf4; byte 5: 0x06 ^ (0x06 + 0xbe + 5) = 0x06 ^ 0xc9 = 0xcf.
	got := KeyTransform([8]byte{1, 2, 3, 4, 5, 6, 7, 8}, 0xdeadbeef, 5)
	if got[0] != 0xf4 || got[5] != 0xcf {
		t.Fatalf("% x", got)
	}
}

func TestCountSeedsChain(t *testing.T) {
	if CountSeeds(0) != CountSeeds(DefaultCountSeed) {
		t.Fatal("a 0 seed is DefaultCountSeed")
	}
	// The first run from the default seed ends in 0x2d (the TestLFSRByteKnownValues
	// value); the four runs chain on one register.
	v1 := lfsr32(DefaultCountSeed)
	if byte(v1) != 0x2d {
		t.Fatalf("lfsr32(default) low byte 0x%02x", byte(v1))
	}
	v2 := lfsr32(v1)
	v3 := lfsr32(v2)
	v4 := lfsr32(v3)
	a, b := byte(v1)^byte(v2), byte(v4)^byte(v3)
	if a == 0 {
		a = 1
	}
	if b == 0 {
		b = 1
	}
	if s := CountSeeds(0); s != [3]byte{a ^ b, a, b} {
		t.Fatalf("%v", s)
	}
	d0, d1, d2 := DeriveSeed(77)
	if [3]byte{d0, d1, d2} != CountSeeds(77) {
		t.Fatal("DeriveSeed is CountSeeds")
	}
}

func TestRetailFrames(t *testing.T) {
	key := []byte{1, 2, 3, 4, 5, 6, 7, 8}
	mk := func() *RetailSecurity {
		c, _ := NewRetailCipher(key)
		tab, _ := CRCTable(7)
		return &RetailSecurity{Flags: 0x06, Count: CountSeeds(9), CRC: tab, Cipher: c}
	}
	cli, srv := mk(), mk()
	payload := []byte("SR_Client")
	f, err := cli.EncodeClientFrame(0x2001, payload, true)
	if err != nil {
		t.Fatal(err)
	}
	if len(f) != 2+PaddedLen(len(payload)+4) || f[1]&0x80 == 0 {
		t.Fatalf("encrypted frame % x", f)
	}
	if n, err := RetailFrameLen(f); err != nil || n != len(f) {
		t.Fatalf("frame length %d %v", n, err)
	}
	if _, err := RetailFrameLen(f[:len(f)-1]); err != ErrRetailNeedMore {
		t.Fatalf("a short buffer: %v", err)
	}
	rf, err := DecodeRetailFrame(f, srv)
	if err != nil || rf.Opcode != 0x2001 || !bytes.Equal(rf.Payload, payload) {
		t.Fatalf("%+v %v", rf, err)
	}
	if err := srv.CheckFromClient(rf); err != nil {
		t.Fatal(err)
	}
	// A server's frames carry zeros; the client rejects anything else,
	// except on a plain 0x1001.
	sf, _ := srv.EncodeServerFrame(0xA101, []byte{0, 0}, false)
	rf, _ = DecodeRetailFrame(sf, cli)
	if err := cli.CheckFromServer(rf); err != nil {
		t.Fatal(err)
	}
	sf[5] = 1
	rf, _ = DecodeRetailFrame(sf, cli)
	if err := cli.CheckFromServer(rf); err == nil || !strings.Contains(err.Error(), "0x800c") {
		t.Fatalf("a non-zero check byte: %v", err)
	}
	sf[2], sf[3] = 0x01, 0x10
	rf, _ = DecodeRetailFrame(sf, cli)
	if err := cli.CheckFromServer(rf); err != nil {
		t.Fatalf("a plain 0x1001 is exempt: %v", err)
	}
	// Encrypted without Blowfish; over the frame limit.
	if _, err := DecodeRetailFrame(f, &RetailSecurity{Flags: 0x04}); err == nil {
		t.Fatal("an encrypted frame without Blowfish")
	}
	if _, err := RetailFrameLen([]byte{0xff, 0x7f}); err == nil {
		t.Fatal("a 32 KiB frame")
	}
}
