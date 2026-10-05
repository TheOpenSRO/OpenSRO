package gm

import (
	"context"
	"strconv"
	"strings"
	"testing"

	"github.com/OpenSRO/OpenSRO/server/internal/berserk"
	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/combat"
	"github.com/OpenSRO/OpenSRO/server/internal/equipment"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
	"github.com/OpenSRO/OpenSRO/server/internal/leveldata"
	"github.com/OpenSRO/OpenSRO/server/internal/mana"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
	"github.com/OpenSRO/OpenSRO/server/internal/skill"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
	"github.com/OpenSRO/OpenSRO/server/internal/worldmap"
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
	// world holds Aria in jangan, so /level's write to the entity's cached
	// level (round 555) can be read back.
	world *world.Hub
	actor Actor
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
	wh := world.NewHub()
	wh.Enter(gateway.NewTestSession(7001), c.ID, "Aria", c.Level, "jangan", world.Position{X: 10, Z: 20})
	deps := &Deps{
		Chars: chars, Inv: inv, Equip: equip, Items: items, Skills: skills,
		Monsters: hub, World: wh, Mana: mana.NewTracker(), Levels: tbl,
		Species: []Species{{
			Species: combat.Species{Name: "Mangyang", CodeName: "MOB_CH_MANGYANG", Level: 1},
			Zone:    "jangan", MaxHP: 60, Defense: 1, Attack: 5, Gold: 10, X: 100, Z: 200,
		}},
		Zones: []string{"jangan", "donwhang"},
	}
	actor := Actor{Account: "alice", CharacterID: c.ID, Name: "Aria", Zone: "jangan", X: 10, Z: 20}
	return &fixture{ctx: ctx, deps: deps, chars: chars, inv: inv, equip: equip, skills: skills, hub: hub, world: wh, actor: actor}
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

// Under cmd/server's -single-frame (round 571) the actor's Zone is the hub
// bucket every framed label shares, worldmap.WorldBucket, and the console's
// uses map as session/gm.go lays out: no zone label equals the bucket, so
// /goto <zone> always travels -- including to "jangan", which a GM who walked
// to Donwhang has not left by label -- and /goto <monster> always carries the
// species' zone LABEL for the client to re-centre on, never the bucket;
// /spawn spawns into the bucket, where the players are.
func TestGotoAndSpawnInTheOneWorldBucket(t *testing.T) {
	f := newFixture(t)
	f.actor.Zone = worldmap.WorldBucket
	for _, zone := range []string{"jangan", "donwhang"} {
		if res := f.run(t, "/goto "+zone); res.Refused || res.Zone != zone || res.HasPos {
			t.Errorf("/goto %s from the one bucket: %+v, want travelling to the label", zone, res)
		}
	}
	if res := f.run(t, "/goto mangyang"); res.Refused || !res.HasPos || res.Zone != "jangan" || res.X != 100 || res.Z != 200 {
		t.Errorf("/goto mangyang from the one bucket: %+v, want the label jangan and the spot (100, 200)", res)
	}
	res := f.run(t, "/spawn mangyang")
	if res.Refused || len(res.SpawnedMonsterIDs) != 1 {
		t.Fatalf("/spawn in the one bucket: %+v", res)
	}
	if m, ok := f.hub.Get(res.SpawnedMonsterIDs[0]); !ok || m.Zone != worldmap.WorldBucket {
		t.Errorf("the GM's spawn is in %q, want the bucket %q", m.Zone, worldmap.WorldBucket)
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
	for _, bad := range []string{"/give", "/give x", "/give 3 0", "/give 3 -1", "/give 3 1 2 4", "/give 3645 1 256", "/give 3645 1 x"} {
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

// /give's plus and /item are GM test hooks for an item's own data (OURS,
// round 732).
func TestGivePlusAndItemEditTheInstance(t *testing.T) {
	f := newFixture(t)
	if res := f.run(t, "/give 3645 2 5"); res.Refused || !res.RefreshInventory || !strings.Contains(res.Text, "+5") {
		t.Fatalf("/give 3645 2 5: %+v", res)
	}
	bag, _ := f.inv.List(f.ctx, f.actor.CharacterID)
	if len(bag) != 2 || bag[0].OptLevel != 5 || bag[1].OptLevel != 5 {
		t.Fatalf("bag after /give 3645 2 5: %+v", bag)
	}
	for _, line := range []string{"/item 0 quality 31", "/item 0 opt 1 7", "/item 0 opt 2 9", "/item 0 opt 1 8", "/item 0 adv 3", "/item 0 plus 6"} {
		if res := f.run(t, line); res.Refused || !res.RefreshInventory {
			t.Fatalf("%s: %+v", line, res)
		}
	}
	bag, _ = f.inv.List(f.ctx, f.actor.CharacterID)
	got := bag[0].Instance()
	want := []uint64{inventory.MagParam(1, 8), inventory.MagParam(2, 9)}
	if got.OptLevel != 6 || got.AdvElixir != 3 || got.Variance != 0x0fffffffffffffff ||
		len(got.MagParams) != 2 || got.MagParams[0] != want[0] || got.MagParams[1] != want[1] {
		t.Fatalf("slot 0 after /item: %+v", got)
	}
	if bag[1].OptLevel != 5 || len(bag[1].MagParams) != 0 {
		t.Fatalf("slot 1 changed: %+v", bag[1])
	}
	if res := f.run(t, "/item 0 clear"); res.Refused {
		t.Fatalf("/item 0 clear: %+v", res)
	}
	bag, _ = f.inv.List(f.ctx, f.actor.CharacterID)
	if c := bag[0].Instance(); c.OptLevel != 0 || c.AdvElixir != 0 || len(c.MagParams) != 0 || c.Variance != 0x0fffffffffffffff {
		t.Fatalf("after clear: %+v", c)
	}
	for i := 0; i < inventory.MaxMagParams; i++ {
		f.run(t, "/item 0 opt "+strconv.Itoa(i+1)+" 1")
	}
	for _, bad := range []string{"/item", "/item 0", "/item 7 plus 1", "/item 0 plus 256", "/item 0 quality 32",
		"/item 0 opt 0 1", "/item 0 opt 1", "/item 0 opt 99 1", "/item 0 bogus 1", "/item 0 clear 1"} {
		if res := f.run(t, bad); !res.Refused {
			t.Errorf("%q should be refused: %+v", bad, res)
		}
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
	// The world entity's cached level moved with the row (round 555): the
	// monster AI reads the level there, so a /level that left it at 1 would
	// have every monster fight a level-1 character.
	if e, ok := f.world.EntityByCharacterID(f.actor.CharacterID); !ok || e.Level != 4 {
		t.Fatalf("the world entity's level after /level 4 = %d (in world %v), want 4", e.Level, ok)
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

// /hwan sets the berserk orbs in the tracker and on the character row, and
// asks the client to re-read its stats (round 629's review; a test tool).
func TestHwan(t *testing.T) {
	f := newFixture(t)
	if res := f.run(t, "/hwan 5"); !res.Refused {
		t.Fatalf("/hwan with no tracker: %+v, want refused", res)
	}
	f.deps.Berserk = berserk.NewTracker()
	for _, bad := range []string{"/hwan", "/hwan 6", "/hwan -1", "/hwan x"} {
		if res := f.run(t, bad); !res.Refused {
			t.Errorf("%s accepted: %+v", bad, res)
		}
	}
	res := f.run(t, "/hwan 5")
	if res.Refused || !res.RefreshStats {
		t.Fatalf("/hwan 5: %+v", res)
	}
	if got := f.deps.Berserk.Charges(f.actor.CharacterID); got != 5 {
		t.Errorf("tracker holds %d, want 5", got)
	}
	if c, _ := f.chars.GetByID(f.ctx, f.actor.CharacterID); c.HwanCount != 5 {
		t.Errorf("row holds %d, want 5", c.HwanCount)
	}
	if !f.deps.Berserk.Activate(f.actor.CharacterID) {
		t.Error("five orbs from /hwan do not activate")
	}
}

// Round 633: /invsize shows and sets the GM's own bag size, the one the client
// pages (32 to a page, at most three) and every bag operation is held to.
// "default" goes back to the store's own; a size that would leave an item
// past the end is refused and changes nothing.
func TestInvsize(t *testing.T) {
	f := newFixture(t)
	f.inv.SetCapacityFunc(inventory.BagCapacity(f.chars, inventory.DefaultBagSlots))
	if res := f.run(t, "/invsize"); res.Refused || res.Text != "inventory size 96 slots (3 pages)" {
		t.Fatalf("/invsize: %+v", res)
	}
	for _, bad := range []string{"/invsize 0", "/invsize 97", "/invsize x", "/invsize 1 2"} {
		if res := f.run(t, bad); !res.Refused {
			t.Errorf("%s accepted: %+v", bad, res)
		}
	}
	res := f.run(t, "/invsize 40")
	if res.Refused || !res.RefreshInventory || res.Text != "inventory size now 40 slots (2 pages)" {
		t.Fatalf("/invsize 40: %+v", res)
	}
	if got := inventory.CapacityOf(f.ctx, f.inv, f.actor.CharacterID); got != 40 {
		t.Errorf("the bag's capacity is %d, want 40", got)
	}
	if err := f.inv.AddItem(f.ctx, f.actor.CharacterID, 3, 1); err != nil {
		t.Fatal(err)
	}
	if err := f.inv.MoveItem(f.ctx, f.actor.CharacterID, 0, 39); err != nil {
		t.Fatalf("moving into slot 39 of 40: %v", err)
	}
	if err := f.inv.MoveItem(f.ctx, f.actor.CharacterID, 39, 40); err == nil {
		t.Error("slot 40 of a 40-slot bag took an item")
	}
	if res := f.run(t, "/invsize 32"); !res.Refused {
		t.Errorf("/invsize 32 with an item in slot 39: %+v, want refused", res)
	}
	if got := inventory.CapacityOf(f.ctx, f.inv, f.actor.CharacterID); got != 40 {
		t.Errorf("a refused shrink left the bag at %d, want 40", got)
	}
	if res := f.run(t, "/invsize default"); res.Refused || res.Text != "inventory size now 96 slots (3 pages)" {
		t.Errorf("/invsize default: %+v", res)
	}
}
