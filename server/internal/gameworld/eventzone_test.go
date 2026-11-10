package gameworld

import (
	"context"
	"encoding/binary"
	"fmt"
	"math"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/nest"
	"github.com/TheOpenSRO/OpenSRO/server/internal/reftable"
	"github.com/TheOpenSRO/OpenSRO/server/internal/trigger"
)

// doorRef is world 63 with one trigger: hive 677 killed opens
// POS_STRUCTURE_GOD_BIG_GATE_TOGUI_3 and says so (forgotten_world.md 6's
// NOMAL_MONSTER_4), and the zone's event-zone row.
func doorRef(t *testing.T) *Ref {
	t.Helper()
	tabs := map[string]*reftable.Table{}
	w := reftable.New("ID", "WorldCodeName128", "Type", "WorldMaxCount", "WorldMaxUserCount", "WorldDurationTime", "WorldEmptyRemainTime")
	w.Append("63", "INS_GOD_TOGUI_35_50_LEVEL_1", "1", "50", "4", "7200000", "600000")
	tabs[TableWorld] = w
	ez := reftable.New("Service", "ID", "ZoneName", "EventName", "Param1", "Param2", "Param3", "Param4", "Param5",
		"strParam1", "strParam2", "strParam3", "strParam4", "strParam5")
	ez.Append("1", "238", "POS_STRUCTURE_GOD_BIG_GATE_TOGUI_3", "OBJECT", "4", "2", "0", "0", "0", "STRUCTURE_GOD_BIG_GATE_TOGUI_3", "xxx", "xxx", "xxx", "xxx")
	tabs[TableEventZone] = ez
	com := reftable.New("Service", "ID", "CodeName128", "TID1")
	com.Append("1", "5", trigger.EventMonsterKill, "1")
	com.Append("1", "9", trigger.CondHiveKill, "2")
	com.Append("1", "14", trigger.ActActiveNest, "3")
	com.Append("1", "17", trigger.ActSwitchEventZone, "3")
	com.Append("1", "20", trigger.ActNotifyWindow, "3")
	tabs["_RefTriggerCommon"] = com
	tr := reftable.New("Service", "ID", "CodeName128", "IsActive", "IsRepeat")
	tr.Append("1", "173", "TRI_GOD_TOGUI_35_50_NOMAL_MONSTER_4", "1", "0")
	tabs["_RefTrigger"] = tr
	ev := reftable.New("Service", "ID", "RefTriggerCommonID")
	ev.Append("1", "1", "5")
	tabs["_RefTriggerEvent"] = ev
	be := reftable.New("Service", "ID", "TriggerID", "TriggerEventID")
	be.Append("1", "1", "173", "1")
	tabs["_RefTriggerBindEvent"] = be
	c := reftable.New("Service", "ID", "RefTriggerCommonID", "OnTrue", "OnFalse", "Sequence", "ParamGroupCodeName128")
	c.Append("1", "1", "9", "RETURN_TRUE", "RETURN_FALSE", "0", "C1")
	tabs["_RefTriggerCondition"] = c
	bc := reftable.New("Service", "ID", "TriggerID", "TriggerConditionID")
	bc.Append("1", "1", "173", "1")
	tabs["_RefTriggerBindCondition"] = bc
	cp := reftable.New("Service", "ID", "GroupCodeName128", "ValueCodeName128", "Value", "Type")
	cp.Append("1", "1", "C1", "HIVE_MONSTER_SELECT", "677", "INT32")
	tabs["_RefTriggerConditionParam"] = cp
	a := reftable.New("Service", "ID", "RefTriggerCommonID", "Delay", "ParamGroupCodeName128")
	a.Append("1", "1", "17", "0", "A1")
	a.Append("1", "2", "14", "0", "A2")
	a.Append("1", "3", "20", "0", "A3")
	tabs["_RefTriggerAction"] = a
	ba := reftable.New("Service", "ID", "TriggerID", "TriggerActionID")
	ba.Append("1", "1", "173", "1")
	ba.Append("1", "2", "173", "2")
	ba.Append("1", "3", "173", "3")
	tabs["_RefTriggerBindAction"] = ba
	ap := reftable.New("Service", "ID", "GroupCodeName128", "ValueCodeName128", "Value", "Type")
	ap.Append("1", "1", "A1", "EVENT_ZONE_SELECT", "POS_STRUCTURE_GOD_BIG_GATE_TOGUI_3", "STRING")
	ap.Append("1", "2", "A1", "ON_OFF_SWITCH", "ON", "STRING")
	ap.Append("1", "3", "A2", "NEST_MONSTER_SELECT", "30126", "INT32")
	ap.Append("1", "4", "A3", "STRING_INPUT", "UIIT_MGS_GOD_TRIGGER_NOTICE_COMMON_OPEN_DOOR", "STRING")
	ap.Append("1", "5", "A3", "TARGET_PLAYER_INS_SELECT", "TARGET_PLAYER_ALL", "STRING")
	tabs["_RefTriggerActionParam"] = ap
	cat := reftable.New("Service", "ID", "CodeName128")
	cat.Append("1", "4", "TRI_CATEGORY_GOD_TOGUI_35_50_NOMAL_MONSTER")
	tabs["_RefTriggerCategory"] = cat
	cbt := reftable.New("Service", "ID", "TriggerCategoryID", "TriggerID")
	cbt.Append("1", "1", "4", "173")
	tabs["_RefTriggerCategoryBindTrigger"] = cbt
	wb := reftable.New("Service", "ID", "GameWorldID", "TriggerCategoryID")
	wb.Append("1", "1", "63", "4")
	tabs["_RefGameWorldBindTriggerCategory"] = wb
	ref, err := Build(func(n string) *reftable.Table { return tabs[n] })
	if err != nil {
		t.Fatal(err)
	}
	return ref
}

