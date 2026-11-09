package session

import (
	"bytes"
	"encoding/binary"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/academy"
	"github.com/TheOpenSRO/OpenSRO/server/internal/party"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
)

// Round 866: the matching board's join, both sides (docs/protocol/academy.md
// 7.10, MEASURED): the requester's 0x747E puts a question to the guardian
// (0x747E down), whose 0x347F settles it.

// nextAcademy is p's next academy message among ops, skipping the rest.
func (f *acFix) nextAcademy(t *testing.T, p *acPlayer, ops ...uint16) *proto.Packet {
	t.Helper()
	for {
		p.conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		pk, err := proto.Read(p.r, nil, nil)
		if err != nil {
			t.Fatalf("%s waiting for % x: %v", p.name, ops, err)
		}
		for _, op := range ops {
			if pk.Opcode == op {
				return pk
			}
		}
	}
}

// register lists Aria's camp for apprentices and answers the entry id.
func (f *acFix) register(t *testing.T) uint32 {
	t.Helper()
	res := f.ask(t, f.p["Aria"], proto.OpAcademyMatchEntry, append(append(acU32(0), acU32(0)...), append(acB(1), acStr("Join us")...)...),
		proto.OpAcademyMatchEntryAck)
	if res[0] != 1 {
		t.Fatalf("register % x", res)
	}
	return binary.LittleEndian.Uint32(res[1:])
}

// askJoin sends Bram's 0x747E for entry and returns the question Aria gets.
func (f *acFix) askJoin(t *testing.T, entry uint32) []byte {
	t.Helper()
	f.send(t, f.p["Bram"], proto.OpAcademyMatchJoin, acU32(entry))
	q := nextOp(t, f.p["Aria"].conn, f.p["Aria"].r, proto.OpAcademyMatchJoin).Data
	br := f.p["Bram"]
	want := academy.EncodeMatchJoinAsk(academy.MatchJoinAsk{JobID: binary.LittleEndian.Uint32(q), Requester: party.JIDOf(br.id),
		Entry: entry, Level: 1, MaxLevel: 1, Name: "Bram"})
	// The body (RefObjID) is the character's; compare around it.
	if len(q) != len(want) || !bytes.Equal(q[4:18], want[4:18]) || !bytes.Equal(q[22:], want[22:]) {
		t.Fatalf("747E down\n got % x\nwant % x", q, want)
	}
	return q
}

func answer(q []byte, a byte) []byte { return append(append([]byte{}, q[:8]...), a) }

func TestAcademy866MatchJoinRefusedAndTimeout(t *testing.T) {
	f := startAcademy865(t)
	a, br := f.p["Aria"], f.p["Bram"]
	f.found(t)
	entry := f.register(t)
	// No: the requester 0xB47E {01 00}; nothing to the guardian.
	q := f.askJoin(t, entry)
	f.send(t, a, proto.OpAcademyMatchJoinAnswer, answer(q, 0))
	acWant(t, "refused", nextOp(t, br.conn, br.r, proto.OpAcademyMatchJoinAck).Data, acB(1, 0))
	noOp(t, a.conn, a.r, proto.OpAcademyMatchJoinAck)
	// The guardian's box timing out answers 0 too: the same reply.
	q = f.askJoin(t, entry)
	f.send(t, a, proto.OpAcademyMatchJoinAnswer, answer(q, 0))
	acWant(t, "box timed out", nextOp(t, br.conn, br.r, proto.OpAcademyMatchJoinAck).Data, acB(1, 0))
	// A forged answer (another job id, or another requester) is dropped and
	// the request stays waiting; the backstop then answers no reply.
	old := academyJoinWait
	academyJoinWait = 400 * time.Millisecond
	t.Cleanup(func() { academyJoinWait = old })
	q = f.askJoin(t, entry)
	bad := answer(q, 1)
	binary.LittleEndian.PutUint32(bad[4:], 0xdead)
	f.send(t, a, proto.OpAcademyMatchJoinAnswer, bad)
	acWant(t, "backstop", nextOp(t, br.conn, br.r, proto.OpAcademyMatchJoinAck).Data, acB(1, 2))
	if c, _ := f.store.CampOf(t.Context(), br.id); c != nil {
		t.Fatal("joined on a forged answer")
	}
	// The entry is free again: a new request is asked, not refused 0x6827.
	f.askJoin(t, entry)
	// Round 869 lane W2: that request's backstop answers before the test
	// ends -- its timer would otherwise answer the next test's Bram, whom
	// the academy now finds in whichever world he is (reachOf).
	acWant(t, "the last backstop", nextOp(t, br.conn, br.r, proto.OpAcademyMatchJoinAck).Data, acB(1, 2))
}

func TestAcademy866MatchJoinAccepted(t *testing.T) {
	f := startAcademy865(t)
	a, br := f.p["Aria"], f.p["Bram"]
	f.found(t)
	entry := f.register(t)
	q := f.askJoin(t, entry)
	f.send(t, a, proto.OpAcademyMatchJoinAnswer, answer(q, 1))
	// The guardian: 3C80 02, 0d, 05, then 0xB47E {01 01} (MEASURED order).
	ops := []uint16{proto.OpAcademyUpdate, proto.OpAcademyMatchJoinAck}
	var gotA []byte
	for range 4 {
		p := f.nextAcademy(t, a, ops...)
		if p.Opcode == proto.OpAcademyMatchJoinAck {
			gotA = append(gotA, 0xB4, p.Data[0], p.Data[1])
		} else {
			gotA = append(gotA, 0x3C, p.Data[0])
		}
	}
	acWant(t, "guardian's order", gotA, acB(0x3C, academy.PushJoined, 0x3C, academy.PushPosition, 0x3C, academy.PushField, 0xB4, 1, 1))
	// The requester: 3C80 {0a 01, CampInfo}, 05, then 0xB47E {01 01}.
	var gotB []byte
	for range 3 {
		p := f.nextAcademy(t, br, ops...)
		if p.Opcode == proto.OpAcademyMatchJoinAck {
			gotB = append(gotB, 0xB4, p.Data[0], p.Data[1])
		} else {
			gotB = append(gotB, 0x3C, p.Data[0], p.Data[1])
		}
	}
	acWant(t, "requester's order", gotB, acB(0x3C, academy.PushJoin, 1, 0x3C, academy.PushField, byte(br.id), 0xB4, 1, 1))
	c, err := f.store.CampOf(t.Context(), br.id)
	if err != nil || c == nil {
		t.Fatalf("not in the camp: %v", err)
	}
	if m, _ := c.Member(br.id); m.Class != academy.MemberClassStudent {
		t.Fatalf("class %d", m.Class)
	}
	// Bram is in a camp now: a second request is refused 0x6812.
	acWant(t, "already in", f.ask(t, br, proto.OpAcademyMatchJoin, acU32(entry), proto.OpAcademyMatchJoinAck), acFailB(0x6812))
}
