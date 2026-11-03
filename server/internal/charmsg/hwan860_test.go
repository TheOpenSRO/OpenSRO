package charmsg

import (
	"bytes"
	"testing"
)

// Round 860: 0x304E kind 4 is u8 4, u8 the count, u32 the source (READ,
// GObjPC::FUN_004e3fb0 and the client's c:0x8a70d0).
func TestHwanGoldenBytes(t *testing.T) {
	got := EncodeHwan(3, 0x01020304)
	want := []byte{4, 3, 0x04, 0x03, 0x02, 0x01}
	if !bytes.Equal(got, want) {
		t.Fatalf("encoded % x, want % x", got, want)
	}
	n, src, err := DecodeHwan(got)
	if err != nil || n != 3 || src != 0x01020304 {
		t.Fatalf("decoded %d %#x %v", n, src, err)
	}
	if _, _, err := DecodeHwan(EncodeGold(5, false)); err == nil {
		t.Fatal("a gold update decoded as a hwan one")
	}
}
