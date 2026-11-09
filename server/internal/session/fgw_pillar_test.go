package session

// Round 869 lane W3 (forgotten_world.md 11 SERVER item 6): the ENVY_DROP
// pillar's hole drops on a seeded source (READ s:0x724a00's roll: a 0..1 row
// attempts half the time, so 0.3 falls 15 % of the kills), the pillar's
// summon at its death, and the world-1 pillar trigger's 0.1 % on a seeded
// layer source; death inside an instance.

import (
	"context"
	"math"
	"math/rand"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gameworld"
	"github.com/TheOpenSRO/OpenSRO/server/internal/grounditem"
	"github.com/TheOpenSRO/OpenSRO/server/internal/reftable"
	"github.com/TheOpenSRO/OpenSRO/server/internal/trigger"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// envyDropRef is world 1 with the 35-50 ENVY_DROP's measured rows and the
// 35-50 pillar trigger (MEASURED shape: rarity 0, the monster's level 35..50
// and the killer's 35..57, FLOAT_INPUT 0.001).
func envyDropRef(t *testing.T) *gameworld.Ref {
	t.Helper()
	tabs := map[string]*reftable.Table{}
	w := reftable.New("ID", "WorldCodeName128", "Type", "WorldMaxCount", "WorldMaxUserCount")
	w.Append("1", "INS_DEFAULT", "0", "1", "0")
	tabs[gameworld.TableWorld] = w
	d := reftable.New("RefMonsterID", "RefItemID", "DropGroupType", "OptLevel", "DropAmountMin", "DropAmountMax", "DropRatio")
	d.Append("36048", "35883", "0", "0", "0", "1", "0.3")
	d.Append("36048", "35884", "0", "0", "0", "1", "0.2")
	tabs[gameworld.TableAssignedDrop] = d
	tr := reftable.New("Service", "ID", "CodeName128", "IsActive", "IsRepeat", "IndexNumber")
	tr.Append("1", "1", "TRI_GOD_PILLAR_35_50", "1", "1", "0")
	tabs["_RefTrigger"] = tr
	cat := reftable.New("Service", "ID", "CodeName128")
	cat.Append("1", "1", "TRI_CATEGORY_GOD_PILLAR")
	tabs["_RefTriggerCategory"] = cat
	cb := reftable.New("Service", "ID", "TriggerCategoryID", "TriggerID")
	cb.Append("1", "1", "1", "1")
	tabs["_RefTriggerCategoryBindTrigger"] = cb
	wb := reftable.New("Service", "ID", "GameWorldID", "TriggerCategoryID")
	wb.Append("1", "1", "1", "1")
	tabs["_RefGameWorldBindTriggerCategory"] = wb
	common := reftable.New("Service", "ID", "CodeName128", "TID1")
	for i, c := range []struct{ code, tid string }{{trigger.EventMonsterKill, "1"}, {trigger.CondRarityKill, "2"},
		{trigger.CondMonsterLevelKill, "2"}, {trigger.CondUserLevel, "2"}, {trigger.ActLoadMonster, "3"}} {
		common.Append("1", itoa(i+1), c.code, c.tid)
	}
	tabs["_RefTriggerCommon"] = common
	ev := reftable.New("Service", "ID", "RefTriggerCommonID")
	ev.Append("1", "1", "1")
	tabs["_RefTriggerEvent"] = ev
	be := reftable.New("Service", "ID", "TriggerID", "TriggerEventID")
	be.Append("1", "1", "1", "1")
	tabs["_RefTriggerBindEvent"] = be
	cond := reftable.New("Service", "ID", "RefTriggerCommonID", "OnTrue", "OnFalse", "Sequence", "ParamGroupCodeName128")
	cp := reftable.New("Service", "ID", "GroupCodeName128", "ValueCodeName128", "Value")
	bc := reftable.New("Service", "ID", "TriggerID", "TriggerConditionID")
	addCond := func(id, common int, seq int, params map[string]string) {
		g := "C" + itoa(id)
		cond.Append("1", itoa(id), itoa(common), "NEXT", "RETURN_FALSE", itoa(seq), g)
		for k, v := range params {
			cp.Append("1", itoa(len(cp.Rows)+1), g, k, v)
		}
		bc.Append("1", itoa(id), "1", itoa(id))
	}
	addCond(1, 2, 1, map[string]string{"NUM_INPUT": "0"})
	addCond(2, 3, 2, map[string]string{"SIGN_SELECT": "SIGN_LEFT_BIG_EQUAL", "NUM_INPUT": "35"})
	addCond(3, 3, 3, map[string]string{"SIGN_SELECT": "SIGN_RIGHT_BIG_EQUAL", "NUM_INPUT": "50"})
	addCond(4, 4, 4, map[string]string{"SIGN_SELECT": "SIGN_LEFT_BIG_EQUAL", "NUM_INPUT": "35"})
	addCond(5, 4, 5, map[string]string{"SIGN_SELECT": "SIGN_RIGHT_BIG_EQUAL", "NUM_INPUT": "57"})
	tabs["_RefTriggerCondition"], tabs["_RefTriggerConditionParam"], tabs["_RefTriggerBindCondition"] = cond, cp, bc
	act := reftable.New("Service", "ID", "RefTriggerCommonID", "Delay", "ParamGroupCodeName128")
	act.Append("1", "1", "5", "0", "A1")
	tabs["_RefTriggerAction"] = act
	ap := reftable.New("Service", "ID", "GroupCodeName128", "ValueCodeName128", "Value")
	for i, kv := range [][2]string{{"MONSTER_SELECT", "MOB_GOD_PILLAR_TOGUI_35_50"}, {"FLOAT_INPUT", "0.001"}, {"NUM_INPUT_1", "0"},
		{"NUM_INPUT_2", "1"}, {"TARGET_PLAYER_INS_SELECT", "TARGET_PLAYER_EVENT_USER"}} {
		ap.Append("1", itoa(i+1), "A1", kv[0], kv[1])
	}
	tabs["_RefTriggerActionParam"] = ap
	ba := reftable.New("Service", "ID", "TriggerID", "TriggerActionID")
	ba.Append("1", "1", "1", "1")
	tabs["_RefTriggerBindAction"] = ba
	ref, err := gameworld.Build(func(n string) *reftable.Table { return tabs[n] })
	if err != nil {
		t.Fatal(err)
	}
	return ref
}

func TestEnvyDropHoles(t *testing.T) {
	ref := envyDropRef(t)
	m := gameworld.NewManager(gameworld.ManagerConfig{Ref: ref})
	SetGameWorlds(m)
	defer SetGameWorlds(nil)
	fgwDropRand = rand.New(rand.NewSource(869))
	envy := combat.Monster{ID: 1, RefObjID: 36048, CodeName: "MOB_GOD_PILLAR_ENVY_DROP_35_50"}
	const kills = 200000
	n := map[int64]int{}
	for i := 0; i < kills; i++ {
		for _, d := range fgwAssignedDrops(envy) {
			n[d.ItemID]++
		}
	}
	for item, want := range map[int64]float64{35883: 0.15, 35884: 0.10} {
		if got := float64(n[item]) / kills; math.Abs(got-want) > 0.004 {
			t.Errorf("item %d per kill %.4f, want %.2f (0..1 attempts x the ratio)", item, got, want)
		}
	}
	// Outside the Forgotten World's scope: the rows are not served.
	if d := fgwAssignedDrops(combat.Monster{RefObjID: 36048, CodeName: "MOB_CH_MANGNYANG"}); len(d) != 0 {
		t.Errorf("a non-MOB_GOD_ monster dropped %v", d)
	}
	// dropsForKill adds them to the group drops (none here).
	got := 0
	for i := 0; i < 1000; i++ {
		got += len(dropsForKill(context.Background(), nil, envy))
	}
	if got == 0 {
		t.Error("dropsForKill served no hole in 1000 kills")
	}
}

// TestPillarTriggerAndSummon: a kill in band loads the pillar at the killer
// at 0.1 % (seeded: exactly once in 10,000 eligible kills with this seed's
// draws is not asserted -- the rate is), and the pillar's death runs the
// summon hook into its world.
func TestPillarTriggerAndSummon(t *testing.T) {
	ref := envyDropRef(t)
	hub, monsters := world.NewHub(), combat.NewHub()
	var loads, summons int
	m := gameworld.NewManager(gameworld.ManagerConfig{Ref: ref, Hooks: gameworld.Hooks{
		LoadMonster: func(w *gameworld.World, code string, count int, num1 int64, targets []int64) {
			if code == "MOB_GOD_PILLAR_TOGUI_35_50" && count == 1 && len(targets) == 1 && targets[0] == 7 {
				loads++
			}
		}}})
	w := m.AttachOpenWorld(hub, monsters, grounditem.NewHub())
	SetGameWorlds(m)
	defer SetGameWorlds(nil)
	SetGameWorldDeps(GameWorldDeps{PillarSummon: func(pw *gameworld.World, p combat.Monster) []int64 {
		if pw == w && p.CodeName == "MOB_GOD_PILLAR_TOGUI_35_50" {
			summons++
		}
		return nil
	}})
	defer SetGameWorldDeps(GameWorldDeps{})
	const kills = 100000
	for i := 0; i < kills; i++ {
		w.MonsterKilled(combat.Monster{ID: int64(i + 1), CodeName: "MOB_X", Rarity: 0, Level: 40}, 7, 40)
	}
	// Out of band: the killer at 58, a champion, a monster at 51.
	w.MonsterKilled(combat.Monster{ID: 1, Level: 40}, 7, 58)
	w.MonsterKilled(combat.Monster{ID: 2, Rarity: 1, Level: 40}, 7, 40)
	w.MonsterKilled(combat.Monster{ID: 3, Level: 51}, 7, 40)
	w.Sync()
	if rate := float64(loads) / kills; math.Abs(rate-0.001) > 0.0004 {
		t.Errorf("pillar loads %d in %d kills (%.5f), want about 0.001", loads, kills, rate)
	}
	fgwPillarDied(hub, combat.Monster{ID: 9, CodeName: "MOB_GOD_PILLAR_TOGUI_35_50"})
	fgwPillarDied(hub, combat.Monster{ID: 10, CodeName: "MOB_GOD_PILLAR_ENVY_DROP_35_50"})
	if summons != 1 {
		t.Errorf("summons %d, want the pillar's one (an Envy's death summons nothing)", summons)
	}
}

// TestDeathInside: a member dying inside and taking the return-point revive
// leaves the layer for the open world (OURS rule, the original's OPEN): the
// layer counts it out and its empty close starts.
func TestDeathInside(t *testing.T) {
	rig := newGWRig(t, nil, map[string]int{"Aria": 40})
	w := rig.open(t)
	aria := rig.players["Aria"]
	if err := EnterInstance(context.Background(), aria.sess, w, "test"); err != nil {
		t.Fatal(err)
	}
	rig.until("Aria", OpChangeZoneResult)
	for i := 0; i < 100 && len(w.Members()) == 0; i++ {
		time.Sleep(5 * time.Millisecond)
	}
	w.Hub.SetLifeState(aria.charID, world.LifeAlive, world.LifeDead, time.Now())
	if moved, err := warpHome(context.Background(), aria.sess, nil, rig.chars, w.Hub, nil, "death: return point"); err != nil || !moved {
		t.Fatalf("warpHome %v %v", moved, err)
	}
	rig.until("Aria", OpChangeZoneResult)
	for i := 0; i < 100 && len(w.Members()) != 0; i++ {
		time.Sleep(5 * time.Millisecond)
	}
	if _, ok := rig.hub.EntityByCharacterID(aria.charID); !ok || len(w.Members()) != 0 {
		t.Fatalf("after the revive: in the open world %v, members %v", ok, w.Members())
	}
	if w.EmptySince().IsZero() {
		t.Error("the layer's empty close did not start")
	}
}
