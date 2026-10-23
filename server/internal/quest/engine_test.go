package quest

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/quest/luabc"
)

// The fixtures are made-up quests in the shape of the server script's setup
// calls (no retail script or table is a fixture).

func n(v float64) luabc.Value { return luabc.Value{K: luabc.Number, N: v} }
func s(v string) luabc.Value  { return luabc.Value{K: luabc.String, S: v} }

func call(name string, a ...luabc.Value) Call { return Call{Name: name, Args: a} }

func testCatalog(t *testing.T) *Catalog {
	t.Helper()
	kill := &Quest{ID: 10, Code: "QT_KILL", Reward: Reward{Gold: 5, Exp: 7, SPExp: 1, FromTable: true}}
	Apply(kill, []Call{
		call("LuaSetStartCodition", n(2), n(QSCQuest), n(QSCLevel), n(3), n(1)),
		call("LuaSetStartMethod", n(1), n(1), s("NPC_A")),
		call("LuaInsertMissionOrCompleteNpc", s("NPC_A")),
		call("LuaQuestInsertNpc", n(1), s("NPC_A")),
		call("LuaSetAchievementLimit", n(1)),
		call("LuaSetMissionDataSize", n(10), n(1)),
		call("LuaSetMissionData_EX", n(10), n(0), n(MissionKillMonster), s("SN_CON_QT_KILL"), n(2), s("MOB_X_CLON"), s("MOB_X"), n(0), n(3), n(0), n(1)),
		call("InsertQuestMenuStringList", s("NPC_A"), n(2), s("BASIC_MENUSTRING_GREETING"), s("SN_A_QS"), s("BASIC_MENUSTRING_REQUEST_ACCEPT_QUEST"), s("SN_TALK_QT_KILL_01")),
		call("LuaSetAchievedItem", n(0), n(999), n(0), n(999), n(0), n(0)),
		call("LuaSetAchievedSkillPont", n(0)),
	})
	gather := &Quest{ID: 11, Code: "QT_GATHER"}
	Apply(gather, []Call{
		call("LuaSetStartCodition", n(2), n(QSCQuest), n(QSCLevel), n(1), n(1)),
		call("LuaSetStartMethod", n(1), n(1), s("NPC_B")),
		call("LuaInsertMissionOrCompleteNpc", s("NPC_B")),
		call("LuaInsertDependancyQuests", n(1), s("QT_KILL")),
		call("LuaSetCollectionItemMissionData", n(11), n(0), n(MissionGatherFromMonster), s("SN_CON_QT_GATHER"), n(2), s("NPC_B"), n(1), n(2), s("ITEM_QT_GATHER"), s("MOB_Y"), n(50), s("MOB_Y_CLON"), n(100)),
		call("LuaSetAchievedItem", n(1), n(100), n(10), n(20), n(1), s("ITEM_PRIZE"), n(2)),
	})
	deliver := &Quest{ID: 12, Code: "QT_DELIVER"}
	Apply(deliver, []Call{
		call("LuaSetStartCodition", n(2), n(QSCQuest), n(QSCLevel), n(1), n(1)),
		call("LuaSetStartMethod", n(1), n(2), s("NPC_A"), s("NPC_C")),
		call("LuaInsertMissionOrCompleteNpc", s("NPC_A")),
		call("LuaInsertMissionNPC", s("NPC_C")),
		call("LuaSetDeliverMissionData_EX", n(12), n(0), n(MissionDeliverItem), s("SN_CON_QT_DELIVER"), s("NPC_C"), n(0), n(2), s("SN_T1"), s(""),
			n(1), n(1), s("ITEM_LETTER"), n(0), s(""), n(1), n(0), n(1), n(0), n(0), n(0)),
	})
	race := &Quest{ID: 13, Code: "QT_EUROPE"}
	Apply(race, []Call{
		call("LuaSetStartCodition", n(2), n(QSCQuest), n(QSCLevel), n(1), n(1)),
		call("LuaSetRaceStartCodition", n(QSCRace), n(1)),
		call("LuaSetStartMethod", n(1), n(1), s("NPC_A")),
		call("LuaSetDialLogMissionData", n(13), n(0), n(MissionDialog), s("SN_CON_QT_EUROPE"), n(1), s("SN_T")),
		call("LuaInsertMissionOrCompleteNpc", s("NPC_D")),
	})
	compiled := &Quest{ID: 14, Code: "QT_COMPILED", Source: SourceCompiled, Level: 1}
	return NewCatalog([]*Quest{kill, gather, deliver, race, compiled})
}

