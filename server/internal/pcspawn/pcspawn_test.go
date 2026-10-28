package pcspawn

import (
	"bytes"
	"encoding/binary"
	"math"
	"testing"
)

func plain() Record {
	return Record{
		RefObjID: 1907, Scale: 0x22, InventorySize: 109, AvatarSize: 5,
		Items: []Item{{RefItemID: 3643, Plus: 0, HasPlus: true}, {RefItemID: 3632, Plus: 7, HasPlus: true}},
		UID:   42, Region: 0x61a8, X: 1002, Y: 3.5, Z: 1020, Angle: 16384, RunFlag: 1,
		Life: 1, Walk: 16, Run: 50, Param140: 100,
		Name: "Aria", JobState: JobStateNone, Team: TeamNone,
	}
}

func f32(v float32) []byte { return binary.LittleEndian.AppendUint32(nil, math.Float32bits(v)) }

// The plain character, standing, byte for byte in the order the round-737
// reading gives (docs/protocol/pc_spawn.md): the instance block, the two
// item lists, the mask flag, the mobile/char block, the PC tail with the
// no-guild block (job state 4) and the world-1 team byte.
func TestPlainRecordBytes(t *testing.T) {
	got, err := Append(nil, plain())
	if err != nil {
		t.Fatal(err)
	}
	var w bytes.Buffer
	le := func(v any) { _ = binary.Write(&w, binary.LittleEndian, v) }
	le(uint32(1907))
	w.Write([]byte{0x22, 0, 0, 0}) // scale, hwan, cape, auto-invest
	w.Write([]byte{109, 2})        // inventory size, count
	le(uint32(3643))
	w.WriteByte(0)
	le(uint32(3632))
	w.WriteByte(7)
	w.Write([]byte{5, 0}) // avatars: size, count
	w.WriteByte(0)        // mask
	le(uint32(42))
	le(uint16(0x61a8))
	w.Write(f32(1002))
	w.Write(f32(3.5))
	w.Write(f32(1020))
	le(uint16(16384))
	w.Write([]byte{0, 1, 0}) // no destination, run flag, source byte
	le(uint16(16384))
	w.Write([]byte{1, 0, 0, 0}) // alive, [1], stand, normal
	w.Write(f32(16))
	w.Write(f32(50))
	w.Write(f32(100))
	w.WriteByte(0) // buffs
	le(uint16(4))
	w.WriteString("Aria")
	w.Write([]byte{0, 0, 0, 0, 0}) // job type, job level, pvp, ride, battle
	w.Write([]byte{0, 0, 0})       // teleport, interact, trade rank
	le(uint16(0))                  // guild name
	le(uint32(0))                  // guild id
	le(uint16(0))                  // member nickname
	le(uint32(0))
	le(uint32(0))
	le(uint32(0))
	w.Write([]byte{0, 0}) // membership byte, fortress role
	w.Write([]byte{0, 0xff})
	if !bytes.Equal(got, w.Bytes()) {
		t.Fatalf("record\n got % x\nwant % x", got, w.Bytes())
	}
}

type suit struct{ state byte }

// HasPlus is the client's TypeID 3/1 test: the fixture's arrows (3/3/4,
// worn in equip slot 7) carry no plus byte (round 737's review, F1).
func (s suit) HasPlus(id uint32) bool     { return id != fixtureArrows }
func (s suit) JobState(items []Item) byte { return s.state }

// A record decodes back as the client reads it, and the bytes after it are
// the next record's; a job suit drops the guild block on both sides.
func TestRecordRoundTrip(t *testing.T) {
	a := plain()
	a.Motion, a.BodyMode = 4, 1
	b := plain()
	b.UID, b.Name, b.JobState = 43, "Bram", 2
	buf, err := Append(nil, a)
	if err != nil {
		t.Fatal(err)
	}
	withSuit, err := Append(nil, b)
	if err != nil {
		t.Fatal(err)
	}
	if len(buf)-len(withSuit) != 4+2+12+2+(len("Aria")-len("Bram")) {
		t.Fatalf("a job suit's record is %d bytes shorter, want the guild block's 20", len(buf)-len(withSuit))
	}
	both := append(append([]byte(nil), buf...), buf...)
	d, rest, err := Decode(both, nil)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(rest, buf) || d.UID != 42 || d.Name != "Aria" || d.Motion != 4 || d.BodyMode != 1 ||
		len(d.Items) != 2 || d.Items[1].Plus != 7 || d.Team != TeamNone || d.JobState != JobStateNone {
		t.Fatalf("decoded %+v, rest %d", d, len(rest))
	}
	d2, rest2, err := Decode(withSuit, suit{2})
	if err != nil || len(rest2) != 0 || d2.Name != "Bram" || d2.JobState != 2 {
		t.Fatalf("suit record %+v rest %d err %v", d2, len(rest2), err)
	}
}

