package npcspawn

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/nest"
)

func unhex(t *testing.T, s string) []byte {
	t.Helper()
	s = strings.NewReplacer(" ", "", "|", "").Replace(s)
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatalf("golden hex %q: %v", s, err)
	}
	return b
}

type goldenRecord struct {
	Hex          string  `json:"hex"`
	RefID        uint32  `json:"ref_id"`
	UID          uint32  `json:"uid"`
	Region       uint16  `json:"region"`
	X            float32 `json:"x"`
	Y            float32 `json:"y"`
	Z            float32 `json:"z"`
	Angle        uint16  `json:"angle"`
	Flags        byte    `json:"flags"`
	Name         string  `json:"name"`
	Interactions []int   `json:"interactions"`
}

func (g goldenRecord) record() Record {
	r := Record{RefID: g.RefID, UID: g.UID, Region: g.Region, X: g.X, Y: g.Y, Z: g.Z, Angle: g.Angle, Flags: g.Flags, Name: g.Name}
	for _, v := range g.Interactions {
		r.Interact = append(r.Interact, byte(v))
	}
	return r
}

type golden struct {
	RecordA           goldenRecord `json:"record_a"`
	RecordB           goldenRecord `json:"record_b"`
	GroupBeginSpawn   string       `json:"group_begin_spawn"`
	GroupBeginDespawn string       `json:"group_begin_despawn"`
	DespawnBody       string       `json:"despawn_body"`
	SingleDespawn     string       `json:"single_despawn"`
	SingleSpawnTail   string       `json:"single_spawn_tail"`
	FacingUnknown     string       `json:"facing_unknown"`
}

func loadGolden(t *testing.T) golden {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "client", "scripts", "net", "testdata", "npc_spawn_golden.json"))
	if err != nil {
		t.Fatal(err)
	}
	var g golden
	if err := json.Unmarshal(raw, &g); err != nil {
		t.Fatal(err)
	}
	return g
}

// The record, the groups and the singles against the bytes written by hand
// from the layout both binaries hold (docs/protocol/npc_spawn.md); the client
// test decodes the same bytes.
func TestGolden(t *testing.T) {
	g := loadGolden(t)
	for name, gr := range map[string]goldenRecord{"a": g.RecordA, "b": g.RecordB} {
		want := unhex(t, gr.Hex)
		if got := AppendRecord(nil, gr.record()); !bytes.Equal(got, want) {
			t.Errorf("record %s:\n got %x\nwant %x", name, got, want)
		}
		d, rest, err := DecodeRecord(want)
		if err != nil || len(rest) != 0 {
			t.Fatalf("record %s decodes: %v, %d left", name, err, len(rest))
		}
		if !reflect.DeepEqual(d.Record, gr.record()) {
			t.Errorf("record %s decoded %+v, want %+v", name, d.Record, gr.record())
		}
		if d.Life != 1 || d.MoveType != 1 || d.MoveAngle != gr.Angle || d.Param140 != 100 || d.Walk != 0 || d.Run != 0 {
			t.Errorf("record %s constants: %+v", name, d)
		}
	}
	a, b := g.RecordA.record(), g.RecordB.record()
	frames, err := SpawnGroup([]Record{a, b}, 1<<12)
	if err != nil {
		t.Fatal(err)
	}
	if len(frames) != 3 || frames[0].Opcode != 0x3017 || frames[1].Opcode != 0x3019 || frames[2].Opcode != 0x3018 {
		t.Fatalf("group spawn frames %+v", frames)
	}
	if !bytes.Equal(frames[0].Data, unhex(t, g.GroupBeginSpawn)) || len(frames[2].Data) != 0 {
		t.Errorf("group spawn begin %x / end %x", frames[0].Data, frames[2].Data)
	}
	if want := append(unhex(t, g.RecordA.Hex), unhex(t, g.RecordB.Hex)...); !bytes.Equal(frames[1].Data, want) {
		t.Errorf("group spawn body %x, want %x", frames[1].Data, want)
	}
	frames, _ = DespawnGroup([]uint32{a.UID}, 1<<12)
	if !bytes.Equal(frames[0].Data, unhex(t, g.GroupBeginDespawn)) || !bytes.Equal(frames[1].Data, unhex(t, g.DespawnBody)) {
		t.Errorf("group despawn %x %x", frames[0].Data, frames[1].Data)
	}
	if got := SingleDespawn(a.UID); !bytes.Equal(got, unhex(t, g.SingleDespawn)) {
		t.Errorf("0x3016 %x", got)
	}
	if got := SingleSpawn(a, 5); !bytes.Equal(got, append(unhex(t, g.RecordA.Hex), unhex(t, g.SingleSpawnTail)...)) {
		t.Errorf("0x3015 %x", got)
	}
	if got := FacingUnknown([]uint32{b.UID}); !bytes.Equal(got, unhex(t, g.FacingUnknown)) {
		t.Errorf("OpNpcFacingUnknown %x", got)
	}
}