// TestWorldRunsItsScript: on the world's own goroutine a hive's last kill
// opens the door (0x351E state 1, the closed door no longer blocks), wakes
// the dormant nest and sends the notice; the door blocked a move while
// closed (OURS mechanism, game_worlds.md 14 item 9).
func TestWorldRunsItsScript(t *testing.T) {
	var switched []string
	var msgs []string
	m := NewManager(ManagerConfig{Ref: doorRef(t), Hooks: Hooks{
		ZoneSwitched: func(w *World, z *EventZoneObj) {
			switched = append(switched, fmt.Sprintf("%08x:% x", z.UID, EncodeEventZoneState(z.UID, z.WireState())[4:]))
		},
		Message: func(w *World, kind uint8, key string, targets []int64) {
			msgs = append(msgs, fmt.Sprintf("%d %s %v", kind, key, targets))
		},
	}})
	m.SetZonePlaces(map[string]ZonePlace{"POS_STRUCTURE_GOD_BIG_GATE_TOGUI_3": {Region: 0x7EE4, X: 500, Z: 500}})
	w, err := m.Open(context.Background(), 63, 1, 0)
	if err != nil {
		t.Fatal(err)
	}
	z := w.Zone("POS_STRUCTURE_GOD_BIG_GATE_TOGUI_3")
	if z == nil || !z.Closed() || z.StructureCode != "STRUCTURE_GOD_BIG_GATE_TOGUI_3" || z.Ref.ID != 238 {
		t.Fatalf("zone %+v", z)
	}
	if !doorBlocks(w, 400, 500, 600, 500) || doorBlocks(w, 400, 600, 600, 600) {
		t.Fatal("a closed door does not block the move through it, or blocks one 100 away")
	}
	// The hive: two nests of 677 (caps 2 and 1) and the dormant 30126.
	sched := nest.NewScheduler(nil, func(sl *nest.Slot, roll nest.HatchRoll, dx, dz float64) (int64, bool, bool) {
		mon := w.Monsters.SpawnSpecies("x", combat.Species{Name: "m"}, 0, 0, 0, 1, 1, 1, 0)
		w.NoteHatched(mon.ID, trigger.Monster{Hive: map[int64]int64{1: 677, 2: 677, 30126: 684}[sl.ID]})
		return mon.ID, true, false
	})
	dormant := &nest.Slot{ID: 30126, Cap: 1, Budget: 1, Active: false}
	w.Post(func() {
		w.SetNests(sched)
		w.AddNest(&nest.Slot{ID: 1, Cap: 2, Budget: 2, Active: true}, 677)
		w.AddNest(&nest.Slot{ID: 2, Cap: 1, Budget: 1, Active: true}, 677)
		w.AddNest(dormant, 684)
	})
	w.Post(func() {
		for id := int64(100); id <= 102; id++ {
			w.NoteHatched(id, trigger.Monster{Hive: 677})
		}
	})
	w.Sync()
	w.Enter(7, 40)
	for i := 0; i < 2; i++ {
		w.MonsterKilled(combat.Monster{ID: int64(100 + i)}, 7, 40)
	}
	w.Sync()
	if len(switched) != 0 || dormant.Active {
		t.Fatal("fired before the hive's sum (3) of kills")
	}
	w.MonsterKilled(combat.Monster{ID: 102}, 7, 40)
	w.Sync()
	want := fmt.Sprintf("[%08x:10 01]", z.UID)
	if fmt.Sprint(switched) != want || !dormant.Active || len(msgs) != 1 || msgs[0] != "1 UIIT_MGS_GOD_TRIGGER_NOTICE_COMMON_OPEN_DOOR [7]" {
		t.Fatalf("switched %v (want %s), nest woken %v, messages %v", switched, want, dormant.Active, msgs)
	}
	if z.Closed() || doorBlocks(w, 400, 500, 600, 500) {
		t.Fatal("the open door still blocks")
	}
	w.Close(CloseManual)
	_ = time.Second
}

