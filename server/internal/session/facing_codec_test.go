package session

import (
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
