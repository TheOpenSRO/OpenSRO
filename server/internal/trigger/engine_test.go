package trigger

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/reftable"
)

// fakeLayer is a layer for the engine: its nests (id -> hive, cap, dormant),
// the woken nests, the doors, the messages and the delayed actions, in order.
type fakeLayer struct {
	nests   map[int64][3]int64 // nest -> {hive, cap, dormant 1}
	woken   []int64
	doors   []string
	msgs    []string
	loads   []string
	players []int64
	pending []pendingAct
	now     time.Duration
	others  []string
}

type pendingAct struct {
	at time.Duration
	f  func()
}

func (f *fakeLayer) ActivateNest(id int64) bool {
	n, ok := f.nests[id]
	if !ok {
		return false
	}
	n[2] = 0
	f.nests[id] = n
	f.woken = append(f.woken, id)
	return true
}
func (f *fakeLayer) LoadMonster(code string, count int, num1 int64, targets []int64) {
	f.loads = append(f.loads, fmt.Sprintf("%s x%d -> %v", code, count, targets))
}
func (f *fakeLayer) SwitchEventZone(zone string, on bool) {
	f.doors = append(f.doors, fmt.Sprintf("%s %v", zone, on))
}
func (f *fakeLayer) Message(kind uint8, key string, targets []int64) {
	f.msgs = append(f.msgs, fmt.Sprintf("%d %s %v @%v", kind, key, targets, f.now))
}
func (f *fakeLayer) Players() []int64   { return f.players }
func (f *fakeLayer) PartyMaster() int64 { return 0 }
func (f *fakeLayer) Chance() float64    { return 0 }
func (f *fakeLayer) Pick(n int) int     { return 0 }
func (f *fakeLayer) Other(a Action, ev Event, t []int64) {
	f.others = append(f.others, a.Kind)
}
func (f *fakeLayer) After(d time.Duration, fn func()) {
	f.pending = append(f.pending, pendingAct{f.now + d, fn})
}
func (f *fakeLayer) HiveCap(hive int64) int {
	sum := 0
	for _, n := range f.nests {
		if n[0] == hive {
			sum += int(n[1])
		}
	}
	return sum
}

// advance runs the delayed actions due by now+d.
func (f *fakeLayer) advance(d time.Duration) {
	f.now += d
	sort.SliceStable(f.pending, func(i, j int) bool { return f.pending[i].at < f.pending[j].at })
	for len(f.pending) > 0 && f.pending[0].at <= f.now {
		p := f.pending[0]
		f.pending = f.pending[1:]
		p.f()
	}
}

// killHive kills every monster of the hive (its caps' sum), as the layer's
// MONSTER_KILL events, the user 7 at level 40.
func killHive(e *Engine, f *fakeLayer, hive int64) {
	for i := 0; i < f.HiveCap(hive); i++ {
		e.Fire(Event{Kind: EventMonsterKill, User: 7, UserLevel: 40, Monster: &Monster{ID: int64(i + 1), Hive: hive, Code: "MOB"}})
	}
}

func hiveKill(id int, hive int64, acts ...Action) *Trigger {
	return &Trigger{ID: id, Code: fmt.Sprintf("T%d", id), Active: true, Event: EventMonsterKill,
		Conditions: []Condition{{Kind: CondHiveKill, OnTrue: ChainReturnTrue, OnFalse: ChainReturnFalse,
			Params: Params{"HIVE_MONSTER_SELECT": {fmt.Sprint(hive)}}}}, Actions: acts}
}
func wake(nest int64) Action {
	return Action{Kind: ActActiveNest, Params: Params{"NEST_MONSTER_SELECT": {fmt.Sprint(nest)}}}
}
func door(z string) Action {
	return Action{Kind: ActSwitchEventZone, Params: Params{"EVENT_ZONE_SELECT": {z}, "ON_OFF_SWITCH": {"ON"}}}
}
func notice(key string, d time.Duration, target string) []Action {
	return []Action{
		{Kind: ActNotifyWindow, Delay: d, Params: Params{"STRING_INPUT": {key}, "TARGET_PLAYER_INS_SELECT": {target}}},
		{Kind: ActSystemWindow, Params: Params{"STRING_INPUT": {key}, "TARGET_PLAYER_INS_SELECT": {target}}},
	}
}

