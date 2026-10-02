package session

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestRound689ModelGolden holds the encoders and decoders to the hand-written
// bytes client/scripts/net/world_test.gd holds the client's decoders to.
func TestRound689ModelGolden(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "client", "scripts", "net", "testdata", "world_model_golden.json"))
	if err != nil {
		t.Fatal(err)
	}
	var file struct {
		Vectors []struct {
			Name, Kind, Hex string
		}
	}
	if err := json.Unmarshal(raw, &file); err != nil {
		t.Fatal(err)
	}
	bram := EntitySnapshot{CharacterID: 1, Name: "Bram", Gender: "china_woman", Heading: math.Pi, HasHeading: true,
		RefObjID: 1925, Scale: 0x40, HasModel: true}
	built := map[string][]byte{
		"entity_entered": (&EntitySnapshot{CharacterID: 7, Name: "Aria", X: 1, Y: 2, Z: 3, Gender: "europe_man",
			Heading: math.Pi, HasHeading: true, RefObjID: 14875, Scale: 0x14, HasModel: true}).EncodeEntered(),
		"enter_world_result": (&EnterWorldResult{OK: true, Zone: "jangan", Gender: "europe_woman", HP: 1, MaxHP: 1,
			Others: []EntitySnapshot{bram}, FrameRegion: "97/168", Heading: math.Pi / 2, HasHeading: true,
			RefObjID: 14888, Scale: 0x03, HasModel: true}).Encode(),
		"change_zone_result": (&ChangeZoneResult{OK: true, Zone: "hotan", Others: []EntitySnapshot{bram}, FrameRegion: "92/135"}).Encode(),
	}
	if len(file.Vectors) != len(built) {
		t.Fatalf("%d golden vectors, want %d", len(file.Vectors), len(built))
	}
	for _, v := range file.Vectors {
		want, err := hex.DecodeString(strings.NewReplacer(" ", "", "|", "").Replace(v.Hex))
		if err != nil {
			t.Fatalf("%s: %v", v.Name, err)
		}
		if got := built[v.Kind]; !bytes.Equal(got, want) {
			t.Errorf("%s: encodes\n % x\nwant\n % x", v.Name, got, want)
		}
		switch v.Kind {
		case "entity_entered":
			e, err := DecodeEntityEntered(want)
			if err != nil || !e.HasModel || e.RefObjID != 14875 || e.Scale != 0x14 {
				t.Errorf("%s: decodes %+v, %v", v.Name, e, err)
			}
		case "enter_world_result":
			r, err := DecodeEnterWorldResult(want)
			if err != nil || r.RefObjID != 14888 || r.Scale != 3 || len(r.Others) != 1 || r.Others[0].RefObjID != 1925 || r.Others[0].Scale != 0x40 {
				t.Errorf("%s: decodes %+v, %v", v.Name, r, err)
			}
		case "change_zone_result":
			r, err := DecodeChangeZoneResult(want)
			if err != nil || len(r.Others) != 1 || r.Others[0].RefObjID != 1925 || r.Others[0].Scale != 0x40 {
				t.Errorf("%s: decodes %+v, %v", v.Name, r, err)
			}
		}
	}
}
