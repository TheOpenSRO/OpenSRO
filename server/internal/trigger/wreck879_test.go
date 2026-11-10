package trigger

import (
	"fmt"
	"strings"
	"testing"
)

// Round 879: the Wrecked Ship's chain (world 81, forgotten_world.md) on a
// fake layer, as its script binds it (MEASURED, the data): three
// NOMAL_MONSTER steps on the standing hives wake the A, B and C areas'
// normals, each area's Envy, its elite and its nine follow, A and B open a
// gate each, C wakes the boss and the boss's kill gives the notice.
func wreckScript() ([]*Trigger, map[int64][3]int64) {
	nests := map[int64][3]int64{}
	add := func(hive, cap int64, dormant bool, ids ...int64) {
		d := int64(0)
		if dormant {
			d = 1
		}
		for _, id := range ids {
			nests[id] = [3]int64{hive, cap, d}
		}
	}
	add(996, 7, false, 32038, 32039, 32040, 32041)
	add(997, 7, false, 32042, 32043, 32044, 32045)
	add(998, 7, false, 32046, 32047, 32048, 32049, 32050, 32051, 32052, 32053, 32054, 32055)
	add(999, 9, true, 32056, 32057)
	add(1000, 1, true, 32058)
	add(1001, 1, true, 32059)
	add(1001, 9, true, 32060)
	add(1003, 9, true, 32061, 32062)
	add(1004, 1, true, 32063)
	add(1005, 9, true, 32064)
	add(1005, 1, true, 32065)
	add(1007, 1, true, 32066)
	add(1007, 9, true, 32067)
	add(1008, 1, true, 32068)
	add(1009, 1, true, 32069)
	add(1009, 9, true, 32070)
	with := func(n []Action, acts ...Action) []Action { return append(acts, n...) }
	load := Action{Kind: ActLoadMonster, Params: Params{"MONSTER_SELECT": {"MOB_GOD_GHOST_CURSE_B1"}, "NUM_INPUT_1": {"0"},
		"FLOAT_INPUT": {"1"}, "NUM_INPUT_2": {"1"}, "TARGET_PLAYER_INS_SELECT": {TargetRandom}}}
	ts := []*Trigger{
		hiveKill(98, 996, with(notice(pfx+"MONSTER_WRECK_IN_1", 0, TargetAll), wake(32056), wake(32057))...),
		hiveKill(99, 997, with(notice(pfx+"MONSTER_WRECK_IN_2", 0, TargetAll), wake(32061), wake(32062))...),
		hiveKill(100, 998, with(notice(pfx+"MONSTER_WRECK_IN_3", 0, TargetAll), wake(32066), wake(32067))...),
		hiveKill(102, 999, with(notice(pfx+"ENVY_WRECK_1", 0, TargetAll), wake(32058))...),
		hiveKill(103, 1000, wake(32059), wake(32060)),
		hiveKill(104, 1001, with(notice(pfx+"OPEN_DOOR", 0, TargetAll), door("POS_STRUCTURE_GOD_BIG_GATE_WRECK_B1_1"), load)...),
		hiveKill(105, 1003, with(notice(pfx+"ENVY_WRECK_2", 0, TargetAll), wake(32063))...),
		hiveKill(106, 1004, wake(32064), wake(32065)),
		hiveKill(107, 1005, with(notice(pfx+"OPEN_DOOR", 0, TargetAll), door("POS_STRUCTURE_GOD_BIG_GATE_WRECK_B1_2"))...),
		hiveKill(108, 1007, with(notice(pfx+"ENVY_WRECK_3", 0, TargetAll), wake(32068))...),
		hiveKill(109, 1008, with(notice(pfx+"BOSS", 0, TargetAll), wake(32069), wake(32070))...),
		{ID: 416, Code: "C_AREA_BOSS_KILL", Active: true, Event: EventMonsterKill,
			Conditions: []Condition{{Kind: CondMonsterKill, OnTrue: ChainReturnTrue, OnFalse: ChainReturnFalse,
				Params: Params{"MONSTER_SELECT": {"MOB_GOD_GHOST_UNDINE_B1"}}}},
			Actions: notice(pfx+"BOSS_KILL", 0, TargetAll)},
	}
	return ts, nests
}

func wreckNotices(f *fakeLayer) string {
	var keys []string
	for _, m := range f.msgs {
		if strings.HasPrefix(m, "1 ") {
			keys = append(keys, strings.TrimPrefix(strings.Fields(m)[1], pfx))
		}
	}
	return strings.Join(keys, " ")
}