func TestApplyReadsTheSetupCalls(t *testing.T) {
	c := testCatalog(t)
	k := c.ByCode["QT_KILL"]
	if k.Level != 3 || k.LevelArg2 != 1 || k.ConditionMask != QSCQuest|QSCLevel || k.AchievementLimit != 1 {
		t.Fatalf("conditions %+v", k)
	}
	if !reflect.DeepEqual(k.StartNPCs, []string{"NPC_A"}) || k.CompleteNPC() != "NPC_A" {
		t.Fatalf("npcs %+v %+v", k.StartNPCs, k.CompleteNPCs)
	}
	m := k.Missions[0]
	if m.Type != MissionKillMonster || m.Count != 3 || !reflect.DeepEqual(m.Targets, []string{"MOB_X_CLON", "MOB_X"}) || m.Text != "SN_CON_QT_KILL" {
		t.Fatalf("kill mission %+v", m)
	}
	if k.MenuText("NPC_A", "BASIC_MENUSTRING_REQUEST_ACCEPT_QUEST") != "SN_TALK_QT_KILL_01" {
		t.Fatalf("menus %+v", k.Menus)
	}
	// The reward table wins over the script's LuaSetAchievedItem.
	if k.Reward.Gold != 5 || k.Reward.Exp != 7 {
		t.Fatalf("reward %+v", k.Reward)
	}
	g := c.ByCode["QT_GATHER"]
	gm := g.Missions[0]
	if gm.Count != 2 || gm.Item != "ITEM_QT_GATHER" || gm.NPC != "NPC_B" || !reflect.DeepEqual(gm.Rates, []float64{50, 100}) {
		t.Fatalf("gather mission %+v", gm)
	}
	// No table row: the script's reward (exp, spexp, gold, items).
	if g.Reward.Exp != 100 || g.Reward.SPExp != 10 || g.Reward.Gold != 20 || len(g.Reward.Items) != 1 || g.Reward.Items[0].Count != 2 || g.Reward.FromTable {
		t.Fatalf("script reward %+v", g.Reward)
	}
	d := c.ByCode["QT_DELIVER"].Missions[0]
	if d.NPC != "NPC_C" || !reflect.DeepEqual(d.Deliver, []ItemCount{{"ITEM_LETTER", 1}}) || !reflect.DeepEqual(d.Talk, []string{"SN_T1"}) {
		t.Fatalf("delivery %+v", d)
	}
	if r := c.ByCode["QT_EUROPE"]; r.Race != 1 || r.ConditionMask&QSCRace == 0 {
		t.Fatalf("race %+v", r)
	}
	if len(c.ByCode["QT_KILL"].Unhandled) != 0 {
		t.Fatalf("unhandled %v", c.ByCode["QT_KILL"].Unhandled)
	}
}

func TestGates(t *testing.T) {
	c := testCatalog(t)
	l := Log{}
	china, europe := Player{Level: 1, Race: 0}, Player{Level: 5, Race: 1}
	if r := c.CanStart(china, l, c.ByCode["QT_KILL"], "NPC_A"); r != RefuseLevel {
		t.Fatalf("level gate: %v", r)
	}
	if r := c.CanStart(europe, l, c.ByCode["QT_KILL"], "NPC_B"); r != RefuseNotHere {
		t.Fatalf("npc gate: %v", r)
	}
	if r := c.CanStart(europe, l, c.ByCode["QT_GATHER"], "NPC_B"); r != RefusePrerequisite {
		t.Fatalf("prerequisite gate: %v", r)
	}
	if r := c.CanStart(Player{Level: 9, Race: 0}, l, c.ByCode["QT_EUROPE"], "NPC_A"); r != RefuseRace {
		t.Fatalf("race gate: %v", r)
	}
	if r := c.CanStart(europe, l, c.ByCode["QT_EUROPE"], "NPC_A"); r != OK {
		t.Fatalf("europe quest for a european: %v", r)
	}
	if r := c.CanStart(europe, l, c.ByCode["QT_COMPILED"], ""); r != RefuseNotPlayable {
		t.Fatalf("a compiled quest is not offered: %v", r)
	}
	offers := c.Offers(europe, l, "NPC_A")
	if len(offers) != 3 { // kill, deliver, europe
		t.Fatalf("offers %d", len(offers))
	}
	Start(l, c.ByCode["QT_KILL"])
	if r := c.CanStart(europe, l, c.ByCode["QT_KILL"], "NPC_A"); r != RefuseActive {
		t.Fatalf("active gate: %v", r)
	}
}

