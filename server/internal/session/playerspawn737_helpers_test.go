package session

import (
	"bufio"
	"net"
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/npcspawn"
	"github.com/OpenSRO/OpenSRO/server/internal/pcspawn"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
)

// Test helpers for round 737's player spawns (playerview.go): the players in
// view arrive as retail's 0x3015 or as group spawns (0x3017 / 0x3019 /
// 0x3018) with pcspawn records, and leave as 0x3016 or a type-2 group.

// readPacket reads one frame from r with a 2 s deadline on conn.
func readFrame737(t *testing.T, conn net.Conn, r *bufio.Reader) *proto.Packet {
	t.Helper()
	conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	p, err := proto.Read(r, nil, nil)
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	return p
}

// playerSpawnsIn reads the player records a spawn starting with first
// carries: a 0x3015's one, or a whole group's (the rest of whose frames are
// read through next). It fails the test on anything else, or on a group of
// NPCs.
func playerSpawnsIn(t *testing.T, first *proto.Packet, next func() *proto.Packet) []pcspawn.Record {
	t.Helper()
	switch first.Opcode {
	case npcspawn.OpSingleSpawn:
		rec, rest, err := pcspawn.Decode(first.Data, nil)
		if err != nil || len(rest) != 1 {
			t.Fatalf("0x3015: %v (%d byte(s) after the record, want the spawn type)", err, len(rest))
		}
		return []pcspawn.Record{rec}
	case npcspawn.OpGroupBegin:
		frames := []npcspawn.GroupFrame{{Opcode: first.Opcode, Data: first.Data}}
		for {
			p := next()
			frames = append(frames, npcspawn.GroupFrame{Opcode: p.Opcode, Data: p.Data})
			if p.Opcode == npcspawn.OpGroupEnd {
				break
			}
			if p.Opcode != npcspawn.OpGroupData {
				t.Fatalf("%#04x inside a group spawn", p.Opcode)
			}
		}
		recs, uids, kind := decodePlayerGroup(t, frames)
		if kind != npcspawn.GroupSpawn {
			t.Fatalf("a group despawn of %v, want a spawn", uids)
		}
		return recs
	}
	t.Fatalf("got %#04x, want a player spawn (0x3015 or 0x3017)", first.Opcode)
	return nil
}

// decodePlayerGroup reads a group whose spawn records are all players'.
func decodePlayerGroup(t *testing.T, frames []npcspawn.GroupFrame) (recs []pcspawn.Record, uids []uint32, kind byte) {
	t.Helper()
	var buf []byte
	for _, f := range frames[1 : len(frames)-1] {
		buf = append(buf, f.Data...)
	}
	kind = frames[0].Data[0]
	n := int(frames[0].Data[1]) | int(frames[0].Data[2])<<8
	switch kind {
	case npcspawn.GroupSpawn:
		for i := 0; i < n; i++ {
			rec, rest, err := pcspawn.Decode(buf, nil)
			if err != nil {
				t.Fatalf("group record %d of %d: %v", i, n, err)
			}
			recs = append(recs, rec)
			buf = rest
		}
	case npcspawn.GroupDespawn:
		_, _, ids, err := npcspawn.DecodeGroup(frames)
		if err != nil {
			t.Fatal(err)
		}
		return nil, ids, kind
	}
	if len(buf) != 0 {
		t.Fatalf("%d byte(s) after the group", len(buf))
	}
	return recs, nil, kind
}

// playerDespawnsIn reads the uids a despawn starting with first carries: a
// 0x3016's one, or a type-2 group's.
func playerDespawnsIn(t *testing.T, first *proto.Packet, next func() *proto.Packet) []uint32 {
	t.Helper()
	switch first.Opcode {
	case npcspawn.OpSingleDespawn:
		if len(first.Data) != 4 {
			t.Fatalf("0x3016 of %d bytes", len(first.Data))
		}
		return []uint32{uint32(first.Data[0]) | uint32(first.Data[1])<<8 | uint32(first.Data[2])<<16 | uint32(first.Data[3])<<24}
	case npcspawn.OpGroupBegin:
		frames := []npcspawn.GroupFrame{{Opcode: first.Opcode, Data: first.Data}}
		for {
			p := next()
			frames = append(frames, npcspawn.GroupFrame{Opcode: p.Opcode, Data: p.Data})
			if p.Opcode == npcspawn.OpGroupEnd {
				break
			}
		}
		_, uids, kind := decodePlayerGroup(t, frames)
		if kind != npcspawn.GroupDespawn {
			t.Fatalf("a group spawn, want a despawn")
		}
		return uids
	}
	t.Fatalf("got %#04x, want a player despawn (0x3016 or 0x3017 type 2)", first.Opcode)
	return nil
}

