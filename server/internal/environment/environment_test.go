package environment

import (
	"encoding/binary"
	"math"
	"testing"
)

func appendFloat32(b []byte, v float32) []byte {
	var tmp [4]byte
	binary.LittleEndian.PutUint32(tmp[:], math.Float32bits(v))
	return append(b, tmp[:]...)
}

func appendU16(b []byte, v uint16) []byte {
	var tmp [2]byte
	binary.LittleEndian.PutUint16(tmp[:], v)
	return append(b, tmp[:]...)
}

func appendU32(b []byte, v uint32) []byte {
	var tmp [4]byte
	binary.LittleEndian.PutUint32(tmp[:], v)
	return append(b, tmp[:]...)
}

func appendString(b []byte, s string) []byte {
	b = appendU32(b, uint32(len(s)))
	return append(b, s...)
}

// appendRecord writes one real-shaped record: key/pad, name1/name2, a
// reserved uint32, then groupsPerChannel real groups per channel (all 16
// channels), each group's floats set to fill — real per-channel float
// counts (4 or 2) come from channelGroupFloats itself, so this fixture
// automatically tracks the package's own real layout.
func appendRecord(b []byte, key byte, name1, name2 string, groupsPerChannel int, fill float32) []byte {
	b = append(b, key, 0) // key, pad
	b = appendString(b, name1)
	b = appendString(b, name2)
	b = appendU32(b, 0) // reserved
	for _, groupFloats := range channelGroupFloats {
		b = appendU32(b, uint32(groupsPerChannel))
		for g := 0; g < groupsPerChannel; g++ {
			for k := 0; k < groupFloats; k++ {
				b = appendFloat32(b, fill)
			}
		}
	}
	return b
}

type record struct {
	key              byte
	name1, name2     string
	groupsPerChannel int
	fill             float32
}

func buildFile(records []record) []byte {
	var buf []byte
	buf = append(buf, magic...)
	buf = appendU32(buf, uint32(len(records)))
	buf = appendU16(buf, 0) // real fixed field
	for _, rec := range records {
		buf = appendRecord(buf, rec.key, rec.name1, rec.name2, rec.groupsPerChannel, rec.fill)
	}
	return buf
}

func TestParse(t *testing.T) {
	data := buildFile([]record{
		{key: 7, name1: "Env7", name2: "", groupsPerChannel: 2, fill: 1.0},
		{key: 39, name1: "Env8", name2: "Second", groupsPerChannel: 3, fill: 0.5},
	})

	parsed, err := Parse(data)
	if err != nil {
		t.Fatalf("Parse failed: %v", err)
	}
	if parsed.RecordCount != 2 {
		t.Errorf("RecordCount = %d, want 2", parsed.RecordCount)
	}
	if len(parsed.Records) != 2 {
		t.Fatalf("len(Records) = %d, want 2", len(parsed.Records))
	}
	if parsed.TrailerOffset != len(data) {
		t.Errorf("TrailerOffset = %d, want %d (no trailer in this fixture)", parsed.TrailerOffset, len(data))
	}

	r0 := parsed.Records[0]
	if r0.Key != 7 {
		t.Errorf("record 0 Key = %d, want 7", r0.Key)
	}
	if r0.Name1 != "Env7" {
		t.Errorf("record 0 Name1 = %q, want Env7", r0.Name1)
	}
	if r0.Name2 != "" {
		t.Errorf("record 0 Name2 = %q, want empty", r0.Name2)
	}
	if len(r0.Channels[0]) != 2 {
		t.Errorf("record 0 channel 0 has %d groups, want 2", len(r0.Channels[0]))
	}
	if len(r0.Channels[0][0]) != 4 {
		t.Errorf("record 0 channel 0's group has %d floats, want 4", len(r0.Channels[0][0]))
	}
	if r0.Channels[0][0][0] != 1.0 {
		t.Errorf("record 0 channel 0's group = %v, want fill value 1.0", r0.Channels[0][0])
	}
	if len(r0.Channels[7][0]) != 2 {
		t.Errorf("record 0 channel 7 (2-float type) has %d floats, want 2", len(r0.Channels[7][0]))
	}

	r1 := parsed.Records[1]
	if r1.Key != 39 {
		t.Errorf("record 1 Key = %d, want 39", r1.Key)
	}
	if r1.Name2 != "Second" {
		t.Errorf("record 1 Name2 = %q, want Second", r1.Name2)
	}
	if len(r1.Channels[0]) != 3 {
		t.Errorf("record 1 channel 0 has %d groups, want 3", len(r1.Channels[0]))
	}
}

func TestParseRejectsBadMagic(t *testing.T) {
	data := buildFile([]record{{key: 1, name1: "Env1", groupsPerChannel: 0}})
	data[0] = 'X'
	if _, err := Parse(data); err == nil {
		t.Error("expected error for bad magic, got nil")
	}
}

func TestParseRejectsTooSmall(t *testing.T) {
	if _, err := Parse([]byte{1, 2, 3}); err == nil {
		t.Error("expected error for too-small buffer, got nil")
	}
}

func TestParseRejectsNonZeroPad(t *testing.T) {
	data := buildFile([]record{{key: 1, name1: "Env1", groupsPerChannel: 0}})
	data[magicLen+4+2+1] = 5 // the first record's pad byte
	if _, err := Parse(data); err == nil {
		t.Error("expected error for non-zero pad byte, got nil")
	}
}

func TestParseRejectsTruncated(t *testing.T) {
	data := buildFile([]record{
		{key: 7, name1: "Env7", groupsPerChannel: 2, fill: 1.0},
	})
	truncated := data[:len(data)-4]
	if _, err := Parse(truncated); err == nil {
		t.Error("expected error for truncated data, got nil")
	}
}
