package npctalk

import (
	"bytes"
	"testing"
)

// The golden bytes of every message, written out by hand from the layouts
// read in both binaries (wire.go).
func TestGoldenBytes(t *testing.T) {
	for _, c := range []struct {
		name string
		got  []byte
		want []byte
	}{
		{"0x7045 select", EncodeEntity(0x7f000123), []byte{0x23, 0x01, 0x00, 0x7f}},
		{"0x7046 open store", EncodeOpen(0x7f000123, 1), []byte{0x23, 0x01, 0x00, 0x7f, 0x01}},
		{"0x704b end", EncodeEntity(0x7f000123), []byte{0x23, 0x01, 0x00, 0x7f}},
		// The herbalist: ids {1, 2}, no 0x1f or 0x21, the NPC byte 0.
		{"0xb045 herbalist", EncodeSelectNPC(SelectNPC{Entity: 0x7f000123, IDs: []byte{1, 2}}),
			[]byte{0x01, 0x23, 0x01, 0x00, 0x7f, 0x02, 0x01, 0x02, 0x00}},
		// A set with 0x1f: the u16 before the NPC byte.
		{"0xb045 structure", EncodeSelectNPC(SelectNPC{Entity: 1, IDs: []byte{0x1f}, StructureWord: 0x0203, NPCByte: 7}),
			[]byte{0x01, 0x01, 0x00, 0x00, 0x00, 0x01, 0x1f, 0x03, 0x02, 0x07}},
		// The arena manager: the u16 after the NPC byte.
		{"0xb045 arena", EncodeSelectNPC(SelectNPC{Entity: 1, IDs: []byte{0x21}, ArenaWord: 0x0405}),
			[]byte{0x01, 0x01, 0x00, 0x00, 0x00, 0x01, 0x21, 0x00, 0x05, 0x04}},
		{"0xb046 store", EncodeOpenOK(1), []byte{0x01, 0x01}},
		{"0xb046 talk", EncodeOpenOK(2), []byte{0x01, 0x02}},
		{"0xb046 withdraw echoes 2", EncodeOpenOK(10), []byte{0x01, 0x02}},
		{"0xb046 0xc carries a byte", EncodeOpenOK(0xc), []byte{0x01, 0x0c, 0x00}},
		{"0xb04b ok", EncodeEndOK(), []byte{0x01}},
		{"refusal busy", EncodeFail(CodeBusy), []byte{0x02, 0x0b, 0x1c}},
		{"refusal not offered", EncodeFail(CodeNotOffered), []byte{0x02, 0x05, 0x00}},
	} {
		if !bytes.Equal(c.got, c.want) {
			t.Errorf("%s: % x, want % x", c.name, c.got, c.want)
		}
	}
}

func TestDecodeRoundTrip(t *testing.T) {
	e, id, err := DecodeOpen(EncodeOpen(42, 3))
	if err != nil || e != 42 || id != 3 {
		t.Fatalf("open: %d %d %v", e, id, err)
	}
	if _, _, err := DecodeOpen([]byte{1, 2, 3, 4}); err != ErrShort {
		t.Fatalf("short open: %v", err)
	}
	if v, err := DecodeEntity([]byte{1, 0, 0, 0}); err != nil || v != 1 {
		t.Fatalf("entity: %d %v", v, err)
	}
	for _, s := range []SelectNPC{
		{Entity: 9, IDs: []byte{1, 2}},
		{Entity: 9, IDs: []byte{0x1f, 0x21}, StructureWord: 3, NPCByte: 4, ArenaWord: 5},
		{Entity: 9},
	} {
		got, err := DecodeSelectNPC(EncodeSelectNPC(s))
		if err != nil || got.Entity != s.Entity || !bytes.Equal(got.IDs, s.IDs) || got.StructureWord != s.StructureWord ||
			got.NPCByte != s.NPCByte || got.ArenaWord != s.ArenaWord {
			t.Errorf("%+v -> %+v %v", s, got, err)
		}
	}
}