// expectPlayerSpawn reads the next player spawn on conn and checks it names
// exactly the characters in ids, returning the records.
func expectPlayerSpawn(t *testing.T, conn net.Conn, r *bufio.Reader, ids ...int64) []pcspawn.Record {
	t.Helper()
	recs := playerSpawnsIn(t, readFrame737(t, conn, r), func() *proto.Packet { return readFrame737(t, conn, r) })
	if len(recs) != len(ids) {
		t.Fatalf("spawn of %d player(s), want %v", len(recs), ids)
	}
	want := map[uint32]bool{}
	for _, id := range ids {
		want[uint32(id)] = true
	}
	for _, rec := range recs {
		if !want[rec.UID] {
			t.Fatalf("spawn of uid %d, want %v", rec.UID, ids)
		}
	}
	return recs
}

// drainPlayerSpawn reads the next player spawn on conn -- a 0x3015 or a
// whole group -- whoever it names: the arrival a test of something else
// steps over (the second player's group spawn of the first, after its
// result).
func drainPlayerSpawn(t *testing.T, conn net.Conn, r *bufio.Reader) []pcspawn.Record {
	t.Helper()
	return playerSpawnsIn(t, readFrame737(t, conn, r), func() *proto.Packet { return readFrame737(t, conn, r) })
}

// sees reports whether characters a and b are both in the world and in view
// of each other in f's hub now.
func (f *deadWorldFixture) sees(a, b int64) bool {
	ea, okA := f.hub.EntityByCharacterID(a)
	eb, okB := f.hub.EntityByCharacterID(b)
	return okA && okB && f.hub.Sees(ea.Session.ID(), eb.Session.ID())
}

// expectSpawnIfInView reads Bram's spawn on Aria's connection when the hub
// has them in view now -- after a zone change or a warp that brought her
// where he stands (her client was spawned nobody before it).
func (f *deadWorldFixture) expectSpawnIfInView(t *testing.T) {
	t.Helper()
	if f.sees(f.aria, f.bram) {
		expectPlayerSpawn(t, f.connA, f.rA, f.bram)
	}
}

// readAfterAriaMoved reads Aria's next packet after a move she sent, first
// reading the spawn or despawn of Bram the move owes her when it took her
// into or out of his view (before is whether she saw him before the move).
// The hub is read after the first packet arrives, which the server sends
// only after it has handled the move.
func (f *deadWorldFixture) readAfterAriaMoved(t *testing.T, before bool) *proto.Packet {
	t.Helper()
	p := f.read(t, f.connA, f.rA)
	after := f.sees(f.aria, f.bram)
	next := func() *proto.Packet { return f.read(t, f.connA, f.rA) }
	switch {
	case before && !after:
		if uids := playerDespawnsIn(t, p, next); len(uids) != 1 || uids[0] != uint32(f.bram) {
			t.Fatalf("the move out of Bram's view despawned %v", uids)
		}
		p = f.read(t, f.connA, f.rA)
	case !before && after:
		if recs := playerSpawnsIn(t, p, next); len(recs) != 1 || recs[0].UID != uint32(f.bram) {
			t.Fatalf("the move into Bram's view spawned %d record(s)", len(recs))
		}
		p = f.read(t, f.connA, f.rA)
	}
	return p
}

// isPlayerViewOpcode reports whether op is one of the spawn messages.
func isPlayerViewOpcode(op uint16) bool {
	return op >= npcspawn.OpSingleSpawn && op <= npcspawn.OpGroupData
}

// expectPlayerDespawn reads the next player despawn on conn and checks it
// names exactly ids.
func expectPlayerDespawn(t *testing.T, conn net.Conn, r *bufio.Reader, ids ...int64) {
	t.Helper()
	uids := playerDespawnsIn(t, readFrame737(t, conn, r), func() *proto.Packet { return readFrame737(t, conn, r) })
	if len(uids) != len(ids) {
		t.Fatalf("despawn of %v, want %v", uids, ids)
	}
	want := map[uint32]bool{}
	for _, id := range ids {
		want[uint32(id)] = true
	}
	for _, u := range uids {
		if !want[u] {
			t.Fatalf("despawn of %v, want %v", uids, ids)
		}
	}
}