const pfx = "UIIT_MGS_GOD_TRIGGER_NOTICE_COMMON_"

// toguiScript is world 63's camp-1 line as forgotten_world.md 6 tabulates it
// (a part of the script: NOMAL_MONSTER_1, A_AREA_1..4, NOMAL_MONSTER_4, the
// C area's boss and its kill, and the entry notice).
func toguiScript() ([]*Trigger, map[int64][3]int64) {
	nests := map[int64][3]int64{}
	add := func(hive int64, caps []int64, dormant bool, ids ...int64) {
		for i, id := range ids {
			d := int64(0)
			if dormant {
				d = 1
			}
			nests[id] = [3]int64{hive, caps[i%len(caps)], d}
		}
	}
	add(675, []int64{3, 9, 1}, false, 30050, 30051, 30052) // the field's normal nests (a few)
	add(677, []int64{3}, false, 30070, 30071)
	add(679, []int64{1}, true, 30121)                                    // camp-1 Envy
	add(680, []int64{3}, true, 30115, 30116, 30117, 30118, 30119, 30120) // its six
	add(683, []int64{9}, true, 30122, 30123, 30124, 30125)               // 4 x 9
	add(684, []int64{1}, true, 30126)                                    // the general
	add(691, []int64{9}, false, 30205)
	add(692, []int64{1}, true, 30207) // the elder
	var a2 []Action
	for _, n := range []int64{30122, 30123, 30124, 30125} {
		a2 = append(a2, wake(n))
	}
	for i := 1; i <= 4; i++ {
		a2 = append(a2, door(fmt.Sprintf("POS_STRUCTURE_GOD_SMALL_GATE_TOGUI_A_%d", i)))
	}
	var a1 []Action
	for n := int64(30115); n <= 30120; n++ {
		a1 = append(a1, wake(n))
	}
	ts := []*Trigger{
		hiveKill(14, 675, append([]Action{wake(30121)}, notice(pfx+"ENVY_TOGUI_1", 0, TargetAll)...)...),
		hiveKill(173, 677, append([]Action{door("POS_STRUCTURE_GOD_BIG_GATE_TOGUI_3")}, notice(pfx+"OPEN_DOOR", 0, TargetAll)...)...),
		hiveKill(17, 679, a1...),
		hiveKill(18, 680, a2...),
		hiveKill(19, 683, wake(30126)),
		hiveKill(20, 684, append([]Action{door("POS_STRUCTURE_GOD_BIG_GATE_TOGUI_1")}, notice(pfx+"OPEN_DOOR", 0, TargetAll)...)...),
		hiveKill(27, 691, append([]Action{wake(30207)}, notice(pfx+"BOSS", 0, TargetAll)...)...),
		hiveKill(393, 692, notice(pfx+"BOSS_KILL", 0, TargetAll)...),
		{ID: 370, Code: "NOTICE", Active: true, Repeat: true, Event: EventWorldEntrance, Actions: notice(pfx+"MONSTER_KILL", 20*time.Second, TargetEventUser)},
	}
	return ts, nests
}

