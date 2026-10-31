package session

import (
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// lobbyGoldenPath is the vector file the Godot client's lobby_test.gd reads
// too (client/scripts/net/testdata): both sides encode the same fields to the
// same bytes and decode the same bytes to the same fields.
func lobbyGoldenPath() string {
	return filepath.Join("..", "..", "..", "client", "scripts", "net", "testdata", "lobby_golden.json")
}

type goldenItem struct {
	ID   uint32 `json:"id"`
	Plus uint8  `json:"plus"`
	Own  uint32 `json:"own"` // round 847: the list's own-id trailer (OURS)
}

type goldenCharacter struct {
	RefObjID     uint32       `json:"ref_obj_id"`
	Name         string       `json:"name"`
	Scale        uint8        `json:"scale"`
	Level        uint8        `json:"level"`
	Exp          uint64       `json:"exp"`
	Str          uint16       `json:"str"`
	Int          uint16       `json:"int"`
	StatPoints   uint16       `json:"stat_points"`
	HP           uint32       `json:"hp"`
	MP           uint32       `json:"mp"`
	Deleting     bool         `json:"deleting"`
	MinutesLeft  uint32       `json:"minutes_left"`
	GuildClass   uint8        `json:"guild_class"`
	GuildRename  bool         `json:"guild_rename"`
	GuildName    string       `json:"guild_name"`
	AcademyClass uint8        `json:"academy_class"`
	Items        []goldenItem `json:"items"`
	Avatars      []goldenItem `json:"avatars"`
}

type goldenFields struct {
	Action     uint8             `json:"action"`
	Name       string            `json:"name"`
	RefObjID   uint32            `json:"ref_obj_id"`
	Scale      uint8             `json:"scale"`
	Chest      uint32            `json:"chest"`
	Legs       uint32            `json:"legs"`
	Feet       uint32            `json:"feet"`
	Weapon     uint32            `json:"weapon"`
	OK         bool              `json:"ok"`
	Code       uint16            `json:"code"`
	Characters []goldenCharacter `json:"characters"`
}

type goldenVector struct {
	Name   string       `json:"name"`
	Kind   string       `json:"kind"`
	Fields goldenFields `json:"fields"`
	Hex    string       `json:"hex"`
	Error  bool         `json:"error"`
}

type goldenFile struct {
	Opcodes map[string]uint16 `json:"opcodes"`
	Vectors []goldenVector    `json:"vectors"`
}

func loadLobbyGolden(t *testing.T) goldenFile {
	t.Helper()
	b, err := os.ReadFile(lobbyGoldenPath())
	if err != nil {
		t.Fatal(err)
	}
	var f goldenFile
	if err := json.Unmarshal(b, &f); err != nil {
		t.Fatal(err)
	}
	return f
}

func goldenBytes(t *testing.T, s string) []byte {
	t.Helper()
	clean := strings.NewReplacer(" ", "", "|", "").Replace(s)
	b, err := hex.DecodeString(clean)
	if err != nil {
		t.Fatalf("hex %q: %v", s, err)
	}
	return b
}

func items(in []goldenItem) []LobbyItem {
	var out []LobbyItem
	for _, it := range in {
		out = append(out, LobbyItem{RefItemID: it.ID, Plus: it.Plus, Own: it.Own})
	}
	return out
}

func (f goldenFields) lobbyResult() *LobbyResult {
	r := &LobbyResult{Action: f.Action, OK: f.OK, Code: f.Code}
	for _, c := range f.Characters {
		r.Characters = append(r.Characters, LobbyCharacter{
			RefObjID: c.RefObjID, Name: c.Name, Scale: c.Scale, Level: c.Level, Exp: c.Exp,
			Str: c.Str, Int: c.Int, StatPoints: c.StatPoints, HP: c.HP, MP: c.MP,
			Deleting: c.Deleting, MinutesLeft: c.MinutesLeft,
			GuildClass: c.GuildClass, GuildRename: c.GuildRename, GuildName: c.GuildName, AcademyClass: c.AcademyClass,
			Items: items(c.Items), Avatars: items(c.Avatars),
		})
	}
	return r
}

// TestLobbyGolden: every message, both directions, against bytes written by
// hand from the READ layouts. NEGATIVE: before round 682 there is no lobby
// codec (lobby.go) and this file does not compile.
func TestLobbyGolden(t *testing.T) {
	f := loadLobbyGolden(t)
	if f.Opcodes["lobby"] != OpLobby || f.Opcodes["lobby_result"] != OpLobbyResult ||
		f.Opcodes["start"] != OpStart || f.Opcodes["start_result"] != OpStartResult {
		t.Fatalf("opcodes %v", f.Opcodes)
	}
	kinds := map[string]int{}
	for _, v := range f.Vectors {
		want := goldenBytes(t, v.Hex)
		kinds[v.Kind]++
		t.Run(v.Name, func(t *testing.T) {
			switch v.Kind {
			case "lobby_request":
				got, err := DecodeLobbyRequest(want)
				if v.Error {
					if err == nil {
						t.Fatalf("decoded %+v from a malformed payload", got)
					}
					return
				}
				req := &LobbyRequest{Action: v.Fields.Action, Name: v.Fields.Name, RefObjID: v.Fields.RefObjID, Scale: v.Fields.Scale,
					Chest: v.Fields.Chest, Legs: v.Fields.Legs, Feet: v.Fields.Feet, Weapon: v.Fields.Weapon}
				if enc := req.Encode(); string(enc) != string(want) {
					t.Fatalf("encode\n got % x\nwant % x", enc, want)
				}
				if err != nil || !reflect.DeepEqual(got, req) {
					t.Fatalf("decode %+v %v, want %+v", got, err, req)
				}
			case "lobby_result":
				got, err := DecodeLobbyResult(want)
				if v.Error {
					if err == nil {
						t.Fatalf("decoded %+v from a malformed payload", got)
					}
					return
				}
				res := v.Fields.lobbyResult()
				if enc := res.Encode(); string(enc) != string(want) {
					t.Fatalf("encode\n got % x\nwant % x", enc, want)
				}
				if err != nil || !reflect.DeepEqual(got, res) {
					t.Fatalf("decode %+v %v, want %+v", got, err, res)
				}
			case "start_request":
				got, err := DecodeStartRequest(want)
				req := &StartRequest{Name: v.Fields.Name}
				if enc := req.Encode(); string(enc) != string(want) {
					t.Fatalf("encode\n got % x\nwant % x", enc, want)
				}
				if err != nil || *got != *req {
					t.Fatalf("decode %+v %v", got, err)
				}
			case "start_result":
				got, err := DecodeStartResult(want)
				if v.Error {
					if err == nil {
						t.Fatalf("decoded %+v from a malformed payload", got)
					}
					return
				}
				res := &StartResult{OK: v.Fields.OK, Code: v.Fields.Code}
				if enc := res.Encode(); string(enc) != string(want) {
					t.Fatalf("encode\n got % x\nwant % x", enc, want)
				}
				if err != nil || *got != *res {
					t.Fatalf("decode %+v %v", got, err)
				}
			default:
				t.Fatalf("kind %q", v.Kind)
			}
		})
	}
	for _, k := range []string{"lobby_request", "lobby_result", "start_request", "start_result"} {
		if kinds[k] == 0 {
			t.Errorf("no %s vector", k)
		}
	}
}
