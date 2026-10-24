package quest

import (
	"encoding/csv"
	"os"
	"path/filepath"
	"testing"
)

// Round 819: the divide type and the different-string flag travel in the
// catalogue, and a catalogue written before them still loads (prod's).
func TestCatalogue819Columns(t *testing.T) {
	dir := t.TempDir()
	q := &Quest{ID: 1, Code: "QNO_T", Source: SourceScript, Race: -1, StartNPCs: []string{"NPC_A"},
		ConditionMask: CondRealTime, DivideType: 5, DifferentString: true,
		Missions: []Mission{{Type: MissionKillMonster, Targets: []string{"MOB_A"}, Count: 1}}}
	if err := WriteDir(dir, []*Quest{q}); err != nil {
		t.Fatal(err)
	}
	cat, err := LoadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	got := cat.ByCode["QNO_T"]
	if got.DivideType != 5 || !got.DifferentString || got.ConditionMask&CondRealTime == 0 {
		t.Fatalf("round trip %+v", got)
	}

	// The same file cut back to the 26 columns of before.
	path := filepath.Join(dir, FileQuests)
	f, _ := os.Open(path)
	rows, err := csv.NewReader(f).ReadAll()
	f.Close()
	if err != nil {
		t.Fatal(err)
	}
	for i := range rows {
		rows[i] = rows[i][:questColumnsRequired]
	}
	out, _ := os.Create(path)
	w := csv.NewWriter(out)
	_ = w.WriteAll(rows)
	out.Close()
	cat, err = LoadDir(dir)
	if err != nil {
		t.Fatalf("an old catalogue: %v", err)
	}
	if got := cat.ByCode["QNO_T"]; got.DivideType != 0 || got.DifferentString {
		t.Fatalf("old catalogue fields %+v", got)
	}
}

// The three setters as the server's script calls them (s:0x86bb20 the divide
// byte, s:0x86ba00 the 0x100000 bit with no argument, s:0x86b200 the byte).
func TestApply819Setters(t *testing.T) {
	q := &Quest{ID: 2, Code: "QT_SET"}
	Apply(q, []Call{call("LuaSetDivideType", n(1)), call("LuaSetRealTime"), call("LuaSetDifferentString", n(1))})
	if q.DivideType != 1 || q.ConditionMask&CondRealTime == 0 || !q.DifferentString || len(q.Unhandled) != 0 {
		t.Fatalf("%+v", q)
	}
}

// A quest killing only quest-spawned monsters nothing spawns is out of play;
// one naming a field monster (spawned or not) stays.
func TestHideUnspawnedQuestMonsters(t *testing.T) {
	mk := func(id int64, code string, targets ...string) *Quest {
		return &Quest{ID: id, Code: code, Source: SourceScript, Race: -1, StartNPCs: []string{"NPC_A"},
			Missions: []Mission{{Type: MissionKillMonster, Targets: targets, Count: 1}}}
	}
	cat := NewCatalog([]*Quest{
		mk(1, "QT_SPAWNED", "MOB_QT_A"),
		mk(2, "QT_HANDLER", "MOB_QT_B", "MOB_QT_B_CLON"),
		mk(3, "QT_FIELD", "MOB_CA_MONKEY"),
		mk(4, "QT_MIXED", "MOB_QT_C", "MOB_CH_TIGER"),
	})
	spawns := map[string]bool{"MOB_QT_A": true}
	got := cat.HideUnspawnedQuestMonsters(func(c string) bool { return spawns[c] })
	if len(got) != 1 || got[0] != "QT_HANDLER" {
		t.Fatalf("hidden %v", got)
	}
	if cat.ByCode["QT_HANDLER"].Playable() || !cat.ByCode["QT_SPAWNED"].Playable() ||
		!cat.ByCode["QT_FIELD"].Playable() || !cat.ByCode["QT_MIXED"].Playable() {
		t.Fatal("playable flags")
	}
}