// TestWreckChainStallsOneKillShort is the user's run: "I ran through it all
// and cleared every mob. There was one I couldn't see": hives 996 and 997
// cleared, hive 998 one monster short (a monster drawn under the deck, never
// struck) -- NOMAL_MONSTER_3 never fires, the C area stays asleep and the
// boss is never woken. The one kill then carries the chain on.
func TestWreckChainStallsOneKillShort(t *testing.T) {
	ts, nests := wreckScript()
	f := &fakeLayer{nests: nests, players: []int64{7}}
	e := NewEngine(ts, f)
	killHive(e, f, 996)
	killHive(e, f, 997)
	if got := f.HiveCap(998); got != 70 {
		t.Fatalf("hive 998's sum %d, want 70", got)
	}
	for i := 0; i < 69; i++ {
		e.Fire(Event{Kind: EventMonsterKill, User: 7, Monster: &Monster{Hive: 998, Code: "MOB_GOD_GHOST_COMMANDER_B1"}})
	}
	if got := wreckNotices(f); got != "MONSTER_WRECK_IN_1 MONSTER_WRECK_IN_2" {
		t.Fatalf("one short of hive 998: notices %q", got)
	}
	if fmt.Sprint(f.woken) != "[32056 32057 32061 32062]" {
		t.Fatalf("one short of hive 998: woken %v", f.woken)
	}
	e.Fire(Event{Kind: EventMonsterKill, User: 7, Monster: &Monster{Hive: 998, Code: "MOB_GOD_GHOST_COMMANDER_B1"}})
	if got := wreckNotices(f); got != "MONSTER_WRECK_IN_1 MONSTER_WRECK_IN_2 MONSTER_WRECK_IN_3" {
		t.Errorf("hive 998's last kill: notices %q", got)
	}
	if fmt.Sprint(f.woken) != "[32056 32057 32061 32062 32066 32067]" {
		t.Errorf("hive 998's last kill: woken %v", f.woken)
	}
}

// TestWreckChainToItsBoss kills every hive in the order a player meets them
// and wants every step in order: the nests woken, the two gates, the load at
// a player, the boss's notice, and the boss's kill.
func TestWreckChainToItsBoss(t *testing.T) {
	ts, nests := wreckScript()
	f := &fakeLayer{nests: nests, players: []int64{7}}
	e := NewEngine(ts, f)
	for _, h := range []int64{996, 997, 998, 999, 1000, 1001, 1003, 1004, 1005, 1007, 1008} {
		killHive(e, f, h)
	}
	wantWoken := "[32056 32057 32061 32062 32066 32067 32058 32059 32060 32063 32064 32065 32068 32069 32070]"
	if fmt.Sprint(f.woken) != wantWoken {
		t.Errorf("woken %v\nwant  %s", f.woken, wantWoken)
	}
	if got := fmt.Sprint(f.doors); got != "[POS_STRUCTURE_GOD_BIG_GATE_WRECK_B1_1 true POS_STRUCTURE_GOD_BIG_GATE_WRECK_B1_2 true]" {
		t.Errorf("doors %s", got)
	}
	if len(f.loads) != 1 || !strings.HasPrefix(f.loads[0], "MOB_GOD_GHOST_CURSE_B1 x1") {
		t.Errorf("loads %v", f.loads)
	}
	want := "MONSTER_WRECK_IN_1 MONSTER_WRECK_IN_2 MONSTER_WRECK_IN_3 ENVY_WRECK_1 OPEN_DOOR ENVY_WRECK_2 OPEN_DOOR ENVY_WRECK_3 BOSS"
	if got := wreckNotices(f); got != want {
		t.Fatalf("notices %q\nwant    %q", got, want)
	}
	// The boss's nine Seirens die first: no notice. Its own kill gives it,
	// whatever its hive's count.
	for i := 0; i < 9; i++ {
		e.Fire(Event{Kind: EventMonsterKill, User: 7, Monster: &Monster{Hive: 1009, Code: "MOB_GOD_GHOST_SEIREN_B1"}})
	}
	if got := wreckNotices(f); got != want {
		t.Fatalf("after the boss's Seirens: notices %q", got)
	}
	e.Fire(Event{Kind: EventMonsterKill, User: 7, Monster: &Monster{Hive: 1009, Code: "MOB_GOD_GHOST_UNDINE_B1"}})
	if got := wreckNotices(f); got != want+" BOSS_KILL" {
		t.Errorf("the boss's kill: notices %q", got)
	}
}
