package session

import (
	"bytes"
	"context"
	"math"
	"testing"
)

// Round 637's review follow-up: the new fields' own codecs (facing_test.go
// has the flows).
func TestEntityEnteredRoundTripsTheHeading(t *testing.T) {
	snap := EntitySnapshot{CharacterID: 7, Name: "Aria", X: 1, Y: 2, Z: 3, Gender: "china_woman", Heading: math.Pi}
	got, err := DecodeEntityEntered(snap.EncodeEntered())
	if err != nil || !got.HasHeading || math.Abs(got.Heading-math.Pi) > 1e-4 {
		t.Fatalf("round trip gave %+v, %v; want heading pi", got, err)
	}
	old, err := DecodeEntityEntered(snap.Encode())
	if err != nil || old.HasHeading {
		t.Fatalf("a payload with no angle decodes with HasHeading false, got %+v, %v", old, err)
	}
	m, err := DecodeMoveRequest((&MoveRequest{X: 1, Y: 2, Z: 3, Relocated: true}).Encode())
	if err != nil || !m.Relocated {
		t.Fatalf("MoveRequest's relocated flag does not round-trip: %+v, %v", m, err)
	}
	if n := len((&MoveRequest{X: 1}).Encode()); n != 12 {
		t.Fatalf("a walk's MoveRequest is %d bytes, want the old 12", n)
	}
}

// The headings tail of the arrival lists: it round-trips, it rides after the
// older payload (a result built without headings is unchanged, and a decoder
// that stops at Seated reads the same seated list), and a count that does not
// match the list is an error.
func TestArrivalListHeadingsRoundTrip(t *testing.T) {
	others := []EntitySnapshot{
		{CharacterID: 1, Name: "Bram", Gender: "china_man", Heading: math.Pi / 2, HasHeading: true},
		{CharacterID: 2, Name: "Cyra", Gender: "china_woman", Heading: 1.5 * math.Pi, HasHeading: true},
	}
	ew := &EnterWorldResult{OK: true, Zone: "jangan", Gender: "china_man", HP: 1, MaxHP: 1,
		Others: others, FrameRegion: "97/168", Seated: []int64{2}, Heading: math.Pi, HasHeading: true}
	got, err := DecodeEnterWorldResult(ew.Encode())
	if err != nil || len(got.Others) != 2 || !got.HasHeading || math.Abs(got.Heading-math.Pi) > 1e-4 {
		t.Fatalf("EnterWorldResult round trip: %+v, %v", got, err)
	}
	for i, o := range got.Others {
		if !o.HasHeading || math.Abs(o.Heading-others[i].Heading) > 1e-4 {
			t.Errorf("other %d decodes heading %v (has %v), want %v", i, o.Heading, o.HasHeading, others[i].Heading)
		}
	}
	if len(got.Seated) != 1 || got.Seated[0] != 2 {
		t.Errorf("the seated list is %v, want [2]", got.Seated)
	}
	cz := &ChangeZoneResult{OK: true, Zone: "hotan", Others: others, FrameRegion: "92/135"}
	gz, err := DecodeChangeZoneResult(cz.Encode())
	if err != nil || len(gz.Others) != 2 || !gz.Others[1].HasHeading || math.Abs(gz.Others[1].Heading-1.5*math.Pi) > 1e-4 {
		t.Fatalf("ChangeZoneResult round trip: %+v, %v", gz, err)
	}
	// Built without headings, the payload is the older one exactly.
	plain := []EntitySnapshot{{CharacterID: 1, Name: "Bram", Gender: "china_man"}}
	old := (&ChangeZoneResult{OK: true, Zone: "hotan", Others: plain, FrameRegion: "92/135"}).Encode()
	withHeads := (&ChangeZoneResult{OK: true, Zone: "hotan", Others: []EntitySnapshot{{CharacterID: 1, Name: "Bram", Gender: "china_man", HasHeading: true}}, FrameRegion: "92/135"}).Encode()
	if !bytes.HasPrefix(withHeads, old) || len(withHeads) != len(old)+2+4 {
		t.Fatalf("the headings tail is not the older payload plus seated(0) and one heading:\n old  % x\n new  % x", old, withHeads)
	}
	// A Seated read (the older decoders' last) stops before the headings.
	ids, rest, err := decodeSeatedRest(withHeads[len(old):])
	if err != nil || len(ids) != 0 || len(rest) != 4 {
		t.Fatalf("an older Seated read of the new tail: %v, %v", ids, err)
	}
	// A count that does not match the list is refused.
	bad := append(append([]byte{}, withHeads[:len(withHeads)-4]...), 2, 0, 0, 0)
	if _, err := DecodeChangeZoneResult(bad); err == nil {
		t.Fatal("a headings count that does not match the list decoded")
	}
}

// Persisted with the position (OURS; character.HeadingStore): a walk toward
// +x, a logout, and the next entry faces pi/2 -- the store holds it, and the
// entry's own wire angle carries it. With the flag off a re-entry faces 0.
func TestPersistPositionKeepsTheHeading(t *testing.T) {
	SetPersistPosition(true)
	t.Cleanup(func() { SetPersistPosition(false) })
	w := startPositionWorld(t)
	conn, _, _ := w.enter(t)
	w.moveTo(t, conn, 100, 0, -200)
	w.moveTo(t, conn, 110, 0, -200)
	w.leave(t, conn)
	if h, err := w.chars.Heading(context.Background(), w.aria); err != nil || math.Abs(h-math.Pi/2) > 1e-9 {
		t.Fatalf("the saved heading is %v (%v), want pi/2", h, err)
	}
	_, _, again := w.enter(t)
	if !again.HasHeading || math.Abs(again.Heading-math.Pi/2) > 1e-4 {
		t.Fatalf("the re-entry faces %v (has %v), want pi/2", again.Heading, again.HasHeading)
	}
	if e, ok := w.hub.EntityByCharacterID(w.aria); !ok || math.Abs(e.Heading-math.Pi/2) > 1e-9 {
		t.Fatalf("the hub's re-entered Aria faces %v, want pi/2", e.Heading)
	}
}