// A group longer than a data frame is split over several 0x3019 and reads
// back whole, as the client's accumulation buffer (FUN_00833380) reads it.
func TestGroupChunkedRoundTrip(t *testing.T) {
	var recs []Record
	for i := 0; i < 40; i++ {
		recs = append(recs, Record{RefID: uint32(2000 + i), UID: UIDBase + uint32(i), Region: 25000, X: float32(i), Z: float32(2 * i),
			Angle: uint16(i * 1000), Flags: FlagInteractions, Interact: []byte{1, byte(i)}})
	}
	frames, err := SpawnGroup(recs, 100)
	if err != nil {
		t.Fatal(err)
	}
	if len(frames) < 10 {
		t.Fatalf("%d frames for %d records at 100 bytes a frame", len(frames), len(recs))
	}
	kind, got, _, err := DecodeGroup(frames)
	if err != nil || kind != GroupSpawn || len(got) != len(recs) {
		t.Fatalf("decoded kind %d, %d records, %v", kind, len(got), err)
	}
	for i := range recs {
		if !reflect.DeepEqual(got[i].Record, recs[i]) {
			t.Fatalf("record %d: %+v, want %+v", i, got[i].Record, recs[i])
		}
	}
	frames, _ = DespawnGroup([]uint32{1, 2, 3}, 5)
	kind, _, uids, err := DecodeGroup(frames)
	if err != nil || kind != GroupDespawn || !reflect.DeepEqual(uids, []uint32{1, 2, 3}) {
		t.Fatalf("despawn decoded %d %v %v", kind, uids, err)
	}
}

// The facing chain (docs/protocol/npc_spawn.md, "The angle"): the server's
// heading of a nest is a = wInitialDir / 65535 * 2 pi with the unit vector
// (cos a, 0, sin a); the spawn's angle is atan2 of that vector back to a u16,
// which is wInitialDir again; the client's heading h = angle + pi/2 faces
// (sin h, 0, -cos h) -- the same direction. Checked on every u16.
func TestWireAngleRoundTrip(t *testing.T) {
	worst := 0.0
	for dir := 0; dir <= 0xffff; dir++ {
		a := float64(float32(NestRadians(uint16(dir)))) // Nest_Hatch stores a float
		vx, vz := float32(math.Cos(a)), float32(math.Sin(a))
		wire := WireAngleOf(math.Atan2(float64(vz), float64(vx)))
		diff := int(wire) - dir
		if diff > 0x8000 {
			diff -= 0x10000
		} else if diff < -0x8000 {
			diff += 0x10000
		}
		if diff < -1 || diff > 1 {
			t.Fatalf("wInitialDir %d comes back as %d", dir, wire)
		}
		h := HeadingOf(wire)
		fx, fz := math.Sin(h), -math.Cos(h)
		if d := math.Hypot(fx-float64(vx), fz-float64(vz)); d > worst {
			worst = d
		}
	}
	if worst > 2e-4 {
		t.Fatalf("the client's facing differs from the server's heading by up to %g", worst)
	}
}

// The compass in the region-local frame (x east, z north): 0 faces east,
// 16384 north, 32768 west, 49152 south.
func TestCardinalAngles(t *testing.T) {
	for _, c := range []struct {
		angle  uint16
		dx, dz float64
	}{{0, 1, 0}, {16384, 0, 1}, {32768, -1, 0}, {49152, 0, -1}} {
		h := HeadingOf(c.angle)
		if math.Abs(math.Sin(h)-c.dx) > 1e-3 || math.Abs(-math.Cos(h)-c.dz) > 1e-3 {
			t.Errorf("angle %d faces (%.3f, %.3f), want (%g, %g)", c.angle, math.Sin(h), -math.Cos(h), c.dx, c.dz)
		}
	}
}

