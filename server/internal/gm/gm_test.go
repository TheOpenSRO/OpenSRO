package gm

import (
	"context"
	"strings"
	"testing"

	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/equipment"
	"github.com/OpenSRO/srrevamp/server/internal/inventory"
	"github.com/OpenSRO/srrevamp/server/internal/leveldata"
	"github.com/OpenSRO/srrevamp/server/internal/mana"
	"github.com/OpenSRO/srrevamp/server/internal/refdata"
	"github.com/OpenSRO/srrevamp/server/internal/skill"
)

// The gate is a plain username list: trimmed, case kept, nobody by default.
func TestGate(t *testing.T) {
	if (*Gate)(nil).Allows("alice") {
		t.Fatal("a nil gate allowed someone")
	}
	if ParseAccounts("").Allows("alice") || ParseAccounts("").Allows("") {
		t.Fatal("an empty list allowed someone")
	}
	g := ParseAccounts(" opensro, opensrogm ,,")
	for _, name := range []string{"opensro", "opensrogm"} {
		if !g.Allows(name) {
			t.Errorf("%q should be allowed", name)
		}
	}
	for _, name := range []string{"Opensro", "OPENSROGM", "", " ", "opensr"} {
		if g.Allows(name) {
			t.Errorf("%q should be refused", name)
		}
	}
	if got := strings.Join(g.Names(), ","); got != "opensro,opensrogm" {
		t.Errorf("Names() = %q", got)
	}
}

type fixture struct {
	ctx    context.Context
	deps   *Deps
	chars  *character.MemStore
	inv    *inventory.MemStore
	equip  *equipment.MemStore
	skills *skill.MemStore
	hub    *combat.Hub
	actor  Actor
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	ctx := context.Background()
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	items := refdata.NewMemStore()
	if err := items.ImportItems(ctx, []refdata.Item{{ID: 3, MaxStack: 50}, {ID: 3645, MaxStack: 1, TypeID1: 3, TypeID2: 1, TypeID3: 6, TypeID4: 2}}); err != nil {
		t.Fatalf("ImportItems: %v", err)
	}
	inv := inventory.NewMemStore(items)
	equip := equipment.NewMemStore(inv)
	skills := skill.NewMemStore()
	hub := combat.NewHub()
	tbl, err := leveldata.ParseCSV(strings.NewReader(
		"level,exp,mastery_sp,exp_unit\n1,10,1,1\n2,20,1,2\n3,30,1,3\n4,40,1,4\n5,50,1,5\n"))
	if err != nil {
		t.Fatalf("ParseCSV: %v", err)
	}
	deps := &Deps{
		Chars: chars, Inv: inv, Equip: equip, Items: items, Skills: skills,
		Monsters: hub, Mana: mana.NewTracker(), Levels: tbl,
		Species: []Species{{
			Species: combat.Species{Name: "Mangyang", CodeName: "MOB_CH_MANGYANG", Level: 1},
			Zone:    "jangan", MaxHP: 60, Defense: 1, Attack: 5, Gold: 10, X: 100, Z: 200,
		}},
		Zones: []string{"jangan", "donwhang"},
	}
	actor := Actor{Account: "alice", CharacterID: c.ID, Name: "Aria", Zone: "jangan", X: 10, Z: 20}
	return &fixture{ctx: ctx, deps: deps, chars: chars, inv: inv, equip: equip, skills: skills, hub: hub, actor: actor}
}

func (f *fixture) run(t *testing.T, line string) Result {
	t.Helper()
	return f.deps.Run(f.ctx, f.actor, line)
}

func TestUnknownAndEmptyCommandsAreRefusedWithTheHelpLine(t *testing.T) {
	f := newFixture(t)
	for _, line := range []string{"", "/", "/frobnicate 1", "frobnicate"} {
		res := f.run(t, line)
		if !res.Refused || !strings.Contains(res.Text, "/tp <x> <z>") {
			t.Errorf("%q: got %+v, want a refusal carrying the help line", line, res)
		}
	}
}

func TestTp(t *testing.T) {
	f := newFixture(t)
	res := f.run(t, "/tp -300 -880")
	if res.Refused || !res.HasPos || res.X != -300 || res.Z != -880 || res.Zone != "" {
		t.Fatalf("/tp: %+v", res)
	}
	for _, bad := range []string{"/tp", "/tp 1", "/tp a b", "/tp 1 2 3", "/tp NaN 1"} {
		if res := f.run(t, bad); !res.Refused || res.HasPos {
			t.Errorf("%q should be refused: %+v", bad, res)
		}
	}
	out := f.actor
	out.Zone = ""
	if res := f.deps.Run(f.ctx, out, "/tp 1 2"); !res.Refused {
		t.Errorf("/tp outside the world should be refused: %+v", res)
	}
}

