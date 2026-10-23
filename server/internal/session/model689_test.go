package session

import (
	"bufio"
	"bytes"
	"context"
	"math"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Round 689 (charselect.md lane W): the world messages carry each character's
// model -- RefObjID and the scale byte -- in trailing tails an older client
// never reads, so the client draws a Europe body as a Europe body.

// The codecs: every tail round-trips, a payload built without a model is byte
// for byte the older one, and the older decoders read the same fields from the
// new payloads.
func TestRound689ModelTailsRoundTrip(t *testing.T) {
	snap := EntitySnapshot{CharacterID: 7, Name: "Aria", X: 1, Y: 2, Z: 3, Gender: "europe_man",
		Heading: math.Pi, HasHeading: true, RefObjID: 14875, Scale: 0x14, HasModel: true}
	got, err := DecodeEntityEntered(snap.EncodeEntered())
	if err != nil || !got.HasModel || got.RefObjID != 14875 || got.Scale != 0x14 || !got.HasHeading {
		t.Fatalf("OpEntityEntered round trip gave %+v, %v; want model 14875 scale 0x14 and the heading", got, err)
	}
	// Built without a model it is the round-637 payload exactly (snapshot +
	// angle), and that decodes with HasModel false.
	plain := snap
	plain.HasModel = false
	old := plain.EncodeEntered()
	if !bytes.Equal(snap.EncodeEntered()[:len(old)], old) || len(snap.EncodeEntered()) != len(old)+5 {
		t.Fatalf("the model is not the older payload plus 5 bytes:\n old % x\n new % x", old, snap.EncodeEntered())
	}
	if o, err := DecodeEntityEntered(old); err != nil || o.HasModel {
		t.Fatalf("an older server's payload decodes with a model: %+v, %v", o, err)
	}

	others := []EntitySnapshot{
		{CharacterID: 1, Name: "Bram", Gender: "china_woman", Heading: math.Pi / 2, HasHeading: true, RefObjID: 1925, Scale: 0x40, HasModel: true},
		{CharacterID: 2, Name: "Cyra", Gender: "china_man", Heading: 0, HasHeading: true},
	}
	ew := &EnterWorldResult{OK: true, Zone: "jangan", Gender: "europe_man", HP: 1, MaxHP: 1, Others: others,
		FrameRegion: "97/168", Heading: math.Pi, HasHeading: true, RefObjID: 14888, Scale: 0x03, HasModel: true}
	g, err := DecodeEnterWorldResult(ew.Encode())
	if err != nil || !g.HasModel || g.RefObjID != 14888 || g.Scale != 0x03 || len(g.Others) != 2 {
		t.Fatalf("EnterWorldResult round trip: %+v, %v", g, err)
	}
	if o := g.Others[0]; !o.HasModel || o.RefObjID != 1925 || o.Scale != 0x40 {
		t.Errorf("other 0 decodes model %d/%#x (has %v), want 1925/0x40", o.RefObjID, o.Scale, o.HasModel)
	}
	if g.Others[1].HasModel {
		t.Errorf("other 1 was sent without a model and decodes with one: %+v", g.Others[1])
	}
	// The older decoder's last field is the own wire angle: the new payload
	// is the round-637 one plus the models tail (own 5, count 2, 2 x 5).
	ewOld := *ew
	ewOld.HasModel = false
	ewOld.Others = []EntitySnapshot{others[0], others[1]}
	ewOld.Others[0].HasModel = false
	oldBytes := ewOld.Encode()
	newBytes := ew.Encode()
	if !bytes.HasPrefix(newBytes, oldBytes) || len(newBytes) != len(oldBytes)+5+2+2*5 {
		t.Fatalf("the EnterWorldResult models tail is not appended after the wire angle:\n old % x\n new % x", oldBytes, newBytes)
	}

	// A ChangeZoneResult with nobody there still writes Seated and the
	// headings (both counts 0) when models follow -- and with nobody there
	// no model is sent at all, so it is the older payload.
	empty := (&ChangeZoneResult{OK: true, Zone: "hotan", FrameRegion: "92/135"}).Encode()
	if gz, err := DecodeChangeZoneResult(empty); err != nil || len(gz.Others) != 0 {
		t.Fatalf("an empty ChangeZoneResult: %+v, %v", gz, err)
	}
	cz := &ChangeZoneResult{OK: true, Zone: "hotan", Others: others[:1], FrameRegion: "92/135"}
	gz, err := DecodeChangeZoneResult(cz.Encode())
	if err != nil || len(gz.Others) != 1 || !gz.Others[0].HasModel || gz.Others[0].RefObjID != 1925 {
		t.Fatalf("ChangeZoneResult round trip: %+v, %v", gz, err)
	}
	// A models count that does not match the list is refused.
	b := cz.Encode()
	b[len(b)-7] = 2
	if _, err := DecodeChangeZoneResult(b); err == nil {
		t.Fatal("a models count that does not match the list decoded")
	}
}

// The flows: a Europe man and a China woman made through the lobby path enter;
// each one's own result carries its own model, the one already there hears the
// newcomer's OpEntityEntered with its model, the newcomer's arrival list
// carries the first one's, and a zone change's list and arrival carry them
// too. A legacy row (Store.Create) draws its migrated body, 1909 at 0x22.
func TestRound689WorldMessagesCarryTheModel(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	accounts.Add("bob", "hunter3")
	accounts.Add("carol", "hunter4")
	chars := character.NewMemStore()
	aria, err := chars.CreateCharacter(ctx, 1, character.NewCharacter{Name: "Aria", RefObjID: 14875, Scale: 0x14, Gender: character.GenderEuropeMan})
	if err != nil {
		t.Fatal(err)
	}
	bram, err := chars.CreateCharacter(ctx, 2, character.NewCharacter{Name: "Bram", RefObjID: 1925, Scale: 0x40, Gender: character.GenderChinaWoman})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := chars.Create(ctx, 3, "Cyra"); err != nil {
		t.Fatal(err)
	}
	hub := world.NewHub()
	handle := gateway.Chain(LoginHandler(accounts), WorldHandlerWithHook(chars, nil, hub, nil, nil))
	addr, cleanup := startTestServer(t, handle)
	t.Cleanup(cleanup)
	f := &deadWorldFixture{chars: chars, hub: hub, aria: aria.ID, bram: bram.ID}
	f.connA = dialTestServer(t, addr)
	t.Cleanup(func() { f.connA.Close() })
	f.rA = bufio.NewReader(f.connA)
	f.connB = dialTestServer(t, addr)
	t.Cleanup(func() { f.connB.Close() })
	f.rB = bufio.NewReader(f.connB)

	a := f.login(t, f.connA, f.rA, "alice", "hunter2", "Aria")
	if !a.HasModel || a.RefObjID != 14875 || a.Scale != 0x14 {
		t.Fatalf("Aria's own result carries model %d/%#x (has %v), want 14875/0x14", a.RefObjID, a.Scale, a.HasModel)
	}
	b := f.login(t, f.connB, f.rB, "bob", "hunter3", "Bram")
	if !b.HasModel || b.RefObjID != 1925 || b.Scale != 0x40 {
		t.Fatalf("Bram's own result carries model %d/%#x, want 1925/0x40", b.RefObjID, b.Scale)
	}
	// Round 737: the players in view are not in the result any more; each
	// arrives as retail's spawn record, whose RefObjID and scale byte are the
	// model (pcspawn: the record's first u32 and the byte after it).
	if len(b.Others) != 0 {
		t.Fatalf("Bram's result lists %+v; the players in view follow it as spawns", b.Others)
	}
	if r := expectPlayerSpawn(t, f.connB, f.rB, f.aria)[0]; r.RefObjID != 14875 || r.Scale != 0x14 || r.Name != "Aria" {
		t.Fatalf("Bram's spawn of Aria: %+v, want model 14875/0x14", r)
	}
	if r := expectPlayerSpawn(t, f.connA, f.rA, f.bram)[0]; r.RefObjID != 1925 || r.Scale != 0x40 || r.Name != "Bram" {
		t.Fatalf("Aria's spawn of Bram: %+v; want model 1925/0x40", r)
	}

	// Bram changes zone and back: his spawn of Aria names her model, and
	// Aria's of him his.
	if czr := changeZone(t, f, f.connB, f.rB, "donwhang"); !czr.OK {
		t.Fatalf("Bram's change to donwhang refused: %+v", czr)
	}
	expectPlayerDespawn(t, f.connA, f.rA, f.bram)
	czr := changeZone(t, f, f.connB, f.rB, "jangan")
	if !czr.OK || len(czr.Others) != 0 {
		t.Fatalf("Bram's change back: %+v, want OK with no list", czr)
	}
	if r := expectPlayerSpawn(t, f.connB, f.rB, f.aria)[0]; r.RefObjID != 14875 {
		t.Fatalf("Bram's spawn of Aria after the change back: %+v, want model 14875", r)
	}
	if r := expectPlayerSpawn(t, f.connA, f.rA, f.bram)[0]; r.RefObjID != 1925 {
		t.Fatalf("Aria hears Bram come back as %+v; want model 1925", r)
	}

	// A legacy row: Cyra, made through Store.Create, is the migrated body.
	connC := dialTestServer(t, addr)
	t.Cleanup(func() { connC.Close() })
	rC := bufio.NewReader(connC)
	c := f.login(t, connC, rC, "carol", "hunter4", "Cyra")
	if !c.HasModel || int64(c.RefObjID) != character.ModelChinaManFighter || c.Scale != character.DefaultScale {
		t.Fatalf("Cyra's own model is %d/%#x, want the legacy %d/%#x", c.RefObjID, c.Scale, character.ModelChinaManFighter, character.DefaultScale)
	}
}

// modelOf gives a row without a model the body its Gender was migrated to.
func TestRound689ModelOfALegacyRow(t *testing.T) {
	for _, tc := range []struct {
		c     character.Character
		ref   uint32
		scale uint8
	}{
		{character.Character{Gender: character.GenderChinaWoman}, 1923, 0x22},
		{character.Character{Gender: character.GenderChinaMan, Scale: 0x22}, 1909, 0x22},
		{character.Character{RefObjID: 14900, Scale: 0x44}, 14900, 0x44},
		{character.Character{RefObjID: 14900, Scale: 300}, 14900, 0x22},
	} {
		ref, scale := modelOf(&tc.c)
		if ref != tc.ref || scale != tc.scale {
			t.Errorf("modelOf(%+v) = %d/%#x, want %d/%#x", tc.c, ref, scale, tc.ref, tc.scale)
		}
	}
}

// Round 689's review: a result with a model but no heading still writes the
// own wire angle the models tail follows -- the encoder sets HasHeading itself
// -- so the model is read back where it was written, and the heading is the
// result's own Heading rather than a stray byte pair.
func TestRound689AModelForcesTheOwnHeading(t *testing.T) {
	ew := &EnterWorldResult{OK: true, Zone: "jangan", Gender: "europe_man", HP: 1, MaxHP: 1,
		FrameRegion: "97/168", Heading: math.Pi, RefObjID: 14875, Scale: 0x24, HasModel: true}
	got, err := DecodeEnterWorldResult(ew.Encode())
	if err != nil || !got.HasModel || got.RefObjID != 14875 || got.Scale != 0x24 {
		t.Fatalf("a model without a heading: %+v, %v", got, err)
	}
	if !got.HasHeading || math.Abs(got.Heading-math.Pi) > 1e-4 {
		t.Errorf("the own heading decodes as %v (has %v), want the result's own pi", got.Heading, got.HasHeading)
	}
	if ew.HasHeading {
		t.Error("Encode changed the caller's result")
	}
	with := *ew
	with.HasHeading = true
	if !bytes.Equal(ew.Encode(), with.Encode()) {
		t.Error("a model without HasHeading does not encode as the same result with it")
	}
}