func testDB() *nest.DB {
	tactics := map[int64]*nest.TacticsRow{
		10: {ID: 10, ObjID: 2001},
		11: {ID: 11, ObjID: 2002},
		12: {ID: 12, ObjID: 9999},
		13: {ID: 13, ObjID: 2003},
	}
	nests := []nest.NestRow{
		{ID: 1, TacticsID: 10, Region: 25000, X: 100.0001, Y: 3, HasY: true, Z: 200, Dir: 16384}, // 2001's own
		{ID: 2, TacticsID: 12, Region: 25000, X: 300, Z: 300, Dir: 1},                            // another species at 2002's spot
		{ID: 3, TacticsID: 11, Region: 25000, X: 302, Z: 300, Dir: 2},                            // 2002's own, 2 away: too far
		{ID: 4, TacticsID: 10, Region: 25001, X: 100, Z: 200, Dir: 3},                            // 2001's in another region
		{ID: 5, TacticsID: 10, Region: 25000, X: 500, Z: 500, Dir: 49152},                        // 2001's second spot
		{ID: 6, TacticsID: 13, Region: 25000, X: 1000, Z: 1000, Dir: 7},                          // 2003's own, 201 off its row
	}
	return nest.NewDB(tactics, nests, nil)
}

// The join: a row takes the nest of its own species within the tolerance --
// not another species' nest at the same spot, not one in another region --
// and gets the nest's position and wInitialDir. A row with none takes, in the
// second pass, the nearest unclaimed own-species nest of its region within
// NearRadius (here 2002's, two units off). The rest keep their npcpos
// position, with no angle.
func TestPlaceJoin(t *testing.T) {
	rows := []Row{
		{RefID: 2001, Region: 25000, X: 100, Y: 0, Z: 200},
		{RefID: 2002, Region: 25000, X: 300, Y: 0, Z: 300},
		{RefID: 2001, Region: 25000, X: 500.5, Y: 0, Z: 500},
		{RefID: 2001, Region: 25000, X: 100.2, Y: 0, Z: 200}, // a second row on nest 1: taken
		{RefID: 2003, Region: 25000, X: 1201, Y: 0, Z: 1000}, // its nest 201 off: beyond NearRadius
	}
	npcs, rep := Place(rows, testDB(), nil, nil)
	if rep.Rows != 5 || rep.FromNest != 3 || rep.FromNpcpos != 2 || rep.Near != 1 || rep.NestTaken != 1 {
		t.Fatalf("report %+v", rep)
	}
	byPos := map[[2]float32]NPC{}
	for _, n := range npcs {
		if n.X == 100.2 { // the second row on nest 1
			if n.Source != FromNpcpos {
				t.Errorf("the second row on nest 1 took it too: %+v", n)
			}
			continue
		}
		byPos[[2]float32{float32(math.Round(float64(n.X))), n.Z}] = n
	}
	n := byPos[[2]float32{100, 200}]
	if n.Source != FromNest || n.NestID != 1 || n.Angle != 16384 || n.X != float32(100.0001) || n.Y != 3 {
		t.Errorf("row on nest 1: %+v", n)
	}
	if n := byPos[[2]float32{302, 300}]; n.Source != FromNest || !n.Near || n.NestID != 3 || n.Angle != 2 {
		t.Errorf("the row beside its own nest (second pass): %+v", n)
	}
	if n := byPos[[2]float32{1201, 1000}]; n.Source != FromNpcpos || n.Angle != 0 {
		t.Errorf("the row 201 from its nest: %+v", n)
	}
	if n := byPos[[2]float32{500, 500}]; n.Source != FromNest || n.Angle != 49152 || n.NestID != 5 {
		t.Errorf("row on nest 5: %+v", n)
	}
	uids := map[uint32]bool{}
	for _, n := range npcs {
		if uids[n.UID] || n.UID < UIDBase {
			t.Errorf("uid %#x repeated or out of range", n.UID)
		}
		uids[n.UID] = true
	}
	npcs, rep = Place(rows, nil, nil, nil)
	if rep.FromNest != 0 || rep.FromNpcpos != 5 {
		t.Fatalf("no DB: %+v", rep)
	}
	for _, n := range npcs {
		if n.Source != FromNpcpos || n.Angle != 0 {
			t.Errorf("no DB: %+v", n)
		}
	}
}