// What the reader could not take back is refused.
func TestAppendRefusesUnreadableForms(t *testing.T) {
	for name, mut := range map[string]func(*Record){
		"inventory size 0": func(r *Record) { r.InventorySize = 0 },
		"avatar size 0":    func(r *Record) { r.AvatarSize = 0 },
		"ride":             func(r *Record) { r.RideState = 1 },
	} {
		r := plain()
		mut(&r)
		if _, err := Append(nil, r); err == nil {
			t.Errorf("%s: appended", name)
		}
	}
}

// Round 814: a guild member's record carries the guild's name before the
// block and its id and the member's grant name first in it (READ
// s:0x4e5d3b..0x4e5eb3, c:0x9ddfbe..0x9de08c), and decodes back; the rest of
// the block stays 0.
func TestGuildBlockRoundTrip(t *testing.T) {
	a := plain()
	a.GuildName, a.GuildID, a.Nickname = "Verizon", 7, "Roaster"
	buf, err := Append(nil, a)
	if err != nil {
		t.Fatal(err)
	}
	var w bytes.Buffer
	le := func(v any) { _ = binary.Write(&w, binary.LittleEndian, v) }
	le(uint16(7))
	w.WriteString("Verizon")
	le(uint32(7))
	le(uint16(7))
	w.WriteString("Roaster")
	le(uint32(0))
	le(uint32(0))
	le(uint32(0))
	w.Write([]byte{0, 0, 0, 0xff})
	if !bytes.HasSuffix(buf, w.Bytes()) {
		t.Fatalf("the guild tail\n got % x\nwant suffix % x", buf, w.Bytes())
	}
	d, rest, err := Decode(buf, nil)
	if err != nil || len(rest) != 0 || d.GuildName != "Verizon" || d.GuildID != 7 || d.Nickname != "Roaster" {
		t.Fatalf("decoded %+v rest %d err %v", d, len(rest), err)
	}
	// A job suit drops the block: the name alone stays (the original writes
	// it before the job-state test).
	b := a
	b.JobState = 2
	sb, err := Append(nil, b)
	if err != nil {
		t.Fatal(err)
	}
	d2, _, err := Decode(sb, suit{2})
	if err != nil || d2.GuildName != "Verizon" || d2.GuildID != 0 || d2.Nickname != "" {
		t.Fatalf("suit record %+v err %v", d2, err)
	}
}

// Round 839: a stalling owner's record carries the stall block after the
// guild block and before the timer byte (READ s:0x4e5ee6..0x4e5f4f,
// c:0x9de103..0x9de1bd), and decodes back; a guild-less owner's too.
func TestStallBlockRoundTrip(t *testing.T) {
	r := plain()
	r.InteractMode = 4
	r.StallName = "Bram's stall"
	r.StallDecoration = 3847
	r.Timer, r.Team = 7, 9
	b, err := Append(nil, r)
	if err != nil {
		t.Fatal(err)
	}
	tail := []byte{0x0c, 0, 'B', 'r', 'a', 'm', '\'', 's', ' ', 's', 't', 'a', 'l', 'l', 0x07, 0x0f, 0, 0, 7, 9}
	if len(b) < len(tail) || string(b[len(b)-len(tail):]) != string(tail) {
		t.Fatalf("tail % x, want % x", b[len(b)-len(tail):], tail)
	}
	d, rest, err := Decode(b, nil)
	if err != nil || len(rest) != 0 {
		t.Fatalf("decode: %v rest %d", err, len(rest))
	}
	if d.InteractMode != 4 || d.StallName != "Bram's stall" || d.StallDecoration != 3847 || d.Timer != 7 || d.Team != 9 {
		t.Fatalf("decoded %+v", d)
	}
	// Not stalling: no block.
	r.InteractMode = 0
	b2, _ := Append(nil, r)
	if len(b2) != len(b)-len(tail)+2 {
		t.Fatalf("a record without a stall is %d bytes, want %d", len(b2), len(b)-len(tail)+2)
	}
}