func TestToguiScriptOnFakeLayer(t *testing.T) {
	ts, nests := toguiScript()
	f := &fakeLayer{nests: nests, players: []int64{7, 8}}
	e := NewEngine(ts, f)

	// The entry notice: to the entering player only, the system line at once
	// and the banner 20 s later (each action's own Delay).
	e.Fire(Event{Kind: EventWorldEntrance, User: 7, UserLevel: 40})
	f.advance(19 * time.Second)
	if len(f.msgs) != 1 || f.msgs[0] != "2 "+pfx+"MONSTER_KILL [7] @0s" {
		t.Fatalf("at 19 s: %q", f.msgs)
	}
	f.advance(time.Second)
	if len(f.msgs) != 2 || f.msgs[1] != "1 "+pfx+"MONSTER_KILL [7] @20s" {
		t.Fatalf("at 20 s: %q", f.msgs)
	}
	f.msgs = nil

	// One kill short of the hive's sum does nothing; the last one fires.
	cap675 := f.HiveCap(675)
	for i := 0; i < cap675-1; i++ {
		e.Fire(Event{Kind: EventMonsterKill, User: 7, Monster: &Monster{Hive: 675}})
	}
	if len(f.woken) != 0 {
		t.Fatalf("woken before the hive's last kill: %v", f.woken)
	}
	e.Fire(Event{Kind: EventMonsterKill, User: 7, Monster: &Monster{Hive: 675}})
	// A kill past the sum does not fire it again (IsRepeat 0).
	e.Fire(Event{Kind: EventMonsterKill, User: 7, Monster: &Monster{Hive: 675}})
	for _, h := range []int64{679, 680, 683, 684, 677, 691, 692} {
		killHive(e, f, h)
	}
	wantWoken := []int64{30121, 30115, 30116, 30117, 30118, 30119, 30120, 30122, 30123, 30124, 30125, 30126, 30207}
	if fmt.Sprint(f.woken) != fmt.Sprint(wantWoken) {
		t.Errorf("woken %v, want %v", f.woken, wantWoken)
	}
	wantDoors := "[POS_STRUCTURE_GOD_SMALL_GATE_TOGUI_A_1 true POS_STRUCTURE_GOD_SMALL_GATE_TOGUI_A_2 true " +
		"POS_STRUCTURE_GOD_SMALL_GATE_TOGUI_A_3 true POS_STRUCTURE_GOD_SMALL_GATE_TOGUI_A_4 true " +
		"POS_STRUCTURE_GOD_BIG_GATE_TOGUI_1 true POS_STRUCTURE_GOD_BIG_GATE_TOGUI_3 true]"
	if fmt.Sprint(f.doors) != wantDoors {
		t.Errorf("doors %v", f.doors)
	}
	var keys []string
	for _, m := range f.msgs {
		keys = append(keys, strings.Fields(m)[0]+" "+strings.TrimPrefix(strings.Fields(m)[1], pfx))
	}
	want := "[1 ENVY_TOGUI_1 2 ENVY_TOGUI_1 1 OPEN_DOOR 2 OPEN_DOOR 1 OPEN_DOOR 2 OPEN_DOOR 1 BOSS 2 BOSS 1 BOSS_KILL 2 BOSS_KILL]"
	if fmt.Sprint(keys) != want {
		t.Errorf("notices %v\nwant %s", keys, want)
	}
	if strings.Contains(f.msgs[0], "[7 8]") == false {
		t.Errorf("TARGET_PLAYER_ALL: %q, want both players", f.msgs[0])
	}
}

func TestPillarChain(t *testing.T) {
	// The world-1 pillar shape (forgotten_world.md 2): rarity 0, monster
	// level 35..50, killer 35..57, then LOAD_MONSTER at the killer.
	cond := func(kind, sign string, n int, onTrue string) Condition {
		p := Params{"NUM_INPUT": {fmt.Sprint(n)}}
		if sign != "" {
			p["SIGN_SELECT"] = []string{sign}
		}
		return Condition{Kind: kind, OnTrue: onTrue, OnFalse: ChainReturnFalse, Params: p}
	}
	tr := &Trigger{ID: 29, Active: true, Repeat: true, Event: EventMonsterKill, Conditions: []Condition{
		cond(CondRarityKill, "", 0, ChainNext),
		cond(CondMonsterLevelKill, "SIGN_LEFT_BIG_EQUAL", 35, ChainNext),
		cond(CondMonsterLevelKill, "SIGN_RIGHT_BIG_EQUAL", 50, ChainNext),
		cond(CondUserLevel, "SIGN_LEFT_BIG_EQUAL", 35, ChainNext),
		cond(CondUserLevel, "SIGN_RIGHT_BIG_EQUAL", 57, ChainReturnTrue),
	}, Actions: []Action{{Kind: ActLoadMonster, Params: Params{"MONSTER_SELECT": {"MOB_GOD_PILLAR_TOGUI_35_50"},
		"FLOAT_INPUT": {"0.001"}, "NUM_INPUT_2": {"1"}, "TARGET_PLAYER_INS_SELECT": {TargetEventUser}}}}}
	f := &fakeLayer{players: []int64{7}}
	e := NewEngine([]*Trigger{tr}, f)
	for _, c := range []struct {
		rarity, level, user int
		fires               bool
	}{{0, 40, 40, true}, {0, 40, 40, true}, {1, 40, 40, false}, {0, 34, 40, false}, {0, 51, 40, false}, {0, 40, 58, false}, {0, 50, 57, true}} {
		before := len(f.loads)
		e.Fire(Event{Kind: EventMonsterKill, User: 7, UserLevel: c.user, Monster: &Monster{Rarity: c.rarity, Level: c.level}})
		if got := len(f.loads) > before; got != c.fires {
			t.Errorf("rarity %d level %d user %d: fired %v, want %v", c.rarity, c.level, c.user, got, c.fires)
		}
	}
}