func TestGoto(t *testing.T) {
	f := newFixture(t)
	if res := f.run(t, "/goto donwhang"); res.Refused || res.Zone != "donwhang" || res.HasPos {
		t.Fatalf("/goto zone: %+v", res)
	}
	if res := f.run(t, "/goto jangan"); !res.Refused {
		t.Fatalf("/goto the current zone should be refused: %+v", res)
	}
	if res := f.run(t, "/goto mangyang"); res.Refused || !res.HasPos || res.X != 100 || res.Z != 200 || res.Zone != "" {
		t.Fatalf("/goto species in the same zone: %+v", res)
	}
	if res := f.run(t, "/goto MOB_CH_MANGYANG"); res.Refused || !res.HasPos {
		t.Fatalf("/goto by code name: %+v", res)
	}
	if res := f.run(t, "/goto nowhere"); !res.Refused || !strings.Contains(res.Text, "jangan") {
		t.Fatalf("/goto unknown should list the places: %+v", res)
	}
}

func TestGiveChecksTheItemTableAndAddsToTheBag(t *testing.T) {
	f := newFixture(t)
	if res := f.run(t, "/give 999999"); !res.Refused || !strings.Contains(res.Text, "unknown item id 999999") {
		t.Fatalf("unknown id: %+v", res)
	}
	if res := f.run(t, "/give 3 5"); res.Refused || !res.RefreshInventory {
		t.Fatalf("/give 3 5: %+v", res)
	}
	bag, err := f.inv.List(f.ctx, f.actor.CharacterID)
	if err != nil {
		t.Fatal(err)
	}
	if len(bag) != 1 || bag[0].ItemID != 3 || bag[0].Quantity != 5 {
		t.Fatalf("bag after /give 3 5: %+v", bag)
	}
	for _, bad := range []string{"/give", "/give x", "/give 3 0", "/give 3 -1", "/give 3 1 2"} {
		if res := f.run(t, bad); !res.Refused {
			t.Errorf("%q should be refused: %+v", bad, res)
		}
	}
	noItems := *f.deps
	noItems.Items = nil
	if res := noItems.Run(f.ctx, f.actor, "/give 3"); !res.Refused || !strings.Contains(res.Text, "no item table") {
		t.Fatalf("without an item table: %+v", res)
	}
}

func TestGold(t *testing.T) {
	f := newFixture(t)
	before, _ := f.chars.GetByID(f.ctx, f.actor.CharacterID)
	if res := f.run(t, "/gold 1500"); res.Refused || !strings.Contains(res.Text, "gold now") {
		t.Fatalf("/gold 1500: %+v", res)
	}
	after, _ := f.chars.GetByID(f.ctx, f.actor.CharacterID)
	if after.Gold != before.Gold+1500 {
		t.Fatalf("gold %d, want %d", after.Gold, before.Gold+1500)
	}
	if res := f.run(t, "/gold -500"); res.Refused {
		t.Fatalf("/gold -500: %+v", res)
	}
	after, _ = f.chars.GetByID(f.ctx, f.actor.CharacterID)
	if after.Gold != before.Gold+1000 {
		t.Fatalf("gold after taking 500: %d, want %d", after.Gold, before.Gold+1000)
	}
	if res := f.run(t, "/gold -999999999"); !res.Refused {
		t.Fatalf("taking more than owned should be refused: %+v", res)
	}
	for _, bad := range []string{"/gold", "/gold 0", "/gold x"} {
		if res := f.run(t, bad); !res.Refused {
			t.Errorf("%q should be refused: %+v", bad, res)
		}
	}
}