// TestStructureRecordBytes: the gate's spawn record as MEASURED
// (forgotten_world.md 4): {19556, uid, region, x, y, z, angle, 1, 0, 1, 6,
// str name, u32 35883} and the single spawn's trailer; and 0x351E's bytes.
func TestStructureRecordBytes(t *testing.T) {
	r := StructureRecord{RefObjID: 19556, UID: 0x01020304, Region: 0x61A8, X: 1, Y: 2, Z: 3, Angle: 0x4000, B260: 1, State: 0,
		Gate: &GateTail{Restricted: 1, Access: 6, OwnerName: "Aria", HoleRefID: 35883}}
	got := r.Encode(true)
	var want []byte
	want = binary.LittleEndian.AppendUint32(want, 19556)
	want = binary.LittleEndian.AppendUint32(want, 0x01020304)
	want = binary.LittleEndian.AppendUint16(want, 0x61A8)
	for _, f := range []float32{1, 2, 3} {
		want = binary.LittleEndian.AppendUint32(want, math.Float32bits(f))
	}
	want = binary.LittleEndian.AppendUint16(want, 0x4000)
	want = append(want, 1, 0, 1, 6, 4, 0, 'A', 'r', 'i', 'a')
	want = binary.LittleEndian.AppendUint32(want, 35883)
	want = append(want, 1)
	if fmt.Sprintf("% x", got) != fmt.Sprintf("% x", want) {
		t.Errorf("gate record\n got % x\nwant % x", got, want)
	}
	party := StructureRecord{RefObjID: 19556, UID: 1, Gate: &GateTail{Restricted: 1, Access: 7, PartyID: 0xAABBCCDD, HoleRefID: 35883}}.Encode(false)
	if tail := party[len(party)-8:]; fmt.Sprintf("% x", tail) != "dd cc bb aa 2b 8c 00 00" {
		t.Errorf("type-7 tail % x", tail)
	}
	// Round 870: any access type but 6 carries the u32 (+0x258), not a name
	// (READ c:0x56dfa0).
	other := StructureRecord{RefObjID: 19556, UID: 1, Gate: &GateTail{Restricted: 1, Access: 5, OwnerName: "Aria", PartyID: 9, HoleRefID: 35883}}.Encode(false)
	if tail := other[24:]; fmt.Sprintf("% x", tail) != "00 00 01 05 09 00 00 00 2b 8c 00 00" {
		t.Errorf("type-5 tail % x", tail)
	}
	// Round 870: a door's record is the whole runtime-structure record
	// (u8 +0x254, u8 +0x255, u32 +0x258, u32 +0x25c) before the zone and its
	// u8 (READ c:0x535980 -> c:0x56dfa0).
	door := StructureRecord{RefObjID: DoorRefObjID, UID: 2, B260: 1, Door: &DoorTail{ZoneKey: 238}}.Encode(true)
	if len(door) != 24+2+2+4+4+4+1+1 {
		t.Fatalf("door record is %d bytes: % x", len(door), door)
	}
	if tail := door[24:]; fmt.Sprintf("% x", tail) != "01 00 00 00 00 00 00 00 00 00 00 00 ee 00 00 00 00 01" {
		t.Errorf("door tail % x", tail)
	}
	if got := fmt.Sprintf("% x", EncodeEventZoneState(0x7d000001, 1)); got != "01 00 00 7d 10 01" {
		t.Errorf("0x351E % x", got)
	}
	if got := fmt.Sprintf("% x", EncodeTriggerNotice(2, "AB")); got != "1c 0c 02 02 00 41 42" {
		t.Errorf("0x300C 0x0C1C % s", got)
	}
	if got := fmt.Sprintf("% x", EncodeGroupCoolTime(1, 18000*time.Second)); got != "0c 01 00 00 00 50 46 00 00" {
		t.Errorf("0x320C %s", got)
	}
}

