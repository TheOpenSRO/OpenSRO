package session

import (
	"context"
	"reflect"
	"sort"
	"strings"
	"testing"

	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/quest"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
	"github.com/OpenSRO/OpenSRO/server/internal/skill"
)

// Round 692: a new character gets the race's default masteries (level 0),
// skills and level-1 quests, as the shard's `_AddNewChar` gives them (READ,
// this package's procedure; EXTERNAL data). NEGATIVE: before round 692 the
// lobby's create gave a character its items and nothing else -- LobbyDeps has
// no Defaults, Skills or Quests and this file does not compile.

// A SYNTHETIC `_RefCharDefault_*` set in the export's shape (made-up ids and
// codes, none of the export's rows): Race 0 China, 1 Europe, 3 both; one
// mastery and one skill for both races, quests failing the RequiredLevel and
// Service filters, and a Race 1 quest. The real export is checked by
// refdata's TestCharDefaultsRealExport when it is at hand.
const (
	synth692Masteries = "Race,MasteryID\r\n0,9001\r\n0,9002\r\n1,9101\r\n3,9301\r\n"
	synth692Skills    = "Race,SkillID\r\n3,8301\r\n0,8001\r\n0,8002\r\n1,8101\r\n"
	synth692Quests    = "Service,ID,Race,CodeName,RequiredLevel\r\n1,1,3,QSYN_ALL_LATER,5\r\n1,2,3,QSYN_ALL,1\r\n" +
		"1,3,0,QSYN_CH,1\r\n0,4,1,QSYN_EU_OFF,1\r\n1,5,1,QSYN_EU,1\r\n"
)

func synth692Defaults(t *testing.T) *refdata.CharDefaults {
	t.Helper()
	d, err := refdata.LoadCharDefaults(strings.NewReader(synth692Masteries), strings.NewReader(synth692Skills),
		strings.NewReader(synth692Quests))
	if err != nil {
		t.Fatal(err)
	}
	return d
}

func characterNamed(t *testing.T, chars *character.MemStore, name string) *character.Character {
	t.Helper()
	list, err := chars.ListByAccount(context.Background(), 1)
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range list {
		if c.Name == name {
			return c
		}
	}
	t.Fatalf("no character %q on the account", name)
	return nil
}

func TestLobbyCreateGivesTheRaceDefaults692(t *testing.T) {
	skills := skill.NewMemStore()
	quests := quest.NewMemStore()
	h := newLobbyHarnessWith(t, testCatalogue(), true, func(d *LobbyDeps) {
		d.Defaults = synth692Defaults(t)
		d.Skills = skills
		d.Quests = quests
	})
	if r := h.lobby(chinaManCreate("Hanshin")); !r.OK {
		t.Fatalf("China create refused %#x", r.Code)
	}
	eu := &LobbyRequest{Action: LobbyCreate, Name: "Viktor", RefObjID: 14875, Scale: 0x22,
		Chest: 11620, Legs: 11621, Feet: 11622, Weapon: 10888}
	if r := h.lobby(eu); !r.OK {
		t.Fatalf("Europe create refused %#x", r.Code)
	}

	ctx := context.Background()
	cases := []struct {
		name      string
		masteries []int64
		skills    []int64
		quests    []string
	}{
		// READ: Race 0 or 3 for China; RequiredLevel 1 and Service 1 only.
		{"Hanshin", []int64{9001, 9002, 9301}, []int64{8001, 8002, 8301}, []string{"QSYN_ALL", "QSYN_CH"}},
		// READ: Race 1 or 3 for Europe.
		{"Viktor", []int64{9101, 9301}, []int64{8101, 8301}, []string{"QSYN_ALL", "QSYN_EU"}},
	}
	for _, c := range cases {
		ch := characterNamed(t, h.chars, c.name)
		levels, _ := skills.MasteryLevels(ctx, ch.ID)
		var got []int64
		for id, lvl := range levels {
			if lvl != 0 {
				t.Errorf("%s: mastery %d at level %d, want 0 (READ)", c.name, id, lvl)
			}
			got = append(got, id)
		}
		sort.Slice(got, func(i, j int) bool { return got[i] < got[j] })
		if !reflect.DeepEqual(got, c.masteries) {
			t.Errorf("%s: masteries %v, want %v", c.name, got, c.masteries)
		}
		known, _ := skills.KnownSkills(ctx, ch.ID)
		if !reflect.DeepEqual(known, c.skills) {
			t.Errorf("%s: skills %v, want %v", c.name, known, c.skills)
		}
		grants, _ := quests.DefaultQuests(ctx, ch.ID)
		var codes []string
		for _, g := range grants {
			if g.Status != quest.DefaultQuestStatus {
				t.Errorf("%s: %s status %d, want %d (READ)", c.name, g.Code, g.Status, quest.DefaultQuestStatus)
			}
			codes = append(codes, g.Code)
		}
		if !reflect.DeepEqual(codes, c.quests) {
			t.Errorf("%s: default quests %v, want %v", c.name, codes, c.quests)
		}
		// The invented quest catalogue is untouched: a recorded default is not
		// an accepted catalogue quest.
		if p, _ := quests.States(ctx, ch.ID); len(p) != 0 {
			t.Errorf("%s: quest progress %+v, want none", c.name, p)
		}
	}
}

// Without the tables (-chardefaults-dir unset) a create still succeeds and
// gives no defaults: the flag is a no-op when unset.
func TestLobbyCreateWithoutDefaults692(t *testing.T) {
	skills := skill.NewMemStore()
	h := newLobbyHarnessWith(t, testCatalogue(), true, func(d *LobbyDeps) { d.Skills = skills })
	if r := h.lobby(chinaManCreate("Hanshin")); !r.OK {
		t.Fatalf("create refused %#x", r.Code)
	}
	ch := characterNamed(t, h.chars, "Hanshin")
	if levels, _ := skills.MasteryLevels(context.Background(), ch.ID); len(levels) != 0 {
		t.Errorf("masteries %v without defaults, want none", levels)
	}
	if known, _ := skills.KnownSkills(context.Background(), ch.ID); len(known) != 0 {
		t.Errorf("skills %v without defaults, want none", known)
	}
}

// The ammunition a bow or crossbow comes with is the procedure's 250 (READ;
// that it is the count is INFERRED), not a full stack (2,500 on a retail
// archive; round 682's OURS), and never more than one stack.
func TestAmmoStartQuantity692(t *testing.T) {
	for _, c := range []struct{ maxStack, want int }{{2500, 250}, {250, 250}, {100, 100}, {0, 250}} {
		if got := ammoQuantity(c.maxStack); got != c.want {
			t.Errorf("ammoQuantity(%d) = %d, want %d", c.maxStack, got, c.want)
		}
	}
}