// /level applies the combat path's own level-up arithmetic: three spendable
// points and one Str and one Int per level, HP back to the new maximum.
func TestLevelFollowsTheLevelUpArithmetic(t *testing.T) {
	f := newFixture(t)
	before, _ := f.chars.GetByID(f.ctx, f.actor.CharacterID)
	if before.Level != 1 {
		t.Fatalf("a new character is level %d, the test assumes 1", before.Level)
	}
	res := f.run(t, "/level 4")
	if res.Refused || res.LevelUp == nil || res.LevelUp.NewLevel != 4 || !res.RefreshStats {
		t.Fatalf("/level 4: %+v", res)
	}
	after, _ := f.chars.GetByID(f.ctx, f.actor.CharacterID)
	gained := 3
	if after.Level != 4 || after.Exp != 0 {
		t.Fatalf("level/exp after: %d/%d", after.Level, after.Exp)
	}
	if after.StatPoints != before.StatPoints+gained*leveldata.StatPointsPerLevel {
		t.Fatalf("stat points %d, want %d", after.StatPoints, before.StatPoints+gained*leveldata.StatPointsPerLevel)
	}
	if after.Str != before.Str+gained*character.StatGrowthPerLevel || after.Int != before.Int+gained*character.StatGrowthPerLevel {
		t.Fatalf("Str/Int %d/%d, want %d/%d", after.Str, after.Int, before.Str+gained, before.Int+gained)
	}
	if after.HP != after.MaxHP() {
		t.Fatalf("HP %d after a level-up, want the new maximum %d", after.HP, after.MaxHP())
	}
	if res.LevelUp.StatPoints != after.StatPoints {
		t.Fatalf("announced stat points %d, stored %d", res.LevelUp.StatPoints, after.StatPoints)
	}
	if res := f.run(t, "/level 4"); !res.Refused {
		t.Fatalf("the same level again should be refused: %+v", res)
	}
	if res := f.run(t, "/level 2"); !res.Refused {
		t.Fatalf("levelling down should be refused: %+v", res)
	}
	if res := f.run(t, "/level 6"); !res.Refused || !strings.Contains(res.Text, "ends at 5") {
		t.Fatalf("past the table should be refused: %+v", res)
	}
	noTable := *f.deps
	noTable.Levels = nil
	if res := noTable.Run(f.ctx, f.actor, "/level 5"); !res.Refused || !strings.Contains(res.Text, "no level table") {
		t.Fatalf("without a level table: %+v", res)
	}
}

func TestHealRefillsHP(t *testing.T) {
	f := newFixture(t)
	if _, _, err := f.chars.ApplyDamage(f.ctx, f.actor.CharacterID, 5); err != nil {
		t.Fatal(err)
	}
	hurt, _ := f.chars.GetByID(f.ctx, f.actor.CharacterID)
	if hurt.HP == hurt.MaxHP() {
		t.Fatal("damage did not land, the test cannot see a heal")
	}
	res := f.run(t, "/heal")
	if res.Refused || !res.RefreshStats {
		t.Fatalf("/heal: %+v", res)
	}
	healed, _ := f.chars.GetByID(f.ctx, f.actor.CharacterID)
	if healed.HP != healed.MaxHP() {
		t.Fatalf("HP %d after /heal, want %d", healed.HP, healed.MaxHP())
	}
}

func TestSpawnAndKill(t *testing.T) {
	f := newFixture(t)
	res := f.run(t, "/spawn mangyang 3")
	if res.Refused || !res.RefreshMonsters {
		t.Fatalf("/spawn: %+v", res)
	}
	alive := f.hub.InZone("jangan")
	if len(alive) != 3 {
		t.Fatalf("%d monsters in the zone after spawning 3", len(alive))
	}
	for _, m := range alive {
		if m.Name != "Mangyang" || m.MaxHP != 60 || m.Zone != "jangan" {
			t.Errorf("spawned monster %+v", m)
		}
	}
	// Round 542: the result names the three it made, in order, for the
	// session layer's zone push (session.BroadcastMonsterSpawned).
	if len(res.SpawnedMonsterIDs) != 3 {
		t.Fatalf("SpawnedMonsterIDs %v, want the 3 spawned", res.SpawnedMonsterIDs)
	}
	for i, id := range res.SpawnedMonsterIDs {
		if m, ok := f.hub.Get(id); !ok || m.Name != "Mangyang" {
			t.Errorf("SpawnedMonsterIDs[%d] = %d is not a spawned Mangyang", i, id)
		}
		if i > 0 && id <= res.SpawnedMonsterIDs[i-1] {
			t.Errorf("SpawnedMonsterIDs %v are not in spawn order", res.SpawnedMonsterIDs)
		}
	}
	if res := f.run(t, "/spawn MOB_CH_MANGYANG"); res.Refused || len(res.SpawnedMonsterIDs) != 1 {
		t.Fatalf("/spawn by code, default count: %+v", res)
	}
	if got := len(f.hub.InZone("jangan")); got != 4 {
		t.Fatalf("%d monsters after one more", got)
	}
	for _, bad := range []string{"/spawn", "/spawn dragon", "/spawn mangyang 0", "/spawn mangyang 21"} {
		if res := f.run(t, bad); !res.Refused || len(res.SpawnedMonsterIDs) != 0 {
			t.Errorf("%q should be refused, spawning nothing: %+v", bad, res)
		}
	}

	// /kill needs a target, and removes exactly it.
	if res := f.run(t, "/kill"); !res.Refused {
		t.Fatalf("/kill with no target should be refused: %+v", res)
	}
	target := alive[0].ID
	with := f.actor
	with.TargetMonsterID = target
	res = f.deps.Run(f.ctx, with, "/kill")
	if res.Refused || res.KilledMonsterID != target || res.Zone != "jangan" || !res.RefreshMonsters {
		t.Fatalf("/kill: %+v", res)
	}
	if _, stillThere := f.hub.Get(target); stillThere {
		t.Fatal("the killed monster is still alive")
	}
	if got := len(f.hub.InZone("jangan")); got != 3 {
		t.Fatalf("%d monsters after the kill, want 3", got)
	}
	if res := f.deps.Run(f.ctx, with, "/kill"); !res.Refused {
		t.Fatalf("killing a dead monster should be refused: %+v", res)
	}
}