// TestCanEnterOrder: CanEnter's checks in the READ order, one at a time.
func TestCanEnterOrder(t *testing.T) {
	m := testManager(t, nil, Hooks{})
	w, err := m.Open(context.Background(), 63, 1, 0)
	if err != nil {
		t.Fatal(err)
	}
	now := w.Clock().Now()
	ok := Entrant{CharID: 1, Level: 40}
	cases := []struct {
		name string
		e    func(e *Entrant)
		want uint16
	}{
		{"allowed", func(e *Entrant) {}, 0},
		{"job suit", func(e *Entrant) { e.JobSuit = true }, CodeJobSuit},
		{"level low", func(e *Entrant) { e.Level = 34 }, CodeLevel},
		{"level high", func(e *Entrant) { e.Level = 51 }, CodeLevel},
		{"riding", func(e *Entrant) { e.Riding = true }, CodeRiding},
		{"trade transport", func(e *Entrant) { e.TradeCOS = true }, CodeTradeCOS},
		{"cool time, other instance", func(e *Entrant) { e.CoolTimes = []CoolTime{{Group: 1, Key: w.Key + 1, End: now.Add(time.Hour)}} }, CodeCoolTime},
		{"cool time, this instance", func(e *Entrant) { e.CoolTimes = []CoolTime{{Group: 1, Key: w.Key, End: now.Add(time.Hour)}} }, 0},
		{"cool time run out", func(e *Entrant) { e.CoolTimes = []CoolTime{{Group: 1, Key: w.Key + 1, End: now.Add(-time.Second)}} }, 0},
		{"busy", func(e *Entrant) { e.Busy = true }, 2},
		{"job suit before level", func(e *Entrant) { e.JobSuit, e.Level = true, 1 }, CodeJobSuit},
		{"level before riding", func(e *Entrant) { e.Level, e.Riding = 1, true }, CodeLevel},
	}
	for _, c := range cases {
		e := ok
		c.e(&e)
		if got := CanEnter(w, e, now); got != c.want {
			t.Errorf("%s: %#x, want %#x", c.name, got, c.want)
		}
	}
	for i := int64(0); i < 4; i++ {
		w.Enter(100+i, 40)
	}
	if got := CanEnter(w, Entrant{CharID: 1, Level: 1}, now); got != CodeMaxUsers {
		t.Errorf("full before level: %#x", got)
	}
	if got := CanEnter(w, Entrant{CharID: 1, Level: 40, GM: true}, now); got != 0 {
		t.Errorf("a GM in a full layer: %#x", got)
	}
	if ReplyCode(2) != 3 || ReplyCode(6) != 3 || ReplyCode(CodeLevel) != CodeLevel {
		t.Error("ReplyCode")
	}
	w.Close(CloseManual)
	if got := CanEnter(w, ok, now); ReplyCode(got) != 3 {
		t.Errorf("a closed layer: %#x", got)
	}
}

// doorBlocks is whether a move is stopped by a closed door (DoorStop).
func doorBlocks(w *World, x0, z0, x1, z1 float64) bool {
	_, _, b := w.DoorStop(x0, z0, x1, z1)
	return b
}