// The interaction rules of CGObjNPCNPC::Create, by strstr on the code.
func TestInteractions(t *testing.T) {
	for _, c := range []struct {
		code  string
		in    InteractionInputs
		flags byte
		ids   []byte
	}{
		{"NPC_CH_SMITH", InteractionInputs{}, 2, []byte{4, 0x20}},
		{"NPC_CH_ARMOR", InteractionInputs{}, 2, []byte{4}},
		{"NPC_CH_WAREHOUSE_M", InteractionInputs{}, 2, []byte{1, 3}},
		// Round 727: NPC_CH_HORSE and NPC_CH_GENARAL_SW are quest NPCs (id 2).
		{"NPC_CH_HORSE", InteractionInputs{}, 2, []byte{1, 2, 0x0b}},
		{"NPC_CH_SOLDIER_EM1", InteractionInputs{}, 2, []byte{0x1e}},
		{"NPC_CH_GENARAL_SW", InteractionInputs{}, 2, []byte{2, 0x0e, 0x16}},
		// The herbalist (round 727): its shop gives 1 (0x4c7920), the potion
		// quests 2 -- the original's "Talk to this person." and
		// "Purchase/ Sell ..." lines. No longer 0x11.
		{"NPC_CH_POTION", InteractionInputs{OwnsShop: true}, 2, []byte{1, 2}},
		{"NPC_CH_POTION", InteractionInputs{}, 2, []byte{2}},
		{"NPC_CH_POTION2", InteractionInputs{}, 0, nil},
		// A teleport NPC with no rule and no quest: 7 and 9 are in its set,
		// but nothing set bit 1: the spawn record writes no list, the select
		// reply (the whole set) still carries them.
		{"NPC_WC_FERRY", InteractionInputs{Teleport7: true, Teleport9: true}, 0, []byte{7, 9}},
		// A ferry a quest names: bit 1 set, so its teleport ids go out too.
		{"NPC_CH_FERRY", InteractionInputs{Teleport7: true, Teleport9: true, Teleport8: true}, 2, []byte{2, 7, 8, 9}},
		// With a rule, the set carries them.
		{"NPC_CH_SOLDIER_EM1", InteractionInputs{Teleport9: true}, 2, []byte{9, 0x1e}},
		{"NPC_BATTLE_ARENA_MANAGER", InteractionInputs{}, 2, []byte{0x21}},
		{"NPC_BATTLE_ARENA_EXCHANGER", InteractionInputs{}, 2, []byte{0x22}},
		{"npc_siege_dungeon_teleport", InteractionInputs{}, 2, []byte{0x28}},
		{"NPC_SIEGE_DUNGEON_TELEPORT_X", InteractionInputs{}, 0, nil},
		{"STRUCTURE_GATE_PULLEY_JA_02", InteractionInputs{}, 2, []byte{0x1f}},
		{"NPC_CH_GACHA_OPERATOR", InteractionInputs{}, 2, []byte{0x12}},
	} {
		f, ids := Interactions(c.code, c.in)
		if f != c.flags || !bytes.Equal(ids, c.ids) {
			t.Errorf("%s %+v: flags %d ids %v, want %d %v", c.code, c.in, f, ids, c.flags, c.ids)
		}
	}
}

func TestTableRoundTrip(t *testing.T) {
	csv := strings.Join(CSVColumns, ",") + "\n2001,NPC_CH_SMITH,1,2,2,0,1\n2002,STRUCTURE_X,1,2,2,1,0\n"
	tab, err := Read(strings.NewReader(csv))
	if err != nil {
		t.Fatal(err)
	}
	if tab[2001].Code != "NPC_CH_SMITH" || !tab[2001].Shop || tab[2002].TypeID4 != 1 || tab[2002].Shop {
		t.Fatalf("%+v", tab)
	}
	if _, err := Read(strings.NewReader("ID,Code\n")); err == nil {
		t.Fatal("a wrong header loads")
	}
	cols := make([]string, 20)
	cols[1], cols[2], cols[9], cols[10], cols[11], cols[12] = "2031", "NPC_X", "1", "2", "2", "0"
	if r, _, ok := ExportRow(cols); !ok || r.ID != 2031 || r.Code != "NPC_X" {
		t.Fatalf("ExportRow %+v %v", r, ok)
	}
	cols[11] = "1" // a monster
	if _, _, ok := ExportRow(cols); ok {
		t.Fatal("a (1,2,1,0) row exports as an NPC")
	}
}