func TestDurability(t *testing.T) {
	f := newFixture(t)
	if res := f.run(t, "/durability 6 10"); !res.Refused || !strings.Contains(res.Text, "nothing worn") {
		t.Fatalf("empty slot: %+v", res)
	}
	if err := f.inv.AddItem(f.ctx, f.actor.CharacterID, 3645, 1); err != nil {
		t.Fatal(err)
	}
	if err := f.equip.Equip(f.ctx, f.actor.CharacterID, equipment.SlotWeapon, 0); err != nil {
		t.Fatalf("Equip: %v", err)
	}
	res := f.run(t, "/durability 6 7")
	if res.Refused || !res.RefreshEquipment {
		t.Fatalf("/durability 6 7: %+v", res)
	}
	worn, _ := f.equip.Get(f.ctx, f.actor.CharacterID)
	found := false
	for _, e := range worn {
		if e.Slot == equipment.SlotWeapon {
			found = true
			if e.Durability != 7 {
				t.Fatalf("weapon durability %d, want 7", e.Durability)
			}
		}
	}
	if !found {
		t.Fatal("no weapon worn after Equip")
	}
	for _, bad := range []string{"/durability", "/durability 6", "/durability 9 1", "/durability -1 1", "/durability 6 -1", "/durability x y"} {
		if res := f.run(t, bad); !res.Refused {
			t.Errorf("%q should be refused: %+v", bad, res)
		}
	}
}

func TestSP(t *testing.T) {
	f := newFixture(t)
	if res := f.run(t, "/sp 40"); res.Refused || !strings.Contains(res.Text, "skill points now 40") {
		t.Fatalf("/sp 40: %+v", res)
	}
	if res := f.run(t, "/sp -15"); res.Refused || !strings.Contains(res.Text, "skill points now 25") {
		t.Fatalf("/sp -15: %+v", res)
	}
	for _, bad := range []string{"/sp", "/sp 0", "/sp x"} {
		if res := f.run(t, bad); !res.Refused {
			t.Errorf("%q should be refused: %+v", bad, res)
		}
	}
}

// A dependency that is missing refuses with a reply, never a panic.
func TestMissingDependenciesRefuse(t *testing.T) {
	f := newFixture(t)
	empty := &Deps{}
	for _, line := range []string{"/give 3", "/gold 5", "/level 2", "/heal", "/spawn mangyang", "/durability 6 1", "/sp 1"} {
		res := empty.Run(f.ctx, f.actor, line)
		if !res.Refused || res.Text == "" {
			t.Errorf("%q against empty deps: %+v", line, res)
		}
	}
	with := f.actor
	with.TargetMonsterID = 7
	if res := empty.Run(f.ctx, with, "/kill"); !res.Refused {
		t.Errorf("/kill against empty deps: %+v", res)
	}
}

// A dead GM is not moved (round 549, session/deadstate.go): /tp and /goto
// refuse with deadRefusal while Actor.Dead is set, and the rest of the console
// -- /heal here -- runs as before.
func TestDeadActorCannotTeleport(t *testing.T) {
	f := newFixture(t)
	f.actor.Dead = true
	for _, line := range []string{"/tp -300 -880", "/goto donwhang", "/goto mangyang"} {
		res := f.run(t, line)
		if !res.Refused || res.HasPos || res.Zone != "" || res.Text != deadRefusal {
			t.Errorf("%q for a dead actor: %+v, want the refusal %q with no move", line, res, deadRefusal)
		}
	}
	if res := f.run(t, "/heal"); res.Refused {
		t.Errorf("/heal for a dead actor was refused: %+v", res)
	}
	f.actor.Dead = false
	if res := f.run(t, "/tp -300 -880"); res.Refused || !res.HasPos {
		t.Errorf("/tp for a living actor: %+v, want the move", res)
	}
}