func TestKillProgressClaimAndLimit(t *testing.T) {
	c := testCatalog(t)
	l := Log{}
	q := c.ByCode["QT_KILL"]
	st, give := Start(l, q)
	if len(give) != 0 || st.Status != StatusAchieving || len(st.Counts) != 1 {
		t.Fatalf("start %+v %+v", st, give)
	}
	always := func(float64) bool { return true }
	if p := onKill(c, l, "MOB_Z", always); len(p) != 0 {
		t.Fatalf("an unrelated kill counted %+v", p)
	}
	for i := 1; i <= 3; i++ {
		p := onKill(c, l, "MOB_X_CLON", always)
		if len(p) != 1 || p[0].Count != i || p[0].Finished != (i == 3) {
			t.Fatalf("kill %d: %+v", i, p)
		}
	}
	if p := onKill(c, l, "MOB_X", always); len(p) != 0 {
		t.Fatalf("a kill after the count counted %+v", p)
	}
	if ok, _ := Claim(l, q, "NPC_Z"); ok {
		t.Fatal("claimed at the wrong NPC")
	}
	if ok, _ := Claim(l, q, "NPC_A"); !ok {
		t.Fatal("claim refused")
	}
	if ok, _ := Claim(l, q, "NPC_A"); ok {
		t.Fatal("paid twice")
	}
	if r := c.CanStart(Player{Level: 9}, l, q, "NPC_A"); r != RefuseLimit {
		t.Fatalf("limit: %v", r)
	}
	if r := c.CanStart(Player{Level: 9}, l, c.ByCode["QT_GATHER"], "NPC_B"); r != OK {
		t.Fatalf("the prerequisite is now met: %v", r)
	}
}

func TestGatherDeliverDialog(t *testing.T) {
	c := testCatalog(t)
	l := Log{}
	g := c.ByCode["QT_GATHER"]
	Start(l, g)
	var rolled []float64
	miss := func(r float64) bool { rolled = append(rolled, r); return false }
	if p := onKill(c, l, "MOB_Y", miss); len(p) != 0 || len(rolled) != 1 || rolled[0] != 50 {
		t.Fatalf("a missed roll %+v %v", p, rolled)
	}
	hit := func(float64) bool { return true }
	p := onKill(c, l, "MOB_Y_CLON", hit)
	if len(p) != 1 || p[0].Item != "ITEM_QT_GATHER" || p[0].Finished {
		t.Fatalf("a drop %+v", p)
	}
	p = onKill(c, l, "MOB_Y", hit)
	if len(p) != 1 || !p[0].Finished {
		t.Fatalf("the last drop %+v", p)
	}
	ok, take := Claim(l, g, "NPC_B")
	if !ok || !reflect.DeepEqual(take, []ItemCount{{"ITEM_QT_GATHER", 2}}) {
		t.Fatalf("claim %v %+v", ok, take)
	}

	d := c.ByCode["QT_DELIVER"]
	_, give := Start(l, d)
	if !reflect.DeepEqual(give, []ItemCount{{"ITEM_LETTER", 1}}) {
		t.Fatalf("handed %+v", give)
	}
	none := func(string) int { return 0 }
	if p, _ := c.OnTalk(l, "NPC_C", none); len(p) != 0 {
		t.Fatalf("delivered without the item %+v", p)
	}
	one := func(string) int { return 1 }
	if p, _ := c.OnTalk(l, "NPC_A", one); len(p) != 0 {
		t.Fatalf("delivered to the wrong NPC %+v", p)
	}
	p, take = c.OnTalk(l, "NPC_C", one)
	if len(p) != 1 || !p[0].Finished || !reflect.DeepEqual(take, []ItemCount{{"ITEM_LETTER", 1}}) {
		t.Fatalf("delivery %+v %+v", p, take)
	}

	e := c.ByCode["QT_EUROPE"]
	Start(l, e)
	if p, _ := c.OnTalk(l, "NPC_A", one); len(p) != 0 {
		t.Fatalf("the dialogue ended at the start NPC %+v", p)
	}
	if p, _ := c.OnTalk(l, "NPC_D", one); len(p) != 1 || !p[0].Finished {
		t.Fatalf("the dialogue %+v", p)
	}
}