// TestWorld63ScriptExport runs world 63's whole script from an operator's
// export (OPENSRO_GAMEWORLD_DIR, plus OPENSRO_TRIGGER_NESTS naming a
// Tab_RefNest dump for the hive sums): every hive killed in an order the
// script allows, until the boss's defeat notice. Skipped without them.
func TestWorld63ScriptExport(t *testing.T) {
	dir, nestFile := os.Getenv("OPENSRO_GAMEWORLD_DIR"), os.Getenv("OPENSRO_TRIGGER_NESTS")
	if dir == "" || nestFile == "" {
		t.Skip("OPENSRO_GAMEWORLD_DIR / OPENSRO_TRIGGER_NESTS not set")
	}
	tables := map[string]*reftable.Table{}
	for _, n := range TableNames {
		if tab, err := reftable.ReadFile(filepath.Join(dir, n+".csv")); err == nil {
			tables[n] = tab
		}
	}
	ref, err := BuildRef(func(n string) *reftable.Table { return tables[n] })
	if err != nil {
		t.Fatal(err)
	}
	nt, err := reftable.ReadFile(nestFile)
	if err != nil {
		t.Fatal(err)
	}
	ts := ref.ForWorld(63)
	hives := map[int64]bool{}
	for _, tr := range ts {
		for _, c := range tr.Conditions {
			if c.Kind == CondHiveKill {
				hives[c.Params.Int("HIVE_MONSTER_SELECT")] = true
			}
		}
	}
	nests := map[int64][3]int64{}
	for _, r := range nt.Rows {
		h := nt.Int(r, "dwHiveID")
		if hives[h] || h == 674 || h == 710 {
			nests[nt.Int(r, "dwNestID")] = [3]int64{h, nt.Int(r, "dwMaxTotalCount"), nt.Int(r, "btType")}
		}
	}
	f := &fakeLayer{nests: nests, players: []int64{7}}
	e := NewEngine(ts, f)
	e.Fire(Event{Kind: EventWorldEntrance, User: 7, UserLevel: 40})
	f.advance(20 * time.Second)
	// Kill every hive whose nests are all awake, until nothing is left.
	killed := map[int64]bool{}
	for progress := true; progress; {
		progress = false
		var ids []int64
		for h := range hives {
			ids = append(ids, h)
		}
		sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })
		for _, h := range ids {
			if killed[h] {
				continue
			}
			awake := true
			for _, n := range nests {
				if n[0] == h && n[2] != 0 {
					awake = false
				}
			}
			if awake {
				killHive(e, f, h)
				killed[h] = true
				progress = true
			}
		}
	}
	if len(killed) != len(hives) {
		t.Errorf("killed %d of %d hives; the rest never woke", len(killed), len(hives))
	}
	last := f.msgs[len(f.msgs)-1]
	if !strings.Contains(last, "BOSS_KILL") {
		t.Errorf("last notice %q, want the boss kill", last)
	}
	t.Logf("world 63: %d triggers, %d hives, %d nests woken, %d doors, %d notices", len(ts), len(hives), len(f.woken), len(f.doors), len(f.msgs))
}
