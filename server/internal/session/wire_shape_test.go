package session

import (
	"encoding/binary"
	"testing"
)

// The client builds a name-only request by hand:
//
//	var out := PackedByteArray()
//	out.resize(2)
//	out.encode_u16(0, name_bytes.size())
//	out.append_array(name_bytes)
//
// -- a u16 length and the UTF-8 name, and nothing after it. This is that,
// in Go, deliberately *not* built with encodeStrings: a test that uses the
// server's own encoder on both sides cannot tell whether the two halves
// agree, and that is precisely how a real mismatch survived.
//
// Ten handlers -- the inventory, equipment, quest, party, guild and friend
// listings -- used to decode these with DecodeCharacterCreateRequest,
// under a comment reading "reuse: it's just {Name string}". Character
// creation later gained a Gender field, so that decoder started requiring
// two length-prefixed strings while the client kept sending one, and every
// listing began answering "malformed request". Nothing failed: the tests
// for those handlers each sent CharacterCreateRequest{Name: ...}.Encode(),
// which put the second, empty string on the wire that only the server
// expected.
func clientNameRequest(name string) []byte {
	out := make([]byte, 2, 2+len(name))
	binary.LittleEndian.PutUint16(out, uint16(len(name)))
	return append(out, name...)
}

func TestNameOnlyRequestsMatchTheClientsWireShape(t *testing.T) {
	payload := clientNameRequest("Aria")

	req, err := DecodeCharacterNameRequest(payload)
	if err != nil {
		t.Fatalf("DecodeCharacterNameRequest on the client's own bytes: %v", err)
	}
	if req.Name != "Aria" {
		t.Fatalf("decoded name %q, want %q", req.Name, "Aria")
	}

	// And the server's encoder produces the same bytes, so the two stay in
	// step in both directions.
	if got := (&CharacterNameRequest{Name: "Aria"}).Encode(); string(got) != string(payload) {
		t.Fatalf("Encode gave % x, want % x", got, payload)
	}

	// The character-create payload is a different shape and must stay so:
	// it carries a gender after the name.
	if _, err := DecodeCharacterCreateRequest(payload); err == nil {
		t.Fatal("a name-only payload decoded as a character-create request; " +
			"the two shapes have merged again")
	}
}

// A name-only payload with trailing bytes is malformed, not a name with
// junk quietly ignored -- a decoder that accepted it would hide exactly the
// kind of drift above.
func TestNameOnlyRequestRejectsTrailingBytes(t *testing.T) {
	payload := append(clientNameRequest("Aria"), 0x00, 0x00)
	if _, err := DecodeCharacterNameRequest(payload); err == nil {
		t.Fatal("trailing bytes were accepted")
	}
}