func TestAbandon(t *testing.T) {
	c := testCatalog(t)
	l := Log{}
	d := c.ByCode["QT_DELIVER"]
	Start(l, d)
	take := Abandon(l, d)
	if l[d.ID] != nil || len(take) != 1 || take[0].Code != "ITEM_LETTER" {
		t.Fatalf("abandon %+v %+v", l, take)
	}
	if take := Abandon(l, d); take != nil {
		t.Fatal("abandoning a quest not taken")
	}
}

func TestCSVRoundTrip(t *testing.T) {
	c := testCatalog(t)
	var qs []*Quest
	for _, q := range c.ByID {
		qs = append(qs, q)
	}
	dir := t.TempDir()
	if err := WriteDir(dir, qs); err != nil {
		t.Fatal(err)
	}
	back, err := LoadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	for code, q := range c.ByCode {
		b := back.ByCode[code]
		if b == nil {
			t.Fatalf("%s lost", code)
		}
		if len(q.Missions) == 0 {
			q.Missions = nil
		}
		if q.Menus == nil {
			q.Menus = map[string][]MenuText{}
		}
		q.scriptReward = nil // not exported
		if !reflect.DeepEqual(q, b) {
			t.Fatalf("%s:\n got %+v\nwant %+v", code, b, q)
		}
	}
	if cv := back.Coverage(); cv.Total != 5 || cv.Playable != 4 || cv.Compiled != 1 {
		t.Fatalf("coverage %+v", cv)
	}
	// A wrong header is refused.
	os.WriteFile(filepath.Join(dir, FileMenus), []byte("Code,Npc\n"), 0o644)
	if _, err := LoadDir(dir); err == nil {
		t.Fatal("a bad header loaded")
	}
}

func TestBuildFromTables(t *testing.T) {
	quests, rep, err := Build(Inputs{
		QuestData: [][]string{
			{"1", "10", "QT_A", "3", "title", "SN_QT_A", "SN_PAY_QT_A", "xxx", "SN_PAYCON_QT_A", "SN_NN_QT_A", "SN_NC_QT_A"},
			{"0", "11", "QT_OFF", "1", "x"},
		},
		Rewards:     [][]string{{"10", "QT_A", "1", "1", "1", "0", "0", "0", "0", "0", "205", "270", "40"}},
		RewardItems: [][]string{{"10", "QT_A", "0", "ITEM_Q", "xxx", "xxx", "0", "1", "0"}},
		ServerExe:   []byte("junk.?AVCQT_A@@junk"),
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(quests) != 1 || rep.QuestData != 1 || rep.Compiled != 1 {
		t.Fatalf("%+v %+v", quests, rep)
	}
	q := quests[0]
	if q.Level != 3 || q.TextPayCon != "SN_PAYCON_QT_A" || q.Reward.Gold != 205 || q.Reward.Exp != 270 || q.Reward.SPExp != 40 ||
		len(q.Reward.Items) != 1 || q.Reward.Items[0].Code != "ITEM_Q" || q.Source != SourceCompiled {
		t.Fatalf("%+v", q)
	}
}

// onKill credits a kill with every drop granted: KillCredits then Credit,
// as the session's questOnKill does when the bag takes every drop.
func onKill(c *Catalog, l Log, code string, roll func(rate float64) bool) []Progress {
	var out []Progress
	for _, k := range c.KillCredits(l, code, roll) {
		if p, ok := Credit(l, k); ok {
			out = append(out, p)
		}
	}
	return out
}
