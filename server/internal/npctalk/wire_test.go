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
		// The herbalist for a player of level 20 or more, as the original
		// sends it (round 727's review): 01 | uid | 00 (0x4c79f0) | 03 |
		// 01 02 0a | 00.
		{"0xb045 herbalist, level 20", EncodeSelectNPC(SelectNPC{Entity: 0x7f000123, IDs: []byte{1, 2, 10}}),
			[]byte{0x01, 0x23, 0x01, 0x00, 0x7f, 0x00, 0x03, 0x01, 0x02, 0x0a, 0x00}},
		// Below level 20: {1, 2}.
		{"0xb045 herbalist, level 19", EncodeSelectNPC(SelectNPC{Entity: 0x7f000123, IDs: []byte{1, 2}}),
			[]byte{0x01, 0x23, 0x01, 0x00, 0x7f, 0x00, 0x02, 0x01, 0x02, 0x00}},
		// The flag's bit 0: a u32 after it (the client's read, 0x88b385).
		{"0xb045 flag bit 0", EncodeSelectNPC(SelectNPC{Entity: 1, Flag: 1, FlagWord: 0x0a0b0c0d, IDs: []byte{1}}),
			[]byte{0x01, 0x01, 0x00, 0x00, 0x00, 0x01, 0x0d, 0x0c, 0x0b, 0x0a, 0x01, 0x01, 0x00}},
		// A set with 0x1f: the u16 before the NPC byte.
		{"0xb045 structure", EncodeSelectNPC(SelectNPC{Entity: 1, IDs: []byte{0x1f}, StructureWord: 0x0203, NPCByte: 7}),
			[]byte{0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x01, 0x1f, 0x03, 0x02, 0x07}},
		// The arena manager: the u16 after the NPC byte.
		{"0xb045 arena", EncodeSelectNPC(SelectNPC{Entity: 1, IDs: []byte{0x21}, ArenaWord: 0x0405}),
			[]byte{0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x01, 0x21, 0x00, 0x05, 0x04}},
		{"0xb046 store", EncodeOpenSpecialOK(1, 0), []byte{0x01, 0x01}},
		{"0xb046 talk", EncodeOpenSpecialOK(2, 0), []byte{0x01, 0x02}},
		{"0xb046 withdraw echoes 2", EncodeOpenSpecialOK(10, 0), []byte{0x01, 0x02}},
		{"0xb046 0xc carries a byte", EncodeOpenSpecialOK(0xc, 0), []byte{0x01, 0x0c, 0x00}},
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
		{Entity: 9, Flag: 1, FlagWord: 77, IDs: []byte{1, 2, 10}},
		{Entity: 9},
	} {
		got, err := DecodeSelectNPC(EncodeSelectNPC(s))
		if err != nil || got.Entity != s.Entity || got.Flag != s.Flag || got.FlagWord != s.FlagWord ||
			!bytes.Equal(got.IDs, s.IDs) || got.StructureWord != s.StructureWord ||
			got.NPCByte != s.NPCByte || got.ArenaWord != s.ArenaWord {
			t.Errorf("%+v -> %+v %v", s, got, err)
		}
	}
}
